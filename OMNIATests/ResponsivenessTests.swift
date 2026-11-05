import Foundation
import Observation
import Testing
import UIKit
@testable import OMNIA

/// Set from an Observation `onChange` (which may run on any thread).
final class ObservedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() { lock.withLock { raised = true } }
    var isRaised: Bool { lock.withLock { raised } }
}

/// Counts how often what `read` reads changes, by tracking it again after each change.
@MainActor
final class ChangeCounter {
    private(set) var count = 0

    func track(_ read: @escaping @MainActor @Sendable () -> Void) {
        withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.count += 1
                self.track(read)
            }
        }
    }
}

/// A reply written in many small pieces, a few milliseconds apart, as a model streams it.
final class ChunkedBackend: InferenceBackend, @unchecked Sendable {
    let info: LoadedModelInfo
    private let chunks: [String]

    init(modelID: String, chunks: [String]) {
        self.chunks = chunks
        info = LoadedModelInfo(modelID: modelID, displayName: "Chunked", architecture: "llama",
                               configuration: TestModels.cpu, trainContextLength: 512, parameterCount: 1,
                               tensorBytes: 1, measuredFootprintBytes: 0, measuredGPUBytes: 0, loadDuration: 0,
                               chatTemplate: nil, supportsThinkingToggle: false)
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let chunks = chunks
        let modelID = info.modelID
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(PromptInfo(opensInReasoning: false, toolCallFormat: nil)))
                for chunk in chunks {
                    continuation.yield(.text(chunk))
                    try? await Task.sleep(for: .milliseconds(5))
                }
                continuation.yield(.finished(GenerationStats(
                    promptTokens: 4, reusedPromptTokens: 0, generatedTokens: chunks.count, timeToFirstToken: 0.01,
                    promptTokensPerSecond: 100, tokensPerSecond: 50, totalDuration: 0.3, contextUsed: 4 + chunks.count,
                    contextSize: 512, stopReason: .endOfSequence, modelID: modelID, modelName: "Chunked")))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func interrupt(_ reason: InterruptReason) {}
    func setPacing(_ pacing: Duration) {}
    func resetCache() async {}
    func countTokens(_ text: String) async -> Int { max(1, text.count / 4) }
    func benchmark(promptLength: Int, generateLength: Int, repetitions: Int,
                   progress: @escaping @Sendable (Double) -> Void) async throws -> BenchmarkMeasurement {
        throw CancellationError()
    }
    func close() async {}
}

/// Work done once instead of on every redraw.
@Suite("Responsiveness")
@MainActor
struct ResponsivenessTests {
    @Test func aMemoComputesOncePerKey() {
        let memo = Memo<Int, String>()
        var computed = 0
        let compute = { () -> String in
            computed += 1
            return "value \(computed)"
        }
        #expect(memo.value(for: 1, compute: compute) == "value 1")
        #expect(memo.value(for: 1, compute: compute) == "value 1")
        #expect(memo.value(for: 2, compute: compute) == "value 2")
        #expect(computed == 2)
    }

    @Test func planningIgnoresMemoryThatOnlyJitters() {
        let budget = MemoryBudget(measuredAvailable: nil, reclaimable: 0, residentLimit: 8 << 30, footprintLimit: 6 << 30,
                                  physicalMemory: 12 << 30, gpuWorkingSet: nil)
        func phone(memory: UInt64, latency: Double) -> ClusterDevice {
            ClusterDevice(id: "phone/0", name: "iPhone 18 Pro", endpoint: "10.0.0.4:50052", deviceIndex: 0,
                          memoryBudget: memory, bandwidthGBs: 115, latencyMs: latency)
        }
        let now = PlanningInputs(budget: budget, devices: [phone(memory: 6 << 30, latency: 4)], settings: ["quality"])
        var jitter = budget
        jitter.residentLimit += 10 << 20
        #expect(PlanningInputs(budget: jitter, devices: [phone(memory: (6 << 30) + (20 << 20), latency: 4.2)],
                               settings: ["quality"]) == now)

        var smaller = budget
        smaller.residentLimit -= 512 << 20
        #expect(PlanningInputs(budget: smaller, devices: [phone(memory: 6 << 30, latency: 4)], settings: ["quality"]) != now)
        #expect(PlanningInputs(budget: budget, devices: [], settings: ["quality"]) != now)
        #expect(PlanningInputs(budget: budget, devices: [phone(memory: 6 << 30, latency: 4)], settings: ["efficiency"]) != now)
    }

    @Test func aQRCodeIsDrawnOncePerText() throws {
        let link = "omnia://cluster?host=192.168.1.20:8770&code=K7Q2XM4P9T&name=iPad"
        let first = try #require(QRCodeView.image(for: link))
        #expect(QRCodeView.image(for: link) === first)
        #expect(QRCodeView.image(for: link + "2") !== first)
    }
}

/// The chat's state as the screen reads it.
@Suite("Chat state", .serialized, .enabled(if: TestModels.available("stories260K.gguf")))
@MainActor
struct ChatStateTests {
    private func waitForReply(_ harness: ChatHarness) async throws {
        var waited = 0
        while harness.chat.isBusy, waited < 500 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(!harness.chat.isBusy, "The reply didn't finish")
    }

    /// The new chat screen chooses its conversation's ID, so its first message doesn't move it to another screen.
    @Test func aNewChatsConversationGetsTheIDItsScreenChose() async throws {
        let harness = try ChatHarness(replies: ["Hello."])
        let chosen = UUID()
        let conversation = try #require(harness.chat.send("Hi", attachments: [], in: nil, modelID: harness.model.id,
                                                          newConversationID: chosen))
        #expect(conversation.id == chosen)
        try await waitForReply(harness)
        #expect(conversation.orderedMessages.last?.content == "Hello.")
    }

    /// The sidebar, menus and composer read whether a reply runs; that must not change with every token.
    @Test func generatingChangesOnlyWhenAReplyStartsAndEnds() async throws {
        let harness = try ChatHarness(replies: [])
        let backend = ChunkedBackend(modelID: harness.model.id, chunks: (1...40).map { "word\($0) " })
        harness.engine.loadBackend = { _, _, _, _ in backend }

        let generating = ChangeCounter()
        generating.track { _ = harness.chat.isBusy; _ = harness.engine.isGenerating }
        let reply = ChangeCounter()
        reply.track { _ = harness.chat.live }

        _ = try #require(harness.chat.send("Count to forty.", attachments: [], in: nil, modelID: harness.model.id))
        try await waitForReply(harness)
        try await Task.sleep(for: .milliseconds(50))

        // Started and ended, for the chat and for the engine.
        #expect(generating.count <= 4, "changed \(generating.count) times")
        #expect(generating.count >= 1)
        // The reply itself changed with its tokens.
        #expect(reply.count > 4, "the reply changed only \(reply.count) times")
        #expect(!harness.engine.isGenerating)
    }
}
