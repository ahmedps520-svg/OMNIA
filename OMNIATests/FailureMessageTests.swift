import Foundation
import Testing
@testable import OMNIA

/// What a reply says when it stops early: Metal's reason for a failed GPU step, read from
/// llama.cpp's log, and why OMNIA paused it.
@Suite("Failure messages")
struct FailureMessageTests {
    @Test func readsMetalsReasonFromTheLog() {
        // What ggml logs when a command buffer fails, then on the next step (llama_decode -3).
        let log = [
            "ggml_metal_synchronize: error: command buffer 0 failed with status 5",
            "error: Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)",
            "ggml_metal_graph_compute: backend is in error state from a previous command buffer failure - recreate the backend to recover",
            "llama_context::graph_compute: ggml_backend_sched_graph_compute_async failed with error -1",
            "decode: failed to decode, ret = -3"
        ]
        let reason = LlamaRuntime.gpuError(in: log)
        #expect(reason == "Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)")
        let message = InferenceError.gpuFailed(reason ?? "").errorDescription ?? ""
        #expect(message.contains("ran out of memory"))
        #expect(message.contains("tap Continue"))
        #expect(InferenceError.gpuFailed("anything").needsReload)
    }

    @Test func fallsBackToTheCommandBufferLine() {
        let line = "ggml_metal_synchronize: error: command buffer 1 failed with status 5"
        #expect(LlamaRuntime.gpuError(in: [line]) == line)
        #expect(LlamaRuntime.gpuError(in: [line, "error: "]) == line)
        // Errors that aren't about a GPU step aren't blamed on the GPU.
        #expect(LlamaRuntime.gpuError(in: ["llama_model_load: error loading model: tensor data is not within the file bounds"]) == nil)
        #expect(LlamaRuntime.gpuError(in: []) == nil)
    }

    @Test func explainsTheGPUsReasons() {
        let background = "Insufficient Permission (to submit GPU work from background) (00000006:kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted)"
        #expect(InferenceError.plainGPUReason(background).contains("background"))
        #expect(InferenceError.plainGPUReason("Caused GPU Timeout Error (00000002:kIOGPUCommandBufferCallbackErrorTimeout)").contains("too long"))
        #expect(InferenceError.plainGPUReason("Impacting Interactivity (0000000e:kIOGPUCommandBufferCallbackErrorImpactingInteractivity)").contains("responsive"))
        #expect(InferenceError.plainGPUReason("Something new") == "a GPU step failed")
    }

    @Test func pausesSayWhy() {
        #expect(InterruptReason.memoryPressure.pauseMessage(device: "iPad")?.contains("this iPad ran low on memory") == true)
        #expect(InterruptReason.thermal.pauseMessage(device: "iPhone")?.contains("this iPhone got too hot") == true)
        #expect(InterruptReason.background.pauseMessage(device: "iPad")?.contains("left the screen") == true)
        #expect(InterruptReason.unload.pauseMessage(device: "iPad")?.contains("unloaded") == true)
        #expect(InterruptReason.user.pauseMessage(device: "iPad") == nil)
    }

    @Test func statsKeepWhyAReplyWasInterrupted() throws {
        var stats = GenerationStats(promptTokens: 3, reusedPromptTokens: 0, generatedTokens: 2, timeToFirstToken: 0.1,
                                    promptTokensPerSecond: 30, tokensPerSecond: 10, totalDuration: 0.3,
                                    contextUsed: 5, contextSize: 512, stopReason: .interrupted,
                                    modelID: "model", modelName: "Model")
        stats.interruption = .memoryPressure
        let data = try JSONEncoder().encode(stats)
        #expect(try JSONDecoder().decode(GenerationStats.self, from: data).interruption == .memoryPressure)

        // Replies saved before the field existed still load.
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["interruption"] = nil
        let older = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(GenerationStats.self, from: older)
        #expect(decoded.interruption == nil)
        #expect(decoded.stopReason == .interrupted)
    }
}
