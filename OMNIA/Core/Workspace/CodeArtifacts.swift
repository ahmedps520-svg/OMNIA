import Foundation

/// A code block from a conversation, as the workspace shows it.
struct CodeArtifact: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case html, svg, markdown, json, javascript, python, css, other

        init(language: String, code: String) {
            let tag = language.lowercased().trimmingCharacters(in: .whitespaces)
            let start = code.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200).lowercased()
            switch tag {
            case "html", "htm", "xhtml": self = .html
            case "svg": self = .svg
            case "md", "markdown": self = .markdown
            case "json", "jsonc", "json5": self = .json
            case "js", "javascript", "mjs", "node": self = .javascript
            case "py", "python", "python3": self = .python
            case "css": self = .css
            case "xml" where start.hasPrefix("<svg"): self = .svg
            case "":
                if start.hasPrefix("<!doctype html") || start.hasPrefix("<html") { self = .html }
                else if start.hasPrefix("<svg") { self = .svg }
                else { self = .other }
            default: self = .other
            }
        }

        var title: String {
            switch self {
            case .html: "Web page"
            case .svg: "SVG image"
            case .markdown: "Markdown"
            case .json: "JSON"
            case .javascript: "JavaScript"
            case .python: "Python"
            case .css: "CSS"
            case .other: "Code"
            }
        }

        var symbol: String {
            switch self {
            case .html: "safari"
            case .svg: "photo"
            case .markdown: "doc.richtext"
            case .json: "curlybraces"
            case .javascript, .python: "play.rectangle"
            case .css: "paintbrush"
            case .other: "chevron.left.forwardslash.chevron.right"
            }
        }

        /// Shown rendered rather than as code.
        var isPreviewable: Bool { [.html, .svg, .markdown, .json].contains(self) }
        /// Can run in the sandbox.
        var isRunnable: Bool { self == .javascript || self == .python }
    }

    let id: String
    let messageID: UUID?
    let language: String
    let code: String
    let kind: Kind
    /// The other blocks of the same message: an HTML page's CSS and scripts.
    var companions: [CodeArtifact] = []

    var lineCount: Int { code.split(separator: "\n", omittingEmptySubsequences: false).count }

    /// A short description: the page title, the first comment or definition, or the first line.
    var summary: String {
        if kind == .html, let title = code.firstMatch(of: /<title>([^<]{1,80})<\/title>/)?.1 {
            return String(title)
        }
        let lines = code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let definition = lines.first(where: { $0.hasPrefix("def ") || $0.hasPrefix("class ") || $0.hasPrefix("function ") }) {
            return String(definition.prefix(70))
        }
        if let comment = lines.first(where: { $0.hasPrefix("#") || $0.hasPrefix("//") || $0.hasPrefix("<!--") }) {
            return String(comment.drop { "#/<!- ".contains($0) }.prefix(70))
        }
        return String((lines.first ?? "").prefix(70))
    }

    /// The code blocks of the given messages, newest first.
    static func extract(from messages: [Message]) -> [CodeArtifact] {
        var artifacts: [CodeArtifact] = []
        for message in messages.reversed() where message.role == .assistant {
            var blocks: [CodeArtifact] = []
            for block in MarkdownParser.parseCached(message.content) {
                guard case let .code(language, code, _) = block, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                blocks.append(CodeArtifact(id: "\(message.id.uuidString)-\(blocks.count)", messageID: message.id, language: language,
                                           code: code, kind: Kind(language: language, code: code)))
            }
            for index in blocks.indices {
                blocks[index].companions = blocks.enumerated().filter { $0.offset != index }.map(\.element)
            }
            artifacts += blocks
        }
        return artifacts
    }

    /// A block that isn't part of a known message (e.g. one opened from a reply as it streams).
    static func standalone(language: String, code: String) -> CodeArtifact {
        CodeArtifact(id: "code-\(code.hashValue)", messageID: nil, language: language, code: code,
                     kind: Kind(language: language, code: code))
    }

    // MARK: Previews

    /// The page a web preview shows: an HTML page with its message's CSS and scripts inlined
    /// when it refers to them or has none of its own, or an SVG image centered on a page.
    func previewDocument() -> String? {
        switch kind {
        case .svg:
            return """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>html,body{margin:0;height:100%}body{display:flex;align-items:center;justify-content:center;background:#fff}svg{max-width:100%;max-height:100vh}</style>
            </head><body>\(code)</body></html>
            """
        case .html:
            var page = code
            let styles = companions.filter { $0.kind == .css }.map(\.code)
            let scripts = companions.filter { $0.kind == .javascript }.map(\.code)
            if !styles.isEmpty {
                let style = "<style>\n" + styles.joined(separator: "\n") + "\n</style>"
                let linked = /<link[^>]*rel=["']?stylesheet["']?[^>]*href=["'](?!https?:)[^"']*\.css["'][^>]*>/
                if page.contains(linked) {
                    page.replace(linked, maxReplacements: 1) { _ in style }
                    page.replace(linked) { _ in "" }
                } else if !page.contains("<style") {
                    page = Self.insert(style, before: "</head>", in: page, fallbackAtStart: true)
                }
            }
            if !scripts.isEmpty {
                let script = "<script>\n" + scripts.joined(separator: "\n") + "\n</script>"
                let linked = /<script[^>]*src=["'](?!https?:)[^"']*\.js["'][^>]*>\s*<\/script>/
                if page.contains(linked) {
                    page.replace(linked, maxReplacements: 1) { _ in script }
                    page.replace(linked) { _ in "" }
                } else if !page.contains("<script") {
                    page = Self.insert(script, before: "</body>", in: page, fallbackAtStart: false)
                }
            }
            if !page.lowercased().contains("<meta name=\"viewport\"") {
                page = Self.insert(#"<meta name="viewport" content="width=device-width, initial-scale=1">"#,
                                   before: "</head>", in: page, fallbackAtStart: true)
            }
            return page
        default:
            return nil
        }
    }

    private static func insert(_ fragment: String, before marker: String, in page: String, fallbackAtStart: Bool) -> String {
        if let range = page.range(of: marker, options: .caseInsensitive) {
            return page.replacingCharacters(in: range, with: fragment + "\n" + marker)
        }
        return fallbackAtStart ? fragment + "\n" + page : page + "\n" + fragment
    }

    /// Pretty-printed JSON, or nil when the code isn't valid JSON.
    func formattedJSON() -> String? {
        guard let data = code.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }
}
