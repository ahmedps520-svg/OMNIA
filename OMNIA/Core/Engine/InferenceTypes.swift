import Foundation

enum ChatRole: String, Codable, Sendable, CaseIterable {
    /// `tool` only appears in prompts (a tool's result); stored messages are system, user or assistant.
    case system, user, assistant, tool
}

/// One turn of a conversation as handed to the model's chat template.
struct ChatTurn: Hashable, Sendable {
    var role: ChatRole
    var content: String
    /// Calls an assistant turn made.
    var toolCalls: [ToolCall] = []
    /// For `.tool` turns: the call this result answers, and the tool's name.
    var toolCallID: String?
    var toolName: String?
    /// Images shown with a user turn (encoded image files, e.g. JPEG), placed before its text.
    var images: [Data] = []

    /// A tool call or a tool's result, which templates without tool support can't show natively.
    var carriesTools: Bool { role == .tool || !toolCalls.isEmpty }
}

enum KVCacheType: String, Codable, Sendable, CaseIterable, Identifiable {
    case f16, q8_0, q4_0
    var id: String { rawValue }

    /// Storage cost per cached element (ggml block sizes: Q8_0 = 34 B / 32, Q4_0 = 18 B / 32).
    var bytesPerElement: Double {
        switch self {
        case .f16: 2.0
        case .q8_0: 34.0 / 32.0
        case .q4_0: 18.0 / 32.0
        }
    }

    var label: String {
        switch self {
        case .f16: "F16"
        case .q8_0: "Q8_0"
        case .q4_0: "Q4_0"
        }
    }

    /// Quantized V caches require flash attention in llama.cpp.
    var requiresFlashAttention: Bool { self != .f16 }
}

/// Runtime parameters used to create an inference context.
struct RuntimeConfiguration: Hashable, Codable, Sendable {
    var contextLength: Int
    var batchSize: Int
    var microBatchSize: Int
    var threads: Int
    var gpuOffload: Bool
    var kvCacheType: KVCacheType
    var flashAttention: Bool
    /// Recurrent-state snapshots kept so speculative decoding can undo rejected tokens on hybrid
    /// models (llama.cpp `n_rs_seq`); 0 when not needed.
    var rollbackDepth: Int = 0
    /// Spreads the model over a cluster's devices instead of this one alone.
    var cluster: ClusterPlacement? = nil
}

struct SamplingParameters: Hashable, Codable, Sendable {
    var temperature: Double
    var topP: Double
    var topK: Int
    var minP: Double
    var repetitionPenalty: Double
    var repetitionLastN: Int
    var seed: UInt32?

    init(_ settings: GenerationSettings) {
        temperature = settings.temperature
        topP = settings.topP
        topK = settings.topK
        minP = settings.minP
        repetitionPenalty = settings.repetitionPenalty
        repetitionLastN = settings.repetitionLastN
        seed = settings.seed
    }
}

struct GenerationRequest: Sendable {
    /// Full conversation, system turn first when present.
    var turns: [ChatTurn]
    /// Text already produced for the reply being continued ("Continue generation").
    var assistantPrefix: String?
    var sampling: SamplingParameters
    var maxTokens: Int
    /// Extra chat-template variables, e.g. `enable_thinking` for reasoning models.
    var templateVariables: [String: TemplateValue] = [:]
    /// Reuse the KV cache for the longest common token prefix with the previous request.
    var reusePromptCache: Bool = true
    /// Extra delay between tokens; set by the thermal policy on the efficiency profile.
    var pacing: Duration = .zero
    /// Functions the model may call in this reply.
    var tools: [ToolDefinition] = []
    /// Constrains the reply's text, e.g. to valid JSON.
    var responseFormat: ResponseFormat = .text
    /// Text that ends the reply when the model writes it. It isn't included in the reply.
    var stopSequences: [String] = []
    /// The conversation whose saved model memory may be restored and updated (set by the chat).
    var memoryKey: UUID?
    /// Where that memory lives for the loaded model and settings (filled in by the engine).
    var memory: ConversationMemoryRequest?
    /// Use the attached draft model, if any (speculative decoding).
    var speculative: Bool = true
}

/// The shape of a reply.
enum ResponseFormat: Hashable, Sendable {
    case text
    /// A JSON object, enforced token by token with llama.cpp's JSON grammar.
    case json
    /// Any GBNF grammar whose start rule is `root`.
    case grammar(String)
}

/// What the runtime decided while preparing a prompt.
struct PromptInfo: Equatable, Sendable {
    /// The template already opened a thinking block, so the first generated text is reasoning.
    var opensInReasoning: Bool
    /// How the model writes tool calls in this reply; nil when no tools were offered.
    var toolCallFormat: ToolCallFormat?
    /// Tokens restored from saved conversation memory for this prompt.
    var restoredTokens: Int = 0
}

enum StopReason: String, Codable, Sendable {
    case endOfSequence, maxTokens, cancelled, contextFull, interrupted, failed

    var label: String {
        switch self {
        case .endOfSequence: "Complete"
        case .maxTokens: "Reached the output limit"
        case .cancelled: "Stopped"
        case .contextFull: "Context window full"
        case .interrupted: "Interrupted"
        case .failed: "Failed"
        }
    }

    var canContinue: Bool {
        switch self {
        case .maxTokens, .cancelled, .interrupted, .contextFull: true
        case .endOfSequence, .failed: false
        }
    }
}

/// Measured statistics for one generation. Every number is timed on device; nothing is simulated.
struct GenerationStats: Codable, Hashable, Sendable {
    var promptTokens: Int
    var reusedPromptTokens: Int
    var generatedTokens: Int
    var timeToFirstToken: Double
    var promptTokensPerSecond: Double
    var tokensPerSecond: Double
    var totalDuration: Double
    var contextUsed: Int
    var contextSize: Int
    var stopReason: StopReason
    var modelID: String
    var modelName: String
    /// Oldest turns dropped so the prompt fit the context window.
    var trimmedTurns: Int?
    /// Tokens restored from the conversation's saved memory instead of being re-read.
    var restoredPromptTokens: Int?
    /// Speculative decoding: tokens the draft model proposed, and how many the model kept.
    var draftedTokens: Int?
    var acceptedDraftTokens: Int?
    /// Images in the prompt, and the context they take up (included in `promptTokens`).
    var imageCount: Int?
    var imageTokens: Int?
    /// Why OMNIA stopped the reply, when `stopReason` is `.interrupted`.
    var interruption: InterruptReason?

    /// Share of drafted tokens the model kept.
    var draftAcceptance: Double? {
        guard let drafted = draftedTokens, drafted > 0, let accepted = acceptedDraftTokens else { return nil }
        return Double(accepted) / Double(drafted)
    }

    var contextUtilization: Double {
        contextSize > 0 ? Double(contextUsed) / Double(contextSize) : 0
    }

    /// Statistics for a reply written in several rounds (with tool calls in between): token
    /// counts and generation time add up; time to first token comes from the first round;
    /// speeds, prompt and context figures from the latest.
    func merged(with next: GenerationStats) -> GenerationStats {
        var result = next
        result.generatedTokens += generatedTokens
        result.totalDuration += totalDuration
        result.timeToFirstToken = timeToFirstToken
        result.restoredPromptTokens = restoredPromptTokens ?? next.restoredPromptTokens
        return result
    }
}

enum GenerationEvent: Sendable {
    /// The prompt was formatted (see `PromptInfo`).
    case started(PromptInfo)
    /// Fraction of the prompt evaluated so far (0…1). Only emitted for long prompts.
    case promptProgress(Double)
    /// Newly decoded text (always valid UTF-8).
    case text(String)
    case finished(GenerationStats)
}

struct LoadedModelInfo: Sendable, Hashable {
    let modelID: String
    let displayName: String
    let architecture: String
    let configuration: RuntimeConfiguration
    let trainContextLength: Int
    let parameterCount: UInt64
    let tensorBytes: UInt64
    /// Change in process footprint across load (excludes clean, file-backed weight pages).
    let measuredFootprintBytes: UInt64
    /// Change in Metal allocations across load (includes weight buffers, KV cache and compute).
    let measuredGPUBytes: UInt64
    let loadDuration: Double
    let chatTemplate: String?
    let supportsThinkingToggle: Bool
}

struct BenchmarkMeasurement: Codable, Hashable, Sendable {
    var promptTokens: Int
    var generatedTokens: Int
    var promptTokensPerSecond: Double
    var promptStdDev: Double
    var tokensPerSecond: Double
    var generationStdDev: Double
    var timeToFirstToken: Double
    var peakFootprintBytes: UInt64
    var repetitions: Int
}

enum InferenceError: LocalizedError {
    case modelFileMissing(String)
    case invalidModelFile(String)
    case loadFailed(String)
    case contextCreationFailed(String)
    case insufficientMemory(required: UInt64, available: UInt64, suggestion: String?)
    case tokenizationFailed
    case templateFailed
    case decodeFailed(Int32)
    /// A GPU step failed; the text is Metal's own description of why ("Insufficient Memory …").
    case gpuFailed(String)
    /// The engine itself reported a failure (MLX losing the GPU, for one).
    case engineFailed(String)
    case promptTooLong(tokens: Int, context: Int)
    case backgroundExecution
    case busy
    case noModelSelected
    case modelNotInstalled
    case thermalLimit
    case grammarFailed
    case imagesUnsupported(String)
    case imageEncoderMissing
    case imageEncoderFailed
    case imageUnreadable
    case imageFailed(String)
    /// A device holding part of a cluster model stopped answering.
    case clusterDeviceLost(String)

    var errorDescription: String? {
        switch self {
        case .clusterDeviceLost(let name):
            "Lost the connection to \(name), which holds part of the model. Keep OMNIA open with the screen on for every iPhone and iPad in the cluster, and the OMNIA Node window open on PCs. The model reloads on the devices that are left for your next message; tap Continue to try again."
        case .modelFileMissing(let name):
            "The model file for \(name) is missing. Re-download or re-import it."
        case .invalidModelFile(let reason):
            "This model file can't be used: \(reason)"
        case .loadFailed(let reason):
            "The model failed to load. \(reason)"
        case .contextCreationFailed(let reason):
            "Couldn't allocate the inference context. \(reason)"
        case let .insufficientMemory(required, available, suggestion):
            "Not enough memory: needs \(ByteFormat.memory(required)), \(ByteFormat.memory(available)) is safely available."
                + (suggestion.map { " \($0)" } ?? "")
        case .tokenizationFailed:
            "The prompt couldn't be tokenized."
        case .templateFailed:
            "The model's chat template couldn't be applied."
        case .decodeFailed(let code):
            "Inference failed (llama_decode returned \(code)). The model reloads for your next message; tap Continue to try again."
        case .gpuFailed(let reason):
            "The GPU stopped: \(InferenceError.plainGPUReason(reason)) (Metal said \u{201C}\(reason)\u{201D}). The model reloads for your next message; tap Continue to try again."
        case .engineFailed(let message):
            "The model stopped working (\(message)). It reloads for your next message; tap Continue to try again."
        case let .promptTooLong(tokens, context):
            "The prompt needs \(tokens) tokens but the context window holds \(context). Increase the context length or start a new conversation."
        case .backgroundExecution:
            "Generation paused because OMNIA moved to the background. iPadOS and iOS don't allow GPU work in the background."
        case .busy:
            "Another response is still being generated."
        case .noModelSelected:
            "Choose a model to start chatting."
        case .modelNotInstalled:
            "This model isn't downloaded yet."
        case .thermalLimit:
            "Generation stopped to let the device cool down."
        case .grammarFailed:
            "The response format couldn't be applied to this model."
        case .imagesUnsupported(let name):
            "\(name) can't see images. Add its image support in Models, or switch to a model that has it."
        case .imageEncoderMissing:
            "The image encoder file for this model is missing. Add image support again in Models."
        case .imageEncoderFailed:
            "The image encoder couldn't be loaded with this model. Make sure it was made for this exact model."
        case .imageUnreadable:
            "An attached image couldn't be read."
        case .imageFailed(let reason):
            "The image couldn't be processed. \(reason)"
        }
    }
}

extension InferenceError {
    /// The engine's GPU state may be broken (a failed Metal command buffer): the model has to be
    /// loaded again before its next reply.
    var needsReload: Bool {
        switch self {
        case .decodeFailed, .gpuFailed, .engineFailed, .clusterDeviceLost: true
        default: false
        }
    }

    /// Metal's description of a failed GPU step, in plain words.
    static func plainGPUReason(_ reason: String) -> String {
        let text = reason.lowercased()
        if text.contains("outofmemory") || text.contains("insufficient memory") {
            return "this device ran out of memory for the model"
        }
        if text.contains("background") || text.contains("insufficient permission") || text.contains("notpermitted") {
            return "iOS doesn't allow GPU work while OMNIA is in the background"
        }
        if text.contains("interactivity") {
            return "iOS stopped a long GPU step to keep the screen responsive"
        }
        if text.contains("timeout") {
            return "a GPU step took too long and iOS stopped it"
        }
        if text.contains("pagefault") || text.contains("page fault") || text.contains("invalid resource") {
            return "it read memory it had no access to, which is a bug in OMNIA's engine"
        }
        return "a GPU step failed"
    }
}

extension InterruptReason {
    /// Why a reply paused, shown under it; nil for the user's own stop. `device` is "iPad" or "iPhone".
    func pauseMessage(device: String) -> String? {
        switch self {
        case .user: nil
        case .background: "Paused because OMNIA left the screen: iOS doesn't allow GPU work in the background. Tap Continue to resume."
        case .memoryPressure: "Paused because this \(device) ran low on memory, so OMNIA released the model to keep it stable. Tap Continue to resume."
        case .thermal: "Paused because this \(device) got too hot. Tap Continue once it has cooled down."
        case .unload: "Paused because the model was unloaded. Tap Continue to resume."
        }
    }
}
