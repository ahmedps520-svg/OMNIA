import Foundation

/// Block-level Markdown, as models write it. Inline formatting (bold, italics, code, links)
/// is rendered by `AttributedString`'s Markdown support inside each block.
enum MarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String, code: String, isClosed: Bool)
    case list(items: [MarkdownListItem])
    case quote([MarkdownBlock])
    case table(header: [String], alignments: [MarkdownTableAlignment], rows: [[String]])
    case rule
}

struct MarkdownListItem: Hashable {
    var marker: String       // "•", "1.", "☐", "☑"
    var indent: Int
    var text: String
}

enum MarkdownTableAlignment: Hashable {
    case leading, center, trailing
}

enum MarkdownParser {
    private static let cache = NSCache<NSString, BlocksBox>()

    private final class BlocksBox {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    /// Parses with a cache for finished text (streaming text changes on every update).
    static func parseCached(_ text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = parse(text)
        cache.setObject(BlocksBox(blocks), forKey: key, cost: text.utf8.count)
        return blocks
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            // Fenced code block (``` or ~~~), possibly still open while streaming.
            if let fence = fenceMarker(trimmed) {
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                var closed = false
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) && candidate.trimmingCharacters(in: CharacterSet(charactersIn: String(fence.first!))).isEmpty {
                        closed = true
                        index += 1
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language, code: body.joined(separator: "\n"), isClosed: closed))
                continue
            }

            if let heading = heading(trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var content = Substring(candidate.dropFirst())
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                    quoted.append(String(content))
                    index += 1
                }
                blocks.append(.quote(parse(quoted.joined(separator: "\n"))))
                continue
            }

            if index + 1 < lines.count, trimmed.contains("|"), let alignments = tableSeparator(lines[index + 1]) {
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty, candidate.contains("|") else { break }
                    var cells = tableCells(candidate)
                    if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                    rows.append(Array(cells.prefix(header.count)))
                    index += 1
                }
                let normalized = alignments.count >= header.count
                    ? Array(alignments.prefix(header.count))
                    : alignments + Array(repeating: .leading, count: header.count - alignments.count)
                blocks.append(.table(header: header, alignments: normalized, rows: rows))
                continue
            }

            if listItem(line) != nil {
                var items: [MarkdownListItem] = []
                while index < lines.count {
                    let candidate = lines[index]
                    if let item = listItem(candidate) {
                        items.append(item)
                        index += 1
                    } else if !candidate.trimmingCharacters(in: .whitespaces).isEmpty,
                              candidate.hasPrefix("  ") || candidate.hasPrefix("\t"), !items.isEmpty,
                              fenceMarker(candidate.trimmingCharacters(in: .whitespaces)) == nil {
                        // Continuation line of the previous item.
                        items[items.count - 1].text += " " + candidate.trimmingCharacters(in: .whitespaces)
                        index += 1
                    } else if candidate.trimmingCharacters(in: .whitespaces).isEmpty,
                              index + 1 < lines.count, listItem(lines[index + 1]) != nil {
                        index += 1 // loose list: blank line between items
                    } else {
                        break
                    }
                }
                blocks.append(.list(items: items))
                continue
            }

            // Paragraph: consecutive lines until a blank line or another block starts.
            var paragraph: [String] = [trimmed]
            index += 1
            while index < lines.count {
                let candidate = lines[index]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if candidateTrimmed.isEmpty || fenceMarker(candidateTrimmed) != nil || heading(candidateTrimmed) != nil
                    || candidateTrimmed.hasPrefix(">") || listItem(candidate) != nil || isRule(candidateTrimmed) {
                    break
                }
                if index + 1 < lines.count, candidateTrimmed.contains("|"), tableSeparator(lines[index + 1]) != nil { break }
                paragraph.append(candidateTrimmed)
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    // MARK: Line classifiers

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(_ trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> MarkdownListItem? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let body = line.dropFirst(leading.count)
        // Unordered: -, *, +
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            var text = String(body.dropFirst(2))
            var marker = "•"
            if text.hasPrefix("[ ] ") { marker = "☐"; text = String(text.dropFirst(4)) }
            else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text = String(text.dropFirst(4)) }
            return MarkdownListItem(marker: marker, indent: indent, text: text)
        }
        // Ordered: 1. or 1)
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let afterDigits = body.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")", afterDigits.dropFirst().first == " " else { return nil }
        return MarkdownListItem(marker: "\(digits).", indent: indent, text: String(afterDigits.dropFirst(2)))
    }

    private static func tableSeparator(_ line: String) -> [MarkdownTableAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") || trimmed.hasPrefix("-") else { return nil }
        let cells = tableCells(trimmed)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownTableAlignment] = []
        for cell in cells {
            let compact = cell.replacingOccurrences(of: " ", with: "")
            guard compact.count >= 2, compact.allSatisfy({ $0 == "-" || $0 == ":" }), compact.contains("-") else { return nil }
            switch (compact.hasPrefix(":"), compact.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func tableCells(_ line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        return content.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
