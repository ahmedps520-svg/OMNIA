import AppIntents
import Foundation
import Observation
import UniformTypeIdentifiers

/// "Ask OMNIA" in Siri, Shortcuts and Spotlight: a new chat with the question, answered on this
/// device by the default model. OMNIA opens to it, since answering needs the GPU, which iOS
/// doesn't give an app in the background.
struct AskOMNIAIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask OMNIA"
    static let description = IntentDescription("Starts a new chat with your question, answered on this device by your default model.")
    static let openAppWhenRun = true

    @Parameter(title: "Question")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.shared.startChat(question)
        return .result()
    }
}

/// "Summarize with OMNIA": text or a document from Shortcuts (or a shortcut in the share sheet),
/// summarized in a new chat.
struct SummarizeIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize with OMNIA"
    static let description = IntentDescription("Starts a new chat that summarizes text or a document (PDF, text, Markdown or code) on this device.")
    static let openAppWhenRun = true

    @Parameter(title: "Text")
    var text: String?

    @Parameter(title: "Document", supportedContentTypes: [.pdf, .text, .sourceCode, .rtf])
    var document: IntentFile?

    enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case nothingToSummarize

        var localizedStringResource: LocalizedStringResource {
            "Choose some text or a document to summarize."
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        var attachments: [AttachmentRecord] = []
        if let text = text?.trimmed, !text.isEmpty {
            attachments.append(AttachmentRecord(name: "Text", kind: .text, byteSize: text.utf8.count, text: text))
        }
        if let document {
            attachments.append(try Self.attachment(from: document))
        }
        guard !attachments.isEmpty else { throw Failure.nothingToSummarize }
        AppServices.shared.startChat("Summarize this.", attachments: attachments)
        return .result()
    }

    /// The document's text, read as an attached file is.
    private static func attachment(from file: IntentFile) throws -> AttachmentRecord {
        var name = file.filename.isEmpty ? "Document" : file.filename
        if (name as NSString).pathExtension.isEmpty, let suffix = file.type?.preferredFilenameExtension {
            name += ".\(suffix)"
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: name)
        try file.data.write(to: url)
        let extracted = try DocumentExtractor.extract(from: url)
        return AttachmentRecord(name: name, kind: extracted.kind, byteSize: extracted.byteSize, text: extracted.text)
    }
}

struct OMNIAShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskOMNIAIntent(), phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
                    shortTitle: "Ask OMNIA", systemImageName: "bubble.left.and.text.bubble.right")
        AppShortcut(intent: SummarizeIntent(), phrases: ["Summarize with \(.applicationName)"],
                    shortTitle: "Summarize", systemImageName: "text.append")
    }
}

/// Shows a conversation started outside a window (Siri, Shortcuts, shared items) in the window
/// that handles the request first.
@MainActor
@Observable
final class AppNavigator {
    struct Request: Equatable {
        let id = UUID()
        let conversation: UUID
    }

    private(set) var request: Request?

    func show(_ conversation: UUID) {
        request = Request(conversation: conversation)
    }

    func handled(_ request: Request) {
        if self.request == request { self.request = nil }
    }
}
