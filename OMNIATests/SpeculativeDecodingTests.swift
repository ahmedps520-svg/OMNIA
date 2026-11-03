import Foundation
import Testing
@testable import OMNIA

/// Speculative decoding must never change the reply: every token is the main model's own pick,
/// the draft only lets it check several at once. Different quantizations of the same model make
/// the draft guess wrong now and then, so rejected tokens get rolled back too.
@Suite("Speculative decoding", .serialized, .timeLimit(.minutes(10)))
struct SpeculativeDecodingTests {
    @Test(.enabled(if: TestModels.available("stories15M-q8_0.gguf", "stories15M-q4_0.gguf")))
    func matchesThePlainReplyOnAnAttentionModel() async throws {
        let runtime = try await TestModels.load("stories15M-q8_0.gguf")
        let request = GenerationRequest.user("Once upon a time, a little fox", maxTokens: 40)
        let plain = try await collect(runtime.generate(request))
        await runtime.resetCache()
        try await runtime.attachDraft(fileURL: try #require(TestModels.url("stories15M-q4_0.gguf")),
                                      displayName: "draft", length: 5)
        let speculative = try await collect(runtime.generate(request))
        await runtime.close()

        #expect(speculative.text == plain.text)
        let stats = try #require(speculative.stats)
        #expect((stats.draftedTokens ?? 0) > 0)
        #expect((stats.acceptedDraftTokens ?? 0) > 0)
        #expect(stats.generatedTokens == plain.stats?.generatedTokens)
    }

    @Test(.enabled(if: TestModels.available("stories15M-q8_0.gguf", "stories15M-q4_0.gguf")))
    func respectsTheTokenLimit() async throws {
        let runtime = try await TestModels.load("stories15M-q8_0.gguf")
        try await runtime.attachDraft(fileURL: try #require(TestModels.url("stories15M-q4_0.gguf")),
                                      displayName: "draft", length: 6)
        let result = try await collect(runtime.generate(.user("The dog", maxTokens: 7)))
        await runtime.close()

        #expect((result.stats?.generatedTokens ?? 0) <= 7)
    }

    @Test(.enabled(if: TestModels.available("stories15M-q8_0.gguf", "stories15M-q4_0.gguf")))
    func canBeTurnedOffPerRequest() async throws {
        let runtime = try await TestModels.load("stories15M-q8_0.gguf")
        try await runtime.attachDraft(fileURL: try #require(TestModels.url("stories15M-q4_0.gguf")),
                                      displayName: "draft", length: 4)
        var request = GenerationRequest.user("The cat", maxTokens: 12)
        request.speculative = false
        let result = try await collect(runtime.generate(request))
        await runtime.close()

        #expect(result.stats?.draftedTokens == nil)
    }

    @Test(.enabled(if: TestModels.available("stories15M-q8_0.gguf", "stories260K.gguf")))
    func rejectsADraftWithAnotherVocabulary() async throws {
        let runtime = try await TestModels.load("stories15M-q8_0.gguf")
        await #expect(throws: DraftModel.Failure.self) {
            try await runtime.attachDraft(fileURL: try #require(TestModels.url("stories260K.gguf")),
                                          displayName: "draft", length: 4)
        }
        await runtime.close()
    }

    @Test(.enabled(if: TestModels.available("Qwen3.5-0.8B-Q4_0.gguf", "Qwen_Qwen3.5-0.8B-Q4_0.gguf")))
    func rollsBackRejectedTokensOnAHybridModel() async throws {
        var configuration = TestModels.cpu
        configuration.contextLength = 1024
        configuration.rollbackDepth = 6
        let runtime = try await TestModels.load("Qwen3.5-0.8B-Q4_0.gguf", configuration: configuration)
        var request = GenerationRequest.user("List three colors of the rainbow.", maxTokens: 32)
        request.templateVariables = ReasoningPreference.off.templateVariables
        let plain = try await collect(runtime.generate(request))
        await runtime.resetCache()
        try await runtime.attachDraft(fileURL: try #require(TestModels.url("Qwen_Qwen3.5-0.8B-Q4_0.gguf")),
                                      displayName: "draft", length: 5)
        let speculative = try await collect(runtime.generate(request))
        await runtime.close()

        #expect(speculative.text == plain.text)
        #expect((speculative.stats?.draftedTokens ?? 0) > 0)
    }

    @Test(.enabled(if: TestModels.available("Qwen3.5-0.8B-Q4_0.gguf", "Qwen_Qwen3.5-0.8B-Q4_0.gguf")))
    func hybridModelsNeedRollbackSnapshots() async throws {
        let runtime = try await TestModels.load("Qwen3.5-0.8B-Q4_0.gguf")
        await #expect(throws: DraftModel.Failure.self) {
            try await runtime.attachDraft(fileURL: try #require(TestModels.url("Qwen_Qwen3.5-0.8B-Q4_0.gguf")),
                                          displayName: "draft", length: 5)
        }
        await runtime.close()
    }
}
