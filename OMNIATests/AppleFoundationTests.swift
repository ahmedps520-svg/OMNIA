import Foundation
import Testing
@testable import OMNIA

/// Apple's on-device model isn't available on CI simulators, so these check what OMNIA sends it.
@Suite("Apple's on-device model")
struct AppleFoundationTests {
    private func request(_ turns: [ChatTurn], prefix: String? = nil) -> GenerationRequest {
        GenerationRequest(turns: turns, assistantPrefix: prefix, sampling: .greedy, maxTokens: 512)
    }

    @Test func sendsTheLatestMessageAsThePrompt() {
        let conversation = AppleFoundationBackend.conversation(from: request([
            ChatTurn(role: .system, content: "Be brief."),
            ChatTurn(role: .user, content: "Hi"),
            ChatTurn(role: .assistant, content: "Hello!"),
            ChatTurn(role: .user, content: "What's 2 + 2?")
        ]))
        #expect(conversation.prompt == "What's 2 + 2?")
        #expect(conversation.text == "Be brief.\nHi\nHello!\nWhat's 2 + 2?")
    }

    @Test func keepsTheNewestTurnsThatFitItsContext() {
        var turns: [ChatTurn] = []
        for index in 0..<60 {
            turns.append(ChatTurn(role: .user, content: "Question \(index) " + String(repeating: "x", count: 400)))
            turns.append(ChatTurn(role: .assistant, content: "Answer \(index) " + String(repeating: "y", count: 400)))
        }
        turns.append(ChatTurn(role: .user, content: "Last question"))
        let conversation = AppleFoundationBackend.conversation(from: request(turns))

        #expect(conversation.prompt == "Last question")
        #expect(conversation.text.count < Int(Double(AppleFoundationBackend.contextSize) * 3.5))
        #expect(conversation.text.contains("Answer 59"))
        #expect(!conversation.text.contains("Question 0 "))
        // History starts with a question, never with a stray answer.
        #expect(conversation.text.hasPrefix("Question"))
    }

    @Test func asksToContinueACutOffReply() {
        let conversation = AppleFoundationBackend.conversation(from: request([
            ChatTurn(role: .user, content: "Write a poem.")
        ], prefix: "Roses are red,"))
        #expect(conversation.prompt.hasPrefix("Continue your previous answer"))
        #expect(conversation.text.contains("Write a poem.\nRoses are red,"))
    }

    @Test func listsAsABuiltInModel() {
        let model = InstalledModel.appleFoundation
        #expect(model.isSystem)
        #expect(!model.supportsImages)
        #expect(model.facts.trainContext == AppleFoundationBackend.contextSize)
    }
}
