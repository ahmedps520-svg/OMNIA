import Foundation
import Observation

/// Hosts a cluster on this device: other devices join it (iPhones and iPads by scanning its QR
/// code, PCs through the page it serves), check in every few seconds, and lend their GPUs to the
/// models this device runs. The chat stays here; `ClusterPlanner` decides what goes where.
@MainActor
@Observable
final class ClusterHost {
    struct Worker: Identifiable, Hashable {
        let id: String
        var info: ClusterProtocol.WorkerInfo
        var address: String
        var joinedAt: Date
        /// The worker's round trip to this device in milliseconds, as it measured it.
        var rttMs: Double?
        /// It holds part of a model now.
        var busy: Bool
        /// What each of its devices offered while it held nothing, by device index.
        var available: [Int: UInt64]
        /// When it dropped out of a model; it's left out of plans until it has checked in for a while.
        var lostAt: Date?

        var endpoint: String { "\(address):\(info.rpcPort)" }
        var isPC: Bool { info.kind == "pc" }
    }

    /// A device that asked to join without the code on this screen, waiting for approval here.
    struct JoinRequest: Identifiable, Hashable {
        let id: String
        var info: ClusterProtocol.WorkerInfo
        var address: String
        var requestedAt: Date
    }

    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var port: UInt16 = ClusterProtocol.httpPort
    private(set) var addresses: [String] = []
    private(set) var workers: [Worker] = []
    private(set) var requests: [JoinRequest] = []
    /// Why the cluster couldn't start, in a sentence.
    private(set) var problem: String?
    private(set) var code: String

    /// A worker left or vanished; a model with layers on it has to let go of it (its endpoint).
    @ObservationIgnored var onWorkerGone: ((String) -> Void)?
    @ObservationIgnored private var server: ClusterHTTPServer?
    @ObservationIgnored private var sweeper: Task<Void, Never>?
    @ObservationIgnored private var approved: Set<String>
    @ObservationIgnored private var declined: Set<String> = []
    /// When each worker last checked in. Every heartbeat sets it, and nothing on screen shows it,
    /// so it stays out of `workers`: writing it there redrew every view of the cluster each time.
    @ObservationIgnored private var lastSeen: [String: Date] = [:]

    private let device: DeviceProfile
    private let defaults: UserDefaults

    private static let codeKey = "clusterCode"
    private static let approvedKey = "clusterApprovedWorkers"
    /// The token in the script PCs download: anyone on the network can fetch it, so it proves
    /// nothing and a new PC waits for approval here.
    static let nodeToken = "node"

    init(device: DeviceProfile, defaults: UserDefaults = .standard) {
        self.device = device
        self.defaults = defaults
        if let saved = defaults.string(forKey: Self.codeKey), saved.count == 10 {
            code = saved
        } else {
            let fresh = ClusterInvitation.makeCode()
            defaults.set(fresh, forKey: Self.codeKey)
            code = fresh
        }
        approved = Set(defaults.stringArray(forKey: Self.approvedKey) ?? [])
    }

    var name: String { device.name }
    var address: String? { addresses.first }

    /// What the QR code carries.
    var invitation: ClusterInvitation? {
        address.map { ClusterInvitation(host: "\($0):\(port)", code: code, name: name) }
    }

    /// The page a PC opens to join.
    var joinPage: String? { address.map { "http://\($0):\(port)" } }

    /// The command that starts OMNIA Node on a Windows PC.
    var pcCommand: String? { joinPage.map(Self.command(for:)) }

    static func command(for page: String) -> String {
        #"powershell -NoProfile -ExecutionPolicy Bypass -Command "irm \#(page)/node.ps1 | iex""#
    }

    // MARK: Running

    func start() async {
        guard !isRunning, !isStarting else { return }
        guard RPCBridge.isAvailable else {
            problem = "This build of OMNIA was made without cluster support."
            return
        }
        isStarting = true
        defer { isStarting = false }
        problem = nil
        addresses = LocalNetwork.addresses()
        guard !addresses.isEmpty else {
            problem = "Join a Wi-Fi network first. The devices in a cluster find each other on it."
            return
        }
        let server = ClusterHTTPServer { [weak self] request in
            guard let self else { return .text("This cluster has stopped.", status: 404) }
            return await self.handle(request)
        }
        server.onFailure = { [weak self] in
            Task { @MainActor in self?.listenerFailed() }
        }
        do {
            port = try await server.start(preferred: ClusterProtocol.httpPort, name: name)
        } catch {
            problem = "OMNIA couldn't listen on the network (\(error.localizedDescription)). Check that it may use the local network in Settings › Privacy & Security › Local Network."
            return
        }
        self.server = server
        isRunning = true
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(ClusterProtocol.heartbeatSeconds))
                self?.sweep()
            }
        }
    }

    func stop() {
        server?.stop()
        server = nil
        sweeper?.cancel()
        sweeper = nil
        let endpoints = workers.map(\.endpoint)
        workers = []
        lastSeen = [:]
        requests = []
        isRunning = false
        for endpoint in endpoints { onWorkerGone?(endpoint) }
    }

    /// Back from the background: iOS may have closed the listener while OMNIA was suspended.
    func sceneDidBecomeActive() {
        guard isRunning else { return }
        let current = LocalNetwork.addresses()
        if current != addresses { addresses = current }
    }

    private func listenerFailed() {
        guard isRunning else { return }
        stop()
        Task { await start() }
    }

    /// A new code: devices that joined with the old one, or were approved, have to join again.
    func resetCode() {
        code = ClusterInvitation.makeCode()
        defaults.set(code, forKey: Self.codeKey)
        approved = []
        defaults.set([String](), forKey: Self.approvedKey)
        declined = []
        let endpoints = workers.map(\.endpoint)
        workers = []
        lastSeen = [:]
        requests = []
        for endpoint in endpoints { onWorkerGone?(endpoint) }
    }

    func approve(_ id: String) {
        guard let request = requests.first(where: { $0.id == id }) else { return }
        requests.removeAll { $0.id == id }
        approved.insert(request.id)
        defaults.set(Array(approved), forKey: Self.approvedKey)
        // It joins on its next try, within a few seconds.
    }

    func decline(_ id: String) {
        requests.removeAll { $0.id == id }
        declined.insert(id)
    }

    /// Takes a device out of the cluster; it can ask to join again.
    func remove(_ id: String) {
        guard let worker = workers.first(where: { $0.id == id }) else { return }
        workers.removeAll { $0.id == id }
        approved.remove(id)
        defaults.set(Array(approved), forKey: Self.approvedKey)
        onWorkerGone?(worker.endpoint)
    }

    /// Workers that dropped out of a model: left out of the next plans until they've checked in again.
    func markLost(_ endpoints: [String]) {
        for index in workers.indices where endpoints.contains(workers[index].endpoint) {
            workers[index].lostAt = .now
        }
    }

    /// Let a device that dropped out be planned with again right away.
    func retry(_ id: String) {
        guard let index = workers.firstIndex(where: { $0.id == id }) else { return }
        workers[index].lostAt = nil
    }

    private func sweep() {
        let now = Date()
        let silent: (Worker) -> Bool = { now.timeIntervalSince(self.lastSeen[$0.id] ?? .distantPast) > ClusterProtocol.workerTimeout }
        let gone = workers.filter(silent)
        let staleRequests = requests.contains { now.timeIntervalSince($0.requestedAt) > 120 }
        guard !gone.isEmpty || staleRequests else { return }
        if !gone.isEmpty {
            workers.removeAll(where: silent)
            for worker in gone { lastSeen[worker.id] = nil }
        }
        if staleRequests { requests.removeAll { now.timeIntervalSince($0.requestedAt) > 120 } }
        for worker in gone { onWorkerGone?(worker.endpoint) }
    }

    // MARK: Devices for the planner

    /// Every device the cluster's workers offer, as the planner sees them (none once stopped).
    func readyDevices() -> [ClusterDevice] {
        workers.filter { $0.lostAt == nil }.flatMap { worker in
            worker.info.devices.map { device in
                ClusterDevice(id: "\(worker.id)/\(device.index)", name: displayName(of: worker, device: device),
                              endpoint: worker.endpoint, deviceIndex: device.index,
                              memoryBudget: budget(of: worker, device: device),
                              bandwidthGBs: bandwidth(of: worker, device: device),
                              // A fresh HTTP request takes about two round trips.
                              latencyMs: max(1, (worker.rttMs ?? 10) / 2))
            }
        }
    }

    /// "RTX 4060 Ti on DESKTOP-ABC", or an iPhone's model name (numbered when two are alike).
    func displayName(of worker: Worker, device: ClusterProtocol.DeviceInfo) -> String {
        let base: String
        if worker.isPC {
            let gpu = device.detail.replacingOccurrences(of: "NVIDIA GeForce ", with: "")
                .replacingOccurrences(of: "NVIDIA ", with: "")
            base = "\(gpu) on \(worker.info.name)"
        } else {
            base = worker.info.name
        }
        let alike = workers.filter { $0.info.name == worker.info.name && $0.info.kind == worker.info.kind }
            .sorted { $0.joinedAt < $1.joinedAt }
        guard alike.count > 1, let position = alike.firstIndex(where: { $0.id == worker.id }), position > 0 else { return base }
        return "\(base) (\(position + 1))"
    }

    /// What a device can give a model: what it offered while idle, less a margin for the driver
    /// and anything else running on it.
    private func budget(of worker: Worker, device: ClusterProtocol.DeviceInfo) -> UInt64 {
        let offered = worker.available[device.index] ?? device.memoryFree
        let margin: UInt64 = worker.isPC ? 768 << 20 : 0
        return offered > margin ? offered - margin : 0
    }

    private func bandwidth(of worker: Worker, device: ClusterProtocol.DeviceInfo) -> Double {
        if let reported = worker.info.bandwidthGBs, reported > 0 { return reported }
        return GPUBandwidth.estimate(for: device.detail, backend: worker.info.backend, memoryTotal: device.memoryTotal)
    }

    // MARK: HTTP

    func handle(_ request: ClusterHTTPRequest) -> ClusterHTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .text(joinPageHTML(host: hostEndpoint(for: request)), contentType: "text/html; charset=utf-8")
        case ("GET", "/node.ps1"):
            return nodeScript(host: hostEndpoint(for: request))
        case ("GET", "/join.cmd"):
            var response = ClusterHTTPResponse.text(Self.joinCommandFile(host: hostEndpoint(for: request)),
                                                    contentType: "application/octet-stream")
            response.headers["Content-Disposition"] = #"attachment; filename="Join OMNIA Cluster.cmd""#
            return response
        case ("POST", "/v1/join"):
            return join(request)
        case ("POST", "/v1/heartbeat"):
            return heartbeat(request)
        case ("POST", "/v1/leave"):
            return leave(request)
        case (_, "/v1/join"), (_, "/v1/heartbeat"), (_, "/v1/leave"):
            return refusal("Use POST.", status: 405)
        default:
            return .text("Not found.", status: 404)
        }
    }

    /// "address:port" as the client reached this device, for the links it gets back.
    private func hostEndpoint(for request: ClusterHTTPRequest) -> String {
        if let host = request.headers["host"], ClusterInvitation.isEndpoint(host) { return host }
        return "\(address ?? "127.0.0.1"):\(port)"
    }

    private func refusal(_ message: String, status: Int) -> ClusterHTTPResponse {
        .json(ClusterProtocol.Reply(ok: false, error: message), status: status)
    }

    private func join(_ request: ClusterHTTPRequest) -> ClusterHTTPResponse {
        guard let address = request.remoteAddress else {
            return refusal("Join over IPv4 on the local network.", status: 400)
        }
        guard let message = try? JSONDecoder().decode(ClusterProtocol.JoinRequest.self, from: request.body) else {
            return refusal("That isn't a join request OMNIA understands.", status: 400)
        }
        guard message.protocolVersion == ClusterProtocol.version else {
            return refusal("This device speaks another version of OMNIA's cluster. Update OMNIA (and OMNIA Node) on every device.", status: 426)
        }
        if let build = message.worker.llamaBuild, build != ClusterProtocol.llamaBuild {
            return refusal("This device runs llama.cpp \(build), and the cluster needs \(ClusterProtocol.llamaBuild). Run the command from \(name)'s join page again to update it.", status: 426)
        }
        let worker = message.worker
        guard !worker.id.isEmpty, !worker.devices.isEmpty, (1...65_535).contains(worker.rpcPort) else {
            return refusal("This device offered nothing to run on.", status: 400)
        }
        if declined.contains(worker.id) {
            return refusal("\(name) declined this device.", status: 403)
        }
        let welcome = ClusterProtocol.Reply(ok: true, cluster: name, hostAddresses: addresses,
                                            heartbeatSeconds: ClusterProtocol.heartbeatSeconds)

        // Joining again: it restarted, or came back from the background, or changed address.
        if let index = workers.firstIndex(where: { $0.id == worker.id }) {
            let previous = workers[index].endpoint
            workers[index].info = worker
            workers[index].address = address
            lastSeen[worker.id] = .now
            workers[index].lostAt = nil
            workers[index].available = Self.offers(worker)
            if previous != workers[index].endpoint { onWorkerGone?(previous) }
            return .json(welcome)
        }

        guard message.token == code || approved.contains(worker.id) else {
            if let index = requests.firstIndex(where: { $0.id == worker.id }) {
                requests[index].info = worker
                requests[index].address = address
            } else {
                requests.append(JoinRequest(id: worker.id, info: worker, address: address, requestedAt: .now))
            }
            return .json(ClusterProtocol.Reply(ok: false, pending: true,
                                               message: "Approve \(worker.name) on \(name) to add it to the cluster."),
                         status: 202)
        }
        guard workers.count < ClusterProtocol.maximumWorkers else {
            return refusal("The cluster already has \(ClusterProtocol.maximumWorkers) devices.", status: 409)
        }
        approved.insert(worker.id)
        defaults.set(Array(approved), forKey: Self.approvedKey)
        workers.append(Worker(id: worker.id, info: worker, address: address, joinedAt: .now,
                              rttMs: nil, busy: false, available: Self.offers(worker), lostAt: nil))
        lastSeen[worker.id] = .now
        return .json(welcome)
    }

    private static func offers(_ worker: ClusterProtocol.WorkerInfo) -> [Int: UInt64] {
        Dictionary(worker.devices.map { ($0.index, $0.memoryFree) }, uniquingKeysWith: { first, _ in first })
    }

    private func heartbeat(_ request: ClusterHTTPRequest) -> ClusterHTTPResponse {
        guard let message = try? JSONDecoder().decode(ClusterProtocol.HeartbeatRequest.self, from: request.body) else {
            return refusal("That isn't a heartbeat OMNIA understands.", status: 400)
        }
        guard let index = workers.firstIndex(where: { $0.id == message.id }) else {
            return refusal("This device isn't in the cluster; it joins again.", status: 404)
        }
        lastSeen[message.id] = .now
        // One write, and only for a change that a plan or the screen would show: round trips and
        // free memory jitter with every heartbeat, which used to redraw every view of the cluster.
        var updated = workers[index]
        if let rtt = message.rttMs, rtt > 0, Self.changed(updated.rttMs, to: rtt) { updated.rttMs = rtt }
        let busy = message.busy ?? false
        updated.busy = busy
        // Free memory counts while it holds nothing: what's in use then is someone else's.
        if !busy, let updates = message.devices {
            for update in updates where Self.changed(updated.available[update.index], to: update.memoryFree) {
                updated.available[update.index] = update.memoryFree
            }
        }
        if let lost = updated.lostAt, Date().timeIntervalSince(lost) > 30 {
            updated.lostAt = nil
        }
        if updated != workers[index] { workers[index] = updated }
        return .json(ClusterProtocol.Reply(ok: true))
    }

    /// A round trip that moved by at least 2 ms and a quarter.
    nonisolated static func changed(_ old: Double?, to new: Double) -> Bool {
        guard let old else { return true }
        return abs(new - old) >= max(2, old / 4)
    }

    /// Free memory that moved by at least 64 MB.
    nonisolated static func changed(_ old: UInt64?, to new: UInt64) -> Bool {
        guard let old else { return true }
        return (new > old ? new - old : old - new) >= 64 << 20
    }

    private func leave(_ request: ClusterHTTPRequest) -> ClusterHTTPResponse {
        guard let message = try? JSONDecoder().decode(ClusterProtocol.LeaveRequest.self, from: request.body) else {
            return refusal("That isn't a request OMNIA understands.", status: 400)
        }
        if let worker = workers.first(where: { $0.id == message.id }) {
            workers.removeAll { $0.id == message.id }
            onWorkerGone?(worker.endpoint)
        }
        requests.removeAll { $0.id == message.id }
        return .json(ClusterProtocol.Reply(ok: true))
    }

    // MARK: Joining from a PC

    private func nodeScript(host: String) -> ClusterHTTPResponse {
        guard let url = Bundle.main.url(forResource: "omnia-node", withExtension: "ps1"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            return .text("Write-Host 'OMNIA Node is missing from this build of OMNIA.'", status: 404)
        }
        let script = source
            .replacingOccurrences(of: "__OMNIA_HOST__", with: host)
            .replacingOccurrences(of: "__OMNIA_TOKEN__", with: Self.nodeToken)
            .replacingOccurrences(of: "__OMNIA_CLUSTER_NAME__", with: Self.powerShellQuoted(name))
        return .text(script)
    }

    /// Text for inside a single-quoted PowerShell string. PowerShell also ends one at the curly
    /// quotes iOS types for an apostrophe ("Ahmed’s iPad"), so each is doubled like a straight one.
    static func powerShellQuoted(_ text: String) -> String {
        text.replacingOccurrences(of: "['\u{2018}\u{2019}\u{201A}\u{201B}]", with: "$0$0", options: .regularExpression)
    }

    static func joinCommandFile(host: String) -> String {
        ["@echo off",
         "rem Lends this PC's GPU to the OMNIA cluster at \(host). Keep the window open while you use it.",
         command(for: "http://\(host)"),
         "pause",
         ""].joined(separator: "\r\n")
    }

    private func joinPageHTML(host: String) -> String {
        let page = "http://\(host)"
        let command = Self.command(for: page).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        let cluster = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Join \(cluster)'s OMNIA cluster</title>
        <style>
          :root { color-scheme: light dark; --ink: #1d1d1f; --muted: #6e6e73; --card: #ffffff; --page: #f2f2f7; --accent: #2f6fde; --code: #f5f5f7; }
          @media (prefers-color-scheme: dark) { :root { --ink: #f5f5f7; --muted: #a1a1a6; --card: #1c1c1e; --page: #000000; --accent: #5e9bff; --code: #2c2c2e; } }
          * { box-sizing: border-box; }
          body { margin: 0; background: var(--page); color: var(--ink); font: 16px/1.5 -apple-system, "Segoe UI", system-ui, sans-serif; }
          main { max-width: 720px; margin: 0 auto; padding: 48px 20px; }
          h1 { font-size: 30px; line-height: 1.2; margin: 0 0 8px; }
          p.lead { color: var(--muted); margin: 0 0 28px; }
          ol { list-style: none; padding: 0; margin: 0; display: grid; gap: 14px; }
          li { background: var(--card); border-radius: 16px; padding: 18px 20px; }
          li b { display: block; margin-bottom: 6px; }
          code { display: block; background: var(--code); border-radius: 10px; padding: 12px 14px; font: 13px/1.5 ui-monospace, Consolas, monospace; overflow-wrap: anywhere; }
          button, a.button { margin-top: 10px; border: 0; border-radius: 999px; padding: 9px 18px; background: var(--accent); color: #fff; font: inherit; font-weight: 600; cursor: pointer; text-decoration: none; display: inline-block; }
          .note { color: var(--muted); font-size: 14px; margin-top: 24px; }
        </style>
        </head>
        <body>
        <main>
          <h1>Lend this PC to \(cluster)</h1>
          <p class="lead">OMNIA runs models too big for one device by spreading them over your devices. This PC's graphics card holds part of the model; the chat stays on \(cluster).</p>
          <ol>
            <li><b>1. Open PowerShell</b>Press the Windows key, type PowerShell and press Enter.</li>
            <li><b>2. Paste this and press Enter</b><code id="command">\(command)</code><button onclick="copyCommand(this)">Copy</button> <a class="button" href="/join.cmd">Or download it to double-click</a></li>
            <li><b>3. Allow it on \(cluster)</b>Tap Allow when \(cluster) asks. If Windows asks about network access, allow it on private networks.</li>
            <li><b>4. Leave the window open</b>The PC is part of the cluster while OMNIA Node runs. Press Ctrl+C in its window to stop.</li>
          </ol>
          <p class="note">The first run downloads llama.cpp \(ClusterProtocol.llamaBuild) from GitHub and checks it: about 670 MB for NVIDIA graphics cards, 40 MB otherwise. Everything stays on your network: the model's data goes only between this PC and \(cluster). Windows 10 or 11 is needed.</p>
        </main>
        <script>
        function copyCommand(button) {
          const text = document.getElementById("command").innerText;
          const done = () => { button.textContent = "Copied"; setTimeout(() => button.textContent = "Copy", 2000); };
          if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(text).then(done); return; }
          const area = document.createElement("textarea");
          area.value = text; document.body.appendChild(area); area.select(); document.execCommand("copy"); area.remove(); done();
        }
        </script>
        </body>
        </html>
        """
    }
}
