import Foundation

enum ChatRole: String, Codable, Sendable, CaseIterable {
    case system, user, assistant
}

/// One turn of a conversation as handed to the model's chat template.
struct ChatTurn: Hashable, Sendable {
    var role: ChatRole
    var content: String
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

    var contextUtilization: Double {
        contextSize > 0 ? Double(contextUsed) / Double(contextSize) : 0
    }
}

enum GenerationEvent: Sendable {
    /// The prompt was formatted. `opensInReasoning` is true when the template already opened a
    /// thinking block, so the first generated text is reasoning rather than the answer.
    case started(opensInReasoning: Bool)
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
    case promptTooLong(tokens: Int, context: Int)
    case backgroundExecution
    case busy
    case noModelSelected
    case modelNotInstalled
    case thermalLimit

    var errorDescription: String? {
        switch self {
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
            "Inference failed (llama_decode returned \(code))."
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
        }
    }
}
