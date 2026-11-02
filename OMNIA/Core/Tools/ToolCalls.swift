import Foundation
import OrderedCollections

/// A function the model may call, with a JSON Schema describing its arguments.
struct ToolDefinition: Hashable, Sendable {
    let name: String
    let description: String
    /// A JSON Schema object (`type`, `properties`, `required`).
    let parameters: JSONValue

    /// The OpenAI-style declaration chat templates read from `tools`.
    var declaration: JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(name),
                "description": .string(description),
                "parameters": parameters
            ])
        ])
    }

    /// The JSON Schema type of one argument (`string`, `integer`, `number`, `boolean`, …).
    func argumentType(_ argument: String) -> String? {
        parameters["properties"]?[argument]?["type"]?.stringValue
    }

    /// Builds a schema from simple, flat properties.
    static func schema(_ properties: [(name: String, type: String, description: String)],
                       required: [String]) -> JSONValue {
        var members = OrderedDictionary<String, JSONValue>()
        for property in properties {
            members[property.name] = .object(["type": .string(property.type),
                                              "description": .string(property.description)])
        }
        return .object([
            "type": .string("object"),
            "properties": .object(members),
            "required": .array(required.map(JSONValue.string))
        ])
    }
}

/// One function call the model made.
struct ToolCall: Hashable, Sendable {
    var id: String
    var name: String
    var arguments: OrderedDictionary<String, JSONValue>

    init(id: String = ToolCall.makeID(), name: String, arguments: OrderedDictionary<String, JSONValue>) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    var argumentsJSON: String { JSONValue.object(arguments).serialized }

    /// The entry chat templates expect in an assistant message's `tool_calls`.
    var templateValue: JSONValue {
        .object([
            "type": .string("function"),
            "id": .string(id),
            "function": .object(["name": .string(name), "arguments": .object(arguments)])
        ])
    }

    /// Nine alphanumeric characters: the strictest format any template requires (Mistral).
    static func makeID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<9).map { _ in alphabet.randomElement()! })
    }
}

/// Tool calls found in a model's reply.
struct ParsedToolCalls: Equatable, Sendable {
    var calls: [ToolCall]
    /// Text written before the first call, e.g. "Let me look that up."
    var preface: String
}

/// How a model writes tool calls. Detected from its chat template, so prompts and parsing match
/// what the model was trained on.
enum ToolCallFormat: String, Codable, Sendable, CaseIterable {
    /// Qwen 3.5 and later, Ornith, Granite 4.2, LFM3, MiMo:
    /// `<tool_call><function=name><parameter=key>value</parameter></function></tool_call>`
    case xmlFunction
    /// Hermes / Qwen 2.5: `<tool_call>{"name": …, "arguments": {…}}</tool_call>`. Also OMNIA's own
    /// protocol for models whose templates have no tool support.
    case hermesJSON
    /// Gemma 4, Nemotron 3.5 Bolt: `<|tool_call>call:name{key:<|"|>text<|"|>}<tool_call|>`
    case gemma
    /// gpt-oss (Harmony): `to=functions.name … <|message|>{…}<|call|>`
    case harmony
    /// Ministral 3: `[TOOL_CALLS]name[ARGS]{…}`
    case mistral
    /// LFM2.5: `<|tool_call_start|>[name(key='value')]<|tool_call_end|>`
    case pythonic
    /// Muse Glimmer: `<atem:function_calls><atem:invoke name="…"><atem:parameter name="…">…`
    case atem

    /// The format a chat template uses natively, or nil when it has no (recognized) tool support.
    static func detect(template: String?) -> ToolCallFormat? {
        guard let template, template.contains("tools") else { return nil }
        if template.contains("<|tool_call>") && template.contains("<tool_call|>") { return .gemma }
        if template.contains("<atem:function_calls>") { return .atem }
        if template.contains("<|tool_call_start|>") { return .pythonic }
        if template.contains("[TOOL_CALLS]") { return .mistral }
        if template.contains("<|call|>") && template.contains("<|channel|>") { return .harmony }
        if template.contains("<function=") && template.contains("<tool_call>") { return .xmlFunction }
        if template.contains("<tool_call>") { return .hermesJSON }
        return nil
    }

    /// Text the model should never write itself (it's the tool's reply), so generation stops there.
    var stopSequences: [String] {
        switch self {
        case .xmlFunction, .hermesJSON: ["<tool_response>"]
        case .gemma: ["<|tool_response>"]
        case .harmony: ["<|call|>"]
        case .mistral, .pythonic, .atem: []
        }
    }

    /// Markers that begin a tool call in any format. Everything from the first one on is hidden
    /// from the visible reply; the call is shown as a tool step instead.
    static let startMarkers = ["<tool_call>", "<function=", "<|tool_call>", "[TOOL_CALLS]",
                               "<|tool_call_start|>", "<atem:function_calls>"]
}

// MARK: - Parsing

enum ToolCallParser {
    /// Finds the tool calls in `text`, trying the model's own format first and then the others,
    /// because models occasionally drift into a neighbouring syntax.
    static func parse(_ text: String, format: ToolCallFormat?, tools: [ToolDefinition]) -> ParsedToolCalls? {
        let order = [format ?? .hermesJSON] + ToolCallFormat.allCases.filter { $0 != (format ?? .hermesJSON) }
        for candidate in order {
            if let calls = parse(text, as: candidate, tools: tools), !calls.isEmpty {
                return ParsedToolCalls(calls: calls, preface: preface(of: text))
            }
        }
        return nil
    }

    /// The reply text before any tool-call markup.
    static func preface(of text: String) -> String {
        var cut = text.endIndex
        for marker in ToolCallFormat.startMarkers {
            if let range = text.range(of: marker), range.lowerBound < cut { cut = range.lowerBound }
        }
        return String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ text: String, as format: ToolCallFormat, tools: [ToolDefinition]) -> [ToolCall]? {
        switch format {
        case .xmlFunction: parseXMLFunction(text, tools: tools)
        case .hermesJSON: parseHermes(text)
        case .gemma: parseGemma(text)
        case .harmony: parseHarmony(text)
        case .mistral: parseMistral(text)
        case .pythonic: parsePythonic(text)
        case .atem: parseAtem(text, tools: tools)
        }
    }

    // MARK: <function=name><parameter=key>value</parameter></function>

    static func parseXMLFunction(_ text: String, tools: [ToolDefinition]) -> [ToolCall]? {
        var calls: [ToolCall] = []
        var rest = Substring(text)
        while let open = rest.range(of: "<function=") {
            let afterOpen = rest[open.upperBound...]
            guard let nameEnd = afterOpen.firstIndex(of: ">") else { break }
            let name = afterOpen[..<nameEnd].trimmingCharacters(in: .whitespaces)
            var body = afterOpen[afterOpen.index(after: nameEnd)...]
            if let close = body.range(of: "</function>") {
                rest = body[close.upperBound...]
                body = body[..<close.lowerBound]
            } else {
                rest = ""
            }
            guard !name.isEmpty else { continue }
            let tool = tools.first { $0.name == name }
            var arguments = OrderedDictionary<String, JSONValue>()
            var parameters = body
            while let parameterOpen = parameters.range(of: "<parameter=") {
                let afterParameter = parameters[parameterOpen.upperBound...]
                guard let keyEnd = afterParameter.firstIndex(of: ">") else { break }
                let key = afterParameter[..<keyEnd].trimmingCharacters(in: .whitespaces)
                var value = afterParameter[afterParameter.index(after: keyEnd)...]
                if let parameterClose = value.range(of: "</parameter>") {
                    parameters = value[parameterClose.upperBound...]
                    value = value[..<parameterClose.lowerBound]
                } else if let next = value.range(of: "<parameter=") {
                    parameters = value[next.lowerBound...]
                    value = value[..<next.lowerBound]
                } else {
                    parameters = ""
                }
                arguments[key] = typedValue(trimTemplateNewlines(value), type: tool?.argumentType(key))
            }
            calls.append(ToolCall(name: name, arguments: arguments))
        }
        return calls.isEmpty ? nil : calls
    }

    // MARK: <tool_call>{"name": …, "arguments": …}</tool_call>

    static func parseHermes(_ text: String) -> [ToolCall]? {
        var calls: [ToolCall] = []
        var rest = Substring(text)
        while let open = rest.range(of: "<tool_call>") {
            var body = rest[open.upperBound...]
            if let close = body.range(of: "</tool_call>") {
                rest = body[close.upperBound...]
                body = body[..<close.lowerBound]
            } else {
                rest = ""
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"),
                  let object = (try? JSONValue.parse(trimmed, lenient: true))?.objectValue,
                  let call = callFromJSONObject(object) else { continue }
            calls.append(call)
        }
        return calls.isEmpty ? nil : calls
    }

    /// `{"name": …, "arguments": {…} | "{…}"}`; some models say `parameters` instead.
    static func callFromJSONObject(_ object: OrderedDictionary<String, JSONValue>) -> ToolCall? {
        guard let name = object["name"]?.stringValue, !name.isEmpty else { return nil }
        let raw = object["arguments"] ?? object["parameters"] ?? .object([:])
        switch raw {
        case .object(let arguments):
            return ToolCall(name: name, arguments: arguments)
        case .string(let encoded):
            let arguments = (try? JSONValue.parse(encoded, lenient: true))?.objectValue ?? [:]
            return ToolCall(name: name, arguments: arguments)
        default:
            return ToolCall(name: name, arguments: [:])
        }
    }

    // MARK: <|tool_call>call:name{key:value}<tool_call|>

    static let gemmaQuote = "<|\"|>"

    static func parseGemma(_ text: String) -> [ToolCall]? {
        var calls: [ToolCall] = []
        var rest = Substring(text)
        while let open = rest.range(of: "<|tool_call>") {
            var body = rest[open.upperBound...]
            if let close = body.range(of: "<tool_call|>") {
                rest = body[close.upperBound...]
                body = body[..<close.lowerBound]
            } else {
                rest = ""
            }
            body = body.drop(while: \.isWhitespace)
            if body.hasPrefix("call:") { body = body.dropFirst("call:".count) }
            guard let brace = body.firstIndex(of: "{") else { continue }
            let name = body[..<brace].trimmingCharacters(in: .whitespaces)
            var reader = GemmaArgumentReader(body[brace...])
            guard !name.isEmpty, case .object(let arguments)? = reader.readValue() else { continue }
            calls.append(ToolCall(name: name, arguments: arguments))
        }
        return calls.isEmpty ? nil : calls
    }

    /// Reads Gemma's argument notation: bare keys, `<|"|>`-quoted strings, JSON-like numbers,
    /// booleans, null, `{…}` and `[…]`.
    struct GemmaArgumentReader {
        private var text: Substring
        init(_ text: Substring) { self.text = text }

        mutating func readValue() -> JSONValue? {
            text = text.drop(while: \.isWhitespace)
            if text.hasPrefix(ToolCallParser.gemmaQuote) {
                text = text.dropFirst(ToolCallParser.gemmaQuote.count)
                guard let end = text.range(of: ToolCallParser.gemmaQuote) else {
                    defer { text = "" }
                    return .string(String(text))
                }
                defer { text = text[end.upperBound...] }
                return .string(String(text[..<end.lowerBound]))
            }
            if text.hasPrefix("{") {
                text = text.dropFirst()
                var members = OrderedDictionary<String, JSONValue>()
                while true {
                    text = text.drop(while: { $0.isWhitespace || $0 == "," })
                    if text.isEmpty { return .object(members) }
                    if text.hasPrefix("}") {
                        text = text.dropFirst()
                        return .object(members)
                    }
                    guard let colon = text.firstIndex(of: ":") else { return .object(members) }
                    var key = text[..<colon].trimmingCharacters(in: .whitespaces)
                    if key.hasPrefix(ToolCallParser.gemmaQuote), key.hasSuffix(ToolCallParser.gemmaQuote),
                       key.count >= 2 * ToolCallParser.gemmaQuote.count {
                        key = String(key.dropFirst(ToolCallParser.gemmaQuote.count).dropLast(ToolCallParser.gemmaQuote.count))
                    }
                    text = text[text.index(after: colon)...]
                    guard let value = readValue() else { return .object(members) }
                    members[key] = value
                }
            }
            if text.hasPrefix("[") {
                text = text.dropFirst()
                var items: [JSONValue] = []
                while true {
                    text = text.drop(while: { $0.isWhitespace || $0 == "," })
                    if text.isEmpty { return .array(items) }
                    if text.hasPrefix("]") {
                        text = text.dropFirst()
                        return .array(items)
                    }
                    guard let value = readValue() else { return .array(items) }
                    items.append(value)
                }
            }
            // A bare scalar: number, boolean or null, up to the next delimiter.
            let end = text.firstIndex(where: { $0 == "," || $0 == "}" || $0 == "]" }) ?? text.endIndex
            let token = text[..<end].trimmingCharacters(in: .whitespaces)
            text = text[end...]
            guard !token.isEmpty else { return nil }
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null", "None": return .null
            default:
                if let value = Int(token) { return .int(value) }
                if let value = Double(token) { return .double(value) }
                return .string(token)
            }
        }
    }

    // MARK: Harmony: to=functions.name … <|message|>{…}<|call|>

    static func parseHarmony(_ text: String) -> [ToolCall]? {
        var calls: [ToolCall] = []
        var rest = Substring(text)
        while let recipient = rest.range(of: "to=functions.") {
            let afterRecipient = rest[recipient.upperBound...]
            let nameEnd = afterRecipient.firstIndex(where: { $0.isWhitespace || $0 == "<" }) ?? afterRecipient.endIndex
            let name = String(afterRecipient[..<nameEnd])
            guard let message = afterRecipient.range(of: "<|message|>") else { break }
            var body = afterRecipient[message.upperBound...]
            if let end = body.range(of: "<|call|>") ?? body.range(of: "<|end|>") {
                rest = body[end.upperBound...]
                body = body[..<end.lowerBound]
            } else {
                rest = ""
            }
            guard !name.isEmpty else { continue }
            let arguments = (try? JSONValue.parse(body.trimmingCharacters(in: .whitespacesAndNewlines), lenient: true))?.objectValue ?? [:]
            calls.append(ToolCall(name: name, arguments: arguments))
        }
        return calls.isEmpty ? nil : calls
    }

    // MARK: Mistral: [TOOL_CALLS]name[ARGS]{…}  or  [TOOL_CALLS][{"name": …, "arguments": …}]

    static func parseMistral(_ text: String) -> [ToolCall]? {
        guard text.contains("[TOOL_CALLS]") else { return nil }
        var calls: [ToolCall] = []
        let segments = text.components(separatedBy: "[TOOL_CALLS]").dropFirst()
        for segment in segments {
            let trimmed = Substring(segment).drop(while: \.isWhitespace)
            if trimmed.hasPrefix("[") {
                if let parsed = try? JSONValue.parsePrefix(trimmed, lenient: true), let items = parsed.value.arrayValue {
                    calls += items.compactMap { $0.objectValue.flatMap(callFromJSONObject) }
                }
                continue
            }
            guard let args = trimmed.range(of: "[ARGS]") else { continue }
            let name = trimmed[..<args.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let afterArgs = trimmed[args.upperBound...]
            let arguments = (try? JSONValue.parsePrefix(afterArgs, lenient: true))?.value.objectValue ?? [:]
            guard !name.isEmpty else { continue }
            calls.append(ToolCall(name: name, arguments: arguments))
        }
        return calls.isEmpty ? nil : calls
    }

    // MARK: Pythonic: <|tool_call_start|>[name(key='value', n=3)]<|tool_call_end|>

    static func parsePythonic(_ text: String) -> [ToolCall]? {
        guard let start = text.range(of: "<|tool_call_start|>") else { return nil }
        var body = text[start.upperBound...]
        if let end = body.range(of: "<|tool_call_end|>") { body = body[..<end.lowerBound] }
        var reader = PythonCallReader(Array(body.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars))
        let calls = reader.readCalls()
        return calls.isEmpty ? nil : calls
    }

    /// Reads `[f(a=1, b='x'), g()]` with Python literal arguments.
    struct PythonCallReader {
        private let scalars: [Unicode.Scalar]
        private var offset = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        private var current: Unicode.Scalar? { offset < scalars.count ? scalars[offset] : nil }

        private mutating func skip(_ characters: Set<Unicode.Scalar> = [" ", "\n", "\r", "\t"]) {
            while let scalar = current, characters.contains(scalar) { offset += 1 }
        }

        private mutating func identifier() -> String {
            var name = ""
            while let scalar = current, scalar == "_" || scalar == "." || scalar == "-"
                    || CharacterSet.alphanumerics.contains(scalar) {
                name.unicodeScalars.append(scalar)
                offset += 1
            }
            return name
        }

        mutating func readCalls() -> [ToolCall] {
            var calls: [ToolCall] = []
            skip()
            let bracketed = current == "["
            if bracketed { offset += 1 }
            while true {
                skip([" ", "\n", "\r", "\t", ","])
                guard let scalar = current, scalar != "]" else { break }
                let name = identifier()
                skip()
                guard !name.isEmpty, current == "(" else { break }
                offset += 1
                var arguments = OrderedDictionary<String, JSONValue>()
                while true {
                    skip([" ", "\n", "\r", "\t", ","])
                    guard let next = current else { break }
                    if next == ")" {
                        offset += 1
                        break
                    }
                    let key = identifier()
                    skip()
                    guard !key.isEmpty, current == "=" else { return calls + [ToolCall(name: name, arguments: arguments)] }
                    offset += 1
                    skip()
                    let remaining = String(String.UnicodeScalarView(scalars[offset...]))
                    guard let parsed = try? JSONValue.parsePrefix(Substring(remaining), lenient: true) else {
                        return calls + [ToolCall(name: name, arguments: arguments)]
                    }
                    arguments[key] = parsed.value
                    offset += parsed.scalarCount
                }
                calls.append(ToolCall(name: name, arguments: arguments))
                if !bracketed { break }
            }
            return calls
        }
    }

    // MARK: Muse Glimmer: <atem:invoke name="…"><atem:parameter name="…">…</atem:parameter></atem:invoke>

    static func parseAtem(_ text: String, tools: [ToolDefinition]) -> [ToolCall]? {
        var calls: [ToolCall] = []
        var rest = Substring(text)
        while let invoke = rest.range(of: "<atem:invoke name=\"") {
            let afterInvoke = rest[invoke.upperBound...]
            guard let nameEnd = afterInvoke.firstIndex(of: "\"") else { break }
            let name = String(afterInvoke[..<nameEnd])
            var body = afterInvoke[afterInvoke.index(after: nameEnd)...]
            if let close = body.range(of: "</atem:invoke>") {
                rest = body[close.upperBound...]
                body = body[..<close.lowerBound]
            } else {
                rest = ""
            }
            let tool = tools.first { $0.name == name }
            var arguments = OrderedDictionary<String, JSONValue>()
            while let parameter = body.range(of: "<atem:parameter name=\"") {
                let afterParameter = body[parameter.upperBound...]
                guard let keyEnd = afterParameter.firstIndex(of: "\""),
                      let valueStart = afterParameter[keyEnd...].firstIndex(of: ">") else { break }
                let key = String(afterParameter[..<keyEnd])
                var value = afterParameter[afterParameter.index(after: valueStart)...]
                if let close = value.range(of: "</atem:parameter>") {
                    body = value[close.upperBound...]
                    value = value[..<close.lowerBound]
                } else {
                    body = ""
                }
                arguments[key] = typedValue(value, type: tool?.argumentType(key))
            }
            guard !name.isEmpty else { continue }
            calls.append(ToolCall(name: name, arguments: arguments))
        }
        return calls.isEmpty ? nil : calls
    }

    // MARK: Helpers

    /// Templates put each parameter value on its own line; drop exactly that framing.
    static func trimTemplateNewlines(_ value: Substring) -> Substring {
        var value = value
        if value.hasPrefix("\r\n") { value = value.dropFirst(2) } else if value.hasPrefix("\n") { value = value.dropFirst() }
        if value.hasSuffix("\r\n") { value = value.dropLast(2) } else if value.hasSuffix("\n") { value = value.dropLast() }
        return value
    }

    /// Converts a textual parameter to the JSON type its schema declares.
    static func typedValue(_ raw: Substring, type: String?) -> JSONValue {
        let text = String(raw)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type ?? "" {
        case "integer":
            if let value = Int(trimmed) { return .int(value) }
            if let value = Double(trimmed) { return .double(value) }
        case "number":
            if let value = Int(trimmed) { return .int(value) }
            if let value = Double(trimmed) { return .double(value) }
        case "boolean":
            switch trimmed.lowercased() {
            case "true", "yes", "1": return .bool(true)
            case "false", "no", "0": return .bool(false)
            default: break
            }
        case "object", "array":
            if let value = try? JSONValue.parse(trimmed, lenient: true) { return value }
        case "null":
            return .null
        default:
            break
        }
        return .string(text)
    }
}
