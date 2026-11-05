import Foundation
import Testing
@testable import OMNIA

/// How OMNIA keeps a `<think>` block within the reasoning effort chosen in Settings.
@Suite("Reasoning budget")
struct ReasoningBudgetTests {
    @Test func countsTokensInsideABlockTheTemplateOpened() {
        var budget = ReasoningBudget(limit: 3, inReasoning: true)
        budget.observe("Let")
        budget.observe(" me")
        #expect(!budget.isExhausted)
        budget.observe(" think")
        #expect(budget.spent == 3)
        #expect(budget.isExhausted)
        budget.end()
        #expect(!budget.isExhausted)
    }

    @Test func aBlockTheModelEndsItselfIsNotCut() {
        var budget = ReasoningBudget(limit: 5, inReasoning: true)
        for piece in ["Short", " thought.", "</th", "ink>", "\n\nThe answer"] { budget.observe(piece) }
        #expect(budget.ended)
        #expect(!budget.isExhausted)
    }

    @Test func findsABlockTheModelOpensItself() {
        var budget = ReasoningBudget(limit: 2, inReasoning: false)
        for piece in ["\n", "<th", "ink>", "\n"] { budget.observe(piece) }
        #expect(budget.inReasoning)
        budget.observe("Hmm")
        #expect(budget.isExhausted)
    }

    @Test func aReplyThatStartsWithItsAnswerHasNoBlock() {
        var budget = ReasoningBudget(limit: 2, inReasoning: false)
        for piece in ["Sure", ", here", " is <think> as a word", " and more", " text"] { budget.observe(piece) }
        #expect(!budget.inReasoning)
        #expect(!budget.isExhausted)

        // A continued reply that had already started its answer doesn't look for one either.
        var continued = ReasoningBudget(limit: 2, inReasoning: false, replyStarted: true)
        for piece in ["<think>", "a", "b", "c"] { continued.observe(piece) }
        #expect(!continued.inReasoning)
    }

    @Test func effortLevelsSetTheBudget() {
        #expect(ReasoningEffort.low.thinkingBudget == 1_024)
        #expect(ReasoningEffort.medium.thinkingBudget == 4_096)
        #expect(ReasoningEffort.high.thinkingBudget == nil)
        #expect(ReasoningBudget.closing.hasSuffix("</think>\n\n"))
    }
}

/// A tool call is shown while the model writes it, since its markup is hidden from the reply.
@Suite("Tool calls being written")
struct PendingToolCallTests {
    @Test func namesTheToolOnceItIsWritten() throws {
        let text = "I'll check that.\n<tool_call>\n<function=run_code>\n<parameter=code>\nfor i in range(3):\n    print(i)"
        let call = try #require(ToolCallParser.pendingCall(in: text, tools: ["calculator", "run_code", "web_search"]))
        #expect(call.name == "run_code")
        #expect(call.text.hasPrefix("<tool_call>"))
        #expect(call.preview.hasSuffix("print(i)"))
        #expect(ToolCallParser.visibleText(text, streaming: true) == "I'll check that.\n")
    }

    @Test func readsJSONCallsAndUnnamedStarts() throws {
        let json = #"<tool_call>{"name": "web_search", "arguments": {"query": "M5 iPad Pro mem"#
        #expect(ToolCallParser.pendingCall(in: json, tools: ["open_url", "web_search"])?.name == "web_search")
        let start = try #require(ToolCallParser.pendingCall(in: "Let me look.<tool_call>\n", tools: ["web_search"]))
        #expect(start.name == nil)
        #expect(ToolCallParser.pendingCall(in: "Just an answer, no tools.", tools: ["web_search"]) == nil)
    }
}
