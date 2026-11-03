import Foundation
import WebKit

/// Reads the web for the model with its own offscreen WebKit view: pages run their scripts as
/// in Safari and their visible text comes back. It shares nothing with the Browser tab (separate
/// website data, kept only while a page is read) and does nothing in Offline-only mode.
@MainActor
final class WebReader {
    struct Page: Sendable {
        let url: URL
        let title: String
        let text: String
    }

    struct SearchResult: Sendable {
        let title: String
        let url: URL
        let snippet: String
    }

    enum Failure: LocalizedError {
        case offline
        case notWebAddress(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .offline: "Offline-only mode is on, so the web can't be used."
            case .notWebAddress(let address): "“\(address)” isn't a web address (http or https)."
            case .unreadable(let reason): reason
            }
        }
    }

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Opens a page and returns its title and readable text.
    func read(_ address: String, timeout: Duration = .seconds(20)) async throws -> Page {
        guard let url = Self.webURL(address) else { throw Failure.notWebAddress(address) }
        let (webView, error) = try await open(url, timeout: timeout)
        defer { WebSandbox.release(webView) }
        let script = """
        const root = document.querySelector('article, main, [role=main]') || document.body;
        return { title: document.title || '', url: location.href, text: root ? root.innerText : '' };
        """
        let reply = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        let fields = reply as? [String: Any] ?? [:]
        let text = Self.tidy(fields["text"] as? String ?? "")
        guard !text.isEmpty else {
            throw Failure.unreadable(error.map { "The page couldn't be loaded: \($0.localizedDescription)" } ?? "The page has no readable text.")
        }
        return Page(url: (fields["url"] as? String).flatMap(URL.init(string:)) ?? url,
                    title: fields["title"] as? String ?? "", text: text)
    }

    /// The top web results for `query` (DuckDuckGo's HTML results page, without ads).
    func search(_ query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let (webView, error) = try await open(components.url!, timeout: .seconds(20))
        defer { WebSandbox.release(webView) }
        let script = """
        return [...document.querySelectorAll('.result:not(.result--ad)')].map(r => {
          const link = r.querySelector('a.result__a');
          return { title: link ? link.innerText.trim() : '', url: link ? link.href : '',
                   snippet: ((r.querySelector('.result__snippet') || {}).innerText || '').trim() };
        }).filter(r => r.url).slice(0, 8);
        """
        let reply = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        let results = (reply as? [[String: Any]] ?? []).compactMap { fields -> SearchResult? in
            guard let link = (fields["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return SearchResult(title: fields["title"] as? String ?? "", url: Self.resolveRedirect(link),
                                snippet: fields["snippet"] as? String ?? "")
        }
        if results.isEmpty, let error { throw Failure.unreadable("The search couldn't be loaded: \(error.localizedDescription)") }
        return results
    }

    /// The results page a person would see for `query`.
    nonisolated static func searchPage(_ query: String) -> URL? {
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    // MARK: Loading

    /// Loads `url` in a fresh offscreen view. A page still loading at the time limit is stopped
    /// and read as far as it got.
    private func open(_ url: URL, timeout: Duration) async throws -> (WKWebView, Error?) {
        guard !settings.offlineOnly else { throw Failure.offline }
        let configuration = await WebSandbox.configuration(console: nil, blockNetwork: false)
        configuration.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366), configuration: configuration)
        let stopper = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            webView.stopLoading()
        }
        let error = await PageLoader().load({ $0.load(URLRequest(url: url, timeoutInterval: 20)) }, in: webView)
        stopper.cancel()
        // Give scripts a moment to fill in pages that render after loading.
        try? await Task.sleep(for: .milliseconds(600))
        return (webView, error)
    }

    nonisolated static func webURL(_ address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil else { return nil }
        return url
    }

    /// DuckDuckGo links go through a redirect that carries the real address in `uddg`.
    nonisolated static func resolveRedirect(_ url: URL) -> URL {
        guard url.host()?.hasSuffix("duckduckgo.com") == true,
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "uddg" })?.value,
              let resolved = URL(string: target) else { return url }
        return resolved
    }

    /// Collapses runs of blank lines and spaces left by page layout.
    nonisolated static func tidy(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) {
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct WebSearchTool: ChatTool {
    let symbol = "magnifyingglass"
    let activity = "Searching the web"
    let reader: WebReader
    let definition = ToolDefinition(
        name: "web_search",
        description: "Searches the web. Returns the top results with their addresses and snippets; open one with open_url to read it.",
        parameters: ToolDefinition.schema([("query", "string", "What to search for")], required: ["query"]))

    func run(_ arguments: ToolArguments) async throws -> String {
        let query = try ToolRunner.string("query", in: arguments)
        let results = try await reader.search(query)
        guard !results.isEmpty else { return "No results." }
        return results.enumerated().map { offset, result in
            "\(offset + 1). \(result.title)\n\(result.url.absoluteString)" + (result.snippet.isEmpty ? "" : "\n\(result.snippet)")
        }.joined(separator: "\n\n")
    }
}

struct OpenURLTool: ChatTool {
    let symbol = "safari"
    let activity = "Reading a web page"
    let reader: WebReader
    let definition = ToolDefinition(
        name: "open_url",
        description: "Opens a web page and returns its title and readable text.",
        parameters: ToolDefinition.schema([("url", "string", "The page's address")], required: ["url"]))

    func run(_ arguments: ToolArguments) async throws -> String {
        let page = try await reader.read(try ToolRunner.string("url", in: arguments))
        return "\(page.title)\n\(page.url.absoluteString)\n\n\(page.text)"
    }
}

/// Lets the model run the code it writes, to check a calculation or try an idea. The sandbox
/// has no network and a time limit.
struct RunCodeTool: ChatTool {
    let symbol = "play.rectangle"
    let activity = "Running code"
    let runner: CodeRunner
    let languages: [CodeRunner.Language]
    let definition: ToolDefinition

    init(runner: CodeRunner, languages: [CodeRunner.Language]) {
        self.runner = runner
        self.languages = languages
        let names = languages.map(\.rawValue).joined(separator: " or ")
        definition = ToolDefinition(
            name: "run_code",
            description: "Runs a short \(names) program in a sandbox without network access and returns what it prints and the value of its last expression. Python has only its standard library.",
            parameters: ToolDefinition.schema([("language", "string", names), ("code", "string", "The program")],
                                              required: ["language", "code"]))
    }

    func run(_ arguments: ToolArguments) async throws -> String {
        let name = try ToolRunner.string("language", in: arguments).lowercased()
        let language: CodeRunner.Language? = switch name {
        case "javascript", "js", "node": .javascript
        case "python", "py", "python3": .python
        default: nil
        }
        guard let language, languages.contains(language) else {
            return "Error: “\(name)” can't run here. Available: \(languages.map(\.rawValue).joined(separator: ", "))."
        }
        let result = await runner.run(try ToolRunner.string("code", in: arguments), language: language)
        return result.transcript
    }
}
