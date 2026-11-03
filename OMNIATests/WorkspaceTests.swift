import Foundation
import Testing
@testable import OMNIA

@Suite("Workspace code")
@MainActor
struct CodeArtifactTests {
    private func reply(_ content: String) -> Message {
        Message(role: .assistant, content: content, position: 1)
    }

    @Test func recognisesWhatEachBlockIs() {
        #expect(CodeArtifact.Kind(language: "html", code: "<p>") == .html)
        #expect(CodeArtifact.Kind(language: "", code: "<!DOCTYPE html><html></html>") == .html)
        #expect(CodeArtifact.Kind(language: "xml", code: "<svg viewBox='0 0 1 1'></svg>") == .svg)
        #expect(CodeArtifact.Kind(language: "py", code: "print(1)") == .python)
        #expect(CodeArtifact.Kind(language: "JavaScript", code: "1") == .javascript)
        #expect(CodeArtifact.Kind(language: "ts", code: "let a: number = 1") == .other)
        #expect(CodeArtifact.Kind(language: "json", code: "{}").isPreviewable)
        #expect(CodeArtifact.Kind(language: "python", code: "").isRunnable)
    }

    @Test func extractsBlocksNewestFirstWithTheirCompanions() {
        let older = reply("```python\nprint('hi')\n```")
        let newer = reply("Here:\n```html\n<html><head><link rel=\"stylesheet\" href=\"style.css\"></head><body><h1>Hi</h1></body></html>\n```\n```css\nh1 { color: red; }\n```")
        let artifacts = CodeArtifact.extract(from: [Message(role: .user, content: "```js\nignored\n```", position: 0), older, newer])

        #expect(artifacts.map(\.kind) == [.html, .css, .python])
        #expect(artifacts[0].messageID == newer.id)
        #expect(artifacts[0].companions.map(\.kind) == [.css])
        let page = try? #require(artifacts[0].previewDocument())
        #expect(page?.contains("h1 { color: red; }") == true)
        #expect(page?.contains("style.css") == false, "the linked stylesheet is replaced by the inline one")
    }

    @Test func addsScriptsToPagesWithoutTheirOwn() {
        var page = CodeArtifact.standalone(language: "html", code: "<html><body><p id=x></p></body></html>")
        page.companions = [CodeArtifact.standalone(language: "js", code: "document.getElementById('x').textContent = 'ok'")]
        let document = try? #require(page.previewDocument())
        #expect(document?.contains("<script>\ndocument.getElementById('x')") == true)
        #expect(document?.contains("name=\"viewport\"") == true)
    }

    @Test func wrapsImagesAndFormatsData() {
        let svg = CodeArtifact.standalone(language: "svg", code: "<svg width='10' height='10'></svg>")
        #expect(svg.previewDocument()?.contains("<body><svg width='10'") == true)
        let json = CodeArtifact.standalone(language: "json", code: #"{"b":1,"a":[true,null]}"#)
        #expect(json.formattedJSON()?.contains("\"a\" : [") == true)
        #expect(CodeArtifact.standalone(language: "json", code: "{oops").formattedJSON() == nil)
    }

    @Test func summarisesBlocks() {
        #expect(CodeArtifact.standalone(language: "html", code: "<title>Snake</title>").summary == "Snake")
        #expect(CodeArtifact.standalone(language: "python", code: "import math\n\ndef area(r):\n    pass").summary == "def area(r):")
        #expect(CodeArtifact.standalone(language: "js", code: "// Draw a chart\nconst x = 1").summary == "Draw a chart")
    }
}

@Suite("Web helpers")
struct WebHelperTests {
    @Test func understandsAddresses() {
        #expect(WebReader.webURL("example.com/path")?.absoluteString == "https://example.com/path")
        #expect(WebReader.webURL("http://example.com")?.scheme == "http")
        #expect(WebReader.webURL("file:///etc/passwd") == nil)
        #expect(WebReader.webURL("two words") == nil)
    }

    @Test func followsSearchRedirects() throws {
        let link = try #require(URL(string: "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2Fdocumentation%2F&rut=abc"))
        #expect(WebReader.resolveRedirect(link).absoluteString == "https://swift.org/documentation/")
        let direct = try #require(URL(string: "https://swift.org"))
        #expect(WebReader.resolveRedirect(direct) == direct)
    }

    @Test func tidiesPageText() {
        #expect(WebReader.tidy("  Title \n\n\n  Body  \n\n") == "Title\n\nBody")
    }
}

@Suite("Running code", .serialized, .timeLimit(.minutes(10)))
@MainActor
struct CodeRunnerTests {
    private func runner() -> CodeRunner {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omnia-python-\(UUID().uuidString)")
        let settings = AppSettings(defaults: UserDefaults(suiteName: "omnia-tests-\(UUID().uuidString)")!)
        return CodeRunner(python: PythonRuntime(settings: settings, directory: directory))
    }

    @Test func runsJavaScriptAndKeepsItsOutput() async {
        let result = await runner().run("console.log('hello'); console.error('careful'); 6 * 7", language: .javascript)
        #expect(result.console.map(\.text) == ["hello", "careful"])
        #expect(result.console.last?.level == .error)
        #expect(result.value == "42")
        #expect(result.error == nil)
        #expect(result.transcript == "hello\n[error] careful\nResult: 42")
    }

    @Test func reportsErrors() async {
        let result = await runner().run("throw new Error('boom')", language: .javascript)
        #expect(result.error?.contains("boom") == true)
        #expect(result.value == nil)
    }

    @Test func supportsTopLevelAwait() async {
        let result = await runner().run("const n = await Promise.resolve(5); console.log(n * 2)", language: .javascript)
        #expect(result.console.map(\.text) == ["10"])
        #expect(result.error == nil)
    }

    @Test func stopsProgramsThatRunTooLong() async {
        let started = ContinuousClock.now
        let result = await runner().run("while (true) {}", language: .javascript, timeout: .seconds(1))
        #expect(result.timedOut)
        #expect(started.secondsElapsed < 10)
    }

    @Test(.enabled(if: TestModels.available("pyodide-314.0.7/pyodide.asm.wasm")))
    func runsPythonOfflineInAWorker() async throws {
        let directory = try #require(TestModels.url("pyodide-314.0.7"))
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: "omnia-tests-\(UUID().uuidString)")))
        let python = PythonRuntime(settings: settings, directory: directory)
        #expect(python.isInstalled)
        let code = CodeRunner(python: python)

        let first = await code.run("import math\nprint(math.factorial(10))\n'ok'", language: .python, timeout: .seconds(60))
        #expect(first.error == nil, "\(first.error ?? "")")
        #expect(first.console.map(\.text) == ["3628800"])
        #expect(first.value == "ok")
        let second = await code.run("x = 21\nx * 2", language: .python)
        #expect(second.value == "42")
        let failure = await code.run("1 / 0", language: .python)
        #expect(failure.error?.contains("ZeroDivisionError") == true)
        // A program that never ends is stopped, and the next run starts a fresh interpreter.
        let loop = await code.run("while True:\n    pass", language: .python, timeout: .seconds(2))
        #expect(loop.timedOut)
        let after = await code.run("print('again')", language: .python, timeout: .seconds(60))
        #expect(after.console.map(\.text) == ["again"])
    }

    @Test func pythonNeedsItsRuntime() async {
        let code = runner()
        #expect(!code.isAvailable(.python))
        let result = await code.run("print(1)", language: .python)
        #expect(result.error?.contains("Python isn't installed") == true)
    }

    @Test func runCodeToolReportsUnavailableLanguages() async throws {
        let tool = RunCodeTool(runner: runner(), languages: [.javascript])
        let reply = try await tool.run(["language": .string("python"), "code": .string("print(1)")])
        #expect(reply.hasPrefix("Error:"))
        #expect(tool.definition.description.contains("javascript"))
    }
}
