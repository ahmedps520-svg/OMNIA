import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The panel beside a conversation: its code, previews of pages and images it made, runs of its
/// programs, and a browser. On iPhone it opens as a sheet.
struct WorkspaceView: View {
    @Bindable var controller: WorkspaceController

    var body: some View {
        VStack(spacing: 0) {
            Picker("Workspace", selection: $controller.tab) {
                ForEach(WorkspaceController.Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(12)
            Divider()
            switch controller.tab {
            case .preview: PreviewTab(controller: controller)
            case .code: CodeListTab(controller: controller)
            case .browser: BrowserTab(session: controller.browser, attach: controller.attach)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

// MARK: - Code

struct CodeListTab: View {
    let controller: WorkspaceController

    var body: some View {
        if controller.artifacts.isEmpty {
            OmniaEmptyState(title: "No code yet",
                            message: "Code from this conversation appears here, ready to preview, run or share.",
                            symbol: "chevron.left.forwardslash.chevron.right")
        } else {
            List(controller.artifacts) { artifact in
                Button {
                    controller.show(artifact)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: artifact.kind.symbol)
                            .frame(width: 28, height: 28)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(artifact.summary.isEmpty ? artifact.kind.title : artifact.summary)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("\(artifact.kind.title) · \(artifact.lineCount) \(artifact.lineCount == 1 ? "line" : "lines")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = artifact.code }
                    ShareLink(item: CodeFile(artifact: artifact), preview: SharePreview(CodeFile(artifact: artifact).name)) {
                        Label("Share File", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

/// Code shared as a file with its proper extension (written only when it's shared).
struct CodeFile: Transferable {
    let artifact: CodeArtifact

    var name: String {
        let extensions: [CodeArtifact.Kind: String] = [.html: "html", .svg: "svg", .markdown: "md", .json: "json",
                                                       .javascript: "js", .python: "py", .css: "css"]
        let fileExtension = extensions[artifact.kind] ?? (artifact.language.isEmpty ? "txt" : artifact.language.lowercased())
        let base = String(artifact.summary.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }.prefix(40))
            .trimmingCharacters(in: .whitespaces)
        return "\(base.isEmpty ? "code" : base).\(fileExtension)"
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { file in
            let directory = FileManager.default.temporaryDirectory.appending(path: "Workspace-\(UUID().uuidString)",
                                                                            directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: file.name)
            try Data(file.artifact.code.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

// MARK: - Preview

struct PreviewTab: View {
    let controller: WorkspaceController

    var body: some View {
        if let artifact = controller.selected {
            ArtifactPreview(artifact: artifact, runner: controller.runner)
                .id(artifact.id)
        } else {
            OmniaEmptyState(title: "Nothing to preview",
                            message: "Pick a web page, image, Markdown, JSON or program in Code, or tap Preview or Run on a code block in the chat.",
                            symbol: "eye")
        }
    }
}

struct ArtifactPreview: View {
    let artifact: CodeArtifact
    let runner: CodeRunner

    var body: some View {
        switch artifact.kind {
        case .html, .svg:
            WebPreviewPane(artifact: artifact)
        case .markdown:
            ScrollView {
                MarkdownView(text: artifact.code).padding(16)
            }
        case .json:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let pretty = artifact.formattedJSON() {
                        CodeBlockView(language: "json", code: pretty, showsWorkspaceActions: false)
                    } else {
                        Label("This isn't valid JSON.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Theme.caution)
                        CodeBlockView(language: "json", code: artifact.code, showsWorkspaceActions: false)
                    }
                }
                .padding(16)
            }
        case .javascript, .python:
            RunPane(artifact: artifact, runner: runner)
        case .css, .other:
            ScrollView {
                CodeBlockView(language: artifact.language, code: artifact.code, showsWorkspaceActions: false).padding(16)
            }
        }
    }
}

struct WebPreviewPane: View {
    let artifact: CodeArtifact

    @Environment(AppSettings.self) private var settings
    @State private var page = PreviewPage()
    @State private var showsConsole = true

    private var document: String { artifact.previewDocument() ?? artifact.code }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label(artifact.summary.isEmpty ? artifact.kind.title : artifact.summary, systemImage: artifact.kind.symbol)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await page.load(document, blockNetwork: settings.offlineOnly) }
                }
                .labelStyle(.iconOnly)
                ShareLink(item: CodeFile(artifact: artifact), preview: SharePreview(CodeFile(artifact: artifact).name)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            WebViewHost(webView: page.webView)
            ConsoleView(lines: page.console, isExpanded: $showsConsole)
        }
        .task { await page.load(document, blockNetwork: settings.offlineOnly) }
    }
}

struct RunPane: View {
    let artifact: CodeArtifact
    let runner: CodeRunner

    @Environment(PythonRuntime.self) private var python
    @State private var result: CodeRunner.Result?
    @State private var running = false
    @State private var showsConsole = true

    private var language: CodeRunner.Language { artifact.kind == .python ? .python : .javascript }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(artifact.kind.title, systemImage: "play.rectangle")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if language == .python, !python.isInstalled {
                    PythonInstallButton()
                } else {
                    Button {
                        run()
                    } label: {
                        Label(running ? "Running…" : "Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(running)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                CodeBlockView(language: artifact.language, code: artifact.code, showsWorkspaceActions: false).padding(16)
            }
            ConsoleView(lines: outputLines, isExpanded: $showsConsole, footer: footer)
        }
    }

    private var outputLines: [ConsoleLine] {
        guard let result else { return [] }
        var lines = result.console
        if let value = result.value { lines.append(ConsoleLine(level: .result, text: value)) }
        if result.timedOut { lines.append(ConsoleLine(level: .error, text: "Stopped: the program ran longer than the time limit.")) }
        if let error = result.error { lines.append(ConsoleLine(level: .error, text: error)) }
        return lines
    }

    private var footer: String? {
        guard let result else { return language == .python ? "Python runs offline with its standard library." : nil }
        return "Ran in \(ByteFormat.seconds(result.duration)) · no network access"
    }

    private func run() {
        running = true
        Task {
            result = await runner.run(artifact.code, language: language)
            running = false
        }
    }
}

/// The Python runtime's state in Settings, with install and remove.
struct PythonRuntimeRow: View {
    @Environment(PythonRuntime.self) private var python

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Python")
                Text(python.isInstalled ? "Installed · \(ByteFormat.file(PythonRuntime.totalBytes))" : "Not installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if python.isInstalled {
                Button("Remove", role: .destructive) { python.remove() }
            } else {
                PythonInstallButton()
            }
        }
    }
}

/// Installs the Python runtime (Pyodide) on demand.
struct PythonInstallButton: View {
    @Environment(PythonRuntime.self) private var python

    var body: some View {
        switch python.state {
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Installing Python · \(Int(fraction * 100))%").font(.caption)
            }
            .frame(width: 180)
        case .failed(let message):
            Button("Retry Python Install", systemImage: "arrow.clockwise") { python.install() }
                .help(message)
        case .notInstalled, .installed:
            Button("Install Python (\(ByteFormat.file(PythonRuntime.totalBytes)))", systemImage: "arrow.down.circle") {
                python.install()
            }
            .buttonStyle(.glassProminent)
        }
    }
}

struct ConsoleView: View {
    let lines: [ConsoleLine]
    @Binding var isExpanded: Bool
    var footer: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Button {
                withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                    Text("Console").font(.caption.weight(.semibold))
                    if !lines.isEmpty {
                        Text("\(lines.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if lines.contains(where: { $0.level == .error }) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.critical)
                    }
                    Spacer()
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if isExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if lines.isEmpty {
                            Text("Output appears here.").foregroundStyle(.tertiary)
                        }
                        ForEach(lines) { line in
                            Text(line.text)
                                .foregroundStyle(color(line.level))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let footer {
                            Text(footer).foregroundStyle(.tertiary).padding(.top, 4)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 220)
            }
        }
        .background(Theme.surface)
    }

    private func color(_ level: ConsoleLine.Level) -> Color {
        switch level {
        case .error: Theme.critical
        case .warn: Theme.caution
        case .result: Theme.positive
        case .log, .info, .debug: .primary
        }
    }
}

// MARK: - Browser

struct BrowserTab: View {
    let session: BrowserSession
    /// Attaches the page to the message being written, so the model can answer about it.
    var attach: ((AttachmentRecord) -> Void)?

    @State private var address = ""
    @State private var attached = false
    @FocusState private var editingAddress: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Back", systemImage: "chevron.backward") { session.goBack() }
                    .disabled(!session.canGoBack)
                Button("Forward", systemImage: "chevron.forward") { session.goForward() }
                    .disabled(!session.canGoForward)
                TextField("Search or enter address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .focused($editingAddress)
                    .onSubmit { session.open(address) }
                Button(session.isLoading ? "Stop" : "Reload", systemImage: session.isLoading ? "xmark" : "arrow.clockwise") {
                    session.reload()
                }
                .disabled(session.url == nil)
                if let url = session.url {
                    if let attach {
                        Button("Ask About This Page", systemImage: attached ? "checkmark" : "text.bubble") {
                            Task {
                                guard let page = await session.pageAttachment() else { return }
                                attach(page)
                                attached = true
                                try? await Task.sleep(for: .seconds(1.5))
                                attached = false
                            }
                        }
                        .help("Attach this page's text to your message")
                    }
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share")
                }
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if session.isLoading {
                ProgressView(value: session.progress).progressViewStyle(.linear)
            }
            if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.caution)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if session.url == nil {
                OmniaEmptyState(title: "Browser",
                                message: "Search the web or enter an address. Pages the model reads in a conversation can be opened here too.",
                                symbol: "safari")
            } else {
                WebViewHost(webView: session.webView)
            }
        }
        .onAppear { address = session.url?.absoluteString ?? "" }
        .onChange(of: session.url) { _, url in
            if !editingAddress { address = url?.absoluteString ?? "" }
        }
    }
}
