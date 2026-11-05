import Foundation
import Testing
@testable import OMNIA

/// A model shaped like Qwen3.8 27B: 64 layers, 5,120 wide, a 152K vocabulary.
private func largeModel(kvElements: Int = 64 * 8 * 128 * 2) -> ArchitectureFacts {
    ArchitectureFacts(architecture: "qwen3", layers: 64, kvElementsFull: kvElements, embeddingLength: 5120,
                      vocabSize: 151_936, trainContext: 262_144, parameters: 27.8)
}

/// A worker at 10.0.0.`address`, or the host when `address` is nil.
private func device(_ id: String, gigabytes: Double, bandwidth: Double, latency: Double = 4, address: Int?) -> ClusterDevice {
    ClusterDevice(id: id, name: id, endpoint: address.map { "10.0.0.\($0):50052" }, deviceIndex: 0,
                  memoryBudget: UInt64(gigabytes * 1_073_741_824), bandwidthGBs: bandwidth, latencyMs: latency)
}

/// The devices this feature was built for: an M5 iPad Pro hosting, two NVIDIA PCs and six more
/// Apple devices.
private let iPadHost = device("iPad Pro (M5)", gigabytes: 10, bandwidth: 153, address: nil)
private let rtx4060Ti = device("RTX 4060 Ti", gigabytes: 15, bandwidth: 288, latency: 3, address: 2)
private let rtx3060 = device("RTX 3060", gigabytes: 11, bandwidth: 360, latency: 3, address: 3)
private let phones = [
    device("iPhone 18 Pro A", gigabytes: 6, bandwidth: 115, latency: 6, address: 4),
    device("iPhone 18 Pro B", gigabytes: 6, bandwidth: 115, latency: 6, address: 5),
    device("iPad Air (M3)", gigabytes: 5, bandwidth: 100, latency: 6, address: 6),
    device("iPhone 16 Pro Max", gigabytes: 4.5, bandwidth: 60, latency: 7, address: 7),
    device("iPhone 15 Pro", gigabytes: 4, bandwidth: 51, latency: 7, address: 8),
    device("iPhone 12 Pro Max", gigabytes: 2.5, bandwidth: 34, latency: 8, address: 9)
]

@Suite("Cluster planner")
struct ClusterPlannerTests {
    private func plan(_ facts: ArchitectureFacts = largeModel(), gigabytes: Double = 29, context: Int = 8192,
                      kv: [KVCacheType] = [.q8_0], host: ClusterDevice = iPadHost, workers: [ClusterDevice],
                      spread: ClusterSpread = .fastest) -> ClusterPlan? {
        ClusterPlanner.plan(facts, fileSize: UInt64(gigabytes * 1e9), requestedContext: context, kvTypes: kv,
                            microBatch: 512, flashAttention: true, host: host, workers: workers, spread: spread)
    }

    @Test func fastestUsesTheGraphicsCardsAndLeavesThePhonesIdle() throws {
        let result = try #require(plan(workers: [rtx4060Ti, rtx3060] + phones))
        #expect(Set(result.workers.map(\.device.id)) == [rtx4060Ti.id, rtx3060.id])
        #expect(result.host.device.isHost)
        #expect(result.shares.last?.device.isHost == true)
        #expect(result.shares.reduce(0) { $0 + $1.layers } == 64)
        #expect(Set(result.idle.map(\.device.id)) == Set(phones.map(\.id)))
        #expect(result.contextLength == 8192)
        // No device is given more than it offered.
        for share in result.shares {
            #expect(share.bytes <= share.device.memoryBudget)
        }
        // The fastest card fills first.
        let first = try #require(result.workers.first)
        #expect(first.device.id == rtx3060.id)
    }

    @Test func everyDeviceSpreadsOverAllOfThem() throws {
        let all = [rtx4060Ti, rtx3060] + phones
        let even = try #require(plan(workers: all, spread: .everyDevice))
        let fastest = try #require(plan(workers: all))
        #expect(even.shares.count == all.count + 1)
        #expect(even.shares.allSatisfy { $0.layers > 0 || $0.device.isHost })
        #expect(even.shares.reduce(0) { $0 + $1.layers } == 64)
        #expect(even.estimatedTokensPerSecond < fastest.estimatedTokensPerSecond)
        for share in even.shares {
            #expect(share.bytes <= share.device.memoryBudget)
        }
    }

    @Test func modelTooBigForEveryDeviceTogetherHasNoPlan() {
        #expect(plan(gigabytes: 200, workers: [rtx4060Ti, rtx3060] + phones) == nil)
    }

    @Test func hostThatCantHoldItsOwnShareHasNoPlan() {
        let tiny = device("Tiny host", gigabytes: 0.5, bandwidth: 50, address: nil)
        #expect(plan(host: tiny, workers: [rtx4060Ti, rtx3060]) == nil)
    }

    @Test func shortensTheContextBeforeGivingUp() throws {
        // A cache this wide doesn't fit at 128K anywhere, but does at a shorter context.
        let result = try #require(plan(largeModel(kvElements: 64 * 8 * 128 * 2), context: 131_072, kv: [.f16],
                                       workers: [rtx4060Ti, rtx3060] + phones))
        #expect(result.contextLength < 131_072)
        #expect(result.contextLength >= 2048)
    }

    @Test func splitsOverAtMostSixteenDevices() throws {
        let many = (1...20).map { device("Phone \($0)", gigabytes: 4, bandwidth: 60, address: 20 + $0) }
        let result = try #require(plan(gigabytes: 20, workers: many, spread: .everyDevice))
        #expect(result.shares.count == ClusterPlanner.maximumDevices)
        #expect(result.idle.count == 5)
        #expect(result.idle.allSatisfy { $0.reason.contains("16") })
    }

    /// The first real cluster: Qwen3.6 35B-A3B UD-IQ3_XXS (13.2 GB, a 248K vocabulary, its
    /// embedding and output tables at Q6_K, 417 MB each) over the M5 iPad Pro and an iPhone 18 Pro.
    @Test func plansQwen36OverTheIPadAndAnIPhone() throws {
        let facts = ArchitectureFacts(architecture: "qwen35moe", layers: 40, kvElementsFull: 10 * 2 * 256 * 2,
                                      recurrentStateBytes: 63 << 20, embeddingLength: 2048, vocabSize: 248_320,
                                      trainContext: 262_144, parameters: 34.7, activeParameters: 3)
        let fileSize: UInt64 = 13_211_155_424
        let shape = ClusterPlanner.shape(facts, fileSize: fileSize, context: 32_768, kv: .q8_0,
                                         microBatch: 512, flashAttention: true)
        // The file's average (0.38 bytes a weight) would put each table at 191 MB.
        #expect(abs(Double(shape.outputBytes) - 417_177_600) < 5_000_000)

        let iPhone = device("iPhone 18 Pro", gigabytes: 6, bandwidth: 115, latency: 6, address: 4)
        let result = try #require(ClusterPlanner.plan(facts, fileSize: fileSize, requestedContext: 32_768, kvTypes: [.q8_0],
                                                      microBatch: 512, flashAttention: true, host: iPadHost,
                                                      workers: [iPhone], spread: .fastest))
        #expect(result.workers.map(\.device.id) == [iPhone.id])
        #expect(result.shares.reduce(0) { $0 + $1.layers } == 40)
        #expect(result.contextLength == 32_768)
        for share in result.shares {
            #expect(share.bytes <= share.device.memoryBudget)
        }
    }

    @Test func aModelThatFitsOnTheHostStaysThere() throws {
        // 4 GB fits on the host alone: no worker is worth a network hop for it.
        let result = try #require(plan(gigabytes: 4, workers: phones))
        #expect(result.workers.isEmpty)
        #expect(result.host.layers == 64)
    }

    @Test func placementListsWorkersThenTheHost() throws {
        let result = try #require(plan(workers: [rtx4060Ti, rtx3060]))
        let placement = result.placement
        #expect(placement.workers.map(\.endpoint) == result.workers.map { $0.device.endpoint! })
        #expect(placement.workers.reduce(0) { $0 + $1.layers } + placement.hostLayers == 64)
        #expect(placement.name(of: rtx3060.endpoint!) == rtx3060.name)
        #expect(placement.name(of: "1.2.3.4:5") == "1.2.3.4:5")
    }

    @Test func estimatesGraphicsCardBandwidth() {
        #expect(GPUBandwidth.estimate(for: "NVIDIA GeForce RTX 4060 Ti", backend: "CUDA", memoryTotal: 16 << 30) == 288)
        #expect(GPUBandwidth.estimate(for: "NVIDIA GeForce RTX 4060", backend: "CUDA", memoryTotal: 8 << 30) == 272)
        #expect(GPUBandwidth.estimate(for: "NVIDIA GeForce RTX 3060", backend: "CUDA", memoryTotal: 12 << 30) == 360)
        #expect(GPUBandwidth.estimate(for: "NVIDIA GeForce RTX 3060", backend: "CUDA", memoryTotal: 8 << 30) == 240)
        #expect(GPUBandwidth.estimate(for: "CPU", backend: "CPU", memoryTotal: 32 << 30) == 40)
        #expect(GPUBandwidth.estimate(for: "Mystery Accelerator", backend: "Vulkan", memoryTotal: 0) == 100)
    }

    @Test func knowsTheDevicesThatLendThemselves() {
        #expect(DeviceCatalog.lookup("iPhone16,1")?.name == "iPhone 15 Pro")
        #expect(DeviceCatalog.lookup("iPhone13,4")?.memoryBandwidthGBs == 34)
        #expect(DeviceCatalog.lookup("iPad15,3")?.chip == "Apple M3")
        #expect(DeviceCatalog.lookup("iPhone17,2")?.deviceClass == .unsupported)
    }
}

@Suite("Cluster invitations and HTTP")
struct ClusterProtocolTests {
    @Test func invitationSurvivesItsQRCode() throws {
        let invitation = ClusterInvitation(host: "192.168.1.20:8770", code: "K7Q2XM4P9T", name: "Ahmed's iPad Pro")
        let decoded = try #require(ClusterInvitation(url: invitation.url))
        #expect(decoded == invitation)
        #expect(decoded.address == "192.168.1.20")
        #expect(invitation.url.absoluteString.hasPrefix("omnia://cluster?"))
    }

    @Test func refusesInvitationsThatDontPointAtTheLocalNetwork() {
        #expect(ClusterInvitation(url: URL(string: "omnia://cluster?host=example.com:80&code=K7Q2XM4P9T")!) == nil)
        #expect(ClusterInvitation(url: URL(string: "omnia://cluster?host=192.168.1.20:8770")!) == nil)
        #expect(ClusterInvitation(url: URL(string: "https://cluster?host=192.168.1.20:8770&code=K7Q2XM4P9T")!) == nil)
        #expect(ClusterInvitation.isEndpoint("10.0.0.5:50052"))
        #expect(!ClusterInvitation.isEndpoint("10.0.0.256:50052"))
        #expect(!ClusterInvitation.isEndpoint("10.0.0.5:0"))
        #expect(!ClusterInvitation.isEndpoint("10.0.0.5"))
    }

    @Test func codesAreTenUnambiguousCharacters() {
        let code = ClusterInvitation.makeCode()
        #expect(code.count == 10)
        #expect(code.allSatisfy { "23456789ABCDEFGHJKMNPQRSTUVWXYZ".contains($0) })
        #expect(ClusterInvitation.makeCode() != code)
    }

    @Test func parsesARequestOnceItHasArrived() throws {
        let text = "POST /v1/join?x=1 HTTP/1.1\r\nHost: 192.168.1.20:8770\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\nhello"
        let full = Data(text.utf8)
        #expect(try ClusterHTTPParser.head(in: full.prefix(20)) == nil)
        let head = try #require(try ClusterHTTPParser.head(in: full))
        #expect(head.method == "POST")
        #expect(head.path == "/v1/join")
        #expect(head.headers["host"] == "192.168.1.20:8770")
        #expect(head.contentLength == 5)
        #expect(head.expectsContinue)
        #expect(full.count == head.headerLength + head.contentLength)
    }

    @Test func refusesRequestsItWontHandle() {
        let chunked = Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        #expect(throws: ClusterHTTPParser.Failure.self) { try ClusterHTTPParser.head(in: chunked) }
        let malformed = Data("NONSENSE\r\n\r\n".utf8)
        #expect(throws: ClusterHTTPParser.Failure.self) { try ClusterHTTPParser.head(in: malformed) }
        let huge = Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)).utf8)
        #expect(throws: ClusterHTTPParser.Failure(status: 431, message: "Request headers are too large.")) {
            try ClusterHTTPParser.head(in: huge)
        }
        let big = Data("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)
        #expect(throws: ClusterHTTPParser.Failure(status: 413, message: "The request body is too large.")) {
            try ClusterHTTPParser.head(in: big)
        }
    }

    @Test func writesAResponseThatClosesTheConnection() {
        let text = String(decoding: ClusterHTTPResponse.text("hi", status: 202).serialized(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\nhi"))
    }
}

@Suite("Cluster host")
@MainActor
struct ClusterHostTests {
    private func makeHost() throws -> ClusterHost {
        let defaults = try #require(UserDefaults(suiteName: "omnia-cluster-tests-\(UUID().uuidString)"))
        return ClusterHost(device: DeviceProfile.detect(), defaults: defaults)
    }

    private func worker(_ id: String, name: String = "DESKTOP-4060TI", kind: String = "pc", free: UInt64 = 16 << 30,
                        build: String? = ClusterProtocol.llamaBuild) -> ClusterProtocol.WorkerInfo {
        ClusterProtocol.WorkerInfo(
            id: id, name: name, kind: kind, platform: "Windows 11", rpcPort: 50052, llamaBuild: build,
            backend: kind == "pc" ? "CUDA" : "Metal", memoryRAM: 32 << 30, bandwidthGBs: kind == "pc" ? nil : 115,
            devices: [ClusterProtocol.DeviceInfo(index: 0, name: kind == "pc" ? "CUDA0" : "MTL0",
                                                 detail: kind == "pc" ? "NVIDIA GeForce RTX 4060 Ti" : "Apple A20 Pro",
                                                 memoryTotal: 17 << 30, memoryFree: free)])
    }

    private func post<Body: Encodable>(_ host: ClusterHost, _ path: String, _ body: Body,
                                       from address: String = "192.168.1.31") throws -> (Int, ClusterProtocol.Reply) {
        let request = ClusterHTTPRequest(method: "POST", path: path, headers: ["host": "192.168.1.20:8770"],
                                         body: try JSONEncoder().encode(body), remoteAddress: address)
        let response = host.handle(request)
        return (response.status, try JSONDecoder().decode(ClusterProtocol.Reply.self, from: response.body))
    }

    private func join(_ host: ClusterHost, _ info: ClusterProtocol.WorkerInfo, token: String? = nil,
                      version: Int = ClusterProtocol.version, from address: String = "192.168.1.31") throws -> (Int, ClusterProtocol.Reply) {
        try post(host, "/v1/join", ClusterProtocol.JoinRequest(protocolVersion: version, token: token ?? host.code, worker: info),
                 from: address)
    }

    @Test func aDeviceWithTheCodeJoinsAtOnce() throws {
        let host = try makeHost()
        let (status, reply) = try join(host, worker("a", name: "iPhone 18 Pro", kind: "apple"))
        #expect(status == 200)
        #expect(reply.ok)
        #expect(reply.cluster == host.name)
        #expect(reply.heartbeatSeconds == ClusterProtocol.heartbeatSeconds)
        #expect(host.workers.map(\.id) == ["a"])
        #expect(host.workers.first?.endpoint == "192.168.1.31:50052")
    }

    @Test func aPCWaitsForApprovalOnce() throws {
        let host = try makeHost()
        let pc = worker("pc-1")
        let (waiting, pending) = try join(host, pc, token: ClusterHost.nodeToken)
        #expect(waiting == 202)
        #expect(pending.pending == true)
        #expect(host.requests.map(\.id) == ["pc-1"])
        #expect(host.workers.isEmpty)

        host.approve("pc-1")
        #expect(host.requests.isEmpty)
        let (status, _) = try join(host, pc, token: ClusterHost.nodeToken)
        #expect(status == 200)
        #expect(host.workers.map(\.id) == ["pc-1"])

        // Approved for good: after leaving, it comes back without asking.
        _ = try post(host, "/v1/leave", ClusterProtocol.LeaveRequest(protocolVersion: 1, token: ClusterHost.nodeToken, id: "pc-1"))
        #expect(host.workers.isEmpty)
        #expect(try join(host, pc, token: ClusterHost.nodeToken).0 == 200)
    }

    @Test func aDeclinedDeviceIsTurnedAway() throws {
        let host = try makeHost()
        _ = try join(host, worker("pc-2"), token: ClusterHost.nodeToken)
        host.decline("pc-2")
        let (status, reply) = try join(host, worker("pc-2"), token: ClusterHost.nodeToken)
        #expect(status == 403)
        #expect(reply.ok == false)
        #expect(reply.error != nil)
    }

    @Test func refusesAnotherProtocolOrBuild() throws {
        let host = try makeHost()
        #expect(try join(host, worker("x"), version: 99).0 == 426)
        #expect(try join(host, worker("y", build: "b1")).0 == 426)
        #expect(host.workers.isEmpty)
    }

    @Test func heartbeatsKeepWorkersAndUpdateTheirOffer() throws {
        let host = try makeHost()
        let unknown = ClusterProtocol.HeartbeatRequest(protocolVersion: 1, token: host.code, id: "nobody",
                                                       rttMs: 4, busy: false, devices: nil)
        #expect(try post(host, "/v1/heartbeat", unknown).0 == 404)

        _ = try join(host, worker("pc", free: 16 << 30))
        let beat = ClusterProtocol.HeartbeatRequest(protocolVersion: 1, token: host.code, id: "pc", rttMs: 8, busy: false,
                                                    devices: [ClusterProtocol.DeviceUpdate(index: 0, memoryFree: 12 << 30)])
        #expect(try post(host, "/v1/heartbeat", beat).0 == 200)
        let ready = try #require(host.readyDevices().first)
        #expect(ready.memoryBudget == (12 << 30) - (768 << 20))
        #expect(ready.bandwidthGBs == 288)
        #expect(ready.latencyMs == 4)
        #expect(ready.name == "RTX 4060 Ti on DESKTOP-4060TI")

        // While it holds a model, what's free there says nothing about what it could offer.
        let busy = ClusterProtocol.HeartbeatRequest(protocolVersion: 1, token: host.code, id: "pc", rttMs: 8, busy: true,
                                                    devices: [ClusterProtocol.DeviceUpdate(index: 0, memoryFree: 1 << 30)])
        #expect(try post(host, "/v1/heartbeat", busy).0 == 200)
        #expect(host.readyDevices().first?.memoryBudget == (12 << 30) - (768 << 20))
    }

    @Test func lostWorkersSitOutAndLeavingIsAnnounced() throws {
        let host = try makeHost()
        var gone: [String] = []
        host.onWorkerGone = { gone.append($0) }
        _ = try join(host, worker("a", name: "iPhone 18 Pro", kind: "apple"), from: "192.168.1.40")
        _ = try join(host, worker("b", name: "iPhone 18 Pro", kind: "apple"), from: "192.168.1.41")
        let names = host.readyDevices().map(\.name)
        #expect(names.contains("iPhone 18 Pro"))
        #expect(names.contains("iPhone 18 Pro (2)"))

        host.markLost(["192.168.1.40:50052"])
        #expect(host.readyDevices().map(\.id) == ["b/0"])
        host.retry("a")
        #expect(host.readyDevices().count == 2)

        _ = try post(host, "/v1/leave", ClusterProtocol.LeaveRequest(protocolVersion: 1, token: host.code, id: "b"))
        #expect(gone == ["192.168.1.41:50052"])
        host.remove("a")
        #expect(gone == ["192.168.1.41:50052", "192.168.1.40:50052"])
        #expect(host.workers.isEmpty)
    }

    @Test func servesThePCPageAndScript() throws {
        let host = try makeHost()
        func get(_ path: String) -> ClusterHTTPResponse {
            host.handle(ClusterHTTPRequest(method: "GET", path: path, headers: ["host": "192.168.1.20:8770"], body: Data(),
                                           remoteAddress: "192.168.1.31"))
        }
        let page = get("/")
        #expect(page.status == 200)
        let html = String(decoding: page.body, as: UTF8.self)
        #expect(html.contains("irm http://192.168.1.20:8770/node.ps1 | iex"))

        let script = get("/node.ps1")
        #expect(script.status == 200)
        let text = String(decoding: script.body, as: UTF8.self)
        #expect(text.contains("192.168.1.20:8770"))
        #expect(!text.contains("__OMNIA_HOST__"))
        #expect(!text.contains("__OMNIA_TOKEN__"))
        // The script never carries the code on this screen.
        #expect(!text.contains(host.code))

        let command = String(decoding: get("/join.cmd").body, as: UTF8.self)
        #expect(command.contains("\r\n"))
        #expect(command.contains("node.ps1"))
        #expect(get("/nothing").status == 404)
    }

    @Test func quotesNamesForPowerShell() {
        #expect(ClusterHost.powerShellQuoted("Ahmed's iPad") == "Ahmed''s iPad")
        // iOS types a curly apostrophe, which ends a PowerShell string just the same.
        #expect(ClusterHost.powerShellQuoted("Ahmed\u{2019}s iPad") == "Ahmed\u{2019}\u{2019}s iPad")
        #expect(ClusterHost.powerShellQuoted("iPad Pro 13-inch (M5)") == "iPad Pro 13-inch (M5)")
    }

    @Test func aNewCodeSendsEveryoneAway() throws {
        let host = try makeHost()
        let old = host.code
        _ = try join(host, worker("a", kind: "apple"))
        host.resetCode()
        #expect(host.code != old)
        #expect(host.workers.isEmpty)
        #expect(try join(host, worker("a", kind: "apple"), token: old).0 == 202)
    }
}

/// The configurations a scripted loader was asked for.
private final class LoadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RuntimeConfiguration] = []

    func record(_ configuration: RuntimeConfiguration) {
        lock.withLock { recorded.append(configuration) }
    }

    var configurations: [RuntimeConfiguration] { lock.withLock { recorded } }
}

/// The engine chooses the cluster for a model too big for this device, with a scripted backend
/// standing in for llama.cpp.
@Suite("Cluster loading decisions", .serialized, .enabled(if: TestModels.available("stories260K.gguf") && RPCBridge.isAvailable))
@MainActor
struct ClusterEngineTests {
    @Test func loadsAModelTooBigForThisDeviceAcrossTheCluster() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omnia-cluster-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: "omnia-tests-\(UUID().uuidString)")))
        let store = ModelStore(directory: directory)
        let source = try #require(TestModels.url("stories260K.gguf"))
        let info = try GGUFInspector.inspect(fileAt: source).info
        var model = try store.install(fileAt: source, id: "test/stories260K.gguf", displayName: "Stories", developer: nil,
                                      repo: "test", fileName: "stories260K.gguf", sha256: nil, verification: .structureValid,
                                      info: info, license: nil, origin: .imported, catalogID: nil, moveFile: false)
        // Pretend it's a 250-billion-parameter, 500 GB model: far beyond this device, within reach
        // of two big workers.
        model.sizeBytes = 500_000_000_000
        model.facts.parameters = 250
        model.facts.activeParameters = 250
        let engine = InferenceEngine(store: store, settings: settings, device: DeviceProfile.detect(), monitor: PerformanceMonitor(),
                                     conversationMemory: ConversationMemoryStore(directory: directory.appendingPathComponent("memory")))
        let workers = [
            ClusterDevice(id: "w1/0", name: "Big worker 1", endpoint: "10.0.0.2:50052", deviceIndex: 0,
                          memoryBudget: 450_000_000_000, bandwidthGBs: 1000, latencyMs: 2),
            ClusterDevice(id: "w2/0", name: "Big worker 2", endpoint: "10.0.0.3:50052", deviceIndex: 0,
                          memoryBudget: 450_000_000_000, bandwidthGBs: 900, latencyMs: 2)
        ]
        engine.clusterDevices = { workers }
        let loads = LoadRecorder()
        engine.loadBackend = { model, _, configuration, _ in
            loads.record(configuration)
            return ScriptedBackend(modelID: model.id, replies: ["ok"])
        }

        let entry = try await engine.ensureLoaded(model)
        let placement = try #require(loads.configurations.first?.cluster)
        #expect(entry.cluster != nil)
        #expect(Set(placement.workers.map(\.endpoint)) == ["10.0.0.2:50052", "10.0.0.3:50052"])
        #expect(placement.workers.reduce(0) { $0 + $1.layers } + placement.hostLayers == model.facts.layers)

        // Without workers it can't load at all, and says how a cluster would help.
        await engine.unload(model.id)
        engine.clusterDevices = { [] }
        do {
            _ = try await engine.ensureLoaded(model)
            Issue.record("A 500 GB model loaded on one device")
        } catch let InferenceError.insufficientMemory(_, _, suggestion) {
            #expect(suggestion?.contains("cluster") == true)
        }
    }
}

/// llama.cpp's RPC backend for real: this device's own server (on the CPU, in the Simulator),
/// reached directly and through the relay, and what happens when a worker goes away.
@Suite("Cluster over RPC", .serialized, .timeLimit(.minutes(10)),
       .enabled(if: TestModels.available("stories260K.gguf") && RPCBridge.isAvailable))
struct ClusterRPCTests {
    private static let model = "stories260K.gguf"

    private static func layers() throws -> Int {
        let url = try #require(TestModels.url(model))
        return try GGUFInspector.inspect(fileAt: url).info.blockCount ?? 5
    }

    private static func configuration(endpoint: String, workerLayers: Int, total: Int) -> RuntimeConfiguration {
        var configuration = TestModels.cpu
        configuration.cluster = ClusterPlacement(
            workers: [ClusterPlacement.Slice(endpoint: endpoint, device: 0, layers: workerLayers, name: "Test worker")],
            hostLayers: total - workerLayers)
        return configuration
    }

    private static func serverPort() throws -> UInt16 {
        try #require(ClusterRPCServer.shared.start(), "The in-app RPC server didn't start")
    }

    @Test func splitsAModelBetweenThisDeviceAndAWorker() async throws {
        let port = try Self.serverPort()
        let total = try Self.layers()
        let local = try await TestModels.load(Self.model)
        let alone = try await collect(local.generate(.user("Once upon a time", maxTokens: 16)))
        await local.close()

        let cluster = try await TestModels.load(Self.model, configuration: Self.configuration(
            endpoint: "127.0.0.1:\(port)", workerLayers: max(1, total / 2), total: total))
        let together = try await collect(cluster.generate(.user("Once upon a time", maxTokens: 16)))
        await cluster.close()

        #expect((together.stats?.generatedTokens ?? 0) > 0)
        // The same arithmetic on the same CPU: the worker's layers change nothing but where they run.
        #expect(together.text == alone.text, "alone: \(alone.text.debugDescription), together: \(together.text.debugDescription)")
    }

    @Test func runsThroughTheRelay() async throws {
        let port = try Self.serverPort()
        let total = try Self.layers()
        let relay = try await ClusterRelay.start(preferred: 50_310, target: port, allowing: ["127.0.0.1"])
        defer { relay.stop() }
        let runtime = try await TestModels.load(Self.model, configuration: Self.configuration(
            endpoint: "127.0.0.1:\(relay.port)", workerLayers: total, total: total))
        let result = try await collect(runtime.generate(.user("The little dog", maxTokens: 12)))
        await runtime.close()
        #expect((result.stats?.generatedTokens ?? 0) > 0)
        #expect(relay.transferred > 0)
    }

    @Test func theRelayTurnsAwayEveryoneButTheHost() async throws {
        let port = try Self.serverPort()
        let total = try Self.layers()
        let relay = try await ClusterRelay.start(preferred: 50_330, target: port, allowing: ["10.9.9.9"])
        defer { relay.stop() }
        await #expect(throws: InferenceError.self) {
            _ = try await TestModels.load(Self.model, configuration: Self.configuration(
                endpoint: "127.0.0.1:\(relay.port)", workerLayers: total, total: total))
        }
        #expect(relay.transferred == 0)
    }

    @Test func aWorkerThatGoesAwayEndsTheReplyNotTheApp() async throws {
        let port = try Self.serverPort()
        let total = try Self.layers()
        let relay = try await ClusterRelay.start(preferred: 50_350, target: port, allowing: ["127.0.0.1"])
        defer { relay.stop() }
        let runtime = try await TestModels.load(Self.model, configuration: Self.configuration(
            endpoint: "127.0.0.1:\(relay.port)", workerLayers: total, total: total))
        do {
            _ = try await collect(runtime.generate(.user("Once upon a time", maxTokens: 64))) { chunks in
                if chunks == 2 { relay.disconnect() }
            }
            Issue.record("The reply finished although its worker went away")
        } catch InferenceError.clusterDeviceLost(let name) {
            #expect(name == "Test worker")
        }
        await runtime.close()

        // The worker is back: the next load connects afresh.
        let again = try await TestModels.load(Self.model, configuration: Self.configuration(
            endpoint: "127.0.0.1:\(relay.port)", workerLayers: total, total: total))
        let result = try await collect(again.generate(.user("Once upon a time", maxTokens: 8)))
        await again.close()
        #expect((result.stats?.generatedTokens ?? 0) > 0)
    }

    @Test func anUnreachableWorkerFailsTheLoadQuickly() async throws {
        let total = try Self.layers()
        let free = try #require(LocalNetwork.freeLoopbackPort())
        let started = ContinuousClock.now
        do {
            _ = try await TestModels.load(Self.model, configuration: Self.configuration(
                endpoint: "127.0.0.1:\(free)", workerLayers: total, total: total))
            Issue.record("Loaded on a worker that isn't there")
        } catch InferenceError.clusterDeviceLost(let name) {
            #expect(name == "Test worker")
        }
        #expect(started.secondsElapsed < 15)
    }

    /// An official llama.cpp b11960 server, the program a PC runs (CI starts one and passes its address).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIA_TEST_RPC_SERVER"] != nil))
    func worksWithTheOfficialServer() async throws {
        let endpoint = try #require(ProcessInfo.processInfo.environment["OMNIA_TEST_RPC_SERVER"])
        let total = try Self.layers()
        let runtime = try await TestModels.load(Self.model, configuration: Self.configuration(
            endpoint: endpoint, workerLayers: max(1, total - 1), total: total))
        let result = try await collect(runtime.generate(.user("Once upon a time", maxTokens: 16)))
        await runtime.close()
        #expect((result.stats?.generatedTokens ?? 0) > 0)
    }
}
