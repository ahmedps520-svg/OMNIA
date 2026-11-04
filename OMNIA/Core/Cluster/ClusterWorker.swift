import Foundation
import Observation
import UIKit

/// Lends this device to a cluster that another device hosts: its GPU serves the host through
/// llama.cpp's RPC server and `ClusterRelay`, and it checks in with the host every few seconds.
/// iOS gives apps no GPU in the background, so lending pauses while OMNIA is off screen.
@MainActor
@Observable
final class ClusterWorker {
    enum Phase: Equatable {
        case idle
        /// Reaching the host.
        case connecting
        /// The host hasn't let this device in yet.
        case waitingForApproval
        /// In the cluster, holding part of a model or ready to.
        case lending
        /// OMNIA left the screen; lending resumes when it's back.
        case paused
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var invitation: ClusterInvitation?
    private(set) var clusterName: String?
    /// The host is connected: part of a model is on this device.
    private(set) var isHolding = false
    /// Bytes per second through the relay, measured each second.
    private(set) var throughput: Double = 0
    /// What this device offers a model, in bytes.
    private(set) var offeredMemory: UInt64 = 0
    /// The host can't be reached right now (it's checked again every few seconds).
    private(set) var hostUnreachable = false
    /// An invitation opened from outside OMNIA (a QR code scanned with the Camera), waiting to be accepted.
    var proposedInvitation: ClusterInvitation?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var meter: Task<Void, Never>?
    @ObservationIgnored private var relay: ClusterRelay?

    let id: String
    private let device: DeviceProfile
    private let engine: InferenceEngine
    private let settings: AppSettings

    init(device: DeviceProfile, engine: InferenceEngine, settings: AppSettings, defaults: UserDefaults = .standard) {
        self.device = device
        self.engine = engine
        self.settings = settings
        if let saved = defaults.string(forKey: "clusterWorkerID") {
            id = saved
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: "clusterWorkerID")
        }
    }

    /// Lending, or trying to.
    var isActive: Bool {
        switch phase {
        case .idle, .failed: false
        default: true
        }
    }

    func join(_ invitation: ClusterInvitation) {
        tearDown()
        self.invitation = invitation
        clusterName = invitation.name
        phase = .connecting
        task = Task { await run(invitation) }
    }

    /// Stops lending and tells the host, so a model it has here is released at once.
    func stop() {
        if let invitation, phase == .lending || phase == .waitingForApproval {
            let id = id
            Task { await ClusterClient.leave(host: invitation.host, token: invitation.code, id: id) }
        }
        tearDown()
        phase = .idle
        invitation = nil
    }

    func sceneDidEnterBackground() {
        guard isActive, phase != .paused, let invitation else { return }
        // The host's reply fails at once rather than after a timeout, and the GPU is never asked
        // for work iOS would refuse in the background.
        let id = id
        let background = UIApplication.shared.beginBackgroundTask(withName: "Leave the cluster")
        Task {
            await ClusterClient.leave(host: invitation.host, token: invitation.code, id: id)
            UIApplication.shared.endBackgroundTask(background)
        }
        tearDown()
        phase = .paused
    }

    func sceneDidBecomeActive() {
        if phase == .paused, let invitation { join(invitation) }
    }

    private func tearDown() {
        task?.cancel()
        task = nil
        meter?.cancel()
        meter = nil
        relay?.stop()
        relay = nil
        isHolding = false
        throughput = 0
        hostUnreachable = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Lending

    private enum HeartbeatEnd {
        case forgotten, refused(String), cancelled
    }

    private func run(_ invitation: ClusterInvitation) async {
        guard RPCBridge.isAvailable else {
            phase = .failed("This build of OMNIA was made without cluster support.")
            return
        }
        // Everything this device can hold goes to the host's model.
        await engine.unloadAll()
        guard let serverPort = await Task.detached(priority: .userInitiated, operation: {
            ClusterRPCServer.shared.start()
        }).value else {
            phase = .failed("OMNIA couldn't start its cluster server on this device.")
            return
        }
        let relay: ClusterRelay
        do {
            relay = try await ClusterRelay.start(preferred: ClusterProtocol.relayPort, target: serverPort,
                                                 allowing: [invitation.address])
        } catch {
            phase = .failed("OMNIA couldn't listen on the network. Check that it may use the local network in Settings › Privacy & Security › Local Network.")
            return
        }
        guard !Task.isCancelled else {
            relay.stop()
            return
        }
        self.relay = relay
        // The screen stays on: a locked device can't lend its GPU.
        UIApplication.shared.isIdleTimerDisabled = true
        startMeter(relay)

        while !Task.isCancelled {
            let outcome = await ClusterClient.join(host: invitation.host, token: invitation.code,
                                                   worker: workerInfo(relayPort: relay.port))
            guard !Task.isCancelled else { return }
            switch outcome {
            case .accepted(let reply):
                phase = .lending
                hostUnreachable = false
                clusterName = reply.cluster ?? invitation.name
                relay.allow(reply.hostAddresses ?? [])
                switch await heartbeat(invitation, relay: relay, every: reply.heartbeatSeconds ?? ClusterProtocol.heartbeatSeconds) {
                case .forgotten:
                    continue
                case .refused(let message):
                    tearDown()
                    phase = .failed(message)
                    return
                case .cancelled:
                    return
                }
            case .pending:
                phase = .waitingForApproval
                hostUnreachable = false
            case .refused(let message):
                tearDown()
                phase = .failed(message)
                return
            case .unreachable:
                hostUnreachable = true
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Checks in until the host forgets this device (it restarted), refuses it, or lending stops.
    private func heartbeat(_ invitation: ClusterInvitation, relay: ClusterRelay, every seconds: Int) async -> HeartbeatEnd {
        var rtt: Double?
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(max(1, seconds)))
            guard !Task.isCancelled else { return .cancelled }
            let busy = relay.isActive
            // While nothing is held, the offer follows what iOS would allow now.
            if !busy { offeredMemory = currentOffer() }
            let request = ClusterProtocol.HeartbeatRequest(
                protocolVersion: ClusterProtocol.version, token: invitation.code, id: id, rttMs: rtt, busy: busy,
                devices: [ClusterProtocol.DeviceUpdate(index: 0, memoryFree: offeredMemory)])
            let started = ContinuousClock.now
            switch await ClusterClient.heartbeat(host: invitation.host, request: request) {
            case .ok:
                rtt = started.secondsElapsed * 1000
                hostUnreachable = false
            case .forgotten:
                return .forgotten
            case .refused(let message):
                return .refused(message)
            case .unreachable:
                hostUnreachable = true
            }
        }
        return .cancelled
    }

    private func startMeter(_ relay: ClusterRelay) {
        meter?.cancel()
        meter = Task { [weak self] in
            var last = relay.transferred
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = relay.transferred
                self?.throughput = Double(now &- last)
                self?.isHolding = relay.isActive
                last = now
            }
        }
    }

    /// What iOS lets OMNIA hold now, with the margins it keeps for its own models.
    private func currentOffer() -> UInt64 {
        let budget = MemoryPlanner.budget(device: device, profile: engine.profile, safety: settings.memorySafety, reclaimable: 0)
        return min(budget.footprintLimit, budget.residentLimit)
    }

    private func workerInfo(relayPort: UInt16) -> ClusterProtocol.WorkerInfo {
        let memory = currentOffer()
        offeredMemory = memory
        return ClusterProtocol.WorkerInfo(
            id: id, name: device.name, kind: "apple", platform: device.systemVersion, rpcPort: Int(relayPort),
            llamaBuild: ClusterProtocol.llamaBuild, backend: "Metal", memoryRAM: device.physicalMemory,
            bandwidthGBs: device.memoryBandwidthGBs,
            devices: [ClusterProtocol.DeviceInfo(index: 0, name: "MTL0", detail: device.chip,
                                                 memoryTotal: device.physicalMemory, memoryFree: memory)])
    }
}

/// A worker's requests to its host: plain HTTP on the local network, a few seconds at most each.
enum ClusterClient {
    enum JoinOutcome {
        case accepted(ClusterProtocol.Reply)
        case pending(String)
        case refused(String)
        case unreachable
    }

    enum HeartbeatOutcome {
        case ok, forgotten, refused(String), unreachable
    }

    static func join(host: String, token: String, worker: ClusterProtocol.WorkerInfo) async -> JoinOutcome {
        let body = ClusterProtocol.JoinRequest(protocolVersion: ClusterProtocol.version, token: token, worker: worker)
        guard let (status, reply) = await post("/v1/join", host: host, body: body) else { return .unreachable }
        switch status {
        case 200 where reply?.ok == true:
            return .accepted(reply!)
        case 202:
            return .pending(reply?.message ?? "Waiting for approval on the host.")
        case 400..<500:
            return .refused(reply?.error ?? "The host refused this device.")
        default:
            return .unreachable
        }
    }

    static func heartbeat(host: String, request: ClusterProtocol.HeartbeatRequest) async -> HeartbeatOutcome {
        guard let (status, reply) = await post("/v1/heartbeat", host: host, body: request) else { return .unreachable }
        switch status {
        case 200: return .ok
        case 404: return .forgotten
        case 400..<500: return .refused(reply?.error ?? "The host refused this device.")
        default: return .unreachable
        }
    }

    static func leave(host: String, token: String, id: String) async {
        _ = await post("/v1/leave", host: host,
                       body: ClusterProtocol.LeaveRequest(protocolVersion: ClusterProtocol.version, token: token, id: id))
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private static func post<Body: Encodable>(_ path: String, host: String, body: Body) async -> (Int, ClusterProtocol.Reply?)? {
        guard ClusterInvitation.isEndpoint(host), let url = URL(string: "http://\(host)\(path)"),
              let data = try? JSONEncoder().encode(body) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        guard let (payload, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, try? JSONDecoder().decode(ClusterProtocol.Reply.self, from: payload))
    }
}
