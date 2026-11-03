import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import os

private let mlxLog = Logger(subsystem: "app.omnia", category: "mlx")

/// Runs MLX models (folders of safetensors) with mlx-swift-lm: Apple's array framework on Metal,
/// which on M5 chips reads prompts with the GPU's Neural Accelerators. Prompts are formatted by
/// OMNIA's own chat-template renderer, as for llama.cpp, so tools, reasoning switches and
/// Continue behave the same on both engines.
///
/// MLX ends the app when iOS takes the GPU away mid-step, so the engine stops MLX replies before
/// OMNIA leaves the screen (unless a background task holds the GPU), and every MLX call runs in an
/// error scope that turns such a failure into an error instead.
final class MLXRuntime: InferenceBackend, @unchecked Sendable {
    enum Failure: LocalizedError {
        case simulator
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .simulator: "MLX models run on iPhone and iPad, not in the Simulator."
            case .unsupported(let type): "MLX in OMNIA can't run this architecture (\(type)) yet."
            }
        }
    }

    let info: LoadedModelInfo
    private let container: ModelContainer
    private let renderer: ChatTemplateRenderer?
    private let nativeToolFormat: ToolCallFormat?
    private let stopTokens: Set<Int>
    private let kvCache: KVCacheConfiguration?
    private let interruptState = OSAllocatedUnfairLock<InterruptReason?>(initialState: nil)
    private let pacingState = OSAllocatedUnfairLock<Duration>(initialState: .zero)
    /// The generation running now, so closing waits for its GPU work to finish.
    private let running = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// How much MLX may keep in its buffer cache between steps; the rest goes back to iOS.
    static let cacheLimit = 32 << 20
    /// Tokens per prefill step: smaller steps answer an interruption sooner.
    static let prefillStep = 256

    private init(info: LoadedModelInfo, container: ModelContainer, renderer: ChatTemplateRenderer?,
                 nativeToolFormat: ToolCallFormat?, stopTokens: Set<Int>, kvCache: KVCacheConfiguration?) {
        self.info = info
        self.container = container
        self.renderer = renderer
        self.nativeToolFormat = nativeToolFormat
        self.stopTokens = stopTokens
        self.kvCache = kvCache
    }

    static func load(model: InstalledModel, folder: URL, configuration: RuntimeConfiguration,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> MLXRuntime {
        #if targetEnvironment(simulator)
        throw Failure.simulator
        #else
        let modelType = model.facts.architecture
        guard await LLMTypeRegistry.shared.contains(modelType) else { throw Failure.unsupported(modelType) }
        let started = ContinuousClock.now
        let footprintBefore = SystemMetrics.processFootprint() ?? 0
        progress(0.05)
        MLX.Memory.cacheLimit = cacheLimit
        let container = try await withMLXErrors {
            try await LLMModelFactory.shared.loadContainer(from: folder, using: LocalTokenizerLoader())
        }
        // Loading reads every tensor, vision and audio towers included, before dropping those.
        MLX.Memory.clearCache()
        progress(0.9)

        let template = MLXModelInspector.chatTemplate(in: folder)
        let tokens = await container.perform { context in
            (bos: context.tokenizer.bosToken ?? "", eos: context.tokenizer.eosToken,
             ids: Self.turnEndTokens.compactMap { context.tokenizer.convertTokenToId($0) })
        }
        var stops = Set(Self.eosTokenIDs(in: folder) + tokens.ids)
        if let eos = tokens.eos, let id = await container.perform({ context in context.tokenizer.convertTokenToId(eos) }) {
            stops.insert(id)
        }
        var renderer: ChatTemplateRenderer?
        if let template {
            do {
                renderer = try ChatTemplateRenderer(source: template, bosToken: tokens.bos, eosToken: tokens.eos ?? "")
            } catch {
                mlxLog.warning("Chat template did not compile, using ChatML: \(error.localizedDescription, privacy: .public)")
            }
        }
        let footprintAfter = SystemMetrics.processFootprint() ?? footprintBefore
        let info = LoadedModelInfo(
            modelID: model.id, displayName: model.displayName, architecture: modelType, configuration: configuration,
            trainContextLength: model.facts.trainContext, parameterCount: UInt64(max(model.facts.parameters, 0) * 1e9),
            tensorBytes: model.sizeBytes,
            measuredFootprintBytes: footprintAfter > footprintBefore ? footprintAfter - footprintBefore : 0,
            measuredGPUBytes: UInt64(max(MLX.Memory.activeMemory, 0)), loadDuration: (ContinuousClock.now - started).seconds,
            chatTemplate: template, supportsThinkingToggle: template?.contains("enable_thinking") ?? false)
        progress(1)
        mlxLog.info("Loaded \(model.id, privacy: .public): \(stops.count) stop tokens")
        return MLXRuntime(info: info, container: container, renderer: renderer,
                          nativeToolFormat: renderer == nil ? nil : ToolCallFormat.detect(template: template),
                          stopTokens: stops, kvCache: Self.kvCacheConfiguration(configuration.kvCacheType))
        #endif
    }

    /// Tokens that end an assistant turn in common chat formats, beyond the model's own end token.
    static let turnEndTokens = ["<|im_end|>", "<end_of_turn>", "<turn|>", "<|eot_id|>", "<|end|>", "<|end_of_text|>"]

    /// End-of-text IDs from config.json and generation_config.json (a number or a list).
    static func eosTokenIDs(in folder: URL) -> [Int] {
        ["config.json", "generation_config.json"].flatMap { name -> [Int] in
            guard let data = try? Data(contentsOf: folder.appending(path: name)),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
            let text = object["text_config"] as? [String: Any]
            switch object["eos_token_id"] ?? text?["eos_token_id"] {
            case let id as NSNumber: return [id.intValue]
            case let ids as [NSNumber]: return ids.map(\.intValue)
            default: return []
            }
        }
    }

    /// The KV cache the memory plan chose: full precision, or 8- or 4-bit groups.
    static func kvCacheConfiguration(_ type: KVCacheType) -> KVCacheConfiguration? {
        switch type {
        case .f16: nil
        case .q8_0: KVCacheConfiguration(strategy: .affine(.eightBit), compatibility: .allowPartial)
        case .q4_0: KVCacheConfiguration(strategy: .affine(.fourBit), compatibility: .allowPartial)
        }
    }

    /// Runs MLX work in a scope that reports a GPU failure as an error rather than ending the app.
    private static func withMLXErrors<R>(_ body: () async throws -> R) async throws -> R {
        let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
        let result = try await withErrorHandler({ message in failure.withLock { $0 = $0 ?? message } }, body)
        if let message = failure.withLock({ $0 }) {
            mlxLog.error("MLX failed: \(message, privacy: .public)")
            throw InferenceError.engineFailed(message)
        }
        return result
    }

    // MARK: Prompt

    private struct Prompt: Sendable {
        var tokens: [Int]
        var trimmedTurns: Int
        var opensInReasoning: Bool
        var toolFormat: ToolCallFormat?
        var nativeTools: Bool
    }

    /// Formats and tokenizes the conversation, dropping the oldest exchanges when it would not
    /// leave room for the reply inside the context window.
    private func prompt(for request: GenerationRequest) async throws -> Prompt {
        let contextLimit = info.configuration.contextLength
        let reserve = min(max(request.maxTokens, 256), contextLimit / 2)
        let parts = promptParts(for: request)
        var turns = parts.turns
        var trimmed = 0
        while true {
            var text = format(turns, variables: request.templateVariables, tools: parts.tools)
            // Thinking templates may open the reasoning block themselves ("…assistant\n<think>\n").
            let opensInReasoning = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("<think>")
            if let prefix = request.assistantPrefix, !prefix.isEmpty { text += prefix }
            let rendered = text
            // The template writes the special tokens itself, as Transformers' apply_chat_template does.
            let tokens = await container.perform { context in context.tokenizer.encode(text: rendered, addSpecialTokens: false) }
            let result = Prompt(tokens: tokens, trimmedTurns: trimmed, opensInReasoning: opensInReasoning,
                                toolFormat: parts.format, nativeTools: parts.native)
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

    private func format(_ turns: [ChatTurn], variables: [String: TemplateValue], tools: [ToolDefinition]) -> String {
        if let renderer {
            do {
                return try renderer.render(turns, addGenerationPrompt: true, variables: variables, tools: tools)
            } catch {
                mlxLog.warning("Chat template failed to render: \(error.localizedDescription, privacy: .public)")
            }
        }
        let plain = turns.contains(where: \.carriesTools) || !tools.isEmpty ? ToolPrompt.flatten(turns, tools: tools) : turns
        return ChatMLFormatter.format(plain, addAssistant: true)
    }

    // MARK: Generation

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        interruptState.withLock { $0 = nil }
        setPacing(request.pacing)
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                do {
                    try await self.run(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            running.withLock { $0 = task }
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.interrupt(.user) }
            }
        }
    }

    /// What one pass through the token loop produced.
    private struct Outcome: Sendable {
        var generated: Int
        var stop: StopReason
        var interrupt: InterruptReason?
        var prefillSeconds: Double
        var firstTokenSeconds: Double?
        var decodeSeconds: Double
    }

    private func run(_ request: GenerationRequest,
                     continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async throws {
        if let reason = interruptState.withLock({ $0 }) {
            if reason == .background { throw InferenceError.backgroundExecution }
            continuation.yield(.finished(stats(prompt: 0, outcome: nil, started: .now, stop: .cancelled)))
            return
        }
        let started = ContinuousClock.now
        let prompt = try await self.prompt(for: request)
        continuation.yield(.started(PromptInfo(opensInReasoning: prompt.opensInReasoning, toolCallFormat: prompt.toolFormat)))

        let parameters = generateParameters(for: request, reportsProgress: prompt.tokens.count > Self.prefillStep * 2,
                                            continuation: continuation)
        let stopSequences = request.stopSequences
            + (prompt.toolFormat.map { prompt.nativeTools ? $0.stopSequences : ["</tool_call>"] } ?? [])
        let maxTokens = min(request.maxTokens, info.configuration.contextLength - prompt.tokens.count)
        let outcome = try await loop(tokens: prompt.tokens, parameters: parameters, maxTokens: maxTokens,
                                     stopSequences: stopSequences, continuation: continuation)
        if outcome.interrupt == .background { throw InferenceError.backgroundExecution }
        // Stopped by the context window rather than the reply limit.
        let stop = outcome.stop == .maxTokens && maxTokens < request.maxTokens ? StopReason.contextFull : outcome.stop
        var stats = stats(prompt: prompt.tokens.count, outcome: outcome, started: started, stop: stop)
        stats.trimmedTurns = prompt.trimmedTurns > 0 ? prompt.trimmedTurns : nil
        continuation.yield(.finished(stats))
    }

    private func generateParameters(for request: GenerationRequest, reportsProgress: Bool,
                                    continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) -> GenerateParameters {
        let sampling = request.sampling
        var parameters = GenerateParameters(
            kvCache: kvCache, temperature: Float(max(sampling.temperature, 0)),
            topP: Float(sampling.topP), topK: max(sampling.topK, 0), minP: Float(sampling.minP),
            repetitionPenalty: sampling.repetitionPenalty > 1 ? Float(sampling.repetitionPenalty) : nil,
            repetitionContextSize: max(sampling.repetitionLastN, 1), seed: sampling.seed.map(UInt64.init))
        parameters.prefill.stepSize = Self.prefillStep
        if reportsProgress {
            parameters.prefill.progress = { processed, total in
                guard total > 0, processed < total else { return }
                continuation.yield(.promptProgress(Double(processed) / Double(total)))
            }
        }
        return parameters
    }

    /// Reads the prompt (in TokenIterator's initializer), then samples tokens until an end token,
    /// a stop sequence, the token limit or an interruption.
    private func loop(tokens: [Int], parameters: GenerateParameters, maxTokens: Int, stopSequences: [String],
                      continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async throws -> Outcome {
        let interrupt = interruptState
        let pacing = pacingState
        let stops = stopTokens
        return try await Self.withMLXErrors {
            try await container.perform(nonSendable: tokens) { context, tokens in
                let prefillStart = ContinuousClock.now
                var iterator = try TokenIterator(input: LMInput(tokens: MLXArray(tokens)), model: context.model,
                                                 parameters: parameters)
                let decodeStart = ContinuousClock.now
                var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
                var matcher = StopSequenceMatcher(stopSequences)
                var outcome = Outcome(generated: 0, stop: .maxTokens, interrupt: nil,
                                      prefillSeconds: (decodeStart - prefillStart).seconds, firstTokenSeconds: nil, decodeSeconds: 0)
                while outcome.generated < maxTokens {
                    if let reason = interrupt.withLock({ $0 }) {
                        outcome.interrupt = reason
                        outcome.stop = reason == .user ? .cancelled : .interrupted
                        break
                    }
                    guard let token = iterator.next() else { break }
                    if stops.contains(token) {
                        outcome.stop = .endOfSequence
                        break
                    }
                    outcome.generated += 1
                    if outcome.firstTokenSeconds == nil { outcome.firstTokenSeconds = (ContinuousClock.now - prefillStart).seconds }
                    detokenizer.append(token: token)
                    if let text = detokenizer.next() {
                        let shown = matcher.feed(text)
                        if !shown.text.isEmpty { continuation.yield(.text(shown.text)) }
                        if shown.stopped {
                            outcome.stop = .endOfSequence
                            break
                        }
                    }
                    // mlx-swift-lm's own loop does the same, so buffers don't pile up.
                    if outcome.generated % 256 == 0 { MLX.Memory.clearCache() }
                    let delay = pacing.withLock { $0 }
                    if delay > .zero { try? await Task.sleep(for: delay) }
                }
                let rest = matcher.flush()
                if !rest.isEmpty { continuation.yield(.text(rest)) }
                // Nothing of this reply may still be running on the GPU when the loop returns.
                MLX.Stream.defaultStream.synchronize()
                outcome.decodeSeconds = (ContinuousClock.now - decodeStart).seconds
                return outcome
            }
        }
    }

    private func stats(prompt: Int, outcome: Outcome?, started: ContinuousClock.Instant, stop: StopReason) -> GenerationStats {
        let generated = outcome?.generated ?? 0
        let prefill = max(outcome?.prefillSeconds ?? 0, 1e-6)
        let decode = max(outcome?.decodeSeconds ?? 0, 1e-6)
        return GenerationStats(
            promptTokens: prompt, reusedPromptTokens: 0, generatedTokens: generated,
            timeToFirstToken: outcome?.firstTokenSeconds ?? prefill,
            promptTokensPerSecond: prompt > 0 ? Double(prompt) / prefill : 0,
            tokensPerSecond: generated > 1 ? Double(generated - 1) / decode : 0,
            totalDuration: (ContinuousClock.now - started).seconds,
            contextUsed: min(prompt + generated, info.configuration.contextLength), contextSize: info.configuration.contextLength,
            stopReason: stop, modelID: info.modelID, modelName: info.displayName)
    }

    // MARK: InferenceBackend

    func interrupt(_ reason: InterruptReason) {
        interruptState.withLock { $0 = reason }
    }

    func setPacing(_ pacing: Duration) {
        pacingState.withLock { $0 = pacing }
    }

    /// Every reply reads its whole prompt: there's no cache kept between replies to reset.
    func resetCache() async {}

    func countTokens(_ text: String) async -> Int {
        await container.perform { context in context.tokenizer.encode(text: text, addSpecialTokens: false).count }
    }

    func benchmark(promptLength: Int, generateLength: Int, repetitions: Int,
                   progress: @escaping @Sendable (Double) -> Void) async throws -> BenchmarkMeasurement {
        interruptState.withLock { $0 = nil }
        let filler = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: max(promptLength / 8, 1))
        let encoded = await container.perform { context in context.tokenizer.encode(text: filler, addSpecialTokens: false) }
        let prompt = Array(encoded.prefix(max(promptLength, 1)))
        var parameters = GenerateParameters(kvCache: kvCache, temperature: 0)
        parameters.prefill.stepSize = Self.prefillStep
        var readSpeeds: [Double] = [], writeSpeeds: [Double] = [], firstTokens: [Double] = []
        var peak = SystemMetrics.processFootprint() ?? 0
        let runs = max(repetitions, 1)
        for index in 0..<runs {
            let outcome = try await loop(tokens: prompt, parameters: parameters, maxTokens: generateLength,
                                         stopSequences: [], continuation: Self.discard)
            if outcome.interrupt != nil { throw InferenceError.thermalLimit }
            readSpeeds.append(Double(prompt.count) / max(outcome.prefillSeconds, 1e-6))
            if outcome.generated > 1 { writeSpeeds.append(Double(outcome.generated - 1) / max(outcome.decodeSeconds, 1e-6)) }
            firstTokens.append(outcome.firstTokenSeconds ?? outcome.prefillSeconds)
            peak = max(peak, SystemMetrics.processFootprint() ?? 0)
            progress(Double(index + 1) / Double(runs))
        }
        func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        func deviation(_ values: [Double]) -> Double {
            guard values.count > 1 else { return 0 }
            let average = mean(values)
            return (values.map { ($0 - average) * ($0 - average) }.reduce(0, +) / Double(values.count - 1)).squareRoot()
        }
        return BenchmarkMeasurement(promptTokens: prompt.count, generatedTokens: generateLength,
                                    promptTokensPerSecond: mean(readSpeeds), promptStdDev: deviation(readSpeeds),
                                    tokensPerSecond: mean(writeSpeeds), generationStdDev: deviation(writeSpeeds),
                                    timeToFirstToken: mean(firstTokens), peakFootprintBytes: peak, repetitions: runs)
    }

    /// A stream nobody reads, for benchmark runs.
    private static let discard = AsyncThrowingStream<GenerationEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(0)).continuation

    func close() async {
        interrupt(.unload)
        if let task = running.withLock({ $0 }) { await task.value }
        MLX.Memory.clearCache()
    }
}
