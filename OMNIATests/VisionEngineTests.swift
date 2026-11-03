import Foundation
import Testing
@testable import OMNIA

/// The vision test models (see scripts/fetch-test-models.sh).
enum VisionModels {
    static let smolVLM = "SmolVLM-256M-Instruct-Q8_0.gguf"
    static let smolVLMEncoder = "mmproj-SmolVLM-256M-Instruct-Q8_0.gguf"
    static let qwen = "Qwen_Qwen3.5-0.8B-Q4_0.gguf"
    static let qwenEncoder = "mmproj-Qwen_Qwen3.5-0.8B-f16.gguf"
}

/// llama.cpp's image path end to end, with two small vision models: SmolVLM (attention only,
/// plain positions) and Qwen3.5 0.8B (hybrid, M-RoPE positions, where an image takes fewer
/// positions than cache cells).
@Suite("Vision", .serialized, .timeLimit(.minutes(10)))
struct VisionEngineTests {
    static let configuration = RuntimeConfiguration(contextLength: 2048, batchSize: 512, microBatchSize: 512, threads: 2,
                                                    gpuOffload: false, kvCacheType: .f16, flashAttention: false)

    private func ask(_ question: String, image: Data, maxTokens: Int = 10) -> GenerationRequest {
        var turn = ChatTurn(role: .user, content: question)
        turn.images = [image]
        return GenerationRequest(turns: [turn], assistantPrefix: nil, sampling: .greedy, maxTokens: maxTokens)
    }

    @Test(.enabled(if: TestModels.available(VisionModels.smolVLM, VisionModels.smolVLMEncoder)))
    func readsWhatIsInTheImage() async throws {
        let runtime = try await TestModels.load(VisionModels.smolVLM, projector: VisionModels.smolVLMEncoder, configuration: Self.configuration)
        let red = try TestImages.solid(red: 1, green: 0, blue: 0)
        let blue = try TestImages.solid(red: 0, green: 0, blue: 1)
        let question = "What color is this image? Answer with one word."
        let first = try await collect(runtime.generate(ask(question, image: red)))
        let second = try await collect(runtime.generate(ask(question, image: blue)))
        await runtime.close()

        #expect(!first.text.trimmed.isEmpty)
        #expect(first.text != second.text, "the answer should depend on the picture: \(first.text) / \(second.text)")
        let stats = try #require(first.stats)
        #expect(stats.imageCount == 1)
        let imageTokens = try #require(stats.imageTokens)
        #expect(imageTokens > 0 && stats.promptTokens > imageTokens)
    }

    @Test(.enabled(if: TestModels.available(VisionModels.smolVLM, VisionModels.smolVLMEncoder)))
    func reusesACachedImageInTheNextTurn() async throws {
        let runtime = try await TestModels.load(VisionModels.smolVLM, projector: VisionModels.smolVLMEncoder, configuration: Self.configuration)
        let image = try TestImages.solid(red: 0, green: 1, blue: 0)
        let first = try await collect(runtime.generate(ask("Describe this image.", image: image, maxTokens: 12)))

        var request = ask("Describe this image.", image: image, maxTokens: 12)
        request.turns += [ChatTurn(role: .assistant, content: first.text), ChatTurn(role: .user, content: "Say it in fewer words.")]
        let followUp = try await collect(runtime.generate(request))
        await runtime.resetCache()
        let fresh = try await collect(runtime.generate(request))
        await runtime.close()

        let reused = try #require(followUp.stats?.reusedPromptTokens)
        #expect(reused > (followUp.stats?.imageTokens ?? 0), "the image and the first question should come from the cache")
        #expect(fresh.stats?.reusedPromptTokens == 0)
        #expect(followUp.text == fresh.text)
    }

    /// Continuing after a cached image on an M-RoPE model: the continuation must sit at the same
    /// positions as when the whole prompt is read from scratch.
    @Test(.enabled(if: TestModels.available(VisionModels.qwen, VisionModels.qwenEncoder)))
    func continuesAfterACachedImageAtTheRightPositions() async throws {
        let runtime = try await TestModels.load(VisionModels.qwen, projector: VisionModels.qwenEncoder, configuration: Self.configuration)
        let image = try TestImages.solid(red: 1, green: 1, blue: 0)
        var request = ask("What is in this picture?", image: image, maxTokens: 0)
        request.templateVariables = ReasoningPreference.off.templateVariables
        // Reads the prompt (and the image) into the cache without writing anything.
        let primed = try await collect(runtime.generate(request))

        request.assistantPrefix = "The picture shows"
        request.maxTokens = 10
        let continued = try await collect(runtime.generate(request))
        await runtime.resetCache()
        let fresh = try await collect(runtime.generate(request))
        await runtime.close()

        let promptTokens = try #require(primed.stats?.promptTokens)
        #expect(continued.stats?.reusedPromptTokens == promptTokens, "the whole first prompt, image included, is reused")
        #expect(continued.stats?.imageCount == 1)
        #expect(!continued.text.isEmpty)
        #expect(continued.text == fresh.text)
    }

    @Test(.enabled(if: TestModels.available(VisionModels.smolVLM, VisionModels.smolVLMEncoder)))
    func trimmingAConversationDropsItsOldestImages() async throws {
        // A 1,024-token window leaves 768 for the prompt: room for the last question only.
        var small = Self.configuration
        small.contextLength = 1024
        let runtime = try await TestModels.load(VisionModels.smolVLM, projector: VisionModels.smolVLMEncoder, configuration: small)
        let filler = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40)
        var turns: [ChatTurn] = []
        for color in [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)] {
            var turn = ChatTurn(role: .user, content: filler + "What color is this?")
            turn.images = [try TestImages.solid(red: color.0, green: color.1, blue: color.2)]
            turns += [turn, ChatTurn(role: .assistant, content: "A color.")]
        }
        turns.removeLast()
        let request = GenerationRequest(turns: turns, assistantPrefix: nil, sampling: .greedy, maxTokens: 16)
        let result = try await collect(runtime.generate(request))
        await runtime.close()

        let stats = try #require(result.stats)
        #expect((stats.trimmedTurns ?? 0) > 0)
        #expect((stats.imageCount ?? 0) >= 1 && (stats.imageCount ?? 0) < 3)
    }

    @Test(.enabled(if: TestModels.available("stories260K.gguf")))
    func modelsWithoutAnEncoderRefuseImages() async throws {
        let runtime = try await TestModels.load("stories260K.gguf")
        do {
            _ = try await collect(runtime.generate(ask("What is this?", image: try TestImages.solid(red: 1, green: 0, blue: 0))))
            Issue.record("Expected the request to fail")
        } catch InferenceError.imagesUnsupported(_) {
            // Expected.
        }
        // The runtime stays usable for text.
        let text = try await collect(runtime.generate(.user("Once upon a time", maxTokens: 8)))
        await runtime.close()
        #expect(!text.text.isEmpty)
    }
}
