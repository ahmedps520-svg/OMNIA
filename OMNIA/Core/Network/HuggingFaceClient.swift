import Foundation

/// Read-only access to the public Hugging Face Hub API: model search, file listings with
/// SHA-256 hashes, and GGUF header inspection via HTTP range requests.
/// No account or token is used; gated repositories are reported as unavailable.
struct HuggingFaceClient: Sendable {
    static let base = URL(string: "https://huggingface.co")!

    enum ClientError: LocalizedError {
        case offlineMode
        case http(Int)
        case gated(String)
        case notFound

        var errorDescription: String? {
            switch self {
            case .offlineMode: "Offline-only mode is on. Turn it off in Settings › Privacy to browse and download models."
            case .http(let code): "Hugging Face responded with HTTP \(code)."
            case .gated(let repo): "\(repo) requires accepting a license on huggingface.co with an account. OMNIA only downloads openly available files."
            case .notFound: "The file is no longer available at this location."
            }
        }
    }

    struct ModelSummary: Decodable, Identifiable, Hashable, Sendable {
        let id: String
        let downloads: Int?
        let likes: Int?
        let tags: [String]?
        let lastModified: String?
        let gated: GatedValue?

        var author: String { id.split(separator: "/").first.map(String.init) ?? id }
        var name: String { id.split(separator: "/").last.map(String.init) ?? id }
        var isGated: Bool { gated?.isGated ?? false }
    }

    struct ModelDetail: Decodable, Sendable {
        let id: String
        let gated: GatedValue?
        let cardData: CardData?
        let tags: [String]?

        struct CardData: Decodable, Sendable {
            let license: String?
        }

        var license: String? {
            cardData?.license ?? tags?.first { $0.hasPrefix("license:") }.map { String($0.dropFirst("license:".count)) }
        }
    }

    /// The Hub returns `false`, `"auto"` or `"manual"`.
    enum GatedValue: Decodable, Hashable, Sendable {
        case open
        case gated(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                self = flag ? .gated("true") : .open
            } else if let mode = try? container.decode(String.self) {
                self = mode.isEmpty || mode == "false" ? .open : .gated(mode)
            } else {
                self = .open
            }
        }

        var isGated: Bool { if case .gated = self { true } else { false } }
    }

    struct TreeEntry: Decodable, Hashable, Sendable {
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?

        struct LFS: Decodable, Hashable, Sendable {
            let oid: String
            let size: Int64
        }

        var fileName: String { (path as NSString).lastPathComponent }
        var byteSize: Int64 { lfs?.size ?? size ?? 0 }
        var sha256: String? { lfs?.oid }
        var isGGUF: Bool { type == "file" && path.lowercased().hasSuffix(".gguf") }
        /// Vision projectors and split shards can't be loaded as a standalone text model.
        var isLoadableGGUF: Bool {
            let lower = fileName.lowercased()
            return isGGUF && !lower.contains("mmproj") && lower.range(of: "-0000[0-9]-of-", options: .regularExpression) == nil
        }
    }

    var offlineOnly: Bool

    private var session: URLSession { .shared }

    // MARK: Endpoints

    func search(_ query: String, limit: Int = 40) async throws -> [ModelSummary] {
        var components = URLComponents(url: Self.base.appending(path: "api/models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        return try await get(components.url!, as: [ModelSummary].self)
    }

    func detail(repo: String) async throws -> ModelDetail {
        try await get(Self.base.appending(path: "api/models/\(repo)"), as: ModelDetail.self)
    }

    func files(repo: String) async throws -> [TreeEntry] {
        var components = URLComponents(url: Self.base.appending(path: "api/models/\(repo)/tree/main"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        return try await get(components.url!, as: [TreeEntry].self)
    }

    /// `revision` pins a commit, so the files match the hashes recorded for it.
    static func downloadURL(repo: String, path: String, revision: String = "main") -> URL {
        var components = URLComponents(url: base.appending(path: "\(repo)/resolve/\(revision)/\(path)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "download", value: "true")]
        return components.url!
    }

    /// Reads the GGUF header of a remote file without downloading the weights.
    func inspectGGUF(repo: String, path: String) async throws -> (header: GGUFHeader, info: GGUFModelInfo) {
        guard !offlineOnly else { throw ClientError.offlineMode }
        let url = Self.downloadURL(repo: repo, path: path)
        return try await GGUFInspector.inspect { range in
            var request = URLRequest(url: url)
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            request.timeoutInterval = 60
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ClientError.http(-1) }
            switch http.statusCode {
            case 206, 200: return data
            case 401, 403: throw ClientError.gated(repo)
            case 404: throw ClientError.notFound
            case 416: return Data() // range beyond end of file
            default: throw ClientError.http(http.statusCode)
            }
        }
    }

    private func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        guard !offlineOnly else { throw ClientError.offlineMode }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 403 { throw ClientError.gated(url.path()) }
            if http.statusCode == 404 { throw ClientError.notFound }
            throw ClientError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
