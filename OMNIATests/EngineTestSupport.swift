import Foundation
import Testing
@testable import OMNIA

/// Small public GGUF models for the engine tests, downloaded by `scripts/fetch-test-models.sh`.
/// CI passes their folder as `OMNIA_TEST_MODELS` (via `TEST_RUNNER_OMNIA_TEST_MODELS`); without it
/// the engine suites are skipped. On the simulator llama.cpp runs on the CPU.
enum TestModels {
    static let directory: URL? = ProcessInfo.processInfo.environment["OMNIA_TEST_MODELS"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    static func url(_ name: String) -> URL? {
        guard let url = directory?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return url
    }

    static func available(_ names: String...) -> Bool {
        names.allSatisfy { url($0) != nil }
    }

    static let cpu = RuntimeConfiguration(contextLength: 512, batchSize: 128, microBatchSize: 128, threads: 2,
                                          gpuOffload: false, kvCacheType: .f16, flashAttention: false)

    static func load(_ name: String, configuration: RuntimeConfiguration = cpu) async throws -> LlamaRuntime {
        let file = try #require(url(name), "Missing test model \(name)")
        return try await LlamaRuntime.load(modelID: name, displayName: name, fileURL: file,
                                           configuration: configuration, progress: { _ in })
    }
}

extension SamplingParameters {
    /// Deterministic sampling: always the most likely token, no repetition penalty.
    static var greedy: SamplingParameters {
        var settings = GenerationSettings()
        settings.temperature = 0
        settings.repetitionPenalty = 1
        return SamplingParameters(settings)
    }
}

extension GenerationRequest {
    static func user(_ text: String, maxTokens: Int = 24) -> GenerationRequest {
        GenerationRequest(turns: [ChatTurn(role: .user, content: text)], assistantPrefix: nil,
                          sampling: .greedy, maxTokens: maxTokens)
    }
}

/// Everything a generation stream produced.
struct CollectedGeneration {
    var text = ""
    var chunks = 0
    var stats: GenerationStats?
}

func collect(_ stream: AsyncThrowingStream<GenerationEvent, Error>,
             onChunk: (Int) -> Void = { _ in }) async throws -> CollectedGeneration {
    var result = CollectedGeneration()
    for try await event in stream {
        switch event {
        case .text(let text):
            result.text += text
            result.chunks += 1
            onChunk(result.chunks)
        case .finished(let stats):
            result.stats = stats
        case .started, .promptProgress:
            break
        }
    }
    return result
}
