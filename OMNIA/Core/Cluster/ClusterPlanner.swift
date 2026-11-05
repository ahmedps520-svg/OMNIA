import Foundation

/// A device that can hold part of a model: this one (the host) or one of a worker's GPUs.
struct ClusterDevice: Identifiable, Hashable, Sendable {
    /// "host", or the worker's ID and the device's index on it.
    let id: String
    let name: String
    /// The worker's RPC relay ("address:port"); nil for this device.
    let endpoint: String?
    /// The device's index on its worker.
    let deviceIndex: Int
    /// Bytes it can give a model: weights, KV cache and compute buffer together.
    let memoryBudget: UInt64
    /// Peak memory bandwidth in GB/s. Generating a token reads every weight a device holds once,
    /// so this sets how fast its layers run.
    let bandwidthGBs: Double
    /// Round trip to the host in milliseconds; 0 for the host.
    let latencyMs: Double

    var isHost: Bool { endpoint == nil }
}

/// How a cluster spreads a model.
enum ClusterSpread: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The fewest, fastest devices that hold the model: every extra device adds network round
    /// trips to each token, so a slow one only helps when the model needs its memory.
    case fastest
    /// Every device takes a share in proportion to its memory.
    case everyDevice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fastest: "Fastest"
        case .everyDevice: "Every Device"
        }
    }
}

/// A model laid out over a cluster.
struct ClusterPlan: Hashable, Sendable {
    struct Share: Hashable, Sendable {
        let device: ClusterDevice
        let layers: Int
        /// Weights, KV cache and compute buffer this device holds.
        let bytes: UInt64
    }

    struct Idle: Hashable, Sendable {
        let device: ClusterDevice
        let reason: String
    }

    /// Workers in pipeline order, then this device, which always comes last: it keeps the output
    /// layer, so the logits (a number per vocabulary entry) never cross the network.
    let shares: [Share]
    let idle: [Idle]
    let contextLength: Int
    let kvType: KVCacheType
    /// From memory bandwidth and network round trips; labelled as an estimate wherever shown.
    let estimatedTokensPerSecond: Double

    var host: Share { shares[shares.count - 1] }
    var workers: [Share] { Array(shares.dropLast()) }
    var totalBytes: UInt64 { shares.reduce(0) { $0 + $1.bytes } }

    var placement: ClusterPlacement {
        ClusterPlacement(
            workers: workers.compactMap { share in
                share.device.endpoint.map {
                    ClusterPlacement.Slice(endpoint: $0, device: share.device.deviceIndex, layers: share.layers,
                                           name: share.device.name)
                }
            },
            hostLayers: host.layers)
    }
}

enum ClusterPlanner {
    /// The most devices llama.cpp splits one model over (`llama_max_devices()`): this one and 15 more.
    static let maximumDevices = 16
    /// Each worker keeps this much aside for its runtime, beyond the compute buffer.
    static let workerOverhead: UInt64 = 192 << 20
    /// The host keeps this much of its budget free on a cluster: while loading it reads every
    /// worker's layers from the file to send them, and iOS needs room for that to come and go.
    static let hostMargin: UInt64 = 512 << 20
    /// Share of peak bandwidth that decoding sustains (as in MemoryPlanner's speed estimates).
    static let sustainedBandwidth = 0.6

    /// How a model divides between devices at one context length and cache precision.
    struct Shape: Hashable, Sendable {
        let layers: Int
        /// Weights of one repeating layer.
        let layerBytes: Double
        /// KV cache (or recurrent state) of one layer at the planned context.
        let kvBytesPerLayer: Double
        /// What the host holds besides its layers: the token embeddings (read on its CPU), the
        /// output layer, its compute buffer (with the logits) and the runtime.
        let hostFixedBytes: UInt64
        let outputBytes: UInt64
        /// What a worker holds besides its layers: its compute buffer and runtime.
        let workerFixedBytes: UInt64
        /// Share of a layer's weights read per token: below 1 for mixture-of-experts models.
        let readFraction: Double

        var bytesPerLayer: Double { layerBytes + kvBytesPerLayer }
    }

    /// Bytes per weight of Q6_K, the least that quantizers give the embedding and output tables:
    /// they keep them above the file's average (Qwen3.6 35B-A3B UD-IQ3_XXS: 0.82 against 0.38).
    static let tableBytesPerWeight = 210.0 / 256

    static func shape(_ facts: ArchitectureFacts, fileSize: UInt64, context: Int, kv: KVCacheType,
                      microBatch: Int, flashAttention: Bool) -> Shape {
        let layers = max(1, facts.layers)
        let bytesPerWeight = facts.parameters > 0 ? Double(fileSize) / (facts.parameters * 1e9) : 1
        // The embedding and output tables (vocabulary × width each). Small models often share
        // one; counting two then only makes the plan cautious.
        let tableWeight = max(bytesPerWeight, tableBytesPerWeight)
        let table = min(Double(facts.vocabSize) * Double(facts.embeddingLength) * tableWeight, Double(fileSize) / 4)
        let layerBytes = max(0, Double(fileSize) - 2 * table) / Double(layers)
        let kvBytes = Double(MemoryPlanner.kvCacheBytes(facts, context: context, kv: kv, microBatch: microBatch))
        let compute = MemoryPlanner.computeBytes(facts, context: context, microBatch: microBatch, flashAttention: flashAttention)
        // A worker's compute buffer holds activations but no logits.
        let logits = UInt64(Double(microBatch) / 4 * Double(facts.vocabSize) * 4)
        let workerCompute = compute > logits ? compute - logits : compute
        let active = facts.parameters > 0 ? min(1, facts.activeParameters / facts.parameters) : 1
        return Shape(layers: layers, layerBytes: layerBytes, kvBytesPerLayer: kvBytes / Double(layers),
                     hostFixedBytes: UInt64(2 * table) + compute + MemoryPlanner.overheadBytes,
                     outputBytes: UInt64(table),
                     workerFixedBytes: workerCompute + workerOverhead,
                     readFraction: facts.isMixtureOfExperts ? min(1, active + 0.06) : 1)
    }

    /// The best layout for the model over `host` and `workers`, at the longest context up to
    /// `requestedContext` that fits (trying each cache precision before shortening it), or nil
    /// when the devices together can't hold it.
    static func plan(_ facts: ArchitectureFacts, fileSize: UInt64, requestedContext: Int, kvTypes: [KVCacheType],
                     microBatch: Int, flashAttention: Bool, host: ClusterDevice, workers: [ClusterDevice],
                     spread: ClusterSpread) -> ClusterPlan? {
        let trained = max(facts.trainContext, 512)
        var context = max(512, min(requestedContext, trained))
        let minimum = min(2048, context)
        let precisions = kvTypes.isEmpty ? [KVCacheType.q8_0] : kvTypes
        while true {
            for kv in precisions {
                let shape = shape(facts, fileSize: fileSize, context: context, kv: kv,
                                  microBatch: microBatch, flashAttention: flashAttention)
                if let plan = layout(shape, host: host, workers: workers, spread: spread, context: context, kv: kv) {
                    return plan
                }
            }
            if context <= minimum { return nil }
            context = max(minimum, (context * 3 / 4) / 1024 * 1024)
        }
    }

    /// How many layers a device can hold besides its fixed share; -1 when the host can't even
    /// hold its fixed share.
    static func capacity(of device: ClusterDevice, shape: Shape) -> Int {
        let fixed = device.isHost ? shape.hostFixedBytes : shape.workerFixedBytes
        guard device.memoryBudget > fixed else { return device.isHost ? -1 : 0 }
        guard shape.bytesPerLayer > 0 else { return shape.layers }
        return min(shape.layers, Int(Double(device.memoryBudget - fixed) / shape.bytesPerLayer))
    }

    /// Milliseconds to generate a token: each device reads the weights it holds at its bandwidth,
    /// and each worker in the pipeline adds network round trips.
    static func millisecondsPerToken(_ assignment: [(device: ClusterDevice, layers: Int)], shape: Shape) -> Double {
        var milliseconds = 0.0
        for (device, layers) in assignment {
            var bytes = Double(layers) * shape.layerBytes * shape.readFraction
            if device.isHost { bytes += Double(shape.outputBytes) }
            milliseconds += bytes / (max(device.bandwidthGBs, 1) * 1e9 * sustainedBandwidth) * 1000
            if !device.isHost && layers > 0 { milliseconds += hopMilliseconds(device) }
        }
        return milliseconds
    }

    /// What one worker adds to every token: activations go out and come back over the network,
    /// which with llama.cpp's pipelined RPC costs about one and a half round trips.
    static func hopMilliseconds(_ device: ClusterDevice) -> Double {
        1.5 * max(device.latencyMs, 1) + 0.5
    }

    // MARK: Layout

    private struct Candidate {
        let device: ClusterDevice
        let capacity: Int
    }

    private static func layout(_ shape: Shape, host: ClusterDevice, workers: [ClusterDevice], spread: ClusterSpread,
                               context: Int, kv: KVCacheType) -> ClusterPlan? {
        let hostCapacity = capacity(of: host, shape: shape)
        guard hostCapacity >= 0 else { return nil }
        let hostCandidate = Candidate(device: host, capacity: hostCapacity)
        let usable = workers.map { Candidate(device: $0, capacity: capacity(of: $0, shape: shape)) }
            .filter { $0.capacity > 0 }
            .sorted { lhs, rhs in
                if lhs.device.bandwidthGBs != rhs.device.bandwidthGBs { return lhs.device.bandwidthGBs > rhs.device.bandwidthGBs }
                if lhs.device.latencyMs != rhs.device.latencyMs { return lhs.device.latencyMs < rhs.device.latencyMs }
                return lhs.capacity > rhs.capacity
            }

        let selection: ([Candidate], [Int])? = switch spread {
        case .fastest: fastestSet(usable, host: hostCandidate, shape: shape)
        case .everyDevice: proportionalSet(usable, host: hostCandidate, shape: shape)
        }
        guard let selection else { return nil }
        let (chosen, layers) = selection

        // Workers (bandwidth order) then the host, each with the layers it got.
        var shares: [ClusterPlan.Share] = []
        for (candidate, count) in zip(chosen, layers) where candidate.device.isHost || count > 0 {
            let fixed = candidate.device.isHost ? shape.hostFixedBytes : shape.workerFixedBytes
            let bytes = fixed + UInt64(Double(count) * shape.bytesPerLayer)
            shares.append(ClusterPlan.Share(device: candidate.device, layers: count, bytes: bytes))
        }
        if let hostIndex = shares.firstIndex(where: { $0.device.isHost }) {
            shares.append(shares.remove(at: hostIndex))
        }
        let used = Set(shares.map(\.device.id))
        let idle = workers.filter { !used.contains($0.id) }.map { device in
            ClusterPlan.Idle(device: device, reason: idleReason(device, shape: shape, spread: spread, usable: usable))
        }
        let milliseconds = millisecondsPerToken(shares.map { ($0.device, $0.layers) }, shape: shape)
        return ClusterPlan(shares: shares, idle: idle, contextLength: context, kvType: kv,
                           estimatedTokensPerSecond: milliseconds > 0 ? 1000 / milliseconds : 0)
    }

    private static func idleReason(_ device: ClusterDevice, shape: Shape, spread: ClusterSpread, usable: [Candidate]) -> String {
        if capacity(of: device, shape: shape) <= 0 {
            return "Too little free memory to hold a layer."
        }
        if spread == .everyDevice || usable.firstIndex(where: { $0.device.id == device.id }).map({ $0 >= maximumDevices - 1 }) == true {
            return "llama.cpp splits a model over at most \(maximumDevices) devices."
        }
        return "Not needed: faster devices hold the model, and another network hop would slow every reply."
    }

    /// Layers per device for one set, fastest device first, each filled to capacity; the host
    /// wins ties since it adds no network hop. Nil when the set can't hold every layer.
    private static func fill(_ set: [Candidate], layers: Int) -> [Int]? {
        let order = set.indices.sorted { lhs, rhs in
            let a = set[lhs].device, b = set[rhs].device
            if a.bandwidthGBs != b.bandwidthGBs { return a.bandwidthGBs > b.bandwidthGBs }
            return a.isHost && !b.isHost
        }
        var remaining = layers
        var result = Array(repeating: 0, count: set.count)
        for index in order where remaining > 0 {
            let take = min(remaining, max(0, set[index].capacity))
            result[index] = take
            remaining -= take
        }
        return remaining == 0 ? result : nil
    }

    private static func cost(_ set: [Candidate], layers: [Int], shape: Shape) -> Double {
        millisecondsPerToken(zip(set, layers).map { ($0.device, $1) }, shape: shape)
    }

    /// The fastest set: the host plus a prefix of the workers by bandwidth, then improved by
    /// dropping, adding or swapping single workers while that lowers the time per token.
    private static func fastestSet(_ workers: [Candidate], host: Candidate, shape: Shape) -> ([Candidate], [Int])? {
        let limit = maximumDevices - 1
        var best: (set: [Candidate], layers: [Int], cost: Double)?
        func consider(_ chosen: [Candidate]) {
            guard chosen.count <= limit else { return }
            let set = chosen + [host]
            guard let layers = fill(set, layers: shape.layers) else { return }
            let time = cost(set, layers: layers, shape: shape)
            if best == nil || time < best!.cost - 1e-9 { best = (set, layers, time) }
        }
        for count in 0...min(workers.count, limit) {
            consider(Array(workers.prefix(count)))
        }
        guard best != nil else { return nil }

        var improved = true
        var rounds = 0
        while improved && rounds < 64 {
            improved = false
            rounds += 1
            let current = Array(best!.set.dropLast())
            let currentCost = best!.cost
            let unused = workers.filter { worker in !current.contains { $0.device.id == worker.device.id } }
            var trials: [[Candidate]] = current.indices.map { index in
                var fewer = current
                fewer.remove(at: index)
                return fewer
            }
            trials += unused.map { current + [$0] }
            for index in current.indices {
                for replacement in unused {
                    var swapped = current
                    swapped[index] = replacement
                    trials.append(swapped)
                }
            }
            for trial in trials {
                consider(trial)
                if best!.cost < currentCost - 1e-9 {
                    improved = true
                    break
                }
            }
        }
        // Keep the workers in bandwidth order, the host last.
        let ordered = best!.set.indices.sorted { lhs, rhs in
            let a = best!.set[lhs].device, b = best!.set[rhs].device
            if a.isHost != b.isHost { return !a.isHost }
            return a.bandwidthGBs > b.bandwidthGBs
        }
        return (ordered.map { best!.set[$0] }, ordered.map { best!.layers[$0] })
    }

    /// Every worker that fits (the largest first, up to llama.cpp's limit) takes layers in
    /// proportion to what it can hold, and so does the host.
    private static func proportionalSet(_ workers: [Candidate], host: Candidate, shape: Shape) -> ([Candidate], [Int])? {
        var chosen = Array(workers.sorted { $0.capacity > $1.capacity }.prefix(maximumDevices - 1))
        // Fewer layers than devices: the smallest workers sit out.
        while chosen.count + 1 > shape.layers, !chosen.isEmpty { chosen.removeLast() }
        let set = chosen.sorted { $0.device.bandwidthGBs > $1.device.bandwidthGBs } + [host]
        let total = set.reduce(0) { $0 + $1.capacity }
        guard total >= shape.layers else { return nil }

        // Largest remainders, so the counts add up exactly; each worker gets at least one layer.
        let ideal = set.map { Double($0.capacity) * Double(shape.layers) / Double(total) }
        var layers = ideal.map { Int($0.rounded(.down)) }
        for index in set.indices where !set[index].device.isHost && layers[index] == 0 && set[index].capacity > 0 {
            layers[index] = 1
        }
        var remaining = shape.layers - layers.reduce(0, +)
        let byRemainder = set.indices.sorted { ideal[$0] - ideal[$0].rounded(.down) > ideal[$1] - ideal[$1].rounded(.down) }
        var cursor = 0
        while remaining > 0 && cursor < byRemainder.count * 2 {
            let index = byRemainder[cursor % byRemainder.count]
            if layers[index] < set[index].capacity {
                layers[index] += 1
                remaining -= 1
            }
            cursor += 1
        }
        // Rounding up can overshoot a small device; give the excess to whoever has room.
        while remaining < 0, let index = layers.indices.max(by: { layers[$0] < layers[$1] }), layers[index] > 1 {
            layers[index] -= 1
            remaining += 1
        }
        if remaining > 0 {
            for index in set.indices where remaining > 0 {
                let room = set[index].capacity - layers[index]
                let take = min(room, remaining)
                if take > 0 {
                    layers[index] += take
                    remaining -= take
                }
            }
        }
        guard remaining == 0, zip(set, layers).allSatisfy({ $1 <= $0.capacity }) else { return nil }
        return (set, layers)
    }
}
