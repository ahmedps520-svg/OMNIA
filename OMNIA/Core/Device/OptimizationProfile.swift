import Foundation

enum RecommendationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case maxQuality, balanced, maxSpeed, maxContext
    var id: String { rawValue }

    var title: String {
        switch self {
        case .maxQuality: "Maximum Quality"
        case .balanced: "Balanced"
        case .maxSpeed: "Maximum Speed"
        case .maxContext: "Maximum Context"
        }
    }

    var symbol: String {
        switch self {
        case .maxQuality: "sparkle"
        case .balanced: "circle.lefthalf.filled"
        case .maxSpeed: "hare"
        case .maxContext: "text.alignleft"
        }
    }

    var explanation: String {
        switch self {
        case .maxQuality: "The most capable model that fits safely, at its highest affordable precision."
        case .balanced: "Strong reasoning with comfortable, conversational speed."
        case .maxSpeed: "The fastest responses that still clear a quality bar."
        case .maxContext: "The longest context window for documents and long conversations."
        }
    }
}

/// How OMNIA tunes inference for the hardware class.
///
/// iPad prioritizes model quality and context length; iPhone prioritizes efficient inference,
/// thermal stability and battery life. The user can override the automatic choice in Settings.
struct OptimizationProfile: Sendable, Hashable {
    enum Kind: String, Sendable { case quality, efficiency }

    let kind: Kind
    let title: String
    let summary: String
    /// Context used when the user leaves context length on Automatic.
    let defaultContext: Int
    let minimumContext: Int
    let maximumContext: Int
    /// KV-cache precisions tried in order when the user leaves the cache on Automatic.
    let kvPreference: [KVCacheType]
    let batchSize: Int
    let microBatchSize: Int
    /// Upper bound on the fraction of measured headroom a model may use, whatever the user picks.
    let headroomCap: Double
    /// Share of physical RAM that resident model memory (weights included) may occupy,
    /// for conservative / balanced / maximum safety.
    let physicalShare: (conservative: Double, balanced: Double, maximum: Double)
    /// Memory always left untouched for the system, the UI and transient allocations.
    let reserveBytes: UInt64
    /// After loading, at least this much of the app's own limit must remain or the load is undone.
    let minimumHeadroomAfterLoad: UInt64
    let idleUnloadMinutes: Int
    /// Seconds after entering the background before loaded models are released.
    let backgroundUnloadDelay: TimeInterval
    /// Extra delay per token while the device reports a serious thermal state.
    let seriousThermalPacing: Duration
    let defaultRecommendation: RecommendationMode
    /// Speed below which the Balanced recommendation starts to penalize a model.
    let comfortableTokensPerSecond: Double
    /// Smallest context a recommendation must support.
    let minimumUsefulContext: Int

    static let iPadQuality = OptimizationProfile(
        kind: .quality,
        title: "Maximum quality",
        summary: "Targets the most capable model and the longest context that fit safely in unified memory.",
        defaultContext: 32_768,
        minimumContext: 4_096,
        maximumContext: 131_072,
        kvPreference: [.f16, .q8_0, .q4_0],
        batchSize: 1_024,
        microBatchSize: 512,
        headroomCap: 0.94,
        physicalShare: (conservative: 0.66, balanced: 0.72, maximum: 0.78),
        reserveBytes: 512 << 20,
        minimumHeadroomAfterLoad: 512 << 20,
        idleUnloadMinutes: 30,
        backgroundUnloadDelay: 60,
        seriousThermalPacing: .zero,
        defaultRecommendation: .maxQuality,
        comfortableTokensPerSecond: 12,
        minimumUsefulContext: 8_192
    )

    static let iPhoneEfficiency = OptimizationProfile(
        kind: .efficiency,
        title: "Efficiency",
        summary: "Favors fast, cool, battery-friendly inference: compact KV cache, moderate context, quicker release of memory.",
        defaultContext: 8_192,
        minimumContext: 2_048,
        maximumContext: 32_768,
        kvPreference: [.q8_0, .q4_0],
        batchSize: 512,
        microBatchSize: 512,
        headroomCap: 0.88,
        physicalShare: (conservative: 0.52, balanced: 0.58, maximum: 0.64),
        reserveBytes: 384 << 20,
        minimumHeadroomAfterLoad: 384 << 20,
        idleUnloadMinutes: 5,
        backgroundUnloadDelay: 15,
        seriousThermalPacing: .milliseconds(30),
        defaultRecommendation: .balanced,
        comfortableTokensPerSecond: 18,
        minimumUsefulContext: 4_096
    )

    static func == (lhs: OptimizationProfile, rhs: OptimizationProfile) -> Bool { lhs.kind == rhs.kind }
    func hash(into hasher: inout Hasher) { hasher.combine(kind) }

    func physicalShare(for safety: MemorySafety) -> Double {
        switch safety {
        case .conservative: physicalShare.conservative
        case .balanced: physicalShare.balanced
        case .maximum: physicalShare.maximum
        }
    }

    static func resolve(device: DeviceProfile, preference: ProfilePreference) -> OptimizationProfile {
        switch preference {
        case .quality: return .iPadQuality
        case .efficiency: return .iPhoneEfficiency
        case .automatic: return device.isPad ? .iPadQuality : .iPhoneEfficiency
        }
    }

    /// CPU threads for llama.cpp. With full GPU offload these only feed the GPU and sample,
    /// so the performance cores are enough; efficiency cores stay free for the UI.
    func threads(for device: DeviceProfile) -> Int {
        max(2, min(device.performanceCores, kind == .efficiency ? 2 : 4))
    }
}
