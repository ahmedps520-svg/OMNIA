import Foundation

/// The architecture facts that decide runtime memory, read from a model's GGUF header.
///
/// KV-cache size is expressed as cached elements per token, already summed over layers, so
/// hybrid layouts reduce to two numbers: full-attention layers grow with the context, and
/// sliding-window layers grow only up to their window.
struct ArchitectureFacts: Codable, Hashable, Sendable {
    var architecture: String
    var layers: Int
    /// Σ over full-attention layers of KV heads × (key + value head size).
    var kvElementsFull: Int
    /// Σ over sliding-window layers of KV heads × (key + value head size).
    var kvElementsSliding: Int
    var slidingWindow: Int
    /// Multi-head latent attention (DeepSeek-style) compresses the cache to this rank.
    var kvLoraRank: Int
    /// Fixed-size state of recurrent / linear-attention / short-convolution layers.
    var recurrentStateBytes: UInt64
    var embeddingLength: Int
    var vocabSize: Int
    var trainContext: Int
    /// Billions of parameters, total and active per token (equal for dense models).
    var parameters: Double
    var activeParameters: Double
    var thinkingToggle: Bool

    init(architecture: String, layers: Int, kvElementsFull: Int, kvElementsSliding: Int = 0,
         slidingWindow: Int = 0, kvLoraRank: Int = 0, recurrentStateBytes: UInt64 = 0,
         embeddingLength: Int, vocabSize: Int, trainContext: Int,
         parameters: Double, activeParameters: Double? = nil, thinkingToggle: Bool = false) {
        self.architecture = architecture
        self.layers = layers
        self.kvElementsFull = kvElementsFull
        self.kvElementsSliding = kvElementsSliding
        self.slidingWindow = slidingWindow
        self.kvLoraRank = kvLoraRank
        self.recurrentStateBytes = recurrentStateBytes
        self.embeddingLength = embeddingLength
        self.vocabSize = vocabSize
        self.trainContext = trainContext
        self.parameters = parameters
        self.activeParameters = activeParameters ?? parameters
        self.thinkingToggle = thinkingToggle
    }

    /// Mirrors how llama.cpp lays out memory per layer for the architecture.
    init(info: GGUFModelInfo, fileSize: UInt64) {
        let layers = info.blockCount ?? 32
        let perLayerHeads = info.headCountKVPerLayer ?? Array(repeating: info.headCount ?? 8, count: layers)
        let headDim = info.headDimension ?? 128
        let keyLength = info.keyLength ?? headDim
        let valueLength = info.valueLength ?? keyLength
        let keyLengthSWA = info.keyLengthSWA ?? keyLength
        let valueLengthSWA = info.valueLengthSWA ?? valueLength
        let kvLayerLimit = layers - min(layers, info.sharedKVLayers ?? 0)

        var full = 0
        var sliding = 0
        var recurrentLayers = 0
        for index in 0..<layers {
            let heads = index < perLayerHeads.count ? perLayerHeads[index] : (perLayerHeads.last ?? 0)
            let isRecurrent: Bool
            if let interval = info.fullAttentionInterval, interval > 0 {
                isRecurrent = (index + 1) % interval != 0
            } else {
                isRecurrent = heads == 0
            }
            if isRecurrent {
                recurrentLayers += 1
                continue
            }
            guard index < kvLayerLimit else { continue } // reuses an earlier layer's cache
            let windowed = info.slidingWindow != nil && (info.slidingWindowLayers.map { index < $0.count && $0[index] } ?? false)
            if windowed {
                sliding += heads * (keyLengthSWA + valueLengthSWA)
            } else {
                full += heads * (keyLength + valueLength)
            }
        }

        // Recurrent state per layer (float32): delta-net/SSM state plus convolution history,
        // or the short-convolution cache of LFM-style models.
        var statePerLayer: UInt64 = 0
        if let inner = info.ssmInnerSize, let state = info.ssmStateSize {
            let groups = info.ssmGroupCount ?? 1
            let kernel = max(1, info.ssmConvKernel ?? 4)
            statePerLayer = UInt64(inner * state * 4 + (kernel - 1) * (inner + 2 * groups * state) * 4)
        } else if let cache = info.shortConvCache {
            statePerLayer = UInt64(cache * (info.embeddingLength ?? 4096) * 4)
        } else if info.isRecurrentOrHybrid {
            statePerLayer = 4 << 20
        }

        // Without a tensor table, approximate parameters from file size and the quantization.
        let approxParams = Double(fileSize) * 8 / (QuantizationInfo.bitsPerWeight(info.quantizationLabel) ?? 4.8) / 1e9
        let total = info.parameterCount.map { Double($0) / 1e9 } ?? approxParams
        let active = info.activeParameterCount.map { Double($0) / 1e9 } ?? total
        self.init(
            architecture: info.architecture,
            layers: layers,
            kvElementsFull: full,
            kvElementsSliding: sliding,
            slidingWindow: info.slidingWindow ?? 0,
            kvLoraRank: info.kvLoraRank ?? 0,
            recurrentStateBytes: statePerLayer * UInt64(recurrentLayers),
            embeddingLength: info.embeddingLength ?? 4096,
            vocabSize: info.vocabSize ?? 128_000,
            trainContext: info.contextLength ?? 8192,
            parameters: total,
            activeParameters: active,
            thinkingToggle: info.supportsThinkingToggle
        )
    }

    var isMixtureOfExperts: Bool { activeParameters < parameters * 0.9 }
}

/// Estimated runtime memory for one model at one configuration.
struct MemoryEstimate: Codable, Hashable, Sendable {
    var weights: UInt64
    var kvCache: UInt64
    var compute: UInt64
    var overhead: UInt64
    var contextLength: Int
    var kvType: KVCacheType

    var total: UInt64 { weights + kvCache + compute + overhead }

    /// The part iOS charges against the per-app memory limit. Weights are memory-mapped,
    /// clean, file-backed pages, which developers report are not charged; 10% of them is
    /// charged anyway as a safety margin.
    var countedFootprint: UInt64 { kvCache + compute + overhead + weights / 10 }
}

/// What a model may still use, split along the two limits iOS enforces.
struct MemoryAllowance: Hashable, Sendable {
    /// All resident model memory, weights included: bounded by Metal's recommended working
    /// set and a share of physical RAM so the system and other apps keep enough.
    var resident: UInt64
    /// Memory charged to OMNIA's own jetsam limit (KV cache, compute buffers, runtime).
    var footprint: UInt64

    func admits(_ estimate: MemoryEstimate) -> Bool {
        estimate.total <= resident && estimate.countedFootprint <= footprint
    }

    func reserving(_ estimate: MemoryEstimate) -> MemoryAllowance {
        MemoryAllowance(resident: resident > estimate.total ? resident - estimate.total : 0,
                        footprint: footprint > estimate.countedFootprint ? footprint - estimate.countedFootprint : 0)
    }
}

/// Memory OMNIA may give to models right now.
struct MemoryBudget: Hashable, Sendable {
    /// `os_proc_available_memory()` at the time of planning (nil on the Simulator).
    var measuredAvailable: UInt64?
    /// Footprint of loaded models that would be released to make room.
    var reclaimable: UInt64
    var residentLimit: UInt64
    var footprintLimit: UInt64
    var physicalMemory: UInt64
    var gpuWorkingSet: UInt64?

    var isMeasured: Bool { measuredAvailable != nil }
    var allowance: MemoryAllowance { MemoryAllowance(resident: residentLimit, footprint: footprintLimit) }
    /// Headline figure: the largest model footprint (weights included) OMNIA will load.
    var usable: UInt64 { residentLimit }
}

struct LoadPlan: Hashable, Sendable {
    var contextLength: Int
    var kvType: KVCacheType
    var estimate: MemoryEstimate
    var fits: Bool
    /// Set when the requested context had to be shortened to fit.
    var requestedContext: Int
    var maxContextThatFits: Int?

    var wasReduced: Bool { fits && contextLength < requestedContext }
}

enum MemoryPlanner {
    static let overheadBytes: UInt64 = 256 << 20

    // MARK: Estimates

    static func kvCacheBytes(_ facts: ArchitectureFacts, context: Int, kv: KVCacheType, microBatch: Int = 512) -> UInt64 {
        let bytesPerElement = kv.bytesPerElement
        var bytes: Double
        if facts.kvLoraRank > 0 {
            bytes = Double(facts.layers) * Double(facts.kvLoraRank + 64) * Double(context) * bytesPerElement
        } else {
            bytes = Double(facts.kvElementsFull) * Double(context) * bytesPerElement
            if facts.kvElementsSliding > 0 {
                let cells = Double(min(context, max(facts.slidingWindow, 1) + microBatch))
                bytes += Double(facts.kvElementsSliding) * cells * bytesPerElement
            }
        }
        return UInt64(bytes) + facts.recurrentStateBytes
    }

    static func computeBytes(_ facts: ArchitectureFacts, context: Int, microBatch: Int = 512, flashAttention: Bool = true) -> UInt64 {
        let ubatch = Double(microBatch)
        var bytes = 192.0 * 1_048_576
        bytes += ubatch * Double(facts.embeddingLength) * 4 * 10        // activations
        bytes += (ubatch / 4) * Double(facts.vocabSize) * 4              // output logits
        if !flashAttention {
            // Materialized attention scores: roughly heads × context per batch row.
            let heads = Double(max(8, facts.embeddingLength / 128))
            bytes += ubatch * Double(context) * heads * 4
        }
        if facts.isMixtureOfExperts { bytes *= 1.15 }
        return UInt64(bytes)
    }

    static func estimate(_ facts: ArchitectureFacts, fileSize: UInt64, context: Int, kv: KVCacheType,
                         microBatch: Int = 512, flashAttention: Bool = true) -> MemoryEstimate {
        MemoryEstimate(
            weights: fileSize,
            kvCache: kvCacheBytes(facts, context: context, kv: kv, microBatch: microBatch),
            compute: computeBytes(facts, context: context, microBatch: microBatch, flashAttention: flashAttention),
            overhead: overheadBytes,
            contextLength: context,
            kvType: kv
        )
    }

    // MARK: Budget

    /// Measures the current limits. `reclaimable` is the footprint of loaded models that would be
    /// released first, so the result describes memory as if nothing were loaded.
    @MainActor
    static func budget(device: DeviceProfile, profile: OptimizationProfile, safety: MemorySafety,
                       reclaimable: UInt64) -> MemoryBudget {
        let measured = SystemMetrics.availableMemory()
        // The Simulator has no jetsam limit to read; assume half of RAM there.
        let available = (measured ?? device.physicalMemory / 2) + reclaimable
        let fraction = min(safety.headroomFraction, profile.headroomCap)
        var footprint = UInt64(Double(available) * fraction)
        footprint = footprint > profile.reserveBytes ? footprint - profile.reserveBytes : 0

        var resident = UInt64(Double(device.physicalMemory) * profile.physicalShare(for: safety))
        resident = resident > profile.reserveBytes ? resident - profile.reserveBytes : 0
        if let workingSet = device.gpuRecommendedWorkingSet, workingSet > 0 {
            resident = min(resident, workingSet)
        }
        return MemoryBudget(measuredAvailable: measured, reclaimable: reclaimable, residentLimit: resident,
                            footprintLimit: footprint, physicalMemory: device.physicalMemory,
                            gpuWorkingSet: device.gpuRecommendedWorkingSet)
    }

    // MARK: Planning

    /// Chooses a context length and KV precision that fit in `allowance`.
    ///
    /// Every KV precision allowed by the user or profile is tried at the requested context
    /// before the context is shortened, so quality profiles keep long contexts by quantizing
    /// the cache rather than truncating the window.
    static func plan(_ facts: ArchitectureFacts, fileSize: UInt64, requestedContext: Int?,
                     kvChoice: KVCacheChoice, profile: OptimizationProfile, allowance: MemoryAllowance,
                     flashAttention: Bool = true) -> LoadPlan {
        let trainContext = max(facts.trainContext, 512)
        let requested = min(requestedContext ?? profile.defaultContext, trainContext, profile.maximumContext)
        let kvOptions = allowedKVTypes(kvChoice, profile: profile, flashAttention: flashAttention)
        let minimum = min(profile.minimumContext, requested)

        var context = requested
        while true {
            for kv in kvOptions {
                let candidate = estimate(facts, fileSize: fileSize, context: context, kv: kv,
                                         microBatch: profile.microBatchSize, flashAttention: flashAttention)
                if allowance.admits(candidate) {
                    let maxContext = maxContextThatFits(facts, fileSize: fileSize, kv: kv, profile: profile,
                                                        allowance: allowance, flashAttention: flashAttention)
                    return LoadPlan(contextLength: context, kvType: kv, estimate: candidate, fits: true,
                                    requestedContext: requested, maxContextThatFits: maxContext)
                }
            }
            if context <= minimum { break }
            context = max(minimum, roundedContext(context * 3 / 4))
        }

        let kv = kvOptions.last ?? .q8_0
        let smallest = estimate(facts, fileSize: fileSize, context: minimum, kv: kv,
                                microBatch: profile.microBatchSize, flashAttention: flashAttention)
        return LoadPlan(contextLength: minimum, kvType: kv, estimate: smallest, fits: false,
                        requestedContext: requested, maxContextThatFits: nil)
    }

    static func allowedKVTypes(_ choice: KVCacheChoice, profile: OptimizationProfile, flashAttention: Bool) -> [KVCacheType] {
        let options: [KVCacheType]
        switch choice {
        case .automatic: options = profile.kvPreference
        case .f16: options = [.f16]
        case .q8_0: options = [.q8_0]
        case .q4_0: options = [.q4_0]
        }
        // Quantized caches need flash attention; without it only F16 is valid.
        return flashAttention ? options : [.f16]
    }

    /// Largest context (multiple of 256, up to the training context) that fits.
    static func maxContextThatFits(_ facts: ArchitectureFacts, fileSize: UInt64, kv: KVCacheType,
                                   profile: OptimizationProfile, allowance: MemoryAllowance,
                                   flashAttention: Bool = true) -> Int? {
        let upper = min(max(facts.trainContext, 512), profile.maximumContext)
        func fits(_ context: Int) -> Bool {
            allowance.admits(estimate(facts, fileSize: fileSize, context: context, kv: kv,
                                      microBatch: profile.microBatchSize, flashAttention: flashAttention))
        }
        guard fits(512) else { return nil }
        if fits(upper) { return upper }
        var low = 512
        var high = upper
        while high - low > 256 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        return low / 256 * 256
    }

    static func roundedContext(_ value: Int) -> Int {
        max(512, value / 512 * 512)
    }

    // MARK: Speed

    /// Decode speed is bound by memory bandwidth: every generated token streams the active
    /// weights once. This is an estimate, always labelled as such, until a benchmark replaces it.
    static func estimatedTokensPerSecond(fileSize: UInt64, facts: ArchitectureFacts, device: DeviceProfile) -> Double {
        guard fileSize > 0 else { return 0 }
        let activeFraction = facts.parameters > 0 ? min(1, facts.activeParameters / facts.parameters) : 1
        // Mixture-of-experts decode also reads shared tensors and the output head every token,
        // and its scattered expert reads sustain less of the peak bandwidth.
        let moe = facts.isMixtureOfExperts
        let bytesPerToken = Double(fileSize) * (moe ? min(1, activeFraction + 0.06) : activeFraction)
        let sustainedFraction = moe ? 0.45 : 0.6
        return device.memoryBandwidthGBs * 1e9 * sustainedFraction / bytesPerToken
    }
}

/// Bits-per-weight and quality notes for GGUF quantization types.
enum QuantizationInfo {
    static func bitsPerWeight(_ label: String?) -> Double? {
        guard let label = label?.uppercased() else { return nil }
        let table: [String: Double] = [
            "F32": 32, "F16": 16, "BF16": 16, "Q8_0": 8.5, "Q6_K": 6.56, "Q5_K_M": 5.69, "Q5_K_S": 5.54,
            "Q5_0": 5.5, "Q5_1": 6.0, "Q4_K_M": 4.85, "Q4_K_S": 4.58, "Q4_0": 4.55, "Q4_1": 5.0,
            "IQ4_XS": 4.25, "IQ4_NL": 4.5, "MXFP4": 4.25, "NVFP4": 4.5, "Q3_K_L": 4.27, "Q3_K_M": 3.91,
            "Q3_K_S": 3.5, "IQ3_M": 3.66, "IQ3_S": 3.44, "IQ3_XS": 3.3, "IQ3_XXS": 3.06, "Q2_K": 3.0,
            "Q2_K_S": 2.8, "IQ2_M": 2.7, "IQ2_S": 2.5, "IQ2_XS": 2.31, "IQ2_XXS": 2.06, "IQ1_M": 1.75,
            "IQ1_S": 1.56, "TQ1_0": 1.69, "TQ2_0": 2.06
        ]
        if let exact = table[label] { return exact }
        // Labels such as "UD-Q4_K_XL" or "Q4_K_XL": match the closest known base type.
        return table.first { label.contains($0.key) }?.value
    }

    /// Quality cost of a quantization relative to 8-bit, in catalog score points.
    static func qualityPenalty(bitsPerWeight bits: Double) -> Double {
        switch bits {
        case 7.5...: 0
        case 6.3..<7.5: 0.3
        case 5.4..<6.3: 0.8
        case 4.7..<5.4: 1.5
        case 4.2..<4.7: 2.5
        case 3.8..<4.2: 4
        case 3.4..<3.8: 6
        case 3.0..<3.4: 9
        case 2.5..<3.0: 14
        default: 22
        }
    }

    /// Extracts a quantization label from a GGUF file name, e.g. "Qwen3-14B-Q4_K_M.gguf" → "Q4_K_M".
    static func label(fromFileName name: String) -> String? {
        let upper = name.uppercased().replacingOccurrences(of: ".GGUF", with: "")
        let patterns = ["UD-Q[0-9]_K_XL", "Q[0-9]_K_XL", "IQ[0-9]_[A-Z]+", "Q[0-9]_K_[SML]", "Q[0-9]_K", "Q[0-9]_[01]",
                        "MXFP4(_MOE)?", "NVFP4", "BF16", "F16", "F32", "TQ[12]_0"]
        for pattern in patterns {
            if let range = upper.range(of: pattern, options: .regularExpression) {
                return String(upper[range]).replacingOccurrences(of: "_MOE", with: "")
            }
        }
        return nil
    }
}
