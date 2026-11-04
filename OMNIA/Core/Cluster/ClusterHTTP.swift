import Foundation
import Network

/// One request to the host's HTTP server.
struct ClusterHTTPRequest: Sendable {
    let method: String
    let path: String
    /// Header names in lowercase.
    let headers: [String: String]
    let body: Data
    /// The IPv4 address it came from.
    let remoteAddress: String?
}

struct ClusterHTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data
    var headers: [String: String] = [:]

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> ClusterHTTPResponse {
        let body = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return ClusterHTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: body)
    }

    static func text(_ text: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> ClusterHTTPResponse {
        ClusterHTTPResponse(status: status, contentType: contentType, body: Data(text.utf8))
    }

    /// The response on the wire. Every connection carries one request, so it closes after this.
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 426: "Upgrade Required"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
    }
}

/// Reads HTTP/1.1 requests as their bytes arrive. Only what the cluster needs: small requests
/// with a Content-Length, one per connection.
enum ClusterHTTPParser {
    static let maximumHeaderBytes = 16 * 1024
    static let maximumBodyBytes = 64 * 1024

    struct Head: Equatable, Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        /// Bytes up to and including the blank line after the headers.
        let headerLength: Int
        let contentLength: Int

        /// The client waits for "100 Continue" before sending the body (.NET does by default).
        var expectsContinue: Bool { headers["expect"]?.lowercased() == "100-continue" }
    }

    struct Failure: Error, Equatable {
        let status: Int
        let message: String
    }

    /// The request head once it has fully arrived; nil while more bytes are needed.
    static func head(in buffer: Data) throws -> Head? {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            if buffer.count > maximumHeaderBytes { throw Failure(status: 431, message: "Request headers are too large.") }
            return nil
        }
        let headerLength = end.upperBound - buffer.startIndex
        guard headerLength <= maximumHeaderBytes + separator.count else {
            throw Failure(status: 431, message: "Request headers are too large.")
        }
        guard let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            throw Failure(status: 400, message: "The request isn't text.")
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            throw Failure(status: 400, message: "Malformed request line.")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw Failure(status: 400, message: "Malformed header.") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil {
            throw Failure(status: 400, message: "Send the body with a Content-Length.")
        }
        let length = headers["content-length"].map { Int($0) } ?? 0
        guard let length, length >= 0 else { throw Failure(status: 400, message: "Malformed Content-Length.") }
        guard length <= maximumBodyBytes else { throw Failure(status: 413, message: "The request body is too large.") }
        // The path without its query: the cluster's routes take none.
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return Head(method: String(requestLine[0]).uppercased(), path: path, headers: headers,
                    headerLength: headerLength, contentLength: length)
    }
}

/// The host's HTTP server: workers join and check in through it, and a PC gets the page and the
/// script it needs. Plain HTTP on the local network, advertised over Bonjour.
final class ClusterHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (ClusterHTTPRequest) async -> ClusterHTTPResponse

    private let queue = DispatchQueue(label: "app.omnia.cluster.http")
    private let handler: Handler
    private var listener: NWListener?
    /// Set when the listener fails after it started (iOS can revoke it while the app is suspended).
    var onFailure: (@Sendable () -> Void)?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Listens on the first free port from `preferred` (trying ten), advertising `name` over Bonjour.
    func start(preferred: UInt16, name: String) async throws -> UInt16 {
        var lastError: Error?
        for port in preferred..<(preferred + 10) {
            do {
                try await listen(on: port, name: name)
                return port
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NWError.posix(.EADDRINUSE)
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }

    private func listen(on port: UInt16, name: String) async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: name, type: ClusterProtocol.bonjourType)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let gate = StartGate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if !gate.resumed {
                        gate.resumed = true
                        continuation.resume()
                    }
                case .failed(let error):
                    listener.cancel()
                    if !gate.resumed {
                        gate.resumed = true
                        continuation.resume(throwing: error)
                    } else {
                        self?.onFailure?()
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        queue.sync { self.listener = listener }
    }

    /// Whether a start already reported back; state updates arrive on `queue`, one at a time.
    private final class StartGate: @unchecked Sendable {
        var resumed = false
    }

    /// Bytes received so far on one connection, touched only on `queue`.
    private final class Exchange: @unchecked Sendable {
        var buffer = Data()
        var sentContinue = false
        var answered = false
    }

    private func accept(_ connection: NWConnection) {
        let remote = LocalNetwork.ipv4(of: connection.endpoint)
        let exchange = Exchange()
        connection.start(queue: queue)
        receive(on: connection, exchange: exchange, remote: remote)
        // A client that never finishes its request doesn't keep the connection.
        queue.asyncAfter(deadline: .now() + 20) {
            if !exchange.answered { connection.cancel() }
        }
    }

    private func receive(on connection: NWConnection, exchange: Exchange, remote: String?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let data { exchange.buffer.append(data) }
            do {
                if let head = try ClusterHTTPParser.head(in: exchange.buffer) {
                    let total = head.headerLength + head.contentLength
                    if exchange.buffer.count >= total {
                        let start = exchange.buffer.startIndex
                        let body = exchange.buffer.subdata(in: (start + head.headerLength)..<(start + total))
                        let request = ClusterHTTPRequest(method: head.method, path: head.path, headers: head.headers,
                                                         body: body, remoteAddress: remote)
                        exchange.answered = true
                        let handler = self.handler
                        Task {
                            let response = await handler(request)
                            self.reply(response, on: connection)
                        }
                        return
                    }
                    if head.expectsContinue && !exchange.sentContinue {
                        exchange.sentContinue = true
                        connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .idempotent)
                    }
                }
            } catch let failure as ClusterHTTPParser.Failure {
                exchange.answered = true
                self.reply(.text(failure.message, status: failure.status), on: connection)
                return
            } catch {
                connection.cancel()
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, exchange: exchange, remote: remote)
        }
    }

    private func reply(_ response: ClusterHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// This device on the local network.
enum LocalNetwork {
    /// Its IPv4 addresses on Wi-Fi, wired and Personal Hotspot networks, Wi-Fi (en0) first.
    static func addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(interface: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(bitPattern: entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let interface = String(cString: entry.ifa_name)
            guard interface.hasPrefix("en") || interface.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            // Self-assigned addresses mean no network was joined.
            guard !text.hasPrefix("169.254.") else { continue }
            found.append((interface, text))
        }
        return found.sorted { $0.interface.localizedStandardCompare($1.interface) == .orderedAscending }.map(\.address)
    }

    /// The IPv4 address of a connection's other end (IPv4-mapped IPv6 included).
    static func ipv4(of endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            return dotted(address)
        case .ipv6(let address):
            return address.asIPv4.map(dotted)
        default:
            return nil
        }
    }

    static func dotted(_ address: IPv4Address) -> String {
        address.rawValue.map(String.init).joined(separator: ".")
    }

    /// A free TCP port on the loopback interface, for a server that only this device reaches.
    static func freeLoopbackPort() -> UInt16? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }
}
