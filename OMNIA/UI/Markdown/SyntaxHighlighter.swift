import SwiftUI

/// A fast, dependency-free highlighter for the languages models write most often.
/// It scans once, recognizing comments, strings, numbers, keywords, types and calls.
enum SyntaxHighlighter {
    private struct LanguageSpec {
        var keywords: Set<String>
        var lineComments: [String]
        var blockComment: (open: String, close: String)?
        var capitalizedTypes = true
    }

    private static let cFamily: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto",
        "struct", "union", "enum", "typedef", "const", "static", "extern", "volatile", "sizeof", "void", "int",
        "char", "float", "double", "long", "short", "unsigned", "signed", "bool", "true", "false", "nullptr", "NULL",
        "class", "public", "private", "protected", "virtual", "override", "template", "typename", "namespace",
        "using", "new", "delete", "this", "throw", "try", "catch", "auto", "inline", "constexpr", "include", "define"
    ]

    private static let specs: [String: LanguageSpec] = [
        "swift": LanguageSpec(keywords: ["import", "let", "var", "func", "struct", "class", "enum", "protocol", "extension", "actor",
                                         "if", "else", "guard", "for", "in", "while", "repeat", "switch", "case", "default", "return",
                                         "break", "continue", "throw", "throws", "rethrows", "try", "catch", "do", "async", "await",
                                         "self", "Self", "super", "init", "deinit", "nil", "true", "false", "static", "private",
                                         "fileprivate", "internal", "public", "open", "final", "override", "mutating", "inout",
                                         "some", "any", "where", "typealias", "associatedtype", "weak", "unowned", "lazy", "defer",
                                         "is", "as", "get", "set", "willSet", "didSet", "@MainActor", "nonisolated", "consuming", "borrowing"],
                              lineComments: ["//"], blockComment: ("/*", "*/")),
        "python": LanguageSpec(keywords: ["def", "class", "import", "from", "as", "if", "elif", "else", "for", "while", "in", "not",
                                          "and", "or", "is", "return", "yield", "with", "try", "except", "finally", "raise", "pass",
                                          "break", "continue", "lambda", "global", "nonlocal", "async", "await", "None", "True",
                                          "False", "self", "assert", "del", "match", "case"],
                               lineComments: ["#"], blockComment: nil),
        "javascript": LanguageSpec(keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch",
                                              "case", "default", "break", "continue", "class", "extends", "new", "this", "super",
                                              "import", "export", "from", "as", "async", "await", "try", "catch", "finally", "throw",
                                              "typeof", "instanceof", "in", "of", "null", "undefined", "true", "false", "yield",
                                              "interface", "type", "enum", "implements", "readonly", "public", "private", "protected", "static"],
                                   lineComments: ["//"], blockComment: ("/*", "*/")),
        "c": LanguageSpec(keywords: cFamily, lineComments: ["//"], blockComment: ("/*", "*/")),
        "java": LanguageSpec(keywords: cFamily.union(["package", "import", "extends", "implements", "interface", "final", "abstract",
                                                      "synchronized", "instanceof", "null", "fun", "val", "var", "when", "object",
                                                      "companion", "data", "sealed", "suspend", "is", "in", "out"]),
                             lineComments: ["//"], blockComment: ("/*", "*/")),
        "go": LanguageSpec(keywords: ["package", "import", "func", "var", "const", "type", "struct", "interface", "map", "chan",
                                      "go", "defer", "select", "if", "else", "for", "range", "switch", "case", "default", "return",
                                      "break", "continue", "fallthrough", "nil", "true", "false", "make", "new", "len", "append"],
                           lineComments: ["//"], blockComment: ("/*", "*/")),
        "rust": LanguageSpec(keywords: ["fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "for", "in", "if",
                                        "else", "match", "loop", "while", "return", "break", "continue", "use", "mod", "pub", "crate",
                                        "self", "Self", "super", "where", "as", "ref", "move", "async", "await", "dyn", "unsafe",
                                        "true", "false", "Some", "None", "Ok", "Err"],
                             lineComments: ["//"], blockComment: ("/*", "*/")),
        "bash": LanguageSpec(keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
                                        "in", "function", "return", "export", "local", "readonly", "echo", "cd", "sudo", "set",
                                        "source", "exit", "true", "false"],
                             lineComments: ["#"], blockComment: nil, capitalizedTypes: false),
        "sql": LanguageSpec(keywords: ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create",
                                       "table", "index", "view", "drop", "alter", "add", "join", "left", "right", "inner", "outer",
                                       "on", "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "null",
                                       "is", "in", "like", "between", "distinct", "count", "sum", "avg", "min", "max", "primary",
                                       "key", "foreign", "references", "union", "all", "case", "when", "then", "else", "end"],
                            lineComments: ["--"], blockComment: ("/*", "*/"), capitalizedTypes: false),
        "ruby": LanguageSpec(keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for",
                                        "in", "do", "return", "yield", "begin", "rescue", "ensure", "raise", "nil", "true", "false",
                                        "self", "require", "attr_accessor", "private", "public", "then", "case", "when"],
                             lineComments: ["#"], blockComment: nil),
        "yaml": LanguageSpec(keywords: ["true", "false", "null", "yes", "no"], lineComments: ["#"], blockComment: nil, capitalizedTypes: false),
        "json": LanguageSpec(keywords: ["true", "false", "null"], lineComments: [], blockComment: nil, capitalizedTypes: false),
        "css": LanguageSpec(keywords: ["important", "media", "import", "from", "to"], lineComments: [], blockComment: ("/*", "*/"), capitalizedTypes: false),
        "html": LanguageSpec(keywords: [], lineComments: [], blockComment: ("<!--", "-->"), capitalizedTypes: false)
    ]

    private static func spec(for language: String) -> LanguageSpec? {
        switch language.lowercased() {
        case "swift": specs["swift"]
        case "python", "py": specs["python"]
        case "javascript", "js", "jsx", "typescript", "ts", "tsx": specs["javascript"]
        case "c", "cpp", "c++", "h", "hpp", "objc", "objectivec", "objective-c", "cs", "csharp", "c#", "metal", "cuda": specs["c"]
        case "java", "kotlin", "kt", "scala", "dart": specs["java"]
        case "go", "golang": specs["go"]
        case "rust", "rs": specs["rust"]
        case "bash", "sh", "shell", "zsh", "console": specs["bash"]
        case "sql", "postgres", "sqlite", "mysql": specs["sql"]
        case "ruby", "rb": specs["ruby"]
        case "yaml", "yml", "toml": specs["yaml"]
        case "json", "jsonc": specs["json"]
        case "css", "scss": specs["css"]
        case "html", "xml", "svg": specs["html"]
        default: nil
        }
    }

    static func highlight(_ code: String, language: String) -> AttributedString {
        guard let spec = spec(for: language), code.utf8.count < 60_000 else {
            return AttributedString(code)
        }
        let caseInsensitive = language.lowercased() == "sql"
        var output = AttributedString()
        var plain = ""
        let characters = Array(code)
        var index = 0

        func flushPlain() {
            if !plain.isEmpty {
                output.append(AttributedString(plain))
                plain = ""
            }
        }
        func emit(_ text: String, _ color: Color) {
            flushPlain()
            var piece = AttributedString(text)
            piece.foregroundColor = color
            output.append(piece)
        }
        func matches(_ token: String, at position: Int) -> Bool {
            let tokenChars = Array(token)
            guard position + tokenChars.count <= characters.count else { return false }
            for offset in 0..<tokenChars.count where characters[position + offset] != tokenChars[offset] { return false }
            return true
        }

        while index < characters.count {
            let character = characters[index]

            // Comments
            if spec.lineComments.contains(where: { matches($0, at: index) }) {
                var end = index
                while end < characters.count, characters[end] != "\n" { end += 1 }
                emit(String(characters[index..<end]), Theme.Syntax.comment)
                index = end
                continue
            }
            if let block = spec.blockComment, matches(block.open, at: index) {
                var end = index + block.open.count
                while end < characters.count, !matches(block.close, at: end) { end += 1 }
                end = min(characters.count, end + block.close.count)
                emit(String(characters[index..<end]), Theme.Syntax.comment)
                index = end
                continue
            }

            // Strings
            if character == "\"" || character == "'" || character == "`" {
                var end = index + 1
                while end < characters.count {
                    if characters[end] == "\\" { end += 2; continue }
                    if characters[end] == character { end += 1; break }
                    if characters[end] == "\n" && character != "`" { break }
                    end += 1
                }
                end = min(end, characters.count)
                emit(String(characters[index..<end]), Theme.Syntax.string)
                index = end
                continue
            }

            // Numbers (ASCII only: "²", "½" or "٣" aren't hex digits, so the scan would never advance)
            if character.isASCII, character.isNumber, index == 0 || !(characters[index - 1].isLetter || characters[index - 1] == "_") {
                var end = index
                while end < characters.count, characters[end].isHexDigit || characters[end] == "." || characters[end] == "_" || characters[end] == "x" {
                    end += 1
                }
                emit(String(characters[index..<end]), Theme.Syntax.number)
                index = end
                continue
            }

            // Identifiers, keywords, types and calls
            if character.isLetter || character == "_" || character == "@" {
                var end = index + 1
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" { end += 1 }
                let word = String(characters[index..<end])
                let lookup = caseInsensitive ? word.lowercased() : word
                if spec.keywords.contains(lookup) {
                    emit(word, Theme.Syntax.keyword)
                } else if end < characters.count, characters[end] == "(" {
                    emit(word, Theme.Syntax.function)
                } else if spec.capitalizedTypes, character.isUppercase {
                    emit(word, Theme.Syntax.type)
                } else {
                    plain += word
                }
                index = end
                continue
            }

            plain.append(character)
            index += 1
        }
        flushPlain()
        return output
    }
}
