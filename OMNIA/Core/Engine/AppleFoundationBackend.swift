import Foundation
import FoundationModels
import os

/// Apple's on-device language model (Apple Intelligence). It's built into the system: nothing to
/// download, and iOS manages its memory. It has a 4,096-token context and OMNIA uses it for
/// text replies (no tools, grammars or images).
final class AppleFoundationBackend: InferenceBackend, @unchecked Sendable {
    static let modelID = "system/apple-foundation-model"
    static let contextSize = 4096

    enum Availability: Equatable, Sendable {
        case available
        case unavailable(String)
    }

    /// Fails with a message the chat can show.
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var availability: Availability {
        let availability = SystemLanguageModel.default.availability
        if case .available = availability { return .available }
        guard case .unavailable(let reason) = availability else {
            return .unavailable("Apple Intelligence isn't available right now.")
        }
        switch reason {
        case .appleIntelligenceNotEnabled:
            return .unavailable("Turn on Apple Intelligence in Settings to use Apple's on-device model.")
        case .deviceNotEligible:
            return .unavailable("This device doesn't support Apple Intelligence.")
        case .modelNotReady:
            return .unavailable("Apple Intelligence is still preparing its model. Try again later.")
        @unknown default:
            return .unavailable("Apple Intelligence isn't available right now.")
        }
    }

    let info: LoadedModelInfo
    private let interruptState = OSAllocatedUnfairLock<InterruptReason?>(initialState: nil)

    init() {
        info = LoadedModelInfo(
            modelID: Self.modelID, displayName: "Apple Intelligence", architecture: "apple-foundation",
            configuration: RuntimeConfiguration(contextLength: Self.contextSize, batchSize: 512, microBatchSize: 512, threads: 1,
                                                gpuOffload: true, kvCacheType: .f16, flashAttention: true),
            trainContextLength: Self.contextSize, parameterCount: 3_000_000_000, tensorBytes: 0,
            measuredFootprintBytes: 0, measuredGPUBytes: 0, loadDuration: 0, chatTemplate: nil, supportsThinkingToggle: false)
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        interruptState.withLock { $0 = nil }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.describe(error))
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { task.cancel() }
            }
        }
    }

    private func run(_ request: GenerationRequest,
                     continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async throws {
        guard Self.availability == .available else {
            if case .unavailable(let reason) = Self.availability { throw Failure(message: reason) }
            return
        }
        let started = ContinuousClock.now
        let conversation = Self.conversation(from: request)
        let session = LanguageModelSession(model: .default, tools: [], transcript: conversation.transcript)
        continuation.yield(.started(PromptInfo(opensInReasoning: false, toolCallFormat: nil)))

        let sampling = request.sampling
        let options = GenerationOptions(
            sampling: sampling.temperature <= 0
                ? .greedy : .random(probabilityThreshold: min(max(sampling.topP, 0.01), 1), seed: sampling.seed.map(UInt64.init)),
            temperature: sampling.temperature <= 0 ? nil : min(sampling.temperature, 1),
            maximumResponseTokens: max(16, min(request.maxTokens, 2048)))

        var emitted = ""
        var firstToken: ContinuousClock.Instant?
        var stop = StopReason.endOfSequence
        var interruption: InterruptReason?
        for try await snapshot in session.streamResponse(to: conversation.prompt, options: options) {
            if let reason = interruptState.withLock({ $0 }) {
                stop = reason == .user ? .cancelled : .interrupted
                interruption = reason == .user ? nil : reason
                break
            }
            // Snapshots hold the whole reply so far; pass on what's new.
            let content = snapshot.content
            guard content.count > emitted.count, content.hasPrefix(emitted) else { continue }
            continuation.yield(.text(String(content.dropFirst(emitted.count))))
            emitted = content
            if firstToken == nil { firstToken = .now }
        }

        let finished = ContinuousClock.now
        let generated = await Self.tokenCount(emitted)
        let promptTokens = await Self.tokenCount(conversation.text)
        let first = firstToken ?? finished
        let decodeSeconds = max((finished - first).seconds, 1e-6)
        let promptSeconds = max((first - started).seconds, 1e-6)
        var stats = GenerationStats(
            promptTokens: promptTokens, reusedPromptTokens: 0, generatedTokens: generated,
            timeToFirstToken: (first - started).seconds,
            promptTokensPerSecond: Double(promptTokens) / promptSeconds,
            tokensPerSecond: generated > 1 ? Double(generated - 1) / decodeSeconds : 0,
            totalDuration: (finished - started).seconds,
            contextUsed: min(Self.contextSize, promptTokens + generated), contextSize: Self.contextSize,
            stopReason: stop, modelID: info.modelID, modelName: info.displayName)
        stats.interruption = interruption
        continuation.yield(.finished(stats))
    }

    // MARK: Prompt

    /// The conversation as the system model's transcript: instructions, earlier turns (the newest
    /// that fit its context) and the latest user message as the prompt.
    static func conversation(from request: GenerationRequest) -> (transcript: Transcript, prompt: String, text: String) {
        var turns = request.turns.contains(where: \.carriesTools) ? ToolPrompt.flatten(request.turns, tools: []) : request.turns
        let instructions = turns.first?.role == .system ? turns.removeFirst().content : ""
        var prompt = turns.last?.role == .user ? turns.removeLast().content : ""
        if let prefix = request.assistantPrefix, !prefix.isEmpty {
            // The system model can't extend a reply in place: it's asked to continue it.
            if !prompt.isEmpty { turns.append(ChatTurn(role: .user, content: prompt)) }
            turns.append(ChatTurn(role: .assistant, content: prefix))
            prompt = "Continue your previous answer exactly where it stopped, without repeating any of it."
        }
        // About 3.5 characters per token, leaving room for the reply.
        let reply = min(max(request.maxTokens, 256), 1024)
        var budget = Int(Double(contextSize - reply) * 3.5) - instructions.count - prompt.count
        var kept: [ChatTurn] = []
        for turn in turns.reversed() where turn.role == .user || turn.role == .assistant {
            budget -= turn.content.count
            guard budget >= 0 else { break }
            kept.insert(turn, at: 0)
        }
        while kept.first?.role == .assistant { kept.removeFirst() }

        var entries: [Transcript.Entry] = []
        if !instructions.isEmpty {
            entries.append(.instructions(Transcript.Instructions(segments: [.text(Transcript.TextSegment(content: instructions))],
                                                                 toolDefinitions: [])))
        }
        for turn in kept {
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: turn.content))
            if turn.role == .user {
                entries.append(.prompt(Transcript.Prompt(segments: [segment])))
            } else {
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [segment])))
            }
        }
        let text = ([instructions] + kept.map(\.content) + [prompt]).filter { !$0.isEmpty }.joined(separator: "\n")
        return (Transcript(entries: entries), prompt, text)
    }

    /// The model's own count where the system provides it (iOS 26.4), an estimate otherwise.
    static func tokenCount(_ text: String) async -> Int {
        if #available(iOS 26.4, *), let count = try? await SystemLanguageModel.default.tokenCount(for: text) {
            return count
        }
        return max(1, text.count / 4)
    }

    static func describe(_ error: Error) -> Error {
        guard let failure = error as? LanguageModelSession.GenerationError else { return error }
        switch failure {
        case .exceededContextWindowSize:
            return Failure(message: "The conversation is longer than Apple's on-device model can read (4,096 tokens). Start a new conversation or pick a model with a longer context.")
        case .guardrailViolation, .refusal:
            return Failure(message: "Apple's on-device model declined to answer this. Try rephrasing, or pick another model.")
        case .assetsUnavailable:
            return Failure(message: "Apple Intelligence's model isn't available right now. Try again later.")
        case .rateLimited:
            return Failure(message: "Apple Intelligence is busy. Try again in a moment.")
        case .unsupportedLanguageOrLocale:
            return Failure(message: "Apple's on-device model doesn't support this language yet.")
        default:
            return Failure(message: "Apple's on-device model couldn't answer: \(failure.localizedDescription)")
        }
    }

    // MARK: InferenceBackend

    func interrupt(_ reason: InterruptReason) {
        interruptState.withLock { $0 = reason }
    }

    func setPacing(_ pacing: Duration) {}
    func resetCache() async {}

    func countTokens(_ text: String) async -> Int {
        await Self.tokenCount(text)
    }

    func benchmark(promptLength: Int, generateLength: Int, repetitions: Int,
                   progress: @escaping @Sendable (Double) -> Void) async throws -> BenchmarkMeasurement {
        throw Failure(message: "Apple's on-device model can't be benchmarked: iOS doesn't report its token timing.")
    }

    func close() async {
        interrupt(.unload)
    }
}

extension InstalledModel {
    /// Apple's on-device model as an entry in the model list.
    static var appleFoundation: InstalledModel {
        InstalledModel(
            id: AppleFoundationBackend.modelID, displayName: "Apple Intelligence", developer: "Apple", repo: nil,
            fileName: "", relativePath: "", sizeBytes: 0, sha256: nil, verification: .verified, quantization: nil,
            facts: ArchitectureFacts(architecture: "apple-foundation", layers: 0, kvElementsFull: 0, embeddingLength: 0, vocabSize: 0,
                                     trainContext: AppleFoundationBackend.contextSize, parameters: 3),
            license: "Apple", source: .system, catalogID: nil, addedAt: .distantPast)
    }

    /// Built into the system rather than a downloaded file.
    var isSystem: Bool { source == .system }
}
