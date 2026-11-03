import CryptoKit
import Foundation
import Observation
import WebKit

/// Pyodide: CPython compiled to WebAssembly (Mozilla Public License 2.0). An optional 13.5 MB
/// download that lets the workspace and the model run Python offline, with the standard
/// library, inside WebKit's sandbox. Every file is pinned by size and SHA-256.
@MainActor
@Observable
final class PythonRuntime {
    struct File: Sendable {
        let name: String
        let size: Int
        let sha256: String
    }

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    static let version = "314.0.7"
    /// The npm release on jsDelivr, published 2026-09-14; sizes and hashes checked 2026-11-03.
    static let source = URL(string: "https://cdn.jsdelivr.net/npm/pyodide@314.0.7/")!
    static let files: [File] = [
        File(name: "pyodide.js", size: 18_912, sha256: "3141b814715a72e59b51b1b18b9ceae5bf19f7c852417e431bb0a34feadf825c"),
        File(name: "pyodide.asm.mjs", size: 1_250_344, sha256: "f7cdc8ece80678ceb712f8e65ebe6d3a83203a180c399865f49612a051693635"),
        File(name: "pyodide.asm.wasm", size: 9_598_218, sha256: "cc36e3cab04fdfc9a63ff13eb52eae2b911bf46c025cc7b281f394bd3de1d5e6"),
        File(name: "python_stdlib.zip", size: 2_545_637, sha256: "fa1957e5777068fc4f7437f96d860ae2fbe9c19732ba06c84e004ec16dd7dd7a"),
        File(name: "pyodide-lock.json", size: 119_077, sha256: "5dc2fc119108bc148c7457dc86e7675b5c87e1cafd420b9c34c1eaef7b36c010")
    ]
    static var totalBytes: Int64 { Int64(files.reduce(0) { $0 + $1.size }) }

    private(set) var state: State = .notInstalled
    let directory: URL
    private let settings: AppSettings
    @ObservationIgnored private var installTask: Task<Void, Never>?

    init(settings: AppSettings, directory: URL? = nil) {
        self.settings = settings
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? support.appending(path: "Runtimes/pyodide-\(Self.version)", directoryHint: .isDirectory)
        state = Self.isComplete(self.directory) ? .installed : .notInstalled
    }

    var isInstalled: Bool { state == .installed }

    /// Serves the installed files to WebKit.
    func schemeHandler() -> RuntimeSchemeHandler? {
        isInstalled ? RuntimeSchemeHandler(directory: directory) : nil
    }

    func install() {
        guard installTask == nil, !isInstalled else { return }
        guard !settings.offlineOnly else {
            state = .failed(HuggingFaceClient.ClientError.offlineMode.localizedDescription)
            return
        }
        state = .downloading(0)
        installTask = Task { [weak self] in
            await self?.download()
            self?.installTask = nil
        }
    }

    func remove() {
        installTask?.cancel()
        installTask = nil
        try? FileManager.default.removeItem(at: directory)
        state = .notInstalled
    }

    private func download() async {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appending(path: "pyodide-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            var received: Int64 = 0
            for file in Self.files {
                try Task.checkCancellation()
                let (temporary, response) = try await URLSession.shared.download(from: Self.source.appending(path: file.name))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
                try? fileManager.removeItem(at: temporary)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard data.count == file.size, digest == file.sha256 else { throw DownloadError.checksumMismatch }
                try data.write(to: staging.appending(path: file.name), options: .atomic)
                received += Int64(file.size)
                state = .downloading(Double(received) / Double(Self.totalBytes))
            }
            try? fileManager.removeItem(at: directory)
            try fileManager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: staging, to: directory)
            ModelStore.excludeFromBackup(directory)
            state = .installed
        } catch is CancellationError {
            state = .notInstalled
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private static func isComplete(_ directory: URL) -> Bool {
        files.allSatisfy { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appending(path: file.name).path(percentEncoded: false))
            return (attributes?[.size] as? NSNumber)?.intValue == file.size
        }
    }
}

/// Serves the Python runtime to WebKit at omnia-runtime://pyodide/…, plus the page that hosts it.
@MainActor
final class RuntimeSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "omnia-runtime"
    static let pageURL = URL(string: "omnia-runtime://pyodide/index.html")!

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    private static let page = """
    <!doctype html><html><head><meta charset="utf-8"></head><body></body></html>
    """

    /// Runs Python off the page's thread, so a program that never ends can be stopped by
    /// terminating the worker. Pyodide stays loaded between runs.
    private static let worker = """
    importScripts('pyodide.js');
    let pyodide = null;
    const forward = (level) => (text) => postMessage({ type: 'console', level, text });
    onmessage = async (event) => {
      try {
        if (!pyodide) {
          pyodide = await loadPyodide({ indexURL: 'omnia-runtime://pyodide/' });
          pyodide.setStdout({ batched: forward('log') });
          pyodide.setStderr({ batched: forward('error') });
        }
        const value = await pyodide.runPythonAsync(event.data.code);
        postMessage({ type: 'done', ok: true, value: (value === undefined || value === null) ? null : String(value) });
      } catch (e) {
        postMessage({ type: 'done', ok: false, error: String((e && e.message) || e) });
      }
    };
    """

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "pyodide" else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let name = url.lastPathComponent
        let body: Data?
        if name == "index.html" {
            body = Data(Self.page.utf8)
        } else if name == "worker.js" {
            body = Data(Self.worker.utf8)
        } else if PythonRuntime.files.contains(where: { $0.name == name }) {
            body = try? Data(contentsOf: directory.appending(path: name), options: .mappedIfSafe)
        } else {
            body = nil
        }
        guard let body, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                       headerFields: ["Content-Type": Self.mimeType(name),
                                                                      "Content-Length": String(body.count)]) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private static func mimeType(_ name: String) -> String {
        switch (name as NSString).pathExtension {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "wasm": "application/wasm"
        case "json": "application/json"
        case "zip": "application/zip"
        default: "application/octet-stream"
        }
    }
}
