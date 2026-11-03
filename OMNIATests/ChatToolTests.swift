import Foundation
import SwiftData
import Testing
@testable import OMNIA

/// A backend that replies with scripted text, recording every request it gets.
final class ScriptedBackend: InferenceBackend, @unchecked Sendable {
    let info: LoadedModelInfo
    private(set) var requests: [GenerationRequest] = []
    private var replies: [String]

    init(modelID: String, replies: [String]) {
        self.replies = replies
        info = LoadedModelInfo(modelID: modelID, displayName: "Scripted", architecture: "llama",
                               configuration: TestModels.cpu, trainContextLength: 512, parameterCount: 1,
                               tensorBytes: 1, measuredFootprintBytes: 0, measuredGPUBytes: 0, loadDuration: 0,
                               chatTemplate: nil, supportsThinkingToggle: false)
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        requests.append(request)
        let text = replies.isEmpty ? "(no more scripted replies)" : replies.removeFirst()
        let stats = GenerationStats(promptTokens: 10, reusedPromptTokens: 0, generatedTokens: 5, timeToFirstToken: 0.01,
                                    promptTokensPerSecond: 100, tokensPerSecond: 50, totalDuration: 0.1, contextUsed: 15,
                                    contextSize: 512, stopReason: .endOfSequence, modelID: info.modelID,
                                    modelName: info.displayName)
        let format: ToolCallFormat? = request.tools.isEmpty ? nil : .hermesJSON
        return AsyncThrowingStream { continuation in
            continuation.yield(.started(PromptInfo(opensInReasoning: false, toolCallFormat: format)))
            continuation.yield(.text(text))
            continuation.yield(.finished(stats))
            continuation.finish()
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

/// The app's services wired together around a scripted backend, with isolated storage.
@MainActor
final class ChatHarness {
    let settings: AppSettings
    let store: ModelStore
    let engine: InferenceEngine
    let chat: ChatService
    let container: ModelContainer
    let backend: ScriptedBackend
    let model: InstalledModel
    private let directory: URL

    init(replies: [String]) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("omnia-chat-\(UUID().uuidString)", isDirectory: true)
        settings = AppSettings(defaults: try #require(UserDefaults(suiteName: "omnia-tests-\(UUID().uuidString)")))
        store = ModelStore(directory: directory)
        // Any real GGUF works: the scripted backend never reads it.
        let source = try #require(TestModels.url("stories260K.gguf"))
        let info = try GGUFInspector.inspect(fileAt: source).info
        model = try store.install(fileAt: source, id: "test/stories260K.gguf", displayName: "Stories", developer: nil,
                                  repo: "test", fileName: "stories260K.gguf", sha256: nil, verification: .structureValid,
                                  info: info, license: nil, origin: .imported, catalogID: nil, moveFile: false)
        engine = InferenceEngine(store: store, settings: settings, device: DeviceProfile.detect(), monitor: PerformanceMonitor(),
                                 conversationMemory: ConversationMemoryStore(directory: directory.appendingPathComponent("memory")))
        let scripted = ScriptedBackend(modelID: model.id, replies: replies)
        backend = scripted
        engine.loadBackend = { _, _, _, _ in scripted }
        container = try ModelContainer(for: Schema(PersistenceSchema.models),
                                       configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        chat = ChatService(engine: engine, store: store, settings: settings, container: container)
    }

    func send(_ text: String, attachments: [AttachmentRecord] = [], images: [UUID: Data] = [:],
              in conversation: Conversation? = nil) async throws -> Conversation {
        let conversation = try #require(chat.send(text, attachments: attachments, images: images, in: conversation,
                                                  modelID: model.id))
        var waited = 0
        while chat.isBusy, waited < 500 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(!chat.isBusy, "The reply didn't finish")
        return conversation
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Chat with tools", .serialized, .enabled(if: TestModels.available("stories260K.gguf")))
@MainActor
struct ChatToolTests {
    static let calculatorCall = #"<tool_call>{"name": "calculator", "arguments": {"expression": "17*23"}}</tool_call>"#

    @Test func runsAToolAndAnswersWithItsResult() async throws {
        let harness = try ChatHarness(replies: [Self.calculatorCall, "17 × 23 = 391."])
        let conversation = try await harness.send("What is 17 * 23?")
        let reply = try #require(conversation.orderedMessages.last)

        #expect(reply.content == "17 × 23 = 391.")
        #expect(reply.state == .complete)
        #expect(reply.toolSteps.map(\.name) == ["calculator"])
        #expect(reply.toolSteps.first?.result == "391")
        #expect(reply.toolSteps.first?.failed == false)
        #expect(reply.stats?.generatedTokens == 10)

        let requests = harness.backend.requests
        #expect(requests.count == 2)
        #expect(requests.first?.tools.map(\.name).contains("calculator") == true)
        let followUp = try #require(requests.last)
        #expect(followUp.turns.suffix(2).map(\.role) == [.assistant, .tool])
        #expect(followUp.turns.last?.content == "391")
        #expect(followUp.turns.last?.toolCallID == followUp.turns.dropLast().last?.toolCalls.first?.id)
    }

    @Test func reportsUnknownToolsToTheModel() async throws {
        let harness = try ChatHarness(replies: [#"<tool_call>{"name": "teleport", "arguments": {}}</tool_call>"#,
                                                "I can't do that."])
        let conversation = try await harness.send("Teleport me.")
        let step = try #require(conversation.orderedMessages.last?.toolSteps.first)

        #expect(step.failed)
        #expect(step.result.hasPrefix("Error:"))
        #expect(step.result.contains("calculator"))
    }

    @Test func theLastRoundHasToAnswer() async throws {
        let harness = try ChatHarness(replies: Array(repeating: Self.calculatorCall, count: ChatService.maxToolRounds))
        let conversation = try await harness.send("Loop forever.")
        let reply = try #require(conversation.orderedMessages.last)

        #expect(harness.backend.requests.count == ChatService.maxToolRounds)
        #expect(harness.backend.requests.last?.tools.isEmpty == true)
        #expect(reply.toolSteps.count == ChatService.maxToolRounds - 1)
        #expect(reply.state == .complete)
    }

    @Test func jsonModeOffersNoTools() async throws {
        let harness = try ChatHarness(replies: [#"{"answer": 391}"#])
        let conversation = harness.chat.createConversation(modelID: harness.model.id)
        conversation.jsonMode = true
        _ = try await harness.send("17 * 23 as JSON", in: conversation)
        let request = try #require(harness.backend.requests.first)

        #expect(request.tools.isEmpty)
        #expect(request.responseFormat == .json)
        #expect(conversation.orderedMessages.last?.content == #"{"answer": 391}"#)
    }

    @Test func laterTurnsSeeEarlierToolSteps() async throws {
        let harness = try ChatHarness(replies: [Self.calculatorCall, "It's 391.", "You're welcome."])
        let conversation = try await harness.send("What is 17 * 23?")
        _ = try await harness.send("Thanks!", in: conversation)
        let request = try #require(harness.backend.requests.last)
        let roles = request.turns.map(\.role)

        #expect(roles.suffix(5) == [.user, .assistant, .tool, .assistant, .user])
        #expect(request.turns.first(where: { !$0.toolCalls.isEmpty })?.toolCalls.first?.name == "calculator")
    }

    @Test func toolsCanBeTurnedOffPerConversation() async throws {
        let harness = try ChatHarness(replies: ["Just text."])
        let conversation = harness.chat.createConversation(modelID: harness.model.id)
        conversation.toolsEnabled = false
        _ = try await harness.send("Hello", in: conversation)

        #expect(harness.backend.requests.first?.tools.isEmpty == true)
    }
}
