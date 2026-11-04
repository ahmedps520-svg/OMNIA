import Foundation

/// Where a cluster model's layers go, for llama.cpp: workers first, in pipeline order, then this
/// device, which also keeps the output layer so the vocabulary-sized logits never cross the network.
struct ClusterPlacement: Hashable, Codable, Sendable {
    struct Slice: Hashable, Codable, Sendable {
        /// The worker's RPC relay, "address:port".
        var endpoint: String
        /// The device's index on that worker (a PC can serve more than one GPU).
        var device: Int
        var layers: Int
        /// Shown if this device drops out ("RTX 4060 Ti on DESKTOP-4060TI").
        var name: String
    }

    var workers: [Slice]
    var hostLayers: Int

    /// The device behind an endpoint, for messages.
    func name(of endpoint: String) -> String {
        workers.first { $0.endpoint == endpoint }?.name ?? endpoint
    }
}

/// When a cluster this device hosts takes a model instead of this device alone.
enum ClusterUse: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Models too large for this device.
    case whenNeeded
    /// Also models this device could run, when the cluster runs them clearly faster.
    case whenFaster

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whenNeeded: "Models Too Big for This Device"
        case .whenFaster: "Whenever It's Faster"
        }
    }
}

/// The messages between a cluster's host (this app) and its workers (OMNIA on other devices, or
/// OMNIA Node on a PC), as JSON over HTTP to the host. The host then connects to each worker's
/// relay, which forwards llama.cpp's own RPC protocol to the worker's server.
enum ClusterProtocol {
    static let version = 1
    /// Workers and host must run the same llama.cpp: its RPC protocol changes between builds.
    static let llamaBuild = "b11960"
    static let httpPort: UInt16 = 8770
    static let relayPort: UInt16 = 50052
    /// Advertised by a host, so nearby devices with OMNIA find it without typing anything.
    static let bonjourType = "_omnia-cluster._tcp"
    static let maximumWorkers = 20
    static let heartbeatSeconds = 3
    /// A worker that misses heartbeats this long has gone.
    static let workerTimeout: TimeInterval = 15

    struct DeviceInfo: Codable, Hashable, Sendable {
        var index: Int
        /// llama.cpp's name for it: "CUDA0", "Vulkan0", "MTL0", "CPU".
        var name: String
        /// What it is: "NVIDIA GeForce RTX 4060 Ti", "Apple M3".
        var detail: String
        var memoryTotal: UInt64
        /// What it can give a model now, in bytes.
        var memoryFree: UInt64

        enum CodingKeys: String, CodingKey {
            case index, name, memoryTotal, memoryFree
            case detail = "description"
        }
    }

    struct WorkerInfo: Codable, Hashable, Sendable {
        var id: String
        var name: String
        /// "pc" (OMNIA Node) or "apple" (OMNIA on an iPhone or iPad).
        var kind: String
        var platform: String?
        var rpcPort: Int
        var llamaBuild: String?
        /// "CUDA", "Vulkan", "CPU" or "Metal".
        var backend: String?
        var memoryRAM: UInt64?
        /// Apple devices report their own; PCs are estimated from the GPU's name.
        var bandwidthGBs: Double?
        var devices: [DeviceInfo]
    }

    struct JoinRequest: Codable, Sendable {
        var protocolVersion: Int
        var token: String
        var worker: WorkerInfo

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case token, worker
        }
    }

    struct DeviceUpdate: Codable, Sendable {
        var index: Int
        var memoryFree: UInt64
    }

    struct HeartbeatRequest: Codable, Sendable {
        var protocolVersion: Int
        var token: String
        var id: String
        var rttMs: Double?
        var busy: Bool?
        var devices: [DeviceUpdate]?

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case token, id, rttMs, busy, devices
        }
    }

    struct LeaveRequest: Codable, Sendable {
        var protocolVersion: Int
        var token: String
        var id: String

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol"
            case token, id
        }
    }

    /// Every answer from the host. A join is accepted (200), waits for approval on the host (202),
    /// or is refused (403 wrong code, 409 full, 426 another llama.cpp build).
    struct Reply: Codable, Sendable {
        var ok: Bool
        var cluster: String?
        var hostAddresses: [String]?
        var heartbeatSeconds: Int?
        var pending: Bool?
        var message: String?
        var error: String?
    }
}

/// What a device needs to join a cluster, carried by the host's QR code as an `omnia://` link.
struct ClusterInvitation: Hashable, Sendable {
    /// The host's HTTP endpoint, "address:port".
    var host: String
    /// Shown only on the host's screen, so a device that scanned it was let in by someone there.
    var code: String
    var name: String

    var url: URL {
        var components = URLComponents()
        components.scheme = "omnia"
        components.host = "cluster"
        components.queryItems = [URLQueryItem(name: "host", value: host),
                                 URLQueryItem(name: "code", value: code),
                                 URLQueryItem(name: "name", value: name)]
        return components.url!
    }

    var address: String { host.split(separator: ":").first.map(String.init) ?? host }

    init(host: String, code: String, name: String) {
        self.host = host
        self.code = code
        self.name = name
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "omnia", url.host?.lowercased() == "cluster",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value, Self.isEndpoint(host),
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { return nil }
        self.host = host
        self.code = code
        name = items.first { $0.name == "name" }?.value ?? "OMNIA"
    }

    /// "address:port" with a numeric IPv4 address: the only form a host advertises.
    static func isEndpoint(_ text: String) -> Bool {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]), (1...65_535).contains(port) else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { UInt8($0) != nil }
    }

    /// A new code: ten characters with no look-alikes (0/O, 1/I/L), about 49 bits.
    static func makeCode() -> String {
        let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
        var generator = SystemRandomNumberGenerator()
        return String((0..<10).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

/// Memory bandwidth of the GPUs PCs bring, which sets how fast the layers they hold run.
/// Published peak figures; unknown cards get a cautious default.
enum GPUBandwidth {
    static func estimate(for name: String, backend: String?, memoryTotal: UInt64) -> Double {
        let lowered = name.lowercased()
        if backend?.uppercased() == "CPU" || lowered == "cpu" { return 40 }
        // The 8 GB RTX 3060 has a narrower bus than the 12 GB one, under the same name.
        if lowered.contains("rtx 3060"), !lowered.contains("ti"), memoryTotal > 0, memoryTotal < 10 << 30 { return 240 }
        // Longest names first, so "4060 ti" wins over "4060".
        for (pattern, bandwidth) in table where lowered.contains(pattern) {
            return bandwidth
        }
        if lowered.contains("nvidia") || lowered.contains("geforce") || lowered.contains("radeon") { return 250 }
        return 100
    }

    private static let table: [(String, Double)] = [
        ("rtx 5090", 1792), ("rtx 5080", 960), ("rtx 5070 ti", 896), ("rtx 5070", 672), ("rtx 5060 ti", 448),
        ("rtx 5060", 448), ("rtx 4090", 1008), ("rtx 4080", 717), ("rtx 4070 ti super", 672), ("rtx 4070 ti", 504),
        ("rtx 4070 super", 504), ("rtx 4070", 504), ("rtx 4060 ti", 288), ("rtx 4060", 272), ("rtx 3090 ti", 1008),
        ("rtx 3090", 936), ("rtx 3080 ti", 912), ("rtx 3080", 760), ("rtx 3070 ti", 608), ("rtx 3070", 448),
        ("rtx 3060 ti", 448), ("rtx 3060", 360), ("rtx 3050", 224), ("rtx 2080 ti", 616), ("rtx 2080", 448),
        ("rtx 2070", 448), ("rtx 2060", 336), ("gtx 1080 ti", 484), ("gtx 1080", 320), ("gtx 1070", 256),
        ("gtx 1660", 192), ("rx 9070 xt", 640), ("rx 9070", 640), ("rx 7900 xtx", 960), ("rx 7900 xt", 800),
        ("rx 7800 xt", 624), ("rx 7700 xt", 432), ("rx 7600", 288), ("rx 6900 xt", 512), ("rx 6800", 512),
        ("rx 6700 xt", 384), ("rx 6600", 224), ("arc b580", 456), ("arc a770", 560), ("arc a750", 512)
    ].sorted { $0.0.count > $1.0.count }
}
