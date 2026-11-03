import Foundation
import Jinja
import OrderedCollections

/// Values passed to a model's chat template beyond the messages themselves.
enum TemplateValue: Hashable, Sendable {
    case bool(Bool)
    case string(String)
}

/// How much a reasoning model should think. Each template spells this differently.
enum ReasoningPreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic, off, on
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Model default"
        case .off: "Off"
        case .on: "On"
        }
    }

    /// Template variables understood by current model families:
    /// `enable_thinking` (Qwen3.5, Gemma 4, Granite 4.2, LFM), `reasoning_effort` (gpt-oss, Granite)
    /// and `reasoning_strength` (Muse Glimmer).
    var templateVariables: [String: TemplateValue] {
        switch self {
        case .automatic: [:]
        case .off: ["enable_thinking": .bool(false), "reasoning_effort": .string("low"), "reasoning_strength": .string("low")]
        case .on: ["enable_thinking": .bool(true), "reasoning_effort": .string("high"), "reasoning_strength": .string("high")]
        }
    }
}

/// Renders a model's own Jinja chat template (the `tokenizer.chat_template` stored in its GGUF),
/// the same way llama.cpp's server does with `--jinja`. This is what makes newer formats such as
/// Gemma 4's turn markers or reasoning switches work exactly as their authors intended.
///
/// Messages and tools are passed with the same structure and key order as Hugging Face
/// Transformers (`tool_calls` on assistant messages, `tool` messages with `tool_call_id`).
struct ChatTemplateRenderer: Sendable {
    private let template: Template
    private let bosToken: String
    private let eosToken: String

    init(source: String, bosToken: String, eosToken: String) throws {
        template = try Template(Self.jinja2Compatible(source), with: .init(lstripBlocks: true, trimBlocks: true))
        self.bosToken = bosToken
        self.eosToken = eosToken
    }

    /// swift-jinja keeps one space between a literal "{" and a following "{%-", "{{-" or "{#-"
    /// (so its preprocessor can't produce "{{%"), where Jinja2 removes all the whitespace. Writing
    /// such a brace as an expression renders identically in both. Gemma 4's tool declarations
    /// ("properties:{" followed by an indented "{%- if …") depend on it.
    static func jinja2Compatible(_ source: String) -> String {
        source.replacing(#/\{\s+\{([%{#])-/#) { match in "{{ '{' }}{\(match.1)-" }
    }

    /// - Parameter date: Fixes `strftime_now` (tests); templates otherwise see the current date.
    func render(_ turns: [ChatTurn], addGenerationPrompt: Bool, variables: [String: TemplateValue],
                tools: [ToolDefinition] = [], date: Date? = nil) throws -> String {
        // Transformers passes `tools` and `documents` as None when there are none; some templates
        // treat "undefined" differently from "none".
        var context: [String: Value] = [
            "messages": .array(turns.map(Self.message)),
            "tools": tools.isEmpty ? .null : .array(tools.map(\.declaration.jinjaValue)),
            "documents": .null,
            "add_generation_prompt": .boolean(addGenerationPrompt),
            "bos_token": .string(bosToken),
            "eos_token": .string(eosToken)
        ]
        for (key, value) in variables {
            switch value {
            case .bool(let flag): context[key] = .boolean(flag)
            case .string(let text): context[key] = .string(text)
            }
        }
        if let date {
            context["strftime_now"] = .function { arguments, _, _ in
                guard case .string(let format)? = arguments.first else { return .string("") }
                return .string(Self.strftime(format, date))
            }
        }
        return try template.render(context)
    }

    /// An HF-style message: `role` and `content`, plus `tool_calls`, or `tool_call_id` and `name`.
    static func message(_ turn: ChatTurn) -> Value {
        var members: OrderedDictionary<String, JSONValue> = [
            "role": .string(turn.role.rawValue),
            "content": .string(turn.content)
        ]
        if !turn.toolCalls.isEmpty {
            members["tool_calls"] = .array(turn.toolCalls.map(\.templateValue))
        }
        if turn.role == .tool {
            if let id = turn.toolCallID { members["tool_call_id"] = .string(id) }
            if let name = turn.toolName { members["name"] = .string(name) }
        }
        return JSONValue.object(members).jinjaValue
    }

    /// The subset of `strftime` that chat templates use for dates.
    static func strftime(_ format: String, _ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let symbols = DateFormatter()
        symbols.locale = Locale(identifier: "en_US_POSIX")
        var result = ""
        var characters = format.makeIterator()
        while let character = characters.next() {
            guard character == "%", let directive = characters.next() else {
                result.append(character)
                continue
            }
            switch directive {
            case "Y": result += String(format: "%04d", parts.year ?? 0)
            case "y": result += String(format: "%02d", (parts.year ?? 0) % 100)
            case "m": result += String(format: "%02d", parts.month ?? 0)
            case "d": result += String(format: "%02d", parts.day ?? 0)
            case "H": result += String(format: "%02d", parts.hour ?? 0)
            case "M": result += String(format: "%02d", parts.minute ?? 0)
            case "S": result += String(format: "%02d", parts.second ?? 0)
            case "B": result += symbols.monthSymbols[(parts.month ?? 1) - 1]
            case "b": result += symbols.shortMonthSymbols[(parts.month ?? 1) - 1]
            case "A": result += symbols.weekdaySymbols[(parts.weekday ?? 1) - 1]
            case "a": result += symbols.shortWeekdaySymbols[(parts.weekday ?? 1) - 1]
            case "%": result += "%"
            default: result += "%\(directive)"
            }
        }
        return result
    }
}

/// OMNIA's own tool protocol for models whose chat templates don't support tools: the tools are
/// described in the system prompt, calls use `<tool_call>{"name": …, "arguments": …}</tool_call>`,
/// and results come back as a user message.
enum ToolPrompt {
    static func instructions(for tools: [ToolDefinition]) -> String {
        var lines = ["# Tools", "", "You can call these tools when they help you answer:"]
        for tool in tools {
            lines.append("- \(tool.name): \(tool.description) Arguments (JSON Schema): \(tool.parameters.serialized)")
        }
        lines += [
            "",
            "To call a tool, write only this, with no text after it:",
            #"<tool_call>{"name": "TOOL_NAME", "arguments": {"ARGUMENT": "VALUE"}}</tool_call>"#,
            #"The result comes back in the next message, starting with "Tool result". Then continue answering the user. Only call a tool when it is actually needed."#
        ]
        return lines.joined(separator: "\n")
    }

    /// Rewrites tool calls and results as plain turns, and adds the instructions to the system turn.
    /// Consecutive results are merged into one user turn, because strict templates require user and
    /// assistant turns to alternate.
    static func flatten(_ turns: [ChatTurn], tools: [ToolDefinition]) -> [ChatTurn] {
        var result: [ChatTurn] = []
        for turn in turns {
            switch turn.role {
            case .assistant where !turn.toolCalls.isEmpty:
                let calls = turn.toolCalls.map { call in
                    let payload: JSONValue = .object(["name": .string(call.name), "arguments": .object(call.arguments)])
                    return "<tool_call>\(payload.serialized)</tool_call>"
                }.joined(separator: "\n")
                let content = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(ChatTurn(role: .assistant, content: content.isEmpty ? calls : content + "\n" + calls))
            case .tool:
                let text = "Tool result (\(turn.toolName ?? "tool")):\n\(turn.content)"
                if let last = result.last, last.role == .user, last.content.hasPrefix("Tool result") {
                    result[result.count - 1].content += "\n\n" + text
                } else {
                    result.append(ChatTurn(role: .user, content: text))
                }
            default:
                result.append(ChatTurn(role: turn.role, content: turn.content))
            }
        }
        guard !tools.isEmpty else { return result }
        let instructions = instructions(for: tools)
        if let first = result.first, first.role == .system {
            result[0].content = first.content.isEmpty ? instructions : first.content + "\n\n" + instructions
        } else {
            result.insert(ChatTurn(role: .system, content: instructions), at: 0)
        }
        return result
    }
}
