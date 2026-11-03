import Observation
import SwiftUI
import WebKit

/// The workspace's browser: one web view for the whole app, so pages and sign-ins stay while
/// moving between conversations. Website data is kept like Safari's.
@MainActor
@Observable
final class BrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var progress: Double = 0
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    var errorMessage: String?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.url = view.url } },
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.title ?? "" } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in MainActor.assumeIsolated { self?.progress = view.estimatedProgress } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } }
        ]
    }

    /// Opens an address, or searches the web for anything that isn't one.
    func open(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let looksLikeAddress = text.contains("://") || (text.contains(".") && !text.contains(" "))
        if looksLikeAddress, let url = WebReader.webURL(text) {
            load(url)
        } else if let url = WebReader.searchPage(text) {
            load(url)
        }
    }

    func load(_ url: URL) {
        guard !settings.offlineOnly else {
            errorMessage = WebReader.Failure.offline.localizedDescription
            return
        }
        errorMessage = nil
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() {
        if isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    /// The current page's readable text, as an attachment for a question about it.
    func pageAttachment() async -> AttachmentRecord? {
        let script = """
        const root = document.querySelector('article, main, [role=main]') || document.body;
        return { title: document.title || '', text: root ? root.innerText : '' };
        """
        guard let url, let reply = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page),
              let fields = reply as? [String: Any] else { return nil }
        let text = WebReader.tidy(fields["text"] as? String ?? "")
        guard !text.isEmpty else { return nil }
        let title = (fields["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.host() ?? "Web page"
        return AttachmentRecord(name: title, kind: .text, byteSize: text.utf8.count, text: "\(url.absoluteString)\n\n\(text)")
    }

    // MARK: WebKit

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard settings.offlineOnly, let scheme = navigationAction.request.url?.scheme, scheme.hasPrefix("http") else { return .allow }
        errorMessage = WebReader.Failure.offline.localizedDescription
        return .cancel
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        errorMessage = nil
    }

    /// Links that open a new window open here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    private func report(_ error: Error) {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled, code != 102 else { return } // 102: the response became a download
        errorMessage = error.localizedDescription
    }
}

/// A web page made from code (HTML or SVG), with its console. Network requests are blocked
/// in Offline-only mode.
@MainActor
@Observable
final class PreviewPage {
    let webView: WKWebView
    private(set) var console: [ConsoleLine] = []
    private let sink: ConsoleSink
    @ObservationIgnored private var blocksNetwork = false

    init() {
        let sink = ConsoleSink()
        self.sink = sink
        webView = WKWebView(frame: .zero, configuration: WebSandbox.baseConfiguration(console: sink))
        webView.isInspectable = true
        sink.onLine = { [weak self] line in self?.console.append(line) }
    }

    func load(_ html: String, blockNetwork: Bool) async {
        if blockNetwork, !blocksNetwork, let rules = await WebSandbox.networkRules() {
            webView.configuration.userContentController.add(rules)
            blocksNetwork = true
        }
        console = []
        sink.clear()
        webView.loadHTMLString(html, baseURL: nil)
    }
}

/// What the workspace panel shows: a conversation's code, a preview, or the browser.
@MainActor
@Observable
final class WorkspaceController {
    enum Tab: String, CaseIterable, Identifiable {
        case preview, code, browser
        var id: String { rawValue }

        var title: String {
            switch self {
            case .preview: "Preview"
            case .code: "Code"
            case .browser: "Browser"
            }
        }
    }

    var isPresented = false
    var tab: Tab = .code
    var selected: CodeArtifact?
    /// The conversation's code blocks, newest first.
    var artifacts: [CodeArtifact] = []

    let browser: BrowserSession
    let runner: CodeRunner
    /// Adds an attachment to the message being written (set by the chat).
    @ObservationIgnored var attach: ((AttachmentRecord) -> Void)?

    init(browser: BrowserSession, runner: CodeRunner) {
        self.browser = browser
        self.runner = runner
    }

    /// Shows a block from a reply; when it's part of the conversation, with its companions
    /// (an HTML page's CSS and scripts).
    func show(language: String, code: String) {
        show(artifacts.first { $0.code == code } ?? .standalone(language: language, code: code))
    }

    func show(_ artifact: CodeArtifact) {
        selected = artifact
        tab = .preview
        isPresented = true
    }

    func openInBrowser(_ url: URL) {
        browser.load(url)
        tab = .browser
        isPresented = true
    }
}

/// Hosts a web view owned by a model object, so it survives SwiftUI view updates.
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
