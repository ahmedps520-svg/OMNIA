import Foundation
import Network

/// This device's llama.cpp RPC server, which serves its GPU to a cluster host. It starts the first
/// time the device lends itself and runs for the life of the app: llama.cpp's server can't be
/// stopped, and while no host is connected it holds no memory. It listens on the loopback
/// interface only; `ClusterRelay` decides who reaches it.
final class ClusterRPCServer: @unchecked Sendable {
    static let shared = ClusterRPCServer()

    /// Weights the host sends are kept here, so the next load of the same model reads them from
    /// flash instead of the network. iOS may clear it when space runs low.
    let cacheDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "ClusterWeights", directoryHint: .isDirectory)

    private let lock = NSLock()
    private var port: UInt16?

    /// The loopback port the server listens on, starting it if needed; nil when it can't run.
    func start() -> UInt16? {
        lock.lock()
        defer { lock.unlock() }
        if let port { return port }
        guard RPCBridge.isAvailable, let device = RPCBridge.localDevice else { return nil }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cache = cacheDirectory.path(percentEncoded: false)
        let threads = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        // The port is free when chosen but taken only when the server binds it; if another
        // process got there first the server returns at once, and another port is tried.
        for _ in 0..<3 {
            guard let candidate = LocalNetwork.freeLoopbackPort() else { continue }
            let endpoint = "127.0.0.1:\(candidate)"
            let thread = Thread {
                RPCBridge.runServer(endpoint: endpoint, cacheDirectory: cache, threads: threads, device: device)
            }
            thread.name = "OMNIA cluster server"
            // Deep graphs are rebuilt recursively from what the host sends.
            thread.stackSize = 16 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
            Thread.sleep(forTimeInterval: 0.3)
            if !thread.isFinished {
                port = candidate
                return candidate
            }
        }
        return nil
    }

    /// Bytes of weights kept for faster reloads.
    var cacheSize: UInt64 {
        guard let files = FileManager.default.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in files {
            total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}

/// Forwards a cluster host's RPC connection to this device's server. llama.cpp's server would
/// serve anyone who reaches it, so the relay lets in the host's addresses alone, one connection
/// at a time: when the host reconnects, the old connection ends.
final class ClusterRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.omnia.cluster.relay")
    private let target: NWEndpoint.Port
    private var listener: NWListener?
    private var allowed: Set<String>
    private var session: Session?
    private var transferredBytes: UInt64 = 0
    private(set) var port: UInt16 = 0

    private final class Session {
        let inbound: NWConnection
        let outbound: NWConnection
        var closed = false

        init(inbound: NWConnection, outbound: NWConnection) {
            self.inbound = inbound
            self.outbound = outbound
        }
    }

    private init(target: UInt16, allowed: Set<String>) {
        self.target = NWEndpoint.Port(rawValue: target)!
        self.allowed = allowed
    }

    /// Listens on the first free port from `preferred` (trying ten), forwarding to `target` on
    /// the loopback interface.
    static func start(preferred: UInt16, target: UInt16, allowing addresses: Set<String>) async throws -> ClusterRelay {
        let relay = ClusterRelay(target: target, allowed: addresses)
        var lastError: Error?
        for port in preferred..<(preferred + 10) {
            do {
                try await relay.listen(on: port)
                return relay
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NWError.posix(.EADDRINUSE)
    }

    /// Lets in more of the host's addresses (it may reach this device from another interface).
    func allow(_ addresses: [String]) {
        queue.async { self.allowed.formUnion(addresses) }
    }

    /// A host is connected.
    var isActive: Bool { queue.sync { session != nil } }

    /// Bytes forwarded so far, both ways.
    var transferred: UInt64 { queue.sync { transferredBytes } }

    /// Ends the current connection, if any, and stops listening.
    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            close(session)
        }
    }

    /// Ends the current connection but keeps listening, so the host can reconnect.
    func disconnect() {
        queue.sync { close(session) }
    }

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private final class StartGate: @unchecked Sendable {
        var resumed = false
    }

    private func listen(on port: UInt16) async throws {
        let listener = try NWListener(using: Self.parameters(), on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let gate = StartGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready where !gate.resumed:
                    gate.resumed = true
                    continuation.resume()
                case .failed(let error):
                    listener.cancel()
                    if !gate.resumed {
                        gate.resumed = true
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        queue.sync {
            self.listener = listener
            self.port = port
        }
    }

    private func accept(_ connection: NWConnection) {
        guard let address = LocalNetwork.ipv4(of: connection.endpoint), allowed.contains(address) else {
            connection.cancel()
            return
        }
        close(session)
        let outbound = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: target, using: Self.parameters())
        let session = Session(inbound: connection, outbound: outbound)
        self.session = session
        for side in [connection, outbound] {
            side.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.close(session)
                default: break
                }
            }
            side.start(queue: queue)
        }
        pump(from: connection, to: outbound, session: session)
        pump(from: outbound, to: connection, session: session)
    }

    /// Moves bytes one way, waiting for each chunk to be sent before reading the next, so a slow
    /// side holds the other back instead of filling memory.
    private func pump(from source: NWConnection, to destination: NWConnection, session: Session) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !session.closed else { return }
            if let data, !data.isEmpty {
                self.transferredBytes &+= UInt64(data.count)
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil || isComplete {
                        self.close(session)
                    } else {
                        self.pump(from: source, to: destination, session: session)
                    }
                })
                return
            }
            if isComplete || error != nil {
                self.close(session)
            } else {
                self.pump(from: source, to: destination, session: session)
            }
        }
    }

    /// Ends a session; runs on `queue`.
    private func close(_ session: Session?) {
        guard let session, !session.closed else { return }
        session.closed = true
        session.inbound.cancel()
        session.outbound.cancel()
        if self.session === session { self.session = nil }
    }
}
