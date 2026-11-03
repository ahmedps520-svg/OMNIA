import Foundation
import WebKit

/// A message a sandboxed page wrote to its console, or the value a run returned.
struct ConsoleLine: Identifiable, Hashable, Sendable {
    enum Level: String, Sendable {
        case log, info, warn, error, debug, result
    }

    let id = UUID()
    let level: Level
    let text: String
}

/// Collects console messages from a page (`window.webkit.messageHandlers.omniaConsole`).
@MainActor
final class ConsoleSink: NSObject, WKScriptMessageHandler {
    private(set) var lines: [ConsoleLine] = []
    var onLine: (@MainActor (ConsoleLine) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let text = body["text"] as? String else { return }
        let line = ConsoleLine(level: ConsoleLine.Level(rawValue: body["level"] as? String ?? "") ?? .log, text: text)
        // Runaway loops can log without end: keep the first few hundred lines.
        guard lines.count < WebSandbox.maxConsoleLines else { return }
        lines.append(line)
        onLine?(line)
    }

    func clear() {
        lines = []
    }
}

/// WebKit settings shared by code previews, code runs and the model's page reader.
@MainActor
enum WebSandbox {
    static let consoleHandler = "omniaConsole"
    static let maxConsoleLines = 500

    /// Forwards console output, uncaught errors and rejected promises to `ConsoleSink`.
    static let consoleScript = """
    (() => {
      const post = (level, args) => {
        try {
          const text = args.map(a => {
            if (typeof a === 'string') return a;
            if (a instanceof Error) return a.stack || String(a);
            try { return JSON.stringify(a); } catch (_) { return String(a); }
          }).join(' ');
          window.webkit.messageHandlers.omniaConsole.postMessage({ level, text: text.slice(0, 4000) });
        } catch (_) {}
      };
      for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
        const original = console[level];
        console[level] = (...args) => { post(level, args); original.apply(console, args); };
      }
      window.addEventListener('error', e => post('error', [e.message + (e.lineno ? ' (line ' + e.lineno + ')' : '')]));
      window.addEventListener('unhandledrejection', e => post('error', ['Unhandled rejection: ' + ((e.reason && e.reason.message) || e.reason)]));
    })();
    """

    /// A configuration for sandboxed pages: no cookies or storage kept, console forwarded, and
    /// with `blockNetwork` no request leaves the device (code can't send anything anywhere).
    static func configuration(console: ConsoleSink?, blockNetwork: Bool,
                              schemeHandler: RuntimeSchemeHandler? = nil) async -> WKWebViewConfiguration {
        let configuration = baseConfiguration(console: console, schemeHandler: schemeHandler)
        if blockNetwork, let rules = await networkRules() {
            configuration.userContentController.add(rules)
        }
        return configuration
    }

    /// The same, without network blocking (which needs a compiled rule list; add it later with
    /// `networkRules()` before loading).
    static func baseConfiguration(console: ConsoleSink?, schemeHandler: RuntimeSchemeHandler? = nil) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        if let console {
            let controller = configuration.userContentController
            controller.addUserScript(WKUserScript(source: consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            controller.add(console, name: consoleHandler)
        }
        if let schemeHandler {
            configuration.setURLSchemeHandler(schemeHandler, forURLScheme: RuntimeSchemeHandler.scheme)
        }
        return configuration
    }

    /// Detaches the console so the page and the sink can be released.
    static func release(_ webView: WKWebView) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: consoleHandler)
        webView.navigationDelegate = nil
    }

    private static var compiledRules: WKContentRuleList?

    /// A content rule list blocking every web request (http, https, WebSocket, FTP).
    static func networkRules() async -> WKContentRuleList? {
        if let compiledRules { return compiledRules }
        let rules = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp)://"},"action":{"type":"block"}}]"#
        let list = try? await WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "omnia-no-network", encodedContentRuleList: rules)
        compiledRules = list
        return list
    }
}

/// Loads a page and waits until it has finished (or failed) loading.
@MainActor
final class PageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Error?, Never>?

    /// Returns nil when the page loaded, or the error that stopped it.
    func load(_ start: (WKWebView) -> WKNavigation?, in webView: WKWebView) async -> Error? {
        webView.navigationDelegate = self
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if start(webView) == nil { finish(URLError(.badURL)) }
        }
    }

    private func finish(_ error: Error?) {
        continuation?.resume(returning: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(URLError(.cancelled))
    }
}
