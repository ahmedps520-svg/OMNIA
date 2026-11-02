import Foundation
import Jinja
import OrderedCollections

/// A JSON value that keeps object keys in their original order, as Python's `json` module does.
///
/// Tool schemas and tool-call arguments are rendered into chat templates the way the models saw
/// them in training, so key order and number formatting have to survive a round trip.
enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(OrderedDictionary<String, JSONValue>)

    subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        case .string(let text): Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value): value.rounded() == value && abs(value) < 9e15 ? Int(value) : nil
        case .string(let text): Int(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    var objectValue: OrderedDictionary<String, JSONValue>? {
        if case .object(let members) = self { return members }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// The value rendered as a chat-template variable, with object keys kept in order.
    var jinjaValue: Value {
        switch self {
        case .null: .null
        case .bool(let flag): .boolean(flag)
        case .int(let value): .int(value)
        case .double(let value): .double(value)
        case .string(let text): .string(text)
        case .array(let items): .array(items.map(\.jinjaValue))
        case .object(let members):
            var storage = OrderedDictionary<ObjectKey, Value>(minimumCapacity: members.count)
            for (key, value) in members { storage[.string(key)] = value.jinjaValue }
            return .object(storage)
        }
    }
}

// MARK: - Serialization

extension JSONValue {
    /// Serializes like Python's `json.dumps(value, ensure_ascii=False)`: `", "` and `": "`
    /// separators, keys in order, non-ASCII text left as is.
    var serialized: String {
        var output = ""
        write(to: &output)
        return output
    }

    private func write(to output: inout String) {
        switch self {
        case .null: output += "null"
        case .bool(let flag): output += flag ? "true" : "false"
        case .int(let value): output += String(value)
        case .double(let value): output += JSONValue.pythonRepr(value)
        case .string(let text): JSONValue.writeString(text, to: &output)
        case .array(let items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += ", " }
                item.write(to: &output)
            }
            output += "]"
        case .object(let members):
            output += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { output += ", " }
                JSONValue.writeString(member.key, to: &output)
                output += ": "
                member.value.write(to: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ text: String, to output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }

    /// Python's `repr(float)`: shortest round-trip digits, always with a fraction or exponent.
    private static func pythonRepr(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let text = "\(value)"
        return text.contains(".") || text.contains("e") ? text : text + ".0"
    }
}

// MARK: - Parsing

enum JSONParseError: Error, Equatable {
    case unexpectedEnd
    case unexpectedCharacter(Character, offset: Int)
    case invalidNumber(offset: Int)
    case invalidEscape(offset: Int)
    case tooDeep
    case trailingContent(offset: Int)
}

extension JSONValue {
    /// Parses a complete JSON document.
    ///
    /// `lenient` also accepts what language models commonly write instead of strict JSON:
    /// trailing commas, single-quoted strings, unquoted keys and Python's True / False / None.
    static func parse(_ text: String, lenient: Bool = false) throws -> JSONValue {
        var parser = JSONParser(Array(text.unicodeScalars), lenient: lenient)
        let value = try parser.parseDocument()
        return value
    }

    /// Parses one JSON value at the start of `text` and returns how many Unicode scalars it used.
    /// Used where a value is followed by more model output (e.g. `[ARGS]{…}[TOOL_CALLS]…`).
    static func parsePrefix(_ text: Substring, lenient: Bool = false) throws -> (value: JSONValue, scalarCount: Int) {
        var parser = JSONParser(Array(text.unicodeScalars), lenient: lenient)
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        return (value, parser.offset)
    }
}

/// A recursive-descent JSON parser over Unicode scalars.
struct JSONParser {
    private let scalars: [Unicode.Scalar]
    private let lenient: Bool
    private(set) var offset = 0
    private static let maximumDepth = 64

    init(_ scalars: [Unicode.Scalar], lenient: Bool) {
        self.scalars = scalars
        self.lenient = lenient
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard offset == scalars.count else { throw JSONParseError.trailingContent(offset: offset) }
        return value
    }

    private var current: Unicode.Scalar? { offset < scalars.count ? scalars[offset] : nil }

    mutating func skipWhitespace() {
        while let scalar = current, scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t" {
            offset += 1
        }
    }

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth < Self.maximumDepth else { throw JSONParseError.tooDeep }
        guard let scalar = current else { throw JSONParseError.unexpectedEnd }
        switch scalar {
        case "{": return try parseObject(depth: depth)
        case "[": return try parseArray(depth: depth)
        case "\"": return .string(try parseString(quote: "\""))
        case "'" where lenient: return .string(try parseString(quote: "'"))
        case "-", "0"..."9": return try parseNumber()
        default:
            if let literal = parseLiteral() { return literal }
            throw JSONParseError.unexpectedCharacter(Character(scalar), offset: offset)
        }
    }

    private mutating func parseLiteral() -> JSONValue? {
        let literals: [(String, JSONValue)] = lenient
            ? [("true", .bool(true)), ("false", .bool(false)), ("null", .null),
               ("True", .bool(true)), ("False", .bool(false)), ("None", .null)]
            : [("true", .bool(true)), ("false", .bool(false)), ("null", .null)]
        for (word, value) in literals where matches(word) {
            offset += word.unicodeScalars.count
            return value
        }
        return nil
    }

    private func matches(_ word: String) -> Bool {
        var index = offset
        for scalar in word.unicodeScalars {
            guard index < scalars.count, scalars[index] == scalar else { return false }
            index += 1
        }
        // The literal must not run into an identifier ("nullable").
        if index < scalars.count, Self.isIdentifierScalar(scalars[index]) { return false }
        return true
    }

    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        offset += 1 // {
        var members = OrderedDictionary<String, JSONValue>()
        skipWhitespace()
        if current == "}" {
            offset += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            if lenient, current == "}" { // trailing comma
                offset += 1
                return .object(members)
            }
            let key = try parseKey()
            skipWhitespace()
            guard current == ":" else { throw unexpected() }
            offset += 1
            skipWhitespace()
            members[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard let scalar = current else { throw JSONParseError.unexpectedEnd }
            offset += 1
            if scalar == "}" { return .object(members) }
            guard scalar == "," else {
                offset -= 1
                throw unexpected()
            }
        }
    }

    private mutating func parseKey() throws -> String {
        guard let scalar = current else { throw JSONParseError.unexpectedEnd }
        if scalar == "\"" { return try parseString(quote: "\"") }
        if lenient, scalar == "'" { return try parseString(quote: "'") }
        if lenient, Self.isIdentifierScalar(scalar) {
            var key = ""
            while let next = current, Self.isIdentifierScalar(next) {
                key.unicodeScalars.append(next)
                offset += 1
            }
            return key
        }
        throw unexpected()
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        offset += 1 // [
        var items: [JSONValue] = []
        skipWhitespace()
        if current == "]" {
            offset += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            if lenient, current == "]" { // trailing comma
                offset += 1
                return .array(items)
            }
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard let scalar = current else { throw JSONParseError.unexpectedEnd }
            offset += 1
            if scalar == "]" { return .array(items) }
            guard scalar == "," else {
                offset -= 1
                throw unexpected()
            }
        }
    }

    private mutating func parseString(quote: Unicode.Scalar) throws -> String {
        offset += 1 // opening quote
        var result = String.UnicodeScalarView()
        while true {
            guard let scalar = current else { throw JSONParseError.unexpectedEnd }
            offset += 1
            if scalar == quote { return String(result) }
            guard scalar == "\\" else {
                result.append(scalar)
                continue
            }
            guard let escaped = current else { throw JSONParseError.unexpectedEnd }
            let escapeOffset = offset
            offset += 1
            switch escaped {
            case "\"": result.append("\"")
            case "'": result.append("'")
            case "\\": result.append("\\")
            case "/": result.append("/")
            case "b": result.append("\u{08}")
            case "f": result.append("\u{0C}")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "u":
                var code = try parseHex4()
                // Surrogate pair: 😀
                if (0xD800...0xDBFF).contains(code), current == "\\",
                   offset + 1 < scalars.count, scalars[offset + 1] == "u" {
                    offset += 2
                    let low = try parseHex4()
                    guard (0xDC00...0xDFFF).contains(low) else { throw JSONParseError.invalidEscape(offset: escapeOffset) }
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                }
                guard let decoded = Unicode.Scalar(code) else { throw JSONParseError.invalidEscape(offset: escapeOffset) }
                result.append(decoded)
            default:
                throw JSONParseError.invalidEscape(offset: escapeOffset)
            }
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard offset + 4 <= scalars.count else { throw JSONParseError.unexpectedEnd }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let digit = UInt32(String(scalars[offset]), radix: 16) else {
                throw JSONParseError.invalidEscape(offset: offset)
            }
            value = value * 16 + digit
            offset += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = offset
        if current == "-" { offset += 1 }
        guard let first = current, ("0"..."9").contains(first) else { throw JSONParseError.invalidNumber(offset: start) }
        while let scalar = current, ("0"..."9").contains(scalar) { offset += 1 }
        var isInteger = true
        if current == ".", offset + 1 < scalars.count, ("0"..."9").contains(scalars[offset + 1]) {
            isInteger = false
            offset += 1
            while let scalar = current, ("0"..."9").contains(scalar) { offset += 1 }
        }
        if current == "e" || current == "E" {
            isInteger = false
            offset += 1
            if current == "+" || current == "-" { offset += 1 }
            guard let digit = current, ("0"..."9").contains(digit) else { throw JSONParseError.invalidNumber(offset: start) }
            while let scalar = current, ("0"..."9").contains(scalar) { offset += 1 }
        }
        let text = String(String.UnicodeScalarView(scalars[start..<offset]))
        if isInteger, let value = Int(text) { return .int(value) }
        guard let value = Double(text) else { throw JSONParseError.invalidNumber(offset: start) }
        return .double(value)
    }

    private func unexpected() -> JSONParseError {
        guard let scalar = current else { return .unexpectedEnd }
        return .unexpectedCharacter(Character(scalar), offset: offset)
    }
}
