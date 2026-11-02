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

    private let interruptState = OSAllocatedUnfairLock<InterruptReason?>(initialState: nil)
    private let pacingNanoseconds = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    // MARK: Backend

    private static let backendReady: Void = {
        llama_log_set({ level, text, _ in
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
        }, nil)
        llama_backend_init()
    }()

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
    /// prompt doesn't pay for Metal pipeline compilation.
    static func load(modelID: String,
                     displayName: String,
                     fileURL: URL,
                     configuration: RuntimeConfiguration,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> LlamaRuntime {
        _ = backendReady
        let queue = DispatchQueue(label: "app.omnia.llama.\(modelID)", qos: .userInitiated)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let runtime = try LlamaRuntime(modelID: modelID, displayName: displayName, fileURL: fileURL,
                                                   configuration: configuration, queue: queue, progress: progress)
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

    private init(modelID: String, displayName: String, fileURL: URL, configuration: RuntimeConfiguration,
                 queue: DispatchQueue, progress: @escaping @Sendable (Double) -> Void) throws {
        self.queue = queue
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

        let loadedModel: OpaquePointer? = withExtendedLifetime(progressBox) {
            llama_model_load_from_file(path, modelParams)
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

    private static func makeContext(model: OpaquePointer, configuration: RuntimeConfiguration) -> OpaquePointer? {
        var params = llama_context_default_params()
        params.n_ctx = UInt32(configuration.contextLength)
        params.n_batch = UInt32(configuration.batchSize)
        params.n_ubatch = UInt32(min(configuration.microBatchSize, configuration.batchSize))
        params.n_seq_max = 1
        params.n_threads = Int32(configuration.threads)
        params.n_threads_batch = Int32(configuration.threads)
        if configuration.kvCacheType.requiresFlashAttention {
            params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        } else {
            params.flash_attn_type = configuration.flashAttention ? LLAMA_FLASH_ATTN_TYPE_AUTO : LLAMA_FLASH_ATTN_TYPE_DISABLED
        }
        params.type_k = configuration.kvCacheType.ggmlType
        params.type_v = configuration.kvCacheType.ggmlType
        #if targetEnvironment(simulator)
        params.offload_kqv = false
        #else
        params.offload_kqv = configuration.gpuOffload
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
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    deinit {
        if !isClosed { freeResources() }
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
    private func format(_ turns: [ChatTurn], addAssistant: Bool, variables: [String: TemplateValue]) -> String {
        if let templateRenderer {
            do {
                var rendered = try templateRenderer.render(turns, addGenerationPrompt: addAssistant, variables: variables)
                // Templates often begin with the BOS text; the tokenizer adds BOS itself.
                if addsBOS, !bosText.isEmpty, rendered.hasPrefix(bosText) {
                    rendered.removeFirst(bosText.count)
                }
                return rendered
            } catch {
                llamaLog.warning("Chat template failed to render: \(error.localizedDescription, privacy: .public)")
            }
        }
        return formatWithBuiltInTemplate(turns, addAssistant: addAssistant)
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

    /// Formats and tokenizes the conversation, dropping the oldest turns when it would not
    /// leave room for the reply inside the context window.
    private func promptTokens(for request: GenerationRequest, contextLimit: Int) throws
        -> (tokens: [llama_token], trimmedTurns: Int, opensInReasoning: Bool) {
        let reserve = min(max(request.maxTokens, 256), contextLimit / 2)
        var turns = request.turns
        var trimmed = 0
        while true {
            var prompt = format(turns, addAssistant: true, variables: request.templateVariables)
            // Thinking templates may open the reasoning block themselves ("…assistant\n<think>\n").
            let opensInReasoning = prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("<think>")
            if let prefix = request.assistantPrefix, !prefix.isEmpty { prompt += prefix }
            let tokens = try tokenize(prompt, addSpecial: true, parseSpecial: true)
            if tokens.count + reserve <= contextLimit { return (tokens, trimmed, opensInReasoning) }

            let removable = turns.indices.filter { turns[$0].role != .system }
            guard removable.count > 1, let first = removable.first else {
                if tokens.count + 64 <= contextLimit { return (tokens, trimmed, opensInReasoning) }
                throw InferenceError.promptTooLong(tokens: tokens.count, context: contextLimit)
            }
            turns.remove(at: first)
            trimmed += 1
            // Keep user/assistant alternation intact for strict templates.
            if first < turns.count, turns[first].role == .assistant, turns.count - first > 1 {
                turns.remove(at: first)
                trimmed += 1
            }
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
                do {
                    try self.runGeneration(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func runGeneration(_ request: GenerationRequest,
                               continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) throws {
        guard !isClosed else { throw InferenceError.loadFailed("The model was unloaded.") }
        if let reason = currentInterrupt {
            if reason == .background { throw InferenceError.backgroundExecution }
            continuation.yield(.finished(emptyStats(stop: .cancelled)))
            return
        }

        let started = ContinuousClock.now
        let contextLimit = Int(llama_n_ctx(context))
        let (prompt, trimmedTurns, opensInReasoning) = try promptTokens(for: request, contextLimit: contextLimit)
        guard !prompt.isEmpty else { throw InferenceError.tokenizationFailed }
        continuation.yield(.started(opensInReasoning: opensInReasoning && (request.assistantPrefix ?? "").isEmpty))

        // Reuse the longest common prefix still held in the KV cache.
        let memory = llama_get_memory(context)
        var reused = 0
        if request.reusePromptCache, !cachedTokens.isEmpty {
            reused = zip(cachedTokens, prompt).prefix { $0 == $1 }.count
            reused = min(reused, prompt.count - 1) // at least one token must be evaluated for fresh logits
        }
        if reused < cachedTokens.count {
            // Recurrent/hybrid and windowed caches can refuse partial removal: start clean then.
            // A sliding-window cache (swa_full = false) must also still hold the window before `reused`.
            let windowStart = llama_pos(max(0, reused - Int(llama_model_n_swa(model))))
            if reused == 0 || llama_memory_seq_pos_min(memory, 0) > windowStart
                || !llama_memory_seq_rm(memory, 0, llama_pos(reused), -1) {
                llama_memory_clear(memory, true)
                reused = 0
            }
        }
        cachedTokens = Array(prompt.prefix(reused))

        // Evaluate the remaining prompt in batches.
        var position = reused
        let pending = Array(prompt[reused...])
        var evaluated = 0
        while evaluated < pending.count {
            if let reason = currentInterrupt {
                clearMemory()
                if reason == .background { throw InferenceError.backgroundExecution }
                continuation.yield(.finished(emptyStats(stop: reason == .user ? .cancelled : .interrupted)))
                return
            }
            let end = min(evaluated + batchCapacity, pending.count)
            batch.n_tokens = 0
            for index in evaluated..<end {
                LlamaRuntime.add(&batch, token: pending[index], position: position + (index - evaluated),
                                 logits: index == pending.count - 1)
            }
            let status = llama_decode(context, batch)
            if status != 0 {
                clearMemory()
                if currentInterrupt == .background { throw InferenceError.backgroundExecution }
                throw InferenceError.decodeFailed(status)
            }
            position += end - evaluated
            cachedTokens.append(contentsOf: pending[evaluated..<end])
            evaluated = end
            if pending.count > batchCapacity {
                continuation.yield(.promptProgress(Double(evaluated) / Double(pending.count)))
            }
        }
        let promptFinished = ContinuousClock.now

        // Sample.
        guard let sampler = makeSampler(request.sampling) else { throw InferenceError.loadFailed("Sampler unavailable.") }
        defer { llama_sampler_free(sampler) }
        var decoder = UTF8StreamDecoder()
        var generated = 0
        var firstTokenAt: ContinuousClock.Instant?
        var stop = StopReason.maxTokens

        while generated < request.maxTokens {
            if let reason = currentInterrupt {
                stop = reason == .user ? .cancelled : .interrupted
                break
            }
            let token = llama_sampler_sample(sampler, context, -1)
            if firstTokenAt == nil { firstTokenAt = .now }
            if llama_vocab_is_eog(vocab, token) {
                stop = .endOfSequence
                break
            }
            let text = decoder.append(piece(for: token))
            if !text.isEmpty { continuation.yield(.text(text)) }
            generated += 1

            if position >= contextLimit {
                stop = .contextFull
                break
            }
            batch.n_tokens = 0
            LlamaRuntime.add(&batch, token: token, position: position, logits: true)
            let status = llama_decode(context, batch)
            if status != 0 {
                clearMemory()
                if currentInterrupt != nil {
                    stop = .interrupted
                    break
                }
                throw InferenceError.decodeFailed(status)
            }
            position += 1
            cachedTokens.append(token)

            let pause = pacingNanoseconds.withLock { $0 }
            if pause > 0 { Thread.sleep(forTimeInterval: Double(pause) / 1_000_000_000) }
        }

        let tail = decoder.flush()
        if !tail.isEmpty { continuation.yield(.text(tail)) }

        let finished = ContinuousClock.now
        let promptSeconds = max((promptFinished - started).seconds, 1e-6)
        let firstToken = firstTokenAt ?? finished
        let decodeSeconds = max((finished - firstToken).seconds, 1e-6)
        let evaluatedPrompt = prompt.count - reused
        var stats = GenerationStats(
            promptTokens: prompt.count,
            reusedPromptTokens: reused,
            generatedTokens: generated,
            timeToFirstToken: (firstToken - started).seconds,
            promptTokensPerSecond: evaluatedPrompt > 0 ? Double(evaluatedPrompt) / promptSeconds : 0,
            tokensPerSecond: generated > 1 ? Double(generated - 1) / decodeSeconds : 0,
            totalDuration: (finished - started).seconds,
            contextUsed: position,
            contextSize: contextLimit,
            stopReason: stop,
            modelID: info.modelID,
            modelName: info.displayName
        )
        stats.trimmedTurns = trimmedTurns > 0 ? trimmedTurns : nil
        continuation.yield(.finished(stats))
    }

    private func emptyStats(stop: StopReason) -> GenerationStats {
        GenerationStats(promptTokens: 0, reusedPromptTokens: 0, generatedTokens: 0, timeToFirstToken: 0,
                        promptTokensPerSecond: 0, tokensPerSecond: 0, totalDuration: 0,
                        contextUsed: cachedTokens.count, contextSize: Int(llama_n_ctx(context)),
                        stopReason: stop, modelID: info.modelID, modelName: info.displayName)
    }

    private func makeSampler(_ parameters: SamplingParameters) -> UnsafeMutablePointer<llama_sampler>? {
        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { return nil }
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

    private static func add(_ batch: inout llama_batch, token: llama_token, position: Int, logits: Bool) {
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
            let status = llama_decode(context, batch)
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
                let decodeStatus = llama_decode(context, batch)
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
