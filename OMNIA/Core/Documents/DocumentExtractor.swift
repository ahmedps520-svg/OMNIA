import Foundation
import UIKit
import PDFKit
import UniformTypeIdentifiers

enum DocumentKind: String, Codable, Sendable {
    /// `image` is a photo or screenshot attached to a message (see `ImageInput`); it has no text.
    case text, markdown, code, pdf, richText, data, image

    var symbol: String {
        switch self {
        case .text: "doc.text"
        case .markdown: "doc.richtext"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .pdf: "doc.viewfinder"
        case .richText: "doc.richtext"
        case .data: "tablecells"
        case .image: "photo"
        }
    }
}

/// Extracts plain text from files the user attaches or adds to the knowledge library.
///
/// Images reach models through `ImageInput` instead; audio and video are rejected with a clear
/// message rather than silently ignored or pretended to be understood.
enum DocumentExtractor {
    enum ExtractionError: LocalizedError {
        case unsupported(String)
        case empty
        case tooLarge(Int)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let type):
                "\(type) files aren't supported. OMNIA's models read text, so attach text, Markdown, code, CSV/JSON or PDF documents."
            case .empty:
                "No readable text was found in this file (scanned PDFs need OCR first)."
            case .tooLarge(let bytes):
                "This file is too large to attach (\(ByteFormat.file(Int64(bytes)))). Add it to the Library instead, where OMNIA retrieves only the relevant passages."
            case .unreadable(let reason):
                "The file couldn't be read: \(reason)"
            }
        }
    }

    static let maxFileBytes = 64 * 1024 * 1024

    static let codeExtensions: Set<String> = [
        "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "c", "h", "cpp", "hpp", "cc", "m", "mm", "cs",
        "go", "rs", "rb", "php", "sh", "zsh", "bash", "sql", "html", "css", "scss", "xml", "yaml", "yml",
        "toml", "ini", "lua", "r", "dart", "scala", "pl", "ex", "exs", "hs", "zig", "gradle", "cmake", "make"
    ]

    /// Content types offered in file pickers.
    static let supportedTypes: [UTType] = {
        var types: [UTType] = [.plainText, .utf8PlainText, .text, .pdf, .rtf, .json, .commaSeparatedText,
                               .tabSeparatedText, .xml, .html, .sourceCode, .swiftSource, .pythonScript, .shellScript]
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        if let yaml = UTType(filenameExtension: "yaml") { types.append(yaml) }
        return types
    }()

    static func kind(for url: URL) -> DocumentKind {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if ["md", "markdown", "mdx"].contains(ext) { return .markdown }
        if ["rtf", "rtfd"].contains(ext) { return .richText }
        if ["csv", "tsv", "json", "jsonl"].contains(ext) { return .data }
        if codeExtensions.contains(ext) { return .code }
        return .text
    }

    /// Reads a (security-scoped) file URL and returns its text.
    static func extract(from url: URL) throws -> (text: String, kind: DocumentKind, byteSize: Int) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let size = values?.fileSize ?? 0
        if size > maxFileBytes { throw ExtractionError.tooLarge(size) }
        if let type = values?.contentType,
           type.conforms(to: .image) || type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) {
            throw ExtractionError.unsupported(type.localizedDescription ?? "Media")
        }

        let kind = kind(for: url)
        let text: String
        switch kind {
        case .pdf:
            guard let document = PDFDocument(url: url) else { throw ExtractionError.unreadable("the PDF is damaged or encrypted.") }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.string?.trimmed, !page.isEmpty {
                    pages.append(page)
                }
            }
            text = pages.joined(separator: "\n\n")
        case .richText:
            let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            text = attributed.string
        default:
            let data = try Data(contentsOf: url)
            if let utf8 = String(data: data, encoding: .utf8) {
                text = utf8
            } else if let utf16 = String(data: data, encoding: .utf16) {
                text = utf16
            } else if let latin = String(data: data, encoding: .isoLatin1) {
                text = latin
            } else {
                throw ExtractionError.unreadable("unknown text encoding.")
            }
        }
        let cleaned = text.replacingOccurrences(of: "\r\n", with: "\n").trimmed
        guard !cleaned.isEmpty else { throw ExtractionError.empty }
        return (cleaned, kind, size)
    }

    /// Language hint for fenced code blocks of attached source files.
    static func fenceLanguage(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "py": return "python"
        case "js", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "rs": return "rust"
        case "rb": return "ruby"
        case "kt": return "kotlin"
        case "sh", "zsh", "bash": return "bash"
        case "md", "markdown": return "markdown"
        case "yml": return "yaml"
        case "h", "c": return "c"
        case "hpp", "cc", "cpp": return "cpp"
        case "m", "mm": return "objectivec"
        default: return ext
        }
    }
}
