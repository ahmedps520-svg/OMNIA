import Foundation
import Jinja
import Testing
@testable import OMNIA

@Suite("JSON values")
struct JSONValueTests {
    @Test func keepsKeyOrderAndPythonFormatting() throws {
        let value = try JSONValue.parse(#"{"b": 1, "a": [true, null, 2.5, "x\"y"], "c": {"z": 3.0, "y": 1e3}}"#)
        #expect(value.serialized == #"{"b": 1, "a": [true, null, 2.5, "x\"y"], "c": {"z": 3.0, "y": 1000.0}}"#)
    }

    @Test func distinguishesIntegersFromDoubles() throws {
        #expect(try JSONValue.parse("3") == .int(3))
        #expect(try JSONValue.parse("-3.0") == .double(-3.0))
        #expect(try JSONValue.parse("0.5e1") == .double(5.0))
    }

    @Test func decodesEscapesAndSurrogatePairs() throws {
        let value = try JSONValue.parse(#""café 😀\n\t""#)
        #expect(value == .string("café 😀\n\t"))
        #expect(JSONValue.string("a\u{01}b\"c\\").serialized == #""a\u0001b\"c\\""#)
    }

    @Test func strictRejectsWhatLenientAccepts() throws {
        let sloppy = "{'query': 'iPad', count: 3, flag: True, missing: None,}"
        #expect(throws: (any Error).self) { try JSONValue.parse(sloppy) }
        let value = try JSONValue.parse(sloppy, lenient: true)
        #expect(value.serialized == #"{"query": "iPad", "count": 3, "flag": true, "missing": null}"#)
    }

    @Test func rejectsTrailingContentButPrefixParsingStops() throws {
        #expect(throws: JSONParseError.self) { try JSONValue.parse(#"{"a": 1} tail"#) }
        let (value, used) = try JSONValue.parsePrefix(#"{"a": 1} tail"#)
        #expect(value == .object(["a": .int(1)]))
        #expect(used == 8)
    }

    @Test func rendersIntoTemplatesInOrder() throws {
        let template = try Template("{{ value | tojson }}")
        let value: JSONValue = .object(["b": .int(1), "a": .array([.string("x"), .bool(false)])])
        #expect(try template.render(["value": value.jinjaValue]) == #"{"b": 1, "a": ["x", false]}"#)
    }
}

@Suite("Calculator")
struct CalculatorTests {
    @Test(arguments: [
        ("2+3*4", 14.0), ("(2+3)*4", 20.0), ("2**10", 1024.0), ("2^3^2", 512.0), ("-2**2", -4.0),
        ("7 % 3", 1.0), ("-7 % 3", 2.0), ("sqrt(16) + abs(-3)", 7.0), ("round(3.14159, 2)", 3.14),
        ("max(1, 5, 3) - min(4, 2)", 3.0), ("1e3 / 4", 250.0), ("17 × 23", 391.0), ("10 ÷ 4", 2.5),
        ("log(1000)", 3.0), ("ln(e)", 1.0), ("2 * pi", 2 * Double.pi)
    ])
    func evaluates(_ expression: String, _ expected: Double) throws {
        let value = try Calculator.evaluate(expression)
        #expect(abs(value - expected) < 1e-9, "\(expression) = \(value)")
    }

    @Test func reportsErrors() {
        #expect(throws: Calculator.Failure.divisionByZero) { try Calculator.evaluate("10 / 0") }
        #expect(throws: Calculator.Failure.undefined) { try Calculator.evaluate("sqrt(-1)") }
        #expect(throws: Calculator.Failure.unknownName("foo")) { try Calculator.evaluate("foo(2)") }
        #expect(throws: Calculator.Failure.self) { try Calculator.evaluate("2 +") }
        #expect(throws: Calculator.Failure.empty) { try Calculator.evaluate("   ") }
    }

    @Test func formatsResults() {
        #expect(Calculator.format(14) == "14")
        #expect(Calculator.format(0.1 + 0.2) == "0.3")
        #expect(Calculator.format(1.0 / 3.0) == "0.333333333333")
        #expect(Calculator.format(-0.0) == "0")
    }
}

@Suite("Tool-call parsing")
struct ToolCallParserTests {
    static let tools = ChatTemplateParityTests.tools

    private func only(_ text: String, format: ToolCallFormat?) throws -> ToolCall {
        let parsed = try #require(ToolCallParser.parse(text, format: format, tools: Self.tools))
        #expect(parsed.calls.count == 1)
        return try #require(parsed.calls.first)
    }

    @Test func xmlFunctionWithNewlines() throws {
        let call = try only("<tool_call>\n<function=web_search>\n<parameter=query>\nM5 iPad\n</parameter>\n<parameter=count>\n3\n</parameter>\n</function>\n</tool_call>",
                            format: .xmlFunction)
        #expect(call.name == "web_search")
        #expect(call.arguments == ["query": .string("M5 iPad"), "count": .int(3)])
    }

    @Test func xmlFunctionKeepsMultilineStrings() throws {
        let call = try only("<tool_call><function=calculator><parameter=expression>\n2 +\n3\n</parameter></function></tool_call>",
                            format: .xmlFunction)
        #expect(call.arguments["expression"] == .string("2 +\n3"))
    }

    @Test func gemmaNotation() throws {
        let call = try only(#"<|tool_call>call:web_search{count:3,query:<|"|>M5 iPad "Pro"<|"|>}<tool_call|>"#, format: .gemma)
        #expect(call.name == "web_search")
        #expect(call.arguments == ["count": .int(3), "query": .string("M5 iPad \"Pro\"")])
    }

    @Test func gemmaNestedValues() throws {
        let call = try only(#"<|tool_call>call:f{opts:{deep:true,list:[1,<|"|>a<|"|>,2.5]},name:<|"|>x, y<|"|>,none:null}<tool_call|>"#,
                            format: .gemma)
        #expect(call.argumentsJSON == #"{"opts": {"deep": true, "list": [1, "a", 2.5]}, "name": "x, y", "none": null}"#)
    }

    @Test func harmonyRecipientBeforeOrAfterTheChannel() throws {
        for text in [#"<|channel|>commentary to=functions.web_search <|constrain|>json<|message|>{"query": "M5", "count": 3}<|call|>"#,
                     #"to=functions.web_search<|channel|>commentary json<|message|>{"query": "M5", "count": 3}<|call|>"#] {
            let call = try only(text, format: .harmony)
            #expect(call.name == "web_search")
            #expect(call.arguments == ["query": .string("M5"), "count": .int(3)])
        }
    }

    @Test func mistralCallsAndLegacyArrays() throws {
        let parsed = try #require(ToolCallParser.parse(#"[TOOL_CALLS]calculator[ARGS]{"expression": "2+2"}[TOOL_CALLS]web_search[ARGS]{"query": "x"}"#,
                                                       format: .mistral, tools: Self.tools))
        #expect(parsed.calls.map(\.name) == ["calculator", "web_search"])
        let legacy = try only(#"[TOOL_CALLS][{"name": "calculator", "arguments": {"expression": "1+1"}}]"#, format: .mistral)
        #expect(legacy.arguments == ["expression": .string("1+1")])
    }

    @Test func pythonicCalls() throws {
        let parsed = try #require(ToolCallParser.parse(#"<|tool_call_start|>[web_search(query='M5 iPad "Pro"', count=3), calculator(expression="2*3")]<|tool_call_end|>"#,
                                                       format: .pythonic, tools: Self.tools))
        #expect(parsed.calls.map(\.name) == ["web_search", "calculator"])
        #expect(parsed.calls[0].arguments == ["query": .string("M5 iPad \"Pro\""), "count": .int(3)])
        let literals = try only("<|tool_call_start|>[f(flag=True, nothing=None, items=[1, 'a'])]<|tool_call_end|>", format: .pythonic)
        #expect(literals.argumentsJSON == #"{"flag": true, "nothing": null, "items": [1, "a"]}"#)
    }

    @Test func atemInvocations() throws {
        let call = try only("<atem:function_calls>\n<atem:invoke name=\"web_search\">\n<atem:parameter name=\"query\">M5 iPad</atem:parameter>\n<atem:parameter name=\"count\">3</atem:parameter>\n</atem:invoke>\n</atem:function_calls>",
                            format: .atem)
        #expect(call.arguments == ["query": .string("M5 iPad"), "count": .int(3)])
    }

    @Test func hermesJSONIncludingStringArgumentsAndACutOffEnd() throws {
        let call = try only("<tool_call>\n{\"name\": \"calculator\", \"arguments\": {\"expression\": \"17*23\"}}\n</tool_call>", format: .hermesJSON)
        #expect(call.arguments == ["expression": .string("17*23")])
        let encoded = try only(#"<tool_call>{"name": "calculator", "arguments": "{\"expression\": \"1+2\"}"}</tool_call>"#, format: nil)
        #expect(encoded.arguments == ["expression": .string("1+2")])
        // A stop sequence removed the closing tag.
        let open = try only(#"<tool_call>{"name": "calculator", "arguments": {"expression": "5"}}"#, format: nil)
        #expect(open.name == "calculator")
    }

    @Test func keepsThePrefaceAndFallsBackToOtherFormats() throws {
        let parsed = try #require(ToolCallParser.parse("Let me work that out.\n<tool_call>{\"name\": \"calculator\", \"arguments\": {\"expression\": \"6*7\"}}</tool_call>",
                                                       format: .xmlFunction, tools: Self.tools))
        #expect(parsed.preface == "Let me work that out.")
        #expect(parsed.calls.first?.name == "calculator")
    }

    @Test func plainAnswersHaveNoCalls() {
        #expect(ToolCallParser.parse("The answer is 391.", format: .xmlFunction, tools: Self.tools) == nil)
        #expect(ToolCallParser.parse("", format: nil, tools: Self.tools) == nil)
    }

    @Test func callIDsSuitStrictTemplates() {
        let id = ToolCall.makeID()
        #expect(id.count == 9)
        #expect(id.allSatisfy { $0.isLetter || $0.isNumber })
    }
}

@Suite("Stop sequences")
struct StopSequenceMatcherTests {
    @Test func holdsBackAPossibleStartThenStops() {
        var matcher = StopSequenceMatcher(["<|tool_response>"])
        let first = matcher.feed("Hello <|tool")
        #expect(first.text == "Hello ")
        #expect(!first.stopped)
        let second = matcher.feed("_response>response:x")
        #expect(second.text == "")
        #expect(second.stopped)
    }

    @Test func releasesTextThatStopsMatching() {
        var matcher = StopSequenceMatcher(["<|x"])
        #expect(matcher.feed("a<").text == "a")
        #expect(matcher.feed("b").text == "<b")
        #expect(matcher.feed("<|").text == "")
        #expect(matcher.flush() == "<|")
    }

    @Test func earliestSequenceWinsAndInactiveMatcherPassesThrough() {
        var matcher = StopSequenceMatcher(["END", "STOP"])
        let result = matcher.feed("one STOP two END")
        #expect(result.text == "one ")
        #expect(result.stopped)
        var none = StopSequenceMatcher([])
        #expect(none.feed("<|anything").text == "<|anything")
    }
}

@Suite("Tool protocol for templates without tools")
struct ToolPromptTests {
    @Test func flattensCallsAndMergesResults() {
        let call = ToolCall(id: "abc", name: "calculator", arguments: ["expression": .string("2+2")])
        let turns = ToolPrompt.flatten([
            ChatTurn(role: .user, content: "What is 2+2 and 3+3?"),
            ChatTurn(role: .assistant, content: "", toolCalls: [call]),
            ChatTurn(role: .tool, content: "4", toolCallID: "abc", toolName: "calculator"),
            ChatTurn(role: .tool, content: "6", toolCallID: "def", toolName: "calculator")
        ], tools: ChatTemplateParityTests.tools)

        #expect(turns.map(\.role) == [.system, .user, .assistant, .user])
        #expect(turns[0].content.contains("calculator: Evaluates an arithmetic expression."))
        #expect(turns[2].content == #"<tool_call>{"name": "calculator", "arguments": {"expression": "2+2"}}</tool_call>"#)
        #expect(turns[3].content == "Tool result (calculator):\n4\n\nTool result (calculator):\n6")
    }

    @Test func appendsInstructionsToAnExistingSystemTurn() {
        let turns = ToolPrompt.flatten([ChatTurn(role: .system, content: "Be brief."),
                                        ChatTurn(role: .user, content: "Hi")], tools: ChatTemplateParityTests.tools)
        #expect(turns.count == 2)
        #expect(turns[0].content.hasPrefix("Be brief.\n\n# Tools"))
    }
}
