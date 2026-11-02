import Foundation
import UniformTypeIdentifiers

/// Exports conversations as Markdown (readable anywhere) or JSON (complete, machine-readable).
enum ConversationExporter {
    enum Format: String, CaseIterable, Identifiable {
        case markdown, json
        var id: String { rawValue }
        var title: String { self == .markdown ? "Markdown" : "JSON" }
        var fileExtension: String { self == .markdown ? "md" : "json" }
        var contentType: UTType { self == .markdown ? (UTType(filenameExtension: "md") ?? .plainText) : .json }
    }

    struct ExportedMessage: Codable {
        var role: String
        var content: String
        var reasoning: String?
        var model: String?
        var createdAt: Date
        var stats: GenerationStats?
        var attachments: [String]?
    }

    struct ExportedConversation: Codable {
        var title: String
        var createdAt: Date
        var updatedAt: Date
        var model: String?
        var systemPrompt: String?
        var messages: [ExportedMessage]
        var exportedBy = "OMNIA"
    }

    @MainActor
    static func markdown(_ conversation: Conversation) -> String {
        var lines = ["# \(conversation.title)", ""]
        let date = conversation.createdAt.formatted(date: .long, time: .shortened)
        lines.append("_\(date)\(conversation.modelName.map { " · \($0)" } ?? "")_")
        if let system = conversation.systemPrompt, !system.trimmed.isEmpty {
            lines += ["", "> **System:** \(system.replacingOccurrences(of: "\n", with: "\n> "))"]
        }
        for message in conversation.orderedMessages where !message.content.isEmpty {
            lines.append("")
            switch message.role {
            case .user:
                lines.append("## You")
                for attachment in message.attachments { lines.append("_Attached: \(attachment.name)_") }
            case .assistant:
                lines.append("## \(message.modelName ?? "Assistant")")
            case .system:
                lines.append("## System")
            }
            lines.append("")
            lines.append(message.content)
            if let stats = message.stats {
                lines.append("")
                lines.append("<sub>\(stats.generatedTokens) tokens · \(ByteFormat.rate(stats.tokensPerSecond)) · first token \(ByteFormat.seconds(stats.timeToFirstToken))</sub>")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func json(_ conversations: [Conversation]) throws -> Data {
        let exported = conversations.map { conversation in
            ExportedConversation(
                title: conversation.title,
                createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt,
                model: conversation.modelName,
                systemPrompt: conversation.systemPrompt,
                messages: conversation.orderedMessages.map { message in
                    ExportedMessage(role: message.roleRaw, content: message.content, reasoning: message.reasoning,
                                    model: message.modelName, createdAt: message.createdAt, stats: message.stats,
                                    attachments: message.attachments.isEmpty ? nil : message.attachments.map(\.name))
                }
            )
        }
        return try JSONEncoder.omnia.encode(exported)
    }

    /// Writes an export to a temporary file suitable for the share sheet.
    @MainActor
    static func file(for conversations: [Conversation], format: Format) throws -> URL {
        let name: String
        if conversations.count == 1, let first = conversations.first {
            name = sanitize(first.title)
        } else {
            name = "OMNIA Conversations \(Date().formatted(.iso8601.year().month().day()))"
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "\(name).\(format.fileExtension)")
        switch format {
        case .markdown:
            let text = conversations.map { markdown($0) }.joined(separator: "\n\n---\n\n")
            try text.write(to: url, atomically: true, encoding: .utf8)
        case .json:
            try json(conversations).write(to: url, options: .atomic)
        }
        return url
    }

    private static func sanitize(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\?%*|\"<>:")).joined(separator: " ").trimmed
        return cleaned.isEmpty ? "Conversation" : String(cleaned.prefix(80))
    }
}
