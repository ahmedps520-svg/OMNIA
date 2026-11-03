import Foundation
import Testing
@testable import OMNIA

/// Every catalog model's chat template must render exactly like Hugging Face Transformers does
/// (the renderer the models were trained with), for plain chat and for tool calling.
@Suite("Chat templates render like Transformers")
struct ChatTemplateParityTests {
    static let tools = [
        ToolDefinition(name: "calculator", description: "Evaluates an arithmetic expression.",
                       parameters: ToolDefinition.schema([("expression", "string", "The expression, e.g. 2*(3+4)")],
                                                         required: ["expression"])),
        ToolDefinition(name: "web_search", description: "Searches the web.",
                       parameters: ToolDefinition.schema([("query", "string", "Search terms"),
                                                          ("count", "integer", "Number of results")],
                                                         required: ["query"]))
    ]

    static let searchCall = ToolCall(id: "call_1", name: "web_search",
                                     arguments: ["query": .string("M5 iPad \"Pro\" memory"), "count": .int(3)])

    static let scenarios: [(name: String, turns: [ChatTurn], tools: [ToolDefinition])] = {
        let system = ChatTurn(role: .system, content: "You are helpful.")
        return [
            ("chat", [system,
                      ChatTurn(role: .user, content: "Hello!"),
                      ChatTurn(role: .assistant, content: "Hi! How can I help?"),
                      ChatTurn(role: .user, content: "Tell me a joke.")], []),
            ("toolPrompt", [system, ChatTurn(role: .user, content: "What is 17 * 23?")], tools),
            ("toolRoundTrip", [system,
                               ChatTurn(role: .user, content: "Search for the M5 iPad memory."),
                               ChatTurn(role: .assistant, content: "", toolCalls: [searchCall]),
                               ChatTurn(role: .tool, content: "RESULT_TEXT", toolCallID: "call_1", toolName: "web_search")],
             tools)
        ]
    }()

    /// 2026-11-03 at noon, the date the fixtures were rendered with.
    static let date: Date = {
        var components = DateComponents()
        (components.year, components.month, components.day, components.hour) = (2026, 11, 3, 12)
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    @Test(arguments: TemplateFixtures.all)
    func rendersLikeTransformers(_ fixture: TemplateFixture) throws {
        let renderer = try ChatTemplateRenderer(source: fixture.template, bosToken: "<BOS>", eosToken: "<EOS>")
        for scenario in Self.scenarios {
            let expected = try #require(fixture.expected[scenario.name])
            let rendered = try renderer.render(scenario.turns, addGenerationPrompt: true, variables: [:],
                                               tools: scenario.tools, date: Self.date)
            // Compared through the first difference, so a failure reads in one short line.
            let difference = rendered == expected ? nil : Self.firstDifference(rendered, expected)
            #expect(difference == nil, "\(fixture.model) / \(scenario.name)")
        }
    }

    @Test func keepsJinja2WhitespaceAfterALiteralBrace() throws {
        let renderer = try ChatTemplateRenderer(source: "a:{\n    {%- if true -%}\n    b\n{%- endif -%}\n}", bosToken: "", eosToken: "")
        #expect(try renderer.render([], addGenerationPrompt: false, variables: [:]) == "a:{b}")
    }

    @Test(arguments: TemplateFixtures.all)
    func detectsTheToolFormat(_ fixture: TemplateFixture) {
        let expected: ToolCallFormat = switch fixture.model {
        case let name where name.hasPrefix("gemma") || name.hasPrefix("nemotron"): .gemma
        case let name where name.hasPrefix("gpt-oss"): .harmony
        case let name where name.hasPrefix("ministral"): .mistral
        case let name where name.hasPrefix("lfm2.5"): .pythonic
        case let name where name.hasPrefix("muse"): .atem
        default: .xmlFunction
        }
        #expect(ToolCallFormat.detect(template: fixture.template) == expected)
    }

    /// The call each template writes into the history must parse back to the same call.
    @Test(arguments: TemplateFixtures.all)
    func parsesTheCallItsTemplateWrites(_ fixture: TemplateFixture) throws {
        let rendered = try #require(fixture.expected["toolRoundTrip"])
        let start = try #require(rendered.range(of: "Search for the M5 iPad memory."))
        let end = try #require(rendered.range(of: "RESULT_TEXT"))
        let history = String(rendered[start.upperBound..<end.lowerBound])
        let format = ToolCallFormat.detect(template: fixture.template)
        let parsed = try #require(ToolCallParser.parse(history, format: format, tools: Self.tools))

        #expect(parsed.calls.count == 1)
        #expect(parsed.calls.first?.name == "web_search")
        #expect(parsed.calls.first?.arguments["query"] == .string("M5 iPad \"Pro\" memory"))
        #expect(parsed.calls.first?.arguments["count"]?.intValue == 3)
    }

    static func firstDifference(_ actual: String, _ expected: String) -> String {
        let a = Array(actual), b = Array(expected)
        var index = 0
        while index < a.count, index < b.count, a[index] == b[index] { index += 1 }
        func around(_ text: [Character]) -> String {
            let lower = max(0, index - 50), upper = min(text.count, index + 70)
            return lower < upper ? String(text[lower..<upper]).debugDescription : "\"\""
        }
        return "first difference at character \(index) of \(b.count): got \(around(a)), expected \(around(b))"
    }
}
