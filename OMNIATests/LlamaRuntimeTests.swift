import Foundation
import Testing
@testable import OMNIA

/// End-to-end checks of the llama.cpp runtime with a real (tiny) model.
@Suite("llama.cpp runtime", .serialized, .timeLimit(.minutes(10)), .enabled(if: TestModels.available("stories260K.gguf")))
struct LlamaRuntimeTests {
    @Test func greedyGenerationIsDeterministic() async throws {
        let runtime = try await TestModels.load("stories260K.gguf")
        let first = try await collect(runtime.generate(.user("Once upon a time")))
        await runtime.resetCache()
        let second = try await collect(runtime.generate(.user("Once upon a time")))
        await runtime.close()

        let stats = try #require(first.stats)
        #expect(stats.generatedTokens > 0)
        #expect(!first.text.isEmpty)
        #expect(first.text == second.text)
        #expect(second.stats?.reusedPromptTokens == 0)
    }

    @Test func reusingTheCacheDoesNotChangeTheOutput() async throws {
        let runtime = try await TestModels.load("stories260K.gguf")
        let fresh = try await collect(runtime.generate(.user("The cat sat on the mat")))
        let reused = try await collect(runtime.generate(.user("The cat sat on the mat")))
        await runtime.close()

        let stats = try #require(reused.stats)
        #expect(stats.reusedPromptTokens > 0)
        #expect(stats.reusedPromptTokens < stats.promptTokens)
        #expect(fresh.text == reused.text)
    }

    @Test func followUpTurnsReuseThePrompt() async throws {
        let runtime = try await TestModels.load("stories260K.gguf")
        let first = try await collect(runtime.generate(.user("There was a little dog")))
        var followUp = GenerationRequest.user("There was a little dog")
        followUp.turns += [ChatTurn(role: .assistant, content: first.text),
                           ChatTurn(role: .user, content: "What happened next?")]
        let second = try await collect(runtime.generate(followUp))
        await runtime.close()

        // Token boundaries can shift where the reply joins the old prompt, so allow a little slack.
        let firstStats = try #require(first.stats)
        let secondStats = try #require(second.stats)
        #expect(secondStats.reusedPromptTokens > firstStats.promptTokens / 2)
        #expect(secondStats.promptTokens > firstStats.promptTokens)
    }

    @Test func respectsTheTokenLimit() async throws {
        let runtime = try await TestModels.load("stories260K.gguf")
        let result = try await collect(runtime.generate(.user("Once upon a time", maxTokens: 5)))
        await runtime.close()

        let stats = try #require(result.stats)
        #expect(stats.generatedTokens <= 5)
        #expect([.maxTokens, .endOfSequence].contains(stats.stopReason))
    }

    @Test func interruptStopsAfterTheTokenInFlight() async throws {
        let runtime = try await TestModels.load("stories260K.gguf")
        let result = try await collect(runtime.generate(.user("Once upon a time", maxTokens: 400))) { chunks in
            if chunks == 2 { runtime.interrupt(.user) }
        }
        await runtime.close()

        let stats = try #require(result.stats)
        #expect(stats.stopReason == .cancelled)
        #expect(stats.generatedTokens < 400)
    }

    @Test func countsTokens() async throws {
        let runtime = try await TestModels.load("stories260K.gguf")
        let short = await runtime.countTokens("Hello")
        let long = await runtime.countTokens("Hello there, little dog. The sun was warm and the grass was green.")
        await runtime.close()

        #expect(short > 0)
        #expect(long > short)
    }

    @Test func reportsWhatItLoaded() async throws {
        let runtime = try await TestModels.load("stories260K.gguf")
        let info = runtime.info
        await runtime.close()

        #expect(info.architecture == "llama")
        #expect(info.configuration.contextLength == 512)
        #expect(info.parameterCount > 0)
    }
}
