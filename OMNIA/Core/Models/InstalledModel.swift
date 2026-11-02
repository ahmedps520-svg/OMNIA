import Foundation

enum VerificationState: String, Codable, Sendable {
    /// SHA-256 matched the publisher's published hash and the GGUF header parsed.
    case verified
    /// The GGUF header parsed, but there was no published hash to compare against (imports).
    case structureValid
    case failed
}

enum ModelSource: String, Codable, Sendable {
    case catalog, huggingFace, imported
}

/// Per-model settings that override the global defaults.
struct ModelSettings: Codable, Hashable, Sendable {
    var contextLength: Int?
    var kvCache: KVCacheChoice?
    var generation: GenerationOverrides?
    var systemPrompt: String?
    /// For hybrid reasoning models (chat template has `enable_thinking`).
    var thinkingEnabled: Bool?
}

/// A GGUF model stored on this device.
struct InstalledModel: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var displayName: String
    var developer: String?
    var repo: String?
    var fileName: String
    /// Path relative to the Models directory.
    var relativePath: String
    var sizeBytes: UInt64
    var sha256: String?
    var verification: VerificationState
    var quantization: String?
    var facts: ArchitectureFacts
    var license: String?
    var source: ModelSource
    var catalogID: String?
    var addedAt: Date
    var lastUsedAt: Date?
    var settings: ModelSettings = ModelSettings()
    /// Footprint change measured on the last load, with the configuration it was measured at.
    var measuredFootprint: UInt64?
    var measuredGPUBytes: UInt64?
    var measuredContext: Int?
    var benchmark: BenchmarkMeasurement?
    var benchmarkDate: Date?
    var benchmarkContext: Int?

    var parameterLabel: String { ParameterFormat.label(billions: facts.parameters) }

    var bitsPerWeight: Double? {
        guard facts.parameters > 0 else { return QuantizationInfo.bitsPerWeight(quantization) }
        return Double(sizeBytes) * 8 / (facts.parameters * 1e9)
    }

    static func makeID(repo: String?, fileName: String) -> String {
        if let repo { return "\(repo)/\(fileName)" }
        return "local/\(fileName)"
    }
}

enum ParameterFormat {
    static func label(billions: Double) -> String {
        if billions <= 0 { return "—" }
        if billions >= 10 { return String(format: "%.0fB", billions) }
        if billions >= 1 { return String(format: "%.1fB", billions).replacingOccurrences(of: ".0B", with: "B") }
        return String(format: "%.0fM", billions * 1000)
    }
}
