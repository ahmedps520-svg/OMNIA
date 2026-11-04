import Foundation
import llama
import os

private let llamaLog = Logger(subsystem: "app.omnia", category: "llama.cpp")

/// Why a running generation was asked to stop.
enum InterruptReason: Sendable {
    case user, background, memoryPressure, thermal, unload
}

/// One llama.cpp model plus its inference context, confined to a private serial queue.
///
/// Written against llama.cpp b11960 (`include/llama.h`, v0.8.0). Every C call happens on
/// `queue`; the only cross-thread state is the interrupt flag and the pacing value, both
/// protected by unfair locks.
final class LlamaRuntime: @unchecked Sendable {
    let info: LoadedModelInfo

    private let queue: DispatchQueue
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private var batch: llama_batch
    private let batchCapacity: Int
    private var cachedTokens: [llama_token] = []
    private var isClosed = false
    /// The model's own Jinja chat template, when it compiles.
    private let templateRenderer: ChatTemplateRenderer?
    private let bosText: String
    private let addsBOS: Bool
    /// How the template expects tool calls; nil means OMNIA's text protocol (`ToolPrompt`).
    private let nativeToolFormat: ToolCallFormat?
    /// Recurrent and hybrid caches can't be trimmed back to a shared prefix, so a saved state
    /// would rarely be reusable; only attention-only models save conversation memory.
    private let canSaveState: Bool
    /// Where the layers are when the model is spread over a cluster; every step then checks that
    /// no worker dropped out.
    private let cluster: ClusterPlacement?
    /// A small model proposing tokens for speculative decoding, when one is attached.
    private var draft: DraftModel?
    /// The model's image encoder file (mmproj), when image support is installed.
    private var projectorURL: URL?
    /// llama.cpp's multimodal context (`mtmd_context`), loaded from `projectorURL` for the first
    /// prompt with an image.
    private var vision: OpaquePointer?
    /// Images held in the KV cache, by the index of their first cell. In `cachedTokens` their
    /// cells are `LLAMA_TOKEN_NULL`.
    private var cachedMedia: [Int: MediaSpan] = [:]

    private let interruptState = OSAllocatedUnfairLock<InterruptReason?>(initialState: nil)
    private let pacingNanoseconds = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    // MARK: Backend

    /// Sends llama.cpp's and its image encoder's messages to the unified log.
    private static let forwardLog: ggml_log_callback = { level, text, _ in
        guard let text else { return }
        let message = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        if level == GGML_LOG_LEVEL_ERROR {
            llamaLog.error("\(message, privacy: .public)")
        } else if level == GGML_LOG_LEVEL_WARN {
            llamaLog.warning("\(message, privacy: .public)")
        } else {
            llamaLog.debug("\(message, privacy: .public)")
        }
    }

    private static let backendReady: Void = {
        llama_log_set(LlamaRuntime.forwardLog, nil)
        mtmd_log_set(LlamaRuntime.forwardLog, nil)
        mtmd_helper_log_set(LlamaRuntime.forwardLog, nil)
        llama_backend_init()
    }()

    /// Initializes llama.cpp and routes its log, before anything else uses ggml (a cluster worker's
    /// server can start before any model loads).
    static func prepareBackend() {
        _ = backendReady
    }

    /// Where an image goes in a prompt for llama.cpp's multimodal tokenizer ("<__media__>").
    private static let mediaMarker = String(cString: mtmd_default_marker())

    static var engineVersion: String {
        _ = backendReady
        guard let version = llama_version() else { return "b11960" }
        return String(cString: version)
    }

    static var systemInfo: String {
        _ = backendReady
        guard let info = llama_print_system_info() else { return "" }
        return String(cString: info)
    }

    // MARK: Loading

    /// Loads weights, creates the context and runs a one-token warm-up so the first real
    /// prompt doesn't pay for Metal pipeline compilation. An image encoder (`projectorURL`)
    /// loads later, with the first image.
    static func load(modelID: String,
                     displayName: String,
                     fileURL: URL,
                     projectorURL: URL? = nil,
                     configuration: RuntimeConfiguration,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> LlamaRuntime {
        _ = backendReady
        let queue = DispatchQueue(label: "app.omnia.llama.\(modelID)", qos: .userInitiated)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let runtime = try LlamaRuntime(modelID: modelID, displayName: displayName, fileURL: fileURL,
                                                   projectorURL: projectorURL, configuration: configuration,
                                                   queue: queue, progress: progress)
                    continuation.resume(returning: runtime)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private final class ProgressBox {
        let report: @Sendable (Double) -> Void
        init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    }

    private init(modelID: String, displayName: String, fileURL: URL, projectorURL: URL?,
                 configuration: RuntimeConfiguration, queue: DispatchQueue,
                 progress: @escaping @Sendable (Double) -> Void) throws {
        self.queue = queue
        self.projectorURL = projectorURL
        let started = ContinuousClock.now
        let footprintBefore = SystemMetrics.processFootprint() ?? 0
        let gpuBefore = SystemMetrics.gpuAllocatedBytes() ?? 0

        let path = fileURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            throw InferenceError.modelFileMissing(displayName)
        }
        guard GGUFInspector.hasGGUFSignature(fileURL) else {
            throw InferenceError.invalidModelFile("it is not a GGUF file.")
        }

        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = configuration.gpuOffload ? 999 : 0
        #endif
        let progressBox = ProgressBox(progress)
        modelParams.progress_callback = { value, userData in
            if let userData {
                Unmanaged<ProgressBox>.fromOpaque(userData).takeUnretainedValue().report(Double(value))
            }
            return true
        }
        modelParams.progress_callback_user_data = Unmanaged.passUnretained(progressBox).toOpaque()

        let loadedModel: OpaquePointer?
        if let cluster = configuration.cluster {
            loadedModel = try withExtendedLifetime(progressBox) {
                try LlamaRuntime.loadOnCluster(path: path, cluster: cluster, configuration: configuration, params: modelParams)
            }
        } else {
            loadedModel = withExtendedLifetime(progressBox) {
                llama_model_load_from_file(path, modelParams)
            }
        }
        guard let loadedModel else {
            throw InferenceError.loadFailed("llama.cpp could not read this file. Its architecture may be newer than OMNIA's engine (llama.cpp b11960), or the file is damaged.")
        }

        // Context: retry once with an F16 cache if the quantized cache / flash-attention combo is unavailable.
        var effective = configuration
        var createdContext = LlamaRuntime.makeContext(model: loadedModel, configuration: effective)
        if createdContext == nil && effective.kvCacheType != .f16 {
            effective.kvCacheType = .f16
            effective.flashAttention = configuration.flashAttention
            createdContext = LlamaRuntime.makeContext(model: loadedModel, configuration: effective)
        }
        guard let createdContext else {
            llama_model_free(loadedModel)
            if let cluster = configuration.cluster, let lost = RPCBridge.failedEndpoints().first {
                throw InferenceError.clusterDeviceLost(cluster.name(of: lost))
            }
            throw InferenceError.contextCreationFailed("Try a shorter context length or a smaller model.")
        }
        guard let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_free(createdContext)
            llama_model_free(loadedModel)
            throw InferenceError.loadFailed("The model has no vocabulary.")
        }

        // llama_decode asserts if a batch exceeds the context's actual n_batch.
        let capacity = max(1, min(effective.batchSize, Int(llama_n_batch(createdContext))))
        var newBatch = llama_batch_init(Int32(capacity), 0, 1)
        effective.contextLength = Int(llama_n_ctx(createdContext))

        // Warm-up: run one token through the graph, then forget it.
        var warmupToken = llama_vocab_bos(loadedVocab)
        if warmupToken == LLAMA_TOKEN_NULL { warmupToken = 0 }
        newBatch.n_tokens = 0
        LlamaRuntime.add(&newBatch, token: warmupToken, position: 0, logits: true)
        _ = llama_decode(createdContext, newBatch)
        llama_synchronize(createdContext)
        llama_memory_clear(llama_get_memory(createdContext), true)
        // A worker that dropped out while the model loaded, or failed its first token.
        if let cluster = configuration.cluster, let lost = RPCBridge.failedEndpoints().first {
            llama_batch_free(newBatch)
            llama_free(createdContext)
            llama_model_free(loadedModel)
            throw InferenceError.clusterDeviceLost(cluster.name(of: lost))
        }

        let footprintAfter = SystemMetrics.processFootprint() ?? footprintBefore
        let gpuAfter = SystemMetrics.gpuAllocatedBytes() ?? gpuBefore
        let template = llama_model_chat_template(loadedModel, nil).map { String(cString: $0) }
        let bos = LlamaRuntime.tokenText(loadedVocab, llama_vocab_bos(loadedVocab))
        let eos = LlamaRuntime.tokenText(loadedVocab, llama_vocab_eos(loadedVocab))
        var renderer: ChatTemplateRenderer?
        if let template, !template.isEmpty {
            do {
                renderer = try ChatTemplateRenderer(source: template, bosToken: bos, eosToken: eos)
            } catch {
                llamaLog.warning("Chat template did not compile, using llama.cpp built-ins: \(error.localizedDescription, privacy: .public)")
            }
        }

        model = loadedModel
        context = createdContext
        vocab = loadedVocab
        batchCapacity = capacity
        batch = newBatch
        templateRenderer = renderer
        bosText = bos
        addsBOS = llama_vocab_get_add_bos(loadedVocab)
        nativeToolFormat = renderer == nil ? nil : ToolCallFormat.detect(template: template)
        cluster = configuration.cluster
        // A cluster's cache lives on its workers; saving it would pull all of it over the network.
        canSaveState = !llama_model_is_recurrent(loadedModel) && !llama_model_is_hybrid(loadedModel)
            && configuration.cluster == nil
        info = LoadedModelInfo(
            modelID: modelID,
            displayName: displayName,
            architecture: LlamaRuntime.metadata(loadedModel, key: "general.architecture") ?? "unknown",
            configuration: effective,
            trainContextLength: Int(llama_model_n_ctx_train(loadedModel)),
            parameterCount: llama_model_n_params(loadedModel),
            tensorBytes: llama_model_size(loadedModel),
            measuredFootprintBytes: footprintAfter > footprintBefore ? footprintAfter - footprintBefore : 0,
            measuredGPUBytes: gpuAfter > gpuBefore ? gpuAfter - gpuBefore : 0,
            loadDuration: started.secondsElapsed,
            chatTemplate: template,
            supportsThinkingToggle: template?.contains("enable_thinking") ?? false
        )
        progress(1)
    }

    /// Loads a model spread over a cluster: each worker's device takes its layers in pipeline order,
    /// then this device's GPU takes its own layers and the output layer (see `ClusterPlacement`).
    private static func loadOnCluster(path: String, cluster: ClusterPlacement, configuration: RuntimeConfiguration,
                                      params: llama_model_params) throws -> OpaquePointer? {
        guard RPCBridge.isAvailable else {
            throw InferenceError.loadFailed("This build of OMNIA was made without cluster support.")
        }
        RPCBridge.clearFailures()
        var devices: [OpaquePointer?] = []
        var shares: [Float] = []
        for slice in cluster.workers where slice.layers > 0 {
            let served = RPCBridge.devices(at: slice.endpoint)
            guard slice.device < served.count else { throw InferenceError.clusterDeviceLost(slice.name) }
            devices.append(served[slice.device])
            shares.append(Float(slice.layers))
        }

        var params = params
        params.split_mode = LLAMA_SPLIT_MODE_LAYER
        #if targetEnvironment(simulator)
        let hostGPU: OpaquePointer? = nil
        #else
        let hostGPU: OpaquePointer? = configuration.gpuOffload ? ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU) : nil
        #endif
        if let hostGPU {
            devices.append(hostGPU)
            shares.append(Float(cluster.hostLayers + 1))
            params.n_gpu_layers = 999
        } else {
            // Without a GPU here (the Simulator), this device's layers stay on its CPU, which
            // llama.cpp places first; the workers take the rest and the output layer.
            params.n_gpu_layers = Int32(cluster.workers.reduce(0) { $0 + $1.layers } + 1)
        }
        // llama.cpp reads llama_max_devices() proportions, in the order of the device list.
        var split = [Float](repeating: 0, count: max(Int(llama_max_devices()), shares.count))
        for (index, share) in shares.enumerated() { split[index] = share }
        devices.append(nil)
        let model = devices.withUnsafeMutableBufferPointer { deviceList in
            split.withUnsafeBufferPointer { splitList in
                params.devices = deviceList.baseAddress
                params.tensor_split = splitList.baseAddress
                return llama_model_load_from_file(path, params)
            }
        }
        // llama.cpp remembers a worker's devices, so one that vanished since it last loaded only
        // fails when its memory is allocated; that isn't the file's fault.
        if let lost = RPCBridge.failedEndpoints().first {
            if let model { llama_model_free(model) }
            throw InferenceError.clusterDeviceLost(cluster.name(of: lost))
        }
        return model
    }

    private static func makeContext(model: OpaquePointer, configuration: RuntimeConfiguration) -> OpaquePointer? {
        var params = llama_context_default_params()
        params.n_ctx = UInt32(configuration.contextLength)
        params.n_batch = UInt32(configuration.batchSize)
        params.n_ubatch = UInt32(min(configuration.microBatchSize, configuration.batchSize))
        params.n_seq_max = 1
        params.n_rs_seq = UInt32(max(0, configuration.rollbackDepth))
        params.n_threads = Int32(configuration.threads)
        params.n_threads_batch = Int32(configuration.threads)
        if configuration.kvCacheType.requiresFlashAttention {
            params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        } else {
            params.flash_attn_type = configuration.flashAttention ? LLAMA_FLASH_ATTN_TYPE_AUTO : LLAMA_FLASH_ATTN_TYPE_DISABLED
        }
        params.type_k = configuration.kvCacheType.ggmlType
        params.type_v = configuration.kvCacheType.ggmlType
        // On a cluster each layer's cache stays with the layer, on its worker.
        #if targetEnvironment(simulator)
        params.offload_kqv = configuration.cluster != nil
        #else
        params.offload_kqv = configuration.gpuOffload || configuration.cluster != nil
        #endif
        // Sliding-window layers keep only their window: far less memory for Gemma-style models.
        params.swa_full = false
        params.no_perf = true
        return llama_init_from_model(model, params)
    }

    private static func tokenText(_ vocab: OpaquePointer, _ token: llama_token) -> String {
        guard token != LLAMA_TOKEN_NULL, let text = llama_vocab_get_text(vocab, token) else { return "" }
        return String(cString: text)
    }

    private static func metadata(_ model: OpaquePointer, key: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = llama_model_meta_val_str(model, key, &buffer, buffer.count)
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: Control

    /// Asks the current generation or benchmark to stop after the token in flight.
    func interrupt(_ reason: InterruptReason) {
        interruptState.withLock { $0 = reason }
    }

    func setPacing(_ pacing: Duration) {
        let (seconds, attoseconds) = pacing.components
        let nanos = UInt64(max(0, seconds)) * 1_000_000_000 + UInt64(max(0, attoseconds / 1_000_000_000))
        pacingNanoseconds.withLock { $0 = nanos }
    }

    private var currentInterrupt: InterruptReason? { interruptState.withLock { $0 } }

    /// Releases the model and context. Waits for any running work to observe the interrupt.
    func close() async {
        interrupt(.unload)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.freeResources()
                continuation.resume()
            }
        }
    }

    private func freeResources() {
        guard !isClosed else { return }
        isClosed = true
        cachedTokens = []
        cachedMedia = [:]
        draft?.close()
        draft = nil
        // The image encoder refers to the model: it goes first.
        if let vision { mtmd_free(vision) }
        vision = nil
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    deinit {
        if !isClosed { freeResources() }
    }

    // MARK: Speculative decoding

    /// Loads a draft model for speculative decoding: one with this model's vocabulary, able to
    /// undo rejected tokens. A hybrid or recurrent model also needs `rollbackDepth` of at least
    /// `length` in its own configuration.
    func attachDraft(fileURL: URL, displayName: String, length: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard !self.isClosed else { throw InferenceError.loadFailed("The model was unloaded.") }
                    let needsRollback = llama_model_is_recurrent(self.model) || llama_model_is_hybrid(self.model)
                    if needsRollback && llama_n_rs_seq(self.context) < UInt32(length) {
                        throw DraftModel.Failure.noRollback
                    }
                    self.draft?.close()
                    self.draft = nil
                    let configuration = self.info.configuration
                    self.draft = try DraftModel(fileURL: fileURL, displayName: displayName, length: length,
                                                contextLength: configuration.contextLength,
                                                threads: configuration.threads, gpuOffload: configuration.gpuOffload,
                                                targetVocab: self.vocab)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func detachDraft() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.draft?.close()
                self.draft = nil
                continuation.resume()
            }
        }
    }

    // MARK: Images

    /// Memory iOS must still have free beyond the encoder's file size before it loads: room for
    /// the encoder's working memory while it reads an image.
    private static let visionHeadroom: UInt64 = 512 << 20

    /// Image support was added or removed. The old encoder is released once the generation in
    /// progress (if any) finishes; a new one loads with the next image.
    func setProjector(_ url: URL?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if !self.isClosed, url != self.projectorURL {
                    if let vision = self.vision { mtmd_free(vision) }
                    self.vision = nil
                    self.projectorURL = url
                }
                continuation.resume()
            }
        }
    }

    /// Loads the image encoder ahead of the first image, e.g. while the user writes about one.
    func prepareVision() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if !self.isClosed, self.projectorURL != nil { _ = try? self.visionContext() }
                continuation.resume()
            }
        }
    }

    /// The multimodal context, created on first use.
    private func visionContext() throws -> OpaquePointer {
        if let vision { return vision }
        guard let projectorURL else { throw InferenceError.imagesUnsupported(info.displayName) }
        let path = projectorURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { throw InferenceError.imageEncoderMissing }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        if let available = SystemMetrics.availableMemory(), available < size + Self.visionHeadroom {
            throw InferenceError.insufficientMemory(
                required: size + Self.visionHeadroom, available: available,
                suggestion: "Reading images needs the model's image encoder in memory too. Try a shorter context or a smaller model.")
        }

        var params = mtmd_context_params_default()
        #if targetEnvironment(simulator)
        params.use_gpu = false
        #else
        params.use_gpu = info.configuration.gpuOffload
        #endif
        params.n_threads = Int32(info.configuration.threads)
        params.print_timings = false
        params.warmup = false
        // Up to 1,024 tokens per image (a quarter of smaller contexts): sharp enough for
        // screenshots without crowding out the conversation.
        let preferred = min(1024, max(256, Int(llama_n_ctx(context)) / 4))
        params.image_max_tokens = Int32(preferred)
        var created = mtmd_init_from_file(path, model, params)
        // Encoders with bidirectional attention (Gemma 4 12B and 26B) must read a whole image in
        // one micro-batch, or llama.cpp aborts: make their images fit it.
        let batchLimit = min(Int(llama_n_ubatch(context)), batchCapacity)
        if let current = created, mtmd_decode_use_non_causal(current, nil), batchLimit < preferred {
            mtmd_free(current)
            params.image_max_tokens = Int32(batchLimit)
            created = mtmd_init_from_file(path, model, params)
        }
        guard let loaded = created else { throw InferenceError.imageEncoderFailed }
        guard mtmd_support_vision(loaded) else {
            mtmd_free(loaded)
            throw InferenceError.imageEncoderFailed
        }
        vision = loaded
        return loaded
    }

    /// Encodes one image and writes it into the cache at `position`, which it advances.
    private func evaluateImage(_ media: PromptMedia, position: inout Int) throws {
        guard let vision else { throw InferenceError.imagesUnsupported(info.displayName) }
        if mtmd_decode_use_non_causal(vision, media.chunk),
           media.span.tokenCount > min(Int(llama_n_ubatch(context)), batchCapacity) {
            throw InferenceError.imageFailed("It needs a larger batch than this model's context uses.")
        }
        var next = llama_pos(position)
        let status = mtmd_helper_eval_chunk_single(vision, context, media.chunk, llama_pos(position), 0,
                                                   Int32(batchCapacity), false, &next)
        guard status == 0 else {
            clearMemory()
            if currentInterrupt == .background { throw InferenceError.backgroundExecution }
            throw InferenceError.imageFailed("llama.cpp returned \(status) while reading it.")
        }
        position = Int(next)
    }

    /// Tokenizes a formatted prompt. With images, llama.cpp's multimodal tokenizer splits it into
    /// text and image chunks; an image's cells appear in `tokens` as `LLAMA_TOKEN_NULL`.
    private func tokenizePrompt(_ text: String, images: ImagePrompt, bitmaps: ImageBitmaps) throws -> TokenizedPrompt {
        let resolved = images.resolve(text, marker: Self.mediaMarker)
        guard !resolved.order.isEmpty else {
            return TokenizedPrompt(tokens: try tokenize(resolved.text, addSpecial: true, parseSpecial: true))
        }
        let vision = try visionContext()
        let pictures: [OpaquePointer?] = try resolved.order.map { try bitmaps.bitmap($0) }
        guard let chunks = MediaChunks() else { throw InferenceError.tokenizationFailed }
        let status = resolved.text.withCString { characters in
            var input = mtmd_input_text(text: characters, text_len: resolved.text.utf8.count,
                                        add_special: true, parse_special: true)
            return pictures.withUnsafeBufferPointer { list in
                mtmd_tokenize(vision, chunks.pointer, &input, list.baseAddress, list.count)
            }
        }
        switch status {
        case 0: break
        case 2: throw InferenceError.imageUnreadable
        default: throw InferenceError.imageFailed("The chat template didn't place every image.")
        }

        var result = TokenizedPrompt(tokens: [], chunks: chunks, imageCount: Set(resolved.order).count)
        for index in 0..<mtmd_input_chunks_size(chunks.pointer) {
            guard let chunk = mtmd_input_chunks_get(chunks.pointer, index) else { continue }
            if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
                var count = 0
                if let tokens = mtmd_input_chunk_get_tokens_text(chunk, &count), count > 0 {
                    result.tokens.append(contentsOf: UnsafeBufferPointer(start: tokens, count: count))
                }
            } else {
                let cells = mtmd_input_chunk_get_n_tokens(chunk)
                let id = mtmd_input_chunk_get_id(chunk).map { String(cString: $0) } ?? UUID().uuidString
                let span = MediaSpan(id: id, tokenCount: cells, positionCount: Int(mtmd_input_chunk_get_n_pos(chunk)))
                result.media[result.tokens.count] = PromptMedia(span: span, chunk: chunk)
                result.tokens.append(contentsOf: repeatElement(LLAMA_TOKEN_NULL, count: cells))
            }
        }
        return result
    }

    private struct TokenizedPrompt {
        var tokens: [llama_token]
        var media: [Int: PromptMedia] = [:]
        var chunks: MediaChunks?
        var imageCount = 0
    }

    /// Cells of the cache that match the start of `prompt`. An image matches when it's the
    /// same picture read the same way.
    private func commonPrefix(with prompt: Prompt) -> Int {
        let limit = min(cachedTokens.count, prompt.tokens.count)
        var index = 0
        while index < limit {
            let cached = cachedMedia[index]
            let incoming = prompt.media[index]?.span
            if cached != nil || incoming != nil {
                guard let cached, cached == incoming, index + cached.tokenCount <= limit else { break }
                index += cached.tokenCount
                continue
            }
            guard cachedTokens[index] == prompt.tokens[index] else { break }
            index += 1
        }
        return index
    }

    /// The position of cache cell `index`. Each cell takes one position, except that an image
    /// on an M-RoPE model advances fewer positions than it has cells.
    private func cachedPosition(at index: Int) -> Int {
        cachedMedia.reduce(index) { position, entry in
            entry.key + entry.value.tokenCount <= index ? position - (entry.value.tokenCount - entry.value.positionCount) : position
        }
    }

    /// Drops the reusable prompt cache (e.g. when switching conversations).
    func resetCache() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if !self.isClosed { self.clearMemory() }
                continuation.resume()
            }
        }
    }

    private func clearMemory() {
        llama_memory_clear(llama_get_memory(context), true)
        cachedTokens = []
        cachedMedia = [:]
    }

    /// `llama_decode`, then the cluster's health: llama.cpp's network calls run ahead of it, so a
    /// worker that dropped out can leave a step that returned 0 with garbage in it. The model is
    /// unusable then (the engine reloads it), so this throws instead of returning a status.
    private func decode(_ batch: llama_batch) throws -> Int32 {
        let status = llama_decode(context, batch)
        if let cluster, let lost = RPCBridge.failedEndpoints().first {
            cachedTokens = []
            cachedMedia = [:]
            throw InferenceError.clusterDeviceLost(cluster.name(of: lost))
        }
        return status
    }

    // MARK: Tokens

    func countTokens(_ text: String) async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            queue.async {
                guard !self.isClosed else { return continuation.resume(returning: text.utf8.count / 4) }
                let count = (try? self.tokenize(text, addSpecial: false, parseSpecial: false).count) ?? text.utf8.count / 4
                continuation.resume(returning: count)
            }
        }
    }

    private func tokenize(_ text: String, addSpecial: Bool, parseSpecial: Bool) throws -> [llama_token] {
        let byteCount = text.utf8.count
        var capacity = byteCount + 16
        var tokens = [llama_token](repeating: 0, count: capacity)
        var count = llama_tokenize(vocab, text, Int32(byteCount), &tokens, Int32(capacity), addSpecial, parseSpecial)
        if count < 0, count != Int32.min {
            capacity = Int(-count)
            tokens = [llama_token](repeating: 0, count: capacity)
            count = llama_tokenize(vocab, text, Int32(byteCount), &tokens, Int32(capacity), addSpecial, parseSpecial)
        }
        guard count >= 0 else { throw InferenceError.tokenizationFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private func piece(for token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 128)
        var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        }
        guard length > 0 else { return [] }
        return buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
    }

    // MARK: Prompt formatting

    /// Formats the conversation with, in order of preference: the model's own Jinja template,
    /// llama.cpp's built-in template for its family, then ChatML.
    private func format(_ turns: [ChatTurn], addAssistant: Bool, variables: [String: TemplateValue],
                        tools: [ToolDefinition]) -> String {
        if let templateRenderer {
            do {
                var rendered = try templateRenderer.render(turns, addGenerationPrompt: addAssistant,
                                                           variables: variables, tools: tools)
                // Templates often begin with the BOS text; the tokenizer adds BOS itself.
                if addsBOS, !bosText.isEmpty, rendered.hasPrefix(bosText) {
                    rendered.removeFirst(bosText.count)
                }
                return rendered
            } catch {
                llamaLog.warning("Chat template failed to render: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Built-in templates know nothing of tools: describe them in text.
        let plain = turns.contains(where: \.carriesTools) || !tools.isEmpty ? ToolPrompt.flatten(turns, tools: tools) : turns
        return formatWithBuiltInTemplate(plain, addAssistant: addAssistant)
    }

    /// The turns and tools to render. Templates without native tool support get tool turns as text.
    private func promptParts(for request: GenerationRequest)
        -> (turns: [ChatTurn], tools: [ToolDefinition], format: ToolCallFormat?, native: Bool) {
        let offersTools = !request.tools.isEmpty
        guard offersTools || request.turns.contains(where: \.carriesTools) else { return (request.turns, [], nil, false) }
        if let nativeToolFormat {
            return (request.turns, request.tools, offersTools ? nativeToolFormat : nil, true)
        }
        return (ToolPrompt.flatten(request.turns, tools: request.tools), [], offersTools ? .hermesJSON : nil, false)
    }

    private func formatWithBuiltInTemplate(_ turns: [ChatTurn], addAssistant: Bool) -> String {
        let template = llama_model_chat_template(model, nil)
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        defer { cStrings.forEach { free($0) } }
        var messages: [llama_chat_message] = []
        for turn in turns {
            guard let role = strdup(turn.role.rawValue), let content = strdup(turn.content) else { continue }
            cStrings.append(role)
            cStrings.append(content)
            messages.append(llama_chat_message(role: UnsafePointer(role), content: UnsafePointer(content)))
        }
        let estimate = turns.reduce(0) { $0 + $1.content.utf8.count } * 2 + 1024
        var buffer = [CChar](repeating: 0, count: estimate)
        var length = llama_chat_apply_template(template, &messages, messages.count, addAssistant, &buffer, Int32(buffer.count))
        if length > Int32(buffer.count) {
            buffer = [CChar](repeating: 0, count: Int(length) + 1)
            length = llama_chat_apply_template(template, &messages, messages.count, addAssistant, &buffer, Int32(buffer.count))
        }
        guard length >= 0 else { return ChatMLFormatter.format(turns, addAssistant: addAssistant) }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A formatted, tokenized prompt. Image cells are `LLAMA_TOKEN_NULL` in `tokens`, with the
    /// image itself in `media` under the index of its first cell.
    private struct Prompt {
        var tokens: [llama_token]
        var media: [Int: PromptMedia]
        /// Owns the image chunks `media` points into.
        var chunks: MediaChunks?
        var imageCount: Int
        var trimmedTurns: Int
        var opensInReasoning: Bool
        var toolFormat: ToolCallFormat?
        var nativeTools: Bool

        var imageTokens: Int { media.values.reduce(0) { $0 + $1.span.tokenCount } }

        /// `index`, or the first cell of the image it falls inside: images are read whole.
        func boundary(atOrBefore index: Int) -> Int {
            for (start, item) in media where start < index && index < start + item.span.tokenCount {
                return start
            }
            return index
        }
    }

    /// Formats and tokenizes the conversation, dropping the oldest exchanges when it would not
    /// leave room for the reply inside the context window.
    private func prompt(for request: GenerationRequest, contextLimit: Int) throws -> Prompt {
        let reserve = min(max(request.maxTokens, 256), contextLimit / 2)
        // Images ride through formatting as placeholders (see ImagePrompt), so trimming a turn
        // drops its images too.
        let images = ImagePrompt(turns: request.turns, marker: Self.mediaMarker)
        var marked = request
        marked.turns = images.turns
        let bitmaps = ImageBitmaps(images.images)
        let parts = promptParts(for: marked)
        var turns = parts.turns
        var trimmed = 0
        while true {
            var text = format(turns, addAssistant: true, variables: request.templateVariables, tools: parts.tools)
            // Thinking templates may open the reasoning block themselves ("…assistant\n<think>\n").
            let opensInReasoning = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("<think>")
            if let prefix = request.assistantPrefix, !prefix.isEmpty {
                text += images.isEmpty ? prefix : ImagePrompt.sanitize(prefix, marker: Self.mediaMarker)
            }
            let tokenized = try tokenizePrompt(text, images: images, bitmaps: bitmaps)
            let tokens = tokenized.tokens
            let result = Prompt(tokens: tokens, media: tokenized.media, chunks: tokenized.chunks,
                                imageCount: tokenized.imageCount, trimmedTurns: trimmed,
                                opensInReasoning: opensInReasoning, toolFormat: parts.format, nativeTools: parts.native)
            if tokens.count + reserve <= contextLimit { return result }

            // Drop the oldest exchange: everything from the first non-system turn up to the second
            // user turn. Tool calls stay with their results and roles keep alternating.
            let userTurns = turns.indices.filter { turns[$0].role == .user }
            guard userTurns.count > 1, let start = turns.indices.first(where: { turns[$0].role != .system }) else {
                if tokens.count + 64 <= contextLimit { return result }
                throw InferenceError.promptTooLong(tokens: tokens.count, context: contextLimit)
            }
            let end = userTurns[1]
            trimmed += end - start
            turns.removeSubrange(start..<end)
        }
    }

    // MARK: Generation

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        interruptState.withLock { $0 = nil }
        setPacing(request.pacing)
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.interrupt(.user) }
            }
            queue.async {
                var completed = false
                do {
                    completed = try self.runGeneration(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                // After the stream ends, so the reply is already shown while the state is written.
                // Work queued later (including close) waits for this on the serial queue.
                if completed { self.saveStateIfNeeded(request.memory) }
            }
        }
    }

    /// Returns whether the reply finished normally, so its cache state is worth saving.
    private func runGeneration(_ request: GenerationRequest,
                               continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) throws -> Bool {
        guard !isClosed else { throw InferenceError.loadFailed("The model was unloaded.") }
        if let reason = currentInterrupt {
            if reason == .background { throw InferenceError.backgroundExecution }
            continuation.yield(.finished(emptyStats(stop: .cancelled)))
            return false
        }

        let started = ContinuousClock.now
        let contextLimit = Int(llama_n_ctx(context))
        let formatted = try self.prompt(for: request, contextLimit: contextLimit)
        let prompt = formatted.tokens
        guard !prompt.isEmpty else { throw InferenceError.tokenizationFailed }

        // Returning to a conversation whose memory was saved: restore it instead of re-reading.
        var restored = 0
        if let saved = request.memory, canSaveState, request.reusePromptCache,
           commonPrefix(with: formatted) < min(prompt.count / 2, 512),
           FileManager.default.fileExists(atPath: saved.fileURL.path(percentEncoded: false)) {
            restored = restoreState(from: saved.fileURL, capacity: contextLimit)
        }
        let opensInReasoning = formatted.opensInReasoning && (request.assistantPrefix ?? "").isEmpty
        continuation.yield(.started(PromptInfo(opensInReasoning: opensInReasoning,
                                               toolCallFormat: formatted.toolFormat,
                                               restoredTokens: restored)))

        // Reuse the longest common prefix still held in the KV cache (images match by content).
        let memory = llama_get_memory(context)
        var reused = 0
        if request.reusePromptCache, !cachedTokens.isEmpty {
            // At least one token must be evaluated for fresh logits, and images are read whole.
            reused = formatted.boundary(atOrBefore: min(commonPrefix(with: formatted), prompt.count - 1))
        }
        if reused < cachedTokens.count {
            // Recurrent/hybrid and windowed caches can refuse partial removal: start clean then.
            // A sliding-window cache (swa_full = false) must also still hold the window before `reused`.
            let start = cachedPosition(at: reused)
            let windowStart = llama_pos(max(0, start - Int(llama_model_n_swa(model))))
            if reused == 0 || llama_memory_seq_pos_min(memory, 0) > windowStart
                || !llama_memory_seq_rm(memory, 0, llama_pos(start), -1) {
                llama_memory_clear(memory, true)
                reused = 0
            }
        }
        cachedTokens = Array(prompt.prefix(reused))
        cachedMedia = cachedMedia.filter { $0.key < reused }

        // Evaluate the rest of the prompt: text in batches, each image through its encoder.
        var position = cachedPosition(at: reused)
        let pending = prompt.count - reused
        let imageStarts = formatted.media.keys.filter { $0 >= reused }.sorted()
        let reportsProgress = pending > batchCapacity || !imageStarts.isEmpty
        var index = reused
        while index < prompt.count {
            if let reason = currentInterrupt {
                clearMemory()
                if reason == .background { throw InferenceError.backgroundExecution }
                continuation.yield(.finished(emptyStats(stop: reason == .user ? .cancelled : .interrupted)))
                return false
            }
            if let image = formatted.media[index] {
                try evaluateImage(image, position: &position)
                cachedTokens.append(contentsOf: repeatElement(LLAMA_TOKEN_NULL, count: image.span.tokenCount))
                cachedMedia[index] = image.span
                index += image.span.tokenCount
            } else {
                let nextImage = imageStarts.first { $0 > index } ?? prompt.count
                let end = min(index + batchCapacity, nextImage)
                batch.n_tokens = 0
                for cell in index..<end {
                    LlamaRuntime.add(&batch, token: prompt[cell], position: position + (cell - index),
                                     logits: cell == prompt.count - 1)
                }
                let status = try decode(batch)
                if status != 0 {
                    clearMemory()
                    if currentInterrupt == .background { throw InferenceError.backgroundExecution }
                    if status == 1 { throw InferenceError.promptTooLong(tokens: prompt.count, context: contextLimit) }
                    throw InferenceError.decodeFailed(status)
                }
                position += end - index
                cachedTokens.append(contentsOf: prompt[index..<end])
                index = end
            }
            if reportsProgress {
                continuation.yield(.promptProgress(Double(index - reused) / Double(pending)))
            }
        }
        let promptFinished = ContinuousClock.now

        // Sample.
        let constraint = grammar(for: request.responseFormat, opensInReasoning: formatted.opensInReasoning)
        guard let sampler = makeSampler(request.sampling, grammar: constraint) else {
            throw constraint == nil ? InferenceError.loadFailed("Sampler unavailable.") : InferenceError.grammarFailed
        }
        defer { llama_sampler_free(sampler) }
        var output = TokenOutput(stopMatcher: StopSequenceMatcher(stopSequences(for: request, prompt: formatted)))
        let emit: (String) -> Void = { continuation.yield(.text($0)) }
        // The draft model reads text only: with images in the cache, replies are written one by one.
        let draft = request.speculative && cachedMedia.isEmpty ? self.draft : nil
        if let draft {
            try generateSpeculatively(with: draft, sampler: sampler, output: &output, position: &position,
                                      maxTokens: request.maxTokens, contextLimit: contextLimit, emit: emit)
        } else {
            try generateOneByOne(sampler: sampler, output: &output, position: &position,
                                 maxTokens: request.maxTokens, contextLimit: contextLimit, emit: emit)
        }
        output.finish(emit: emit)

        let finished = ContinuousClock.now
        let promptSeconds = max((promptFinished - started).seconds, 1e-6)
        let firstToken = output.firstTokenAt ?? finished
        let decodeSeconds = max((finished - firstToken).seconds, 1e-6)
        let evaluatedPrompt = prompt.count - reused
        let generated = output.generated
        var stats = GenerationStats(
            promptTokens: prompt.count,
            reusedPromptTokens: reused,
            generatedTokens: generated,
            timeToFirstToken: (firstToken - started).seconds,
            promptTokensPerSecond: evaluatedPrompt > 0 ? Double(evaluatedPrompt) / promptSeconds : 0,
            tokensPerSecond: generated > 1 ? Double(generated - 1) / decodeSeconds : 0,
            totalDuration: (finished - started).seconds,
            contextUsed: cachedTokens.count,
            contextSize: contextLimit,
            stopReason: output.stop,
            modelID: info.modelID,
            modelName: info.displayName
        )
        stats.trimmedTurns = formatted.trimmedTurns > 0 ? formatted.trimmedTurns : nil
        stats.restoredPromptTokens = restored > 0 ? restored : nil
        if formatted.imageCount > 0 {
            stats.imageCount = formatted.imageCount
            stats.imageTokens = formatted.imageTokens
        }
        if draft != nil {
            stats.draftedTokens = output.drafted
            stats.acceptedDraftTokens = output.accepted
        }
        continuation.yield(.finished(stats))
        // Interrupted replies (background, memory pressure, heat, unload) leave nothing worth saving.
        return output.stop != .interrupted && output.stop != .failed
    }

    // MARK: Token loops

    /// Turns sampled tokens into reply text: end of generation, UTF-8 assembly and stop sequences.
    private struct TokenOutput {
        var stopMatcher: StopSequenceMatcher
        var decoder = UTF8StreamDecoder()
        var generated = 0
        var stop = StopReason.maxTokens
        var stoppedBySequence = false
        var firstTokenAt: ContinuousClock.Instant?
        var drafted = 0
        var accepted = 0

        /// Takes one sampled token into the reply. Returns false when the reply ends with it.
        mutating func accept(_ token: llama_token, from runtime: LlamaRuntime, emit: (String) -> Void) -> Bool {
            if firstTokenAt == nil { firstTokenAt = .now }
            if llama_vocab_is_eog(runtime.vocab, token) {
                stop = .endOfSequence
                return false
            }
            generated += 1
            let text = decoder.append(runtime.piece(for: token))
            guard !text.isEmpty else { return true }
            let result = stopMatcher.feed(text)
            if !result.text.isEmpty { emit(result.text) }
            if result.stopped {
                stoppedBySequence = true
                stop = .endOfSequence
                return false
            }
            return true
        }

        /// Emits the text still held back when the reply ends.
        mutating func finish(emit: (String) -> Void) {
            guard !stoppedBySequence else { return }
            var remaining = ""
            let tail = decoder.flush()
            if !tail.isEmpty {
                let result = stopMatcher.feed(tail)
                remaining = result.text
                stoppedBySequence = result.stopped
            }
            if !stoppedBySequence { remaining += stopMatcher.flush() }
            if !remaining.isEmpty { emit(remaining) }
        }
    }

    /// The usual loop: sample a token, decode it, repeat.
    private func generateOneByOne(sampler: UnsafeMutablePointer<llama_sampler>, output: inout TokenOutput,
                                  position: inout Int, maxTokens: Int, contextLimit: Int,
                                  emit: (String) -> Void) throws {
        while output.generated < maxTokens {
            if let reason = currentInterrupt {
                output.stop = reason == .user ? .cancelled : .interrupted
                return
            }
            let token = llama_sampler_sample(sampler, context, -1)
            guard output.accept(token, from: self, emit: emit) else { return }
            // Cells, not positions: an image on an M-RoPE model fills more cells than positions.
            if cachedTokens.count >= contextLimit {
                output.stop = .contextFull
                return
            }
            batch.n_tokens = 0
            LlamaRuntime.add(&batch, token: token, position: position, logits: true)
            let status = try decode(batch)
            if status == 1 {
                // No free cache slot (a sliding-window cache can fill early); the cache is unchanged.
                output.stop = .contextFull
                return
            }
            if status != 0 {
                clearMemory()
                if currentInterrupt != nil {
                    output.stop = .interrupted
                    return
                }
                throw InferenceError.decodeFailed(status)
            }
            position += 1
            cachedTokens.append(token)
            pauseForPacing()
        }
    }

    /// Speculative decoding: the draft proposes tokens, this model checks all of them in one batch,
    /// keeps the ones it agrees with and adds one of its own. Every emitted token is this model's
    /// own sample, drawn in order from its sampler, so the reply is the one it would write alone.
    ///
    /// Invariant at the top of each step: `next` was emitted but isn't in the cache yet, and the
    /// cache holds exactly `cachedTokens`.
    private func generateSpeculatively(with draft: DraftModel, sampler: UnsafeMutablePointer<llama_sampler>,
                                       output: inout TokenOutput, position: inout Int, maxTokens: Int,
                                       contextLimit: Int, emit: (String) -> Void) throws {
        let memory = llama_get_memory(context)
        var next = llama_sampler_sample(sampler, context, -1)
        guard output.accept(next, from: self, emit: emit) else { return }

        while output.generated < maxTokens {
            if let reason = currentInterrupt {
                output.stop = reason == .user ? .cancelled : .interrupted
                return
            }
            guard position < contextLimit else {
                output.stop = .contextFull
                return
            }
            let count = min(draft.length, contextLimit - position - 1, maxTokens - output.generated, batchCapacity - 1)
            var proposal: [llama_token] = []
            if count > 0 {
                do {
                    try draft.sync(to: cachedTokens)
                    proposal = try draft.propose(after: next, count: count)
                } catch {
                    // A failing draft never stops the reply: this step goes on without proposals.
                    draft.reset()
                }
            }

            batch.n_tokens = 0
            LlamaRuntime.add(&batch, token: next, position: position, logits: true)
            for (offset, token) in proposal.enumerated() {
                LlamaRuntime.add(&batch, token: token, position: position + 1 + offset, logits: true)
            }
            let status = try decode(batch)
            if status == 1 {
                output.stop = .contextFull
                return
            }
            if status != 0 {
                clearMemory()
                draft.reset()
                if currentInterrupt != nil {
                    output.stop = .interrupted
                    return
                }
                throw InferenceError.decodeFailed(status)
            }
            cachedTokens.append(next)
            position += 1

            // Sample every position in order, keeping drafts for as long as they match.
            var agreed = 0
            var ended = false
            var correction: llama_token?
            for index in 0...proposal.count {
                let sampled = llama_sampler_sample(sampler, context, Int32(index))
                if index < proposal.count, sampled == proposal[index] {
                    guard output.generated < maxTokens, output.accept(sampled, from: self, emit: emit) else {
                        ended = true
                        break
                    }
                    agreed += 1
                } else {
                    correction = sampled
                    break
                }
            }
            output.drafted += proposal.count
            output.accepted += agreed

            // The cache holds `next` and the whole proposal: keep only what was accepted.
            cachedTokens.append(contentsOf: proposal.prefix(agreed))
            position += agreed
            if agreed < proposal.count, !llama_memory_seq_rm(memory, 0, llama_pos(position), -1) {
                try rebuildCache()
            }
            draft.keep(cachedTokens.count)
            if ended { return }
            guard let correction, output.generated < maxTokens else { return }
            guard output.accept(correction, from: self, emit: emit) else { return }
            next = correction
            pauseForPacing()
        }
    }

    /// Re-reads `cachedTokens` into a cleared cache: the fallback when rejected tokens can't be
    /// removed in place. Only text can be re-read (speculative decoding never runs with images).
    private func rebuildCache() throws {
        guard cachedMedia.isEmpty else {
            clearMemory()
            throw InferenceError.decodeFailed(-1)
        }
        let tokens = cachedTokens
        clearMemory()
        var index = 0
        while index < tokens.count {
            let end = min(index + batchCapacity, tokens.count)
            batch.n_tokens = 0
            for position in index..<end {
                LlamaRuntime.add(&batch, token: tokens[position], position: position, logits: position == tokens.count - 1)
            }
            let status = try decode(batch)
            guard status == 0 else {
                clearMemory()
                throw InferenceError.decodeFailed(status)
            }
            cachedTokens.append(contentsOf: tokens[index..<end])
            index = end
        }
    }

    private func pauseForPacing() {
        let pause = pacingNanoseconds.withLock { $0 }
        if pause > 0 { Thread.sleep(forTimeInterval: Double(pause) / 1_000_000_000) }
    }

    // MARK: Stop sequences and grammars

    /// The request's own stop sequences, plus the tool's reply marker for the model's tool format
    /// (generation must stop where the tool, not the model, takes over).
    private func stopSequences(for request: GenerationRequest, prompt: Prompt) -> [String] {
        guard let format = prompt.toolFormat else { return request.stopSequences }
        return request.stopSequences + (prompt.nativeTools ? format.stopSequences : ["</tool_call>"])
    }

    /// GBNF for the requested format, and for reasoning models the pattern after which it applies
    /// (the reasoning itself stays free text).
    private func grammar(for format: ResponseFormat, opensInReasoning: Bool) -> (text: String, trigger: String?)? {
        let text: String
        switch format {
        case .text: return nil
        case .json: text = Self.jsonGrammar
        case .grammar(let custom): text = custom
        }
        let template = info.chatTemplate ?? ""
        if template.contains("<|channel|>") && template.contains("<|message|>") {
            return (text, #"[\s\S]*?<\|channel\|>final<\|message\|>([\s\S]*)"#)
        }
        if template.contains("to=user") && template.contains("<|message|>") {
            return (text, #"[\s\S]*?to=user<\|message\|>([\s\S]*)"#)
        }
        if opensInReasoning {
            return (text, #"[\s\S]*?</think>\s*([\s\S]*)"#)
        }
        return (text, nil)
    }

    /// llama.cpp's `grammars/json.gbnf` (b11960), verbatim: a JSON object.
    static let jsonGrammar = #"""
    root   ::= object
    value  ::= object | array | string | number | ("true" | "false" | "null") ws

    object ::=
      "{" ws (
                string ":" ws value
        ("," ws string ":" ws value)*
      )? "}" ws

    array  ::=
      "[" ws (
                value
        ("," ws value)*
      )? "]" ws

    string ::=
      "\"" (
        [^"\\\x7F\x00-\x1F] |
        "\\" (["\\bfnrt] | "u" [0-9a-fA-F]{4}) # escapes
      )* "\"" ws

    number ::= ("-"? ([0-9] | [1-9] [0-9]{0,15})) ("." [0-9]+)? ([eE] [-+]? [0-9] [1-9]{0,15})? ws

    # Optional space: by convention, applied in this grammar after literal chars when allowed
    ws ::= | " " | "\n" [ \t]{0,20}
    """#

    // MARK: Saved conversation memory

    /// Loads a saved sequence state into the cache. Returns the number of tokens restored, or 0
    /// (with the cache cleared and the unusable file removed) if it can't be used.
    private func restoreState(from url: URL, capacity: Int) -> Int {
        clearMemory()
        var tokens = [llama_token](repeating: 0, count: capacity)
        let tokenCapacity = tokens.count
        var count = 0
        let read = llama_state_seq_load_file(context, url.path(percentEncoded: false), 0, &tokens, tokenCapacity, &count)
        guard read > 0, count > 0, count <= capacity else {
            clearMemory()
            try? FileManager.default.removeItem(at: url)
            llamaLog.warning("Discarded a saved conversation state that couldn't be restored")
            return 0
        }
        cachedTokens = Array(tokens.prefix(count))
        return count
    }

    /// Writes the cached conversation state, when it's long enough to be worth it. Written to a
    /// temporary file first so an interrupted save never leaves a damaged state behind. A state
    /// holding images isn't saved: its image cells can't be matched again after a restore.
    private func saveStateIfNeeded(_ request: ConversationMemoryRequest?) {
        guard let request, canSaveState, !isClosed, cachedMedia.isEmpty,
              cachedTokens.count >= request.minimumTokens else { return }
        let size = llama_state_seq_get_size(context, 0)
        guard size > 0, Int64(size) <= request.maximumBytes else { return }
        let path = request.fileURL.path(percentEncoded: false)
        let partial = path + ".partial"
        let written = cachedTokens.withUnsafeBufferPointer { tokens in
            llama_state_seq_save_file(context, partial, 0, tokens.baseAddress, tokens.count)
        }
        let files = FileManager.default
        if written > 0 {
            try? files.removeItem(atPath: path)
            try? files.moveItem(atPath: partial, toPath: path)
        } else {
            try? files.removeItem(atPath: partial)
        }
    }

    private func emptyStats(stop: StopReason) -> GenerationStats {
        GenerationStats(promptTokens: 0, reusedPromptTokens: 0, generatedTokens: 0, timeToFirstToken: 0,
                        promptTokensPerSecond: 0, tokensPerSecond: 0, totalDuration: 0,
                        contextUsed: cachedTokens.count, contextSize: Int(llama_n_ctx(context)),
                        stopReason: stop, modelID: info.modelID, modelName: info.displayName)
    }

    /// The sampler chain. A grammar comes first, so later samplers only see tokens it allows.
    private func makeSampler(_ parameters: SamplingParameters,
                             grammar: (text: String, trigger: String?)?) -> UnsafeMutablePointer<llama_sampler>? {
        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { return nil }
        if let grammar {
            guard let constraint = makeGrammarSampler(grammar.text, trigger: grammar.trigger) else {
                llama_sampler_free(chain)
                return nil
            }
            llama_sampler_chain_add(chain, constraint)
        }
        if parameters.temperature <= 0 {
            if parameters.repetitionPenalty > 1.0001 {
                llama_sampler_chain_add(chain, llama_sampler_init_top_k(40))
                llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), Int32(parameters.repetitionLastN), Float(parameters.repetitionPenalty), 0, 0))
            }
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
            return chain
        }
        if parameters.topK > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(parameters.topK)))
        }
        // Penalties after top-k: llama.cpp advises against scanning the full vocabulary.
        if parameters.repetitionPenalty > 1.0001 && parameters.repetitionLastN != 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), Int32(parameters.repetitionLastN), Float(parameters.repetitionPenalty), 0, 0))
        }
        if parameters.topP < 0.9999 {
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(parameters.topP), 1))
        }
        if parameters.minP > 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(Float(parameters.minP), 1))
        }
        llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(parameters.temperature)))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(parameters.seed ?? LLAMA_DEFAULT_SEED))
        return chain
    }

    /// A GBNF grammar sampler; with a trigger pattern it only applies to the text after the
    /// pattern's first capture group begins (llama.cpp's lazy grammars).
    private func makeGrammarSampler(_ grammar: String, trigger: String?) -> UnsafeMutablePointer<llama_sampler>? {
        guard let trigger else { return llama_sampler_init_grammar(vocab, grammar, "root") }
        return trigger.withCString { pattern in
            var patterns: [UnsafePointer<CChar>?] = [pattern]
            return llama_sampler_init_grammar_lazy_patterns(vocab, grammar, "root", &patterns, 1, nil, 0)
        }
    }

    static func add(_ batch: inout llama_batch, token: llama_token, position: Int, logits: Bool) {
        let index = Int(batch.n_tokens)
        batch.token[index] = token
        batch.pos[index] = llama_pos(position)
        batch.n_seq_id[index] = 1
        batch.seq_id[index]![0] = 0
        batch.logits[index] = logits ? 1 : 0
        batch.n_tokens += 1
    }

    // MARK: Benchmark

    /// llama-bench style measurement: prompt processing of `promptLength` tokens, then
    /// `generateLength` tokens of generation on top of it, repeated after one warm-up pass.
    func benchmark(promptLength: Int = 512, generateLength: Int = 128, repetitions: Int = 3,
                   progress: @escaping @Sendable (Double) -> Void) async throws -> BenchmarkMeasurement {
        interruptState.withLock { $0 = nil }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try self.runBenchmark(promptLength: promptLength, generateLength: generateLength,
                                                       repetitions: repetitions, progress: progress)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static let benchmarkText = """
    The history of computing is a story of abstraction. Each generation of engineers built tools \
    that hid the complexity of the layer beneath, from switches and vacuum tubes to transistors, \
    integrated circuits, operating systems, compilers and networks. Language models continue that \
    arc: they let people describe intent in ordinary words while the machine handles the details. \
    Running them locally adds privacy, predictability and independence from the network.
    """

    private func runBenchmark(promptLength: Int, generateLength: Int, repetitions: Int,
                              progress: @escaping @Sendable (Double) -> Void) throws -> BenchmarkMeasurement {
        guard !isClosed else { throw InferenceError.loadFailed("The model was unloaded.") }
        let contextLimit = Int(llama_n_ctx(context))
        let promptCount = max(16, min(promptLength, batchCapacity, contextLimit - generateLength - 8))
        let sample = try tokenize(Self.benchmarkText, addSpecial: false, parseSpecial: false)
        guard !sample.isEmpty else { throw InferenceError.tokenizationFailed }
        var promptTokens: [llama_token] = []
        while promptTokens.count < promptCount { promptTokens.append(contentsOf: sample) }
        promptTokens = Array(promptTokens.prefix(promptCount))

        guard let greedy = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw InferenceError.loadFailed("Sampler unavailable.")
        }
        llama_sampler_chain_add(greedy, llama_sampler_init_greedy())
        defer {
            llama_sampler_free(greedy)
            clearMemory()
        }

        var promptRates: [Double] = []
        var generationRates: [Double] = []
        var firstTokenTimes: [Double] = []
        var peakFootprint: UInt64 = 0
        let passes = repetitions + 1

        for pass in 0..<passes {
            if currentInterrupt != nil { throw CancellationError() }
            clearMemory()

            batch.n_tokens = 0
            for (index, token) in promptTokens.enumerated() {
                LlamaRuntime.add(&batch, token: token, position: index, logits: index == promptTokens.count - 1)
            }
            let promptStart = ContinuousClock.now
            let status = try decode(batch)
            guard status == 0 else { throw InferenceError.decodeFailed(status) }
            llama_synchronize(context)
            let promptSeconds = max(promptStart.secondsElapsed, 1e-6)

            var position = promptTokens.count
            let generationStart = ContinuousClock.now
            var firstTokenSeconds = promptSeconds
            for step in 0..<generateLength {
                if currentInterrupt != nil { throw CancellationError() }
                var token = llama_sampler_sample(greedy, context, -1)
                if llama_vocab_is_eog(vocab, token) { token = promptTokens[step % promptTokens.count] }
                batch.n_tokens = 0
                LlamaRuntime.add(&batch, token: token, position: position, logits: true)
                let decodeStatus = try decode(batch)
                guard decodeStatus == 0 else { throw InferenceError.decodeFailed(decodeStatus) }
                llama_synchronize(context)
                position += 1
                if step == 0 { firstTokenSeconds = promptSeconds + generationStart.secondsElapsed }
            }
            let generationSeconds = max(generationStart.secondsElapsed, 1e-6)
            peakFootprint = max(peakFootprint, SystemMetrics.processFootprint() ?? 0)

            if pass > 0 { // the first pass warms caches and is discarded
                promptRates.append(Double(promptTokens.count) / promptSeconds)
                generationRates.append(Double(generateLength) / generationSeconds)
                firstTokenTimes.append(firstTokenSeconds)
            }
            progress(Double(pass + 1) / Double(passes))
        }

        return BenchmarkMeasurement(
            promptTokens: promptTokens.count,
            generatedTokens: generateLength,
            promptTokensPerSecond: promptRates.mean,
            promptStdDev: promptRates.standardDeviation,
            tokensPerSecond: generationRates.mean,
            generationStdDev: generationRates.standardDeviation,
            timeToFirstToken: firstTokenTimes.mean,
            peakFootprintBytes: peakFootprint,
            repetitions: repetitions
        )
    }
}

// MARK: - Helpers

extension KVCacheType {
    var ggmlType: ggml_type {
        switch self {
        case .f16: GGML_TYPE_F16
        case .q8_0: GGML_TYPE_Q8_0
        case .q4_0: GGML_TYPE_Q4_0
        }
    }
}

/// Used only when llama.cpp doesn't recognize a model's template.
enum ChatMLFormatter {
    static func format(_ turns: [ChatTurn], addAssistant: Bool) -> String {
        var prompt = ""
        for turn in turns {
            prompt += "<|im_start|>\(turn.role.rawValue)\n\(turn.content)<|im_end|>\n"
        }
        if addAssistant { prompt += "<|im_start|>assistant\n" }
        return prompt
    }
}

extension Duration {
    var seconds: Double {
        let (s, attoseconds) = components
        return Double(s) + Double(attoseconds) / 1e18
    }
}

extension ContinuousClock.Instant {
    var secondsElapsed: Double { (ContinuousClock.now - self).seconds }
}

extension Array where Element == Double {
    var mean: Double { isEmpty ? 0 : reduce(0, +) / Double(count) }
    var standardDeviation: Double {
        guard count > 1 else { return 0 }
        let m = mean
        return (reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(count - 1)).squareRoot()
    }
}
