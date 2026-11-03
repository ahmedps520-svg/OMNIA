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

    /// The worker evaluates the program as a script, so its last expression is the result. A
    /// program using top-level await, which a script can't, runs as the body of an async function.
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
          if (!(e instanceof SyntaxError) || !/\bawait\b/.test(code)) throw e;
          value = (0, eval)('(async () => {\n' + code + '\n})()');
        }
        if (value instanceof Promise) value = await value;
        postMessage({ type: 'done', ok: true,
                      value: value === undefined ? null : (typeof value === 'string' ? value : (() => { try { return JSON.stringify(value, null, 2); } catch (_) { return String(value); } })()) });
      } catch (e) {
        // JavaScriptCore's stack lists frames without the message, so the error leads.
        postMessage({ type: 'done', ok: false, error: String(e) + (e && e.line ? ' (line ' + e.line + ')' : '') });
      }
    };
    """#

    /// Starts the worker, keeps its console, and ends it at the time limit. The console comes
    /// back with the result, so none of it can arrive after the run is over.
    private static let javaScriptHost = """
    const worker = new Worker(URL.createObjectURL(new Blob([source], { type: 'text/javascript' })));
    const lines = [];
    return await new Promise((resolve) => {
      const finish = (result) => { clearTimeout(timer); worker.terminate(); resolve(Object.assign({}, result, { console: lines })); };
      const timer = setTimeout(() => finish({ ok: false, timedOut: true }), Number(timeoutMs));
      worker.onmessage = (event) => {
        const message = event.data;
        if (message.type === 'console') {
          if (lines.length < maxLines) lines.push({ level: message.level, text: String(message.text).slice(0, 4000) });
        } else {
          finish(message);
        }
      };
      worker.onerror = (event) => finish({ ok: false, error: event.message || 'The program could not start.' });
      worker.postMessage(code);
    });
    """

    private func runJavaScript(_ code: String, timeout: Duration) async -> Result {
        let started = ContinuousClock.now
        let configuration = await WebSandbox.configuration(console: nil, blockNetwork: true)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        defer { WebSandbox.release(webView) }
        if let error = await PageLoader().load({ $0.loadHTMLString("<!doctype html><meta charset=utf-8><body></body>", baseURL: nil) }, in: webView) {
            return Result(console: [], error: error.localizedDescription, duration: started.secondsElapsed)
        }
        let outcome = await Self.evaluate(Self.javaScriptHost,
                                          arguments: ["source": Self.javaScriptWorker, "code": code,
                                                      "timeoutMs": Self.milliseconds(timeout), "maxLines": WebSandbox.maxConsoleLines],
                                          in: webView, limit: timeout + .seconds(5))
        return Self.result(outcome, started: started)
    }

    // MARK: Python

    /// Talks to the Python worker (`RuntimeSchemeHandler` serves it), which keeps Pyodide loaded
    /// between runs. A program that runs too long ends the worker; the next run starts a new one.
    private static let pythonHost = """
    // A new worker first loads Pyodide, which takes a few seconds: that isn't held against the program.
    const fresh = !globalThis.omniaPython;
    if (fresh) globalThis.omniaPython = new Worker('worker.js', { type: 'module' });
    const worker = globalThis.omniaPython;
    const lines = [];
    return await new Promise((resolve) => {
      const finish = (result, stop) => {
        clearTimeout(timer);
        if (stop) { worker.terminate(); globalThis.omniaPython = null; }
        resolve(Object.assign({}, result, { console: lines }));
      };
      const timer = setTimeout(() => finish({ ok: false, timedOut: true }, true), Number(timeoutMs) + (fresh ? 20000 : 0));
      worker.onmessage = (event) => {
        const message = event.data;
        if (message.type === 'console') {
          if (lines.length < maxLines) lines.push({ level: message.level, text: String(message.text).slice(0, 4000) });
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
            let configuration = await WebSandbox.configuration(console: nil, blockNetwork: true, schemeHandler: handler)
            let page = WKWebView(frame: .zero, configuration: configuration)
            if let error = await PageLoader().load({ $0.load(URLRequest(url: RuntimeSchemeHandler.pageURL)) }, in: page) {
                WebSandbox.release(page)
                return Result(console: [], error: error.localizedDescription, duration: started.secondsElapsed)
            }
            pythonPage = page
            webView = page
        }
        let outcome = await Self.evaluate(Self.pythonHost,
                                          arguments: ["code": code, "timeoutMs": Self.milliseconds(timeout),
                                                      "maxLines": WebSandbox.maxConsoleLines],
                                          in: webView, limit: timeout + .seconds(30))
        if case .failed = outcome {
            WebSandbox.release(webView)
            pythonPage = nil
        }
        return Self.result(outcome, started: started)
    }

    // MARK: Evaluation

    private enum Outcome: Sendable {
        case finished(ok: Bool, value: String?, error: String?, timedOut: Bool, console: [ConsoleLine])
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

    /// Runs the host script and waits for the promise it returns. The script enforces the time
    /// limit itself; `limit` is a safety net should the page stop responding.
    private static func evaluate(_ script: String, arguments: [String: Any], in webView: WKWebView,
                                 limit: Duration) async -> Outcome {
        await withCheckedContinuation { continuation in
            let first = FirstResult(continuation)
            Task { @MainActor in
                do {
                    // `contentWorld:` is the async variant, which waits for the promise.
                    let reply = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
                    first.resume(outcome(from: reply))
                } catch {
                    first.resume(.failed(WebSandbox.message(for: error)))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                first.resume(.failed("The sandbox stopped responding."))
            }
        }
    }

    private static func outcome(from reply: Any?) -> Outcome {
        guard let fields = reply as? [String: Any] else {
            return .failed("The sandbox returned no result.")
        }
        let console = (fields["console"] as? [[String: Any]] ?? []).compactMap { line -> ConsoleLine? in
            guard let text = line["text"] as? String else { return nil }
            return ConsoleLine(level: ConsoleLine.Level(rawValue: line["level"] as? String ?? "") ?? .log, text: text)
        }
        return .finished(ok: fields["ok"] as? Bool ?? false, value: fields["value"] as? String,
                         error: fields["error"] as? String, timedOut: fields["timedOut"] as? Bool ?? false, console: console)
    }

    private static func result(_ outcome: Outcome, started: ContinuousClock.Instant) -> Result {
        var result = Result(console: [], duration: started.secondsElapsed)
        switch outcome {
        case let .finished(ok, value, error, timedOut, console):
            result.console = console
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
