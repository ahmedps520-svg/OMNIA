import Foundation
import WebKit

/// Runs JavaScript and Python in WebKit's sandbox: a separate process, no network (nothing a
/// program does can leave the device), no stored data, and a time limit.
///
/// Programs run in a Web Worker, so a program that never ends is stopped by terminating its
/// worker; the page around it stays responsive. JavaScript gets a fresh page each run; Python
/// keeps its page and worker between runs, so Pyodide loads only once.
@MainActor
final class CodeRunner {
    enum Language: String, CaseIterable, Sendable {
        case javascript, python
    }

    struct Result: Sendable {
        var console: [ConsoleLine]
        /// The value of the last expression, when there is one.
        var value: String?
        var error: String?
        var timedOut = false
        var duration: Double

        /// What the model reads back: printed output, then the value or the error.
        var transcript: String {
            var parts = console.map { line in line.level == .error || line.level == .warn ? "[\(line.level.rawValue)] \(line.text)" : line.text }
            if let value { parts.append("Result: \(value)") }
            if timedOut { parts.append("Stopped: the program ran longer than the time limit.") }
            if let error { parts.append("Error: \(error)") }
            return parts.isEmpty ? "(no output)" : parts.joined(separator: "\n")
        }
    }

    let python: PythonRuntime
    private var pythonPage: WKWebView?
    private let pythonConsole = ConsoleSink()

    init(python: PythonRuntime) {
        self.python = python
    }

    func isAvailable(_ language: Language) -> Bool {
        language == .javascript || python.isInstalled
    }

    func run(_ code: String, language: Language, timeout: Duration = .seconds(15)) async -> Result {
        switch language {
        case .javascript: await runJavaScript(code, timeout: timeout)
        case .python: await runPython(code, timeout: timeout)
        }
    }

    // MARK: JavaScript

    /// The worker evaluates the program as a script, so its last expression is the result;
    /// a program using top-level await runs as the body of an async function.
    private static let javaScriptWorker = #"""
    const text = (v) => { if (typeof v === 'string') return v; try { return JSON.stringify(v); } catch (_) { return String(v); } };
    for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
      console[level] = (...args) => postMessage({ type: 'console', level, text: args.map(text).join(' ') });
    }
    onmessage = async (event) => {
      const code = event.data;
      try {
        let value;
        try {
          value = (0, eval)(code);
        } catch (e) {
          if (!(e instanceof SyntaxError) || !/await/.test(String(e.message))) throw e;
          value = (0, eval)('(async () => {\n' + code + '\n})()');
        }
        if (value instanceof Promise) value = await value;
        postMessage({ type: 'done', ok: true,
                      value: value === undefined ? null : (typeof value === 'string' ? value : (() => { try { return JSON.stringify(value, null, 2); } catch (_) { return String(value); } })()) });
      } catch (e) {
        postMessage({ type: 'done', ok: false, error: String((e && e.stack) || e) });
      }
    };
    """#

    /// Starts the worker, forwards its console, and ends it at the time limit.
    private static let javaScriptHost = """
    const worker = new Worker(URL.createObjectURL(new Blob([source], { type: 'text/javascript' })));
    return await new Promise((resolve) => {
      const finish = (result) => { clearTimeout(timer); worker.terminate(); resolve(result); };
      const timer = setTimeout(() => finish({ ok: false, timedOut: true }), Number(timeoutMs));
      worker.onmessage = (event) => {
        const message = event.data;
        if (message.type === 'console') {
          window.webkit.messageHandlers.omniaConsole.postMessage({ level: message.level, text: String(message.text).slice(0, 4000) });
        } else {
          finish(message);
        }
      };
      worker.onerror = (event) => finish({ ok: false, error: event.message || 'The program failed.' });
      worker.postMessage(code);
    });
    """

    private func runJavaScript(_ code: String, timeout: Duration) async -> Result {
        let started = ContinuousClock.now
        let console = ConsoleSink()
        let configuration = await WebSandbox.configuration(console: console, blockNetwork: true)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        defer { WebSandbox.release(webView) }
        if let error = await PageLoader().load({ $0.loadHTMLString("<!doctype html><meta charset=utf-8><body></body>", baseURL: nil) }, in: webView) {
            return Result(console: [], error: error.localizedDescription, duration: started.secondsElapsed)
        }
        let outcome = await Self.evaluate(Self.javaScriptHost,
                                          arguments: ["source": Self.javaScriptWorker, "code": code,
                                                      "timeoutMs": String(Self.milliseconds(timeout))],
                                          in: webView, limit: timeout + .seconds(5))
        return Self.result(outcome, console: console.lines, started: started)
    }

    // MARK: Python

    /// Talks to the Python worker (`RuntimeSchemeHandler` serves it), which keeps Pyodide loaded
    /// between runs. A program that runs too long ends the worker; the next run starts a new one.
    private static let pythonHost = """
    // A new worker first loads Pyodide, which takes a few seconds: that isn't held against the program.
    const fresh = !globalThis.omniaPython;
    if (fresh) globalThis.omniaPython = new Worker('worker.js');
    const worker = globalThis.omniaPython;
    return await new Promise((resolve) => {
      const finish = (result, stop) => {
        clearTimeout(timer);
        if (stop) { worker.terminate(); globalThis.omniaPython = null; }
        resolve(result);
      };
      const timer = setTimeout(() => finish({ ok: false, timedOut: true }, true), Number(timeoutMs) + (fresh ? 20000 : 0));
      worker.onmessage = (event) => {
        const message = event.data;
        if (message.type === 'console') {
          window.webkit.messageHandlers.omniaConsole.postMessage({ level: message.level, text: String(message.text).slice(0, 4000) });
        } else {
          finish(message, false);
        }
      };
      worker.onerror = (event) => finish({ ok: false, error: event.message || 'Python failed to start.' }, true);
      worker.postMessage({ code });
    });
    """

    private func runPython(_ code: String, timeout: Duration) async -> Result {
        let started = ContinuousClock.now
        guard let handler = python.schemeHandler() else {
            return Result(console: [], error: "Python isn't installed. Add it in Settings › Workspace.", duration: 0)
        }
        let webView: WKWebView
        if let page = pythonPage {
            webView = page
        } else {
            let configuration = await WebSandbox.configuration(console: pythonConsole, blockNetwork: true, schemeHandler: handler)
            let page = WKWebView(frame: .zero, configuration: configuration)
            if let error = await PageLoader().load({ $0.load(URLRequest(url: RuntimeSchemeHandler.pageURL)) }, in: page) {
                WebSandbox.release(page)
                return Result(console: [], error: error.localizedDescription, duration: started.secondsElapsed)
            }
            pythonPage = page
            webView = page
        }
        pythonConsole.clear()
        let outcome = await Self.evaluate(Self.pythonHost, arguments: ["code": code, "timeoutMs": String(Self.milliseconds(timeout))],
                                          in: webView, limit: timeout + .seconds(30))
        if case .failed = outcome {
            WebSandbox.release(webView)
            pythonPage = nil
        }
        return Self.result(outcome, console: pythonConsole.lines, started: started)
    }

    // MARK: Evaluation

    private enum Outcome: Sendable {
        case finished(ok: Bool, value: String?, error: String?, timedOut: Bool)
        case failed(String)
    }

    /// Resumes a continuation once, with whichever result comes first.
    @MainActor
    private final class FirstResult {
        private var continuation: CheckedContinuation<Outcome, Never>?

        init(_ continuation: CheckedContinuation<Outcome, Never>) {
            self.continuation = continuation
        }

        func resume(_ outcome: Outcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    /// Runs the host script. The script enforces the time limit itself; `limit` is a safety net
    /// should the page stop responding.
    private static func evaluate(_ script: String, arguments: [String: String], in webView: WKWebView,
                                 limit: Duration) async -> Outcome {
        await withCheckedContinuation { continuation in
            let first = FirstResult(continuation)
            Task { @MainActor in
                do {
                    let reply = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page)
                    let fields = reply as? [String: Any] ?? [:]
                    first.resume(.finished(ok: fields["ok"] as? Bool ?? false, value: fields["value"] as? String,
                                           error: fields["error"] as? String, timedOut: fields["timedOut"] as? Bool ?? false))
                } catch {
                    first.resume(.failed(error.localizedDescription))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                first.resume(.failed("The sandbox stopped responding."))
            }
        }
    }

    private static func result(_ outcome: Outcome, console: [ConsoleLine], started: ContinuousClock.Instant) -> Result {
        var result = Result(console: console, duration: started.secondsElapsed)
        switch outcome {
        case let .finished(ok, value, error, timedOut):
            if timedOut {
                result.timedOut = true
            } else if ok {
                result.value = value
            } else {
                result.error = error ?? "The program failed."
            }
        case .failed(let message):
            result.error = message
        }
        return result
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
