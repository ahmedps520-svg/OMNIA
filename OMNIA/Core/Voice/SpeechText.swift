import Foundation

/// A Markdown reply as text to read aloud: formatting marks go, code blocks and equations are
/// skipped with a short note, links are read by their text and web addresses by their site.
enum SpeechText {
    static func from(markdown: String) -> String {
        var lines: [String] = []
        var fence: String?
        var inEquation = false
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let marker = fence {
                if line.hasPrefix(marker), line.allSatisfy({ $0 == marker.first }) { fence = nil }
                continue
            }
            if inEquation {
                if line.hasSuffix("$$") || line.hasSuffix("\\]") { inEquation = false }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = String(line.prefix { $0 == line.first })
                lines.append("Code omitted.")
            } else if line.hasPrefix("$$") || line.hasPrefix("\\[") {
                inEquation = !(line.count > 2 && (line.hasSuffix("$$") || line.hasSuffix("\\]")))
                lines.append("Equation omitted.")
            } else if let spoken = spoken(line) {
                lines.append(spoken)
            }
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A line as spoken: empty between paragraphs, nil for a line that isn't read at all.
    private static func spoken(_ line: String) -> String? {
        guard !line.isEmpty, firstMatch(thematicBreak, in: line) == nil else { return "" }
        let line = replace(blockquote, in: line, with: "")
        if line.hasPrefix("|") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if cells.allSatisfy({ firstMatch(tableRule, in: $0) != nil }) { return nil }
            return sentence(cells.map(inline).joined(separator: ", "))
        }
        if let match = firstMatch(heading, in: line) {
            return sentence(inline(capture(1, of: match, in: line)))
        }
        if let match = firstMatch(bullet, in: line) {
            return sentence(inline(capture(1, of: match, in: line)))
        }
        if let match = firstMatch(numbered, in: line) {
            return "\(capture(1, of: match, in: line)). " + sentence(inline(capture(2, of: match, in: line)))
        }
        return inline(line)
    }

    /// Formatting within a line. Code spans are read as they are, so they're set aside meanwhile.
    private static func inline(_ line: String) -> String {
        var spans: [String] = []
        var text = ""
        var cursor = line.startIndex
        for match in code.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let whole = Range(match.range, in: line), let content = Range(match.range(at: 2), in: line) else { continue }
            text += line[cursor..<whole.lowerBound]
            text += "\u{E000}\(spans.count)\u{E001}"
            spans.append(String(line[content]))
            cursor = whole.upperBound
        }
        text += line[cursor...]

        text = replace(image, in: text, with: "$1")
        text = replace(link, in: text, with: "$1")
        text = replace(referenceLink, in: text, with: "$1")
        text = replace(footnote, in: text, with: "")
        text = sites(in: text)
        text = replace(htmlTag, in: text, with: " ")
        text = replace(strongMarks, in: text, with: "")
        text = replace(starEmphasis, in: text, with: "$1")
        text = replace(underscoreEmphasis, in: text, with: "$1")
        text = replace(escape, in: text, with: "$1")
        for (index, span) in spans.enumerated() {
            text = text.replacingOccurrences(of: "\u{E000}\(index)\u{E001}", with: span)
        }
        return replace(spaces, in: text, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Ends a heading, list item or table row with a full stop, so the voice pauses after it.
    private static func sentence(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let core = text.trimmingCharacters(in: CharacterSet(charactersIn: ")\"'”’»"))
        if let last = core.last, ".!?:;,…".contains(last) { return text }
        return text + "."
    }

    /// Web addresses as their site: "apple.com" for https://www.apple.com/ipad/.
    private static func sites(in text: String) -> String {
        var result = text
        for match in url.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result), let address = Range(match.range(at: 1), in: result) else { continue }
            let host = URL(string: String(result[address]))?.host() ?? "a link"
            result.replaceSubrange(whole, with: host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        }
        return result
    }

    // MARK: Patterns

    private static let thematicBreak = pattern(#"^([-*_])( *\1){2,}$"#)
    private static let blockquote = pattern(#"^(> ?)+"#)
    private static let tableRule = pattern(#"^:?-+:?$"#)
    private static let heading = pattern(#"^#{1,6}\s+(.*?)(\s+#+)?$"#)
    private static let bullet = pattern(#"^[-*+]\s+(?:\[[ xX]\]\s+)?(.*)$"#)
    private static let numbered = pattern(#"^(\d+)[.)]\s+(.*)$"#)
    private static let code = pattern(#"(`+)(.+?)\1"#)
    private static let image = pattern(#"!\[([^\]]*)\]\([^)]*\)"#)
    private static let link = pattern(#"\[([^\]]+)\]\([^)]*\)"#)
    private static let referenceLink = pattern(#"\[([^\]]+)\]\[[^\]]*\]"#)
    private static let footnote = pattern(#"\[\^[^\]]+\]"#)
    private static let url = pattern(#"<?(https?://[^\s<>()\[\]]*[^\s<>()\[\].,;:!?'"])>?"#)
    private static let htmlTag = pattern(#"</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*)?/?>"#)
    private static let strongMarks = pattern(#"(?<!\\)(?:\*\*|__|~~)"#)
    private static let starEmphasis = pattern(#"(?<![\w*\\])\*(?=\S)(.+?)(?<=[^\s\\])\*(?![\w*])"#)
    private static let underscoreEmphasis = pattern(#"(?<![\w\\])_(?=\S)(.+?)(?<=[^\s\\])_(?!\w)"#)
    private static let escape = pattern(#"\\([\\`*_{}\[\]()#+\-.!|>~])"#)
    private static let spaces = pattern(#" {2,}"#)

    private static func pattern(_ source: String) -> NSRegularExpression {
        // The patterns are fixed, and the tests exercise every one.
        try! NSRegularExpression(pattern: source)
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func capture(_ group: Int, of match: NSTextCheckingResult, in text: String) -> String {
        Range(match.range(at: group), in: text).map { String(text[$0]) } ?? ""
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
