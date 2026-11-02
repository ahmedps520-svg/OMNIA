import Foundation

/// A loaded model that can generate text.
///
/// `LlamaRuntime` (llama.cpp, GGUF, Metal) is the shipping backend. The engine talks only to
/// this protocol, so another runtime (e.g. MLX for safetensors models) can be added without
/// touching chat, comparison, benchmarking or memory management.
protocol InferenceBackend: AnyObject, Sendable {
    var info: LoadedModelInfo { get }
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
    func interrupt(_ reason: InterruptReason)
    func setPacing(_ pacing: Duration)
    func resetCache() async
    func countTokens(_ text: String) async -> Int
    func benchmark(promptLength: Int, generateLength: Int, repetitions: Int,
                   progress: @escaping @Sendable (Double) -> Void) async throws -> BenchmarkMeasurement
    func close() async
}

extension LlamaRuntime: InferenceBackend {}
