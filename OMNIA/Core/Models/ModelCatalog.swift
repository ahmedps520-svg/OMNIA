import Foundation

/// One downloadable GGUF file of a catalog model.
struct CatalogVariant: Identifiable, Hashable, Sendable {
    let quant: String
    let fileName: String
    let sizeBytes: Int64
    let sha256: String

    var id: String { fileName }

    func bitsPerWeight(parameters: Double) -> Double {
        guard parameters > 0 else { return QuantizationInfo.bitsPerWeight(quant) ?? 4.8 }
        return Double(sizeBytes) * 8 / (parameters * 1e9)
    }

    /// Short human label: "Q4_K_M · 4.9 bit".
    func label(parameters: Double) -> String {
        "\(quant) · \(String(format: "%.1f", bitsPerWeight(parameters: parameters))) bit"
    }
}

/// A curated, verified model from a public Hugging Face repository.
struct CatalogModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let developer: String
    let repo: String
    let license: String
    let released: String
    let summary: String
    /// Curated reasoning/chat quality score (0–100) from vendor-reported benchmarks.
    let qualityScore: Double
    let tags: [String]
    let facts: ArchitectureFacts
    let variants: [CatalogVariant]

    var parameterLabel: String {
        if facts.isMixtureOfExperts {
            return "\(ParameterFormat.label(billions: facts.parameters)) · \(ParameterFormat.label(billions: facts.activeParameters)) active"
        }
        return ParameterFormat.label(billions: facts.parameters)
    }

    var architectureLabel: String { ModelCatalog.architectureName(facts.architecture) }

    var huggingFaceURL: URL { HuggingFaceClient.base.appending(path: repo) }

    func downloadRequest(for variant: CatalogVariant) -> DownloadRequest {
        DownloadRequest(
            id: InstalledModel.makeID(repo: repo, fileName: variant.fileName),
            repo: repo,
            path: variant.fileName,
            fileName: variant.fileName,
            displayName: "\(name) \(variant.quant)",
            developer: developer,
            expectedBytes: variant.sizeBytes,
            sha256: variant.sha256,
            license: license,
            catalogID: id
        )
    }

    /// Quality of a specific quantization, after its precision penalty.
    func quality(of variant: CatalogVariant) -> Double {
        qualityScore - QuantizationInfo.qualityPenalty(bitsPerWeight: variant.bitsPerWeight(parameters: facts.parameters))
    }
}

/// How a model fits on this device at a given quantization.
enum Compatibility: Sendable, Hashable {
    case comfortable    // fits at the profile's default context with room to spare
    case fits           // fits at a useful context
    case tight          // fits only with a reduced context
    case tooLarge

    var title: String {
        switch self {
        case .comfortable: "Runs comfortably"
        case .fits: "Fits"
        case .tight: "Tight fit"
        case .tooLarge: "Too large for this device"
        }
    }

    var symbol: String {
        switch self {
        case .comfortable: "checkmark.circle.fill"
        case .fits: "checkmark.circle"
        case .tight: "exclamationmark.circle"
        case .tooLarge: "xmark.circle"
        }
    }

    var isUsable: Bool { self != .tooLarge }
}

struct VariantAssessment: Hashable, Sendable {
    let plan: LoadPlan
    let compatibility: Compatibility
    let estimatedTokensPerSecond: Double
    let quality: Double
}

struct Recommendation: Hashable, Sendable {
    let mode: RecommendationMode
    let model: CatalogModel
    let variant: CatalogVariant
    let assessment: VariantAssessment
    let rationale: String
}

enum ModelCatalog {
    static var all: [CatalogModel] { curated }

    static func model(id: String?) -> CatalogModel? {
        guard let id else { return nil }
        return curated.first { $0.id == id }
    }

    static func architectureName(_ architecture: String) -> String {
        let names: [String: String] = [
            "qwen35": "Qwen3.5 hybrid", "qwen35moe": "Qwen3.5 MoE", "qwen3": "Qwen3", "qwen3moe": "Qwen3 MoE",
            "gemma4": "Gemma 4", "gemma3": "Gemma 3", "gpt-oss": "gpt-oss MoE", "lfm2moe": "LFM2 MoE", "lfm2": "LFM2",
            "lfm3": "LFM3 hybrid", "muse-glimmer": "Muse Glimmer", "mistral3": "Mistral 3", "llama": "Llama",
            "granite": "Granite", "granitehybrid": "Granite hybrid", "phi3": "Phi"
        ]
        return names[architecture] ?? architecture
    }

    // MARK: Assessment

    /// Evaluates one file against the current memory limits: actual file size, architecture,
    /// context requirements and runtime memory. Parameter count alone never rules a model out.
    static func assess(_ model: CatalogModel, _ variant: CatalogVariant, device: DeviceProfile,
                       profile: OptimizationProfile, budget: MemoryBudget, kvChoice: KVCacheChoice = .automatic,
                       flashAttention: Bool = true) -> VariantAssessment {
        let size = UInt64(max(variant.sizeBytes, 0))
        let plan = MemoryPlanner.plan(model.facts, fileSize: size, requestedContext: nil, kvChoice: kvChoice,
                                      profile: profile, allowance: budget.allowance, flashAttention: flashAttention)
        let compatibility: Compatibility
        if !plan.fits {
            compatibility = .tooLarge
        } else if plan.contextLength >= plan.requestedContext {
            compatibility = plan.estimate.total < UInt64(Double(budget.usable) * 0.85) ? .comfortable : .fits
        } else if plan.contextLength >= profile.minimumUsefulContext {
            compatibility = .fits
        } else {
            compatibility = .tight
        }
        return VariantAssessment(
            plan: plan,
            compatibility: compatibility,
            estimatedTokensPerSecond: MemoryPlanner.estimatedTokensPerSecond(fileSize: size, facts: model.facts, device: device),
            quality: model.quality(of: variant)
        )
    }

    /// The best variant of a model that fits (highest quality, then speed).
    static func bestVariant(of model: CatalogModel, device: DeviceProfile, profile: OptimizationProfile,
                            budget: MemoryBudget) -> (CatalogVariant, VariantAssessment)? {
        model.variants
            .map { ($0, assess(model, $0, device: device, profile: profile, budget: budget)) }
            .filter { $0.1.compatibility.isUsable && $0.1.plan.contextLength >= profile.minimumUsefulContext / 2 }
            .max { lhs, rhs in
                lhs.1.quality == rhs.1.quality
                    ? lhs.1.estimatedTokensPerSecond < rhs.1.estimatedTokensPerSecond
                    : lhs.1.quality < rhs.1.quality
            }
    }

    // MARK: Recommendations

    static func recommend(_ mode: RecommendationMode, device: DeviceProfile, profile: OptimizationProfile,
                          budget: MemoryBudget) -> Recommendation? {
        var candidates: [(CatalogModel, CatalogVariant, VariantAssessment)] = []
        for model in curated {
            for variant in model.variants {
                let assessment = assess(model, variant, device: device, profile: profile, budget: budget)
                guard assessment.compatibility.isUsable,
                      assessment.plan.contextLength >= profile.minimumUsefulContext else { continue }
                candidates.append((model, variant, assessment))
            }
        }
        guard !candidates.isEmpty else { return nil }

        let qualityFloor = (candidates.map(\.2.quality).max() ?? 0) - 18
        let chosen: (CatalogModel, CatalogVariant, VariantAssessment)?
        switch mode {
        case .maxQuality:
            chosen = candidates.max { score($0.2, quality: 1, speed: 0.01) < score($1.2, quality: 1, speed: 0.01) }
        case .balanced:
            let target = profile.comfortableTokensPerSecond
            chosen = candidates.max { lhs, rhs in
                balancedScore(lhs.2, target: target, efficiency: profile.kind == .efficiency, size: lhs.1.sizeBytes)
                    < balancedScore(rhs.2, target: target, efficiency: profile.kind == .efficiency, size: rhs.1.sizeBytes)
            }
        case .maxSpeed:
            chosen = candidates.filter { $0.2.quality >= qualityFloor - 6 }
                .max { score($0.2, quality: 0.02, speed: 1) < score($1.2, quality: 0.02, speed: 1) }
        case .maxContext:
            chosen = candidates.filter { $0.2.quality >= qualityFloor }
                .max { lhs, rhs in
                    let l = lhs.2.plan.maxContextThatFits ?? lhs.2.plan.contextLength
                    let r = rhs.2.plan.maxContextThatFits ?? rhs.2.plan.contextLength
                    return l == r ? lhs.2.quality < rhs.2.quality : l < r
                }
        }
        guard let pick = chosen else { return nil }
        let (model, variant, assessment) = pick
        return Recommendation(mode: mode, model: model, variant: variant, assessment: assessment,
                              rationale: rationale(mode, model: model, variant: variant, assessment: assessment, device: device))
    }

    private static func score(_ a: VariantAssessment, quality: Double, speed: Double) -> Double {
        a.quality * quality + a.estimatedTokensPerSecond * speed
    }

    /// Quality, minus a penalty for being slower than comfortable. On the efficiency profile,
    /// large files are also penalized: they cost more energy per token and heat the device faster.
    private static func balancedScore(_ a: VariantAssessment, target: Double, efficiency: Bool, size: Int64) -> Double {
        var value = a.quality - max(0, target - a.estimatedTokensPerSecond) * 1.5
        if efficiency { value -= max(0, Double(size) / 1e9 - 4) * 1.5 }
        return value
    }

    private static func rationale(_ mode: RecommendationMode, model: CatalogModel, variant: CatalogVariant,
                                  assessment: VariantAssessment, device: DeviceProfile) -> String {
        let memory = ByteFormat.memory(assessment.plan.estimate.total)
        let context = ByteFormat.tokens(assessment.plan.maxContextThatFits ?? assessment.plan.contextLength)
        let speed = String(format: "~%.0f tok/s", assessment.estimatedTokensPerSecond)
        switch mode {
        case .maxQuality:
            return "The highest-quality model that fits safely in \(device.name)'s memory: about \(memory) at runtime, \(speed) estimated."
        case .balanced:
            return "Strong reasoning at a conversational \(speed) estimated, using about \(memory)."
        case .maxSpeed:
            return "The quickest capable option: \(speed) estimated with a \(ByteFormat.file(variant.sizeBytes)) download."
        case .maxContext:
            return "Supports up to \(context) tokens of context on this device, ideal for long documents."
        }
    }
}
