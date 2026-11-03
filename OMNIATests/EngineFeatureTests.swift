import Foundation
import Testing
@testable import OMNIA

/// Stop sequences, grammars, saved conversation memory and tool prompts, end to end.
@Suite("llama.cpp runtime features", .serialized,
       .enabled(if: TestModels.available("stories260K.gguf", "stories15M-q8_0.gguf")))
struct EngineFeatureTests {
    @Test func stopSequenceEndsTheReplyBeforeIt() async throws {
        let runtime = try await TestModels.load("stories260K.gguf")
        let full = try await collect(runtime.generate(.user("Once upon a time", maxTokens: 48)))
        let characters = Array(full.text)
        try #require(characters.count > 12, "Output too short: \(full.text.debugDescription)")
        let stop = String(characters[8..<11])
        let expected = String(full.text[..<full.text.range(of: stop)!.lowerBound])

        await runtime.resetCache()
        var request = GenerationRequest.user("Once upon a time", maxTokens: 48)
        request.stopSequences = [stop]
        let cut = try await collect(runtime.generate(request))
        await runtime.close()

        #expect(cut.text == expected)
        #expect(cut.stats?.stopReason == .endOfSequence)
    }

    @Test func grammarAllowsOnlyItsLanguage() async throws {
        let runtime = try await TestModels.load("stories15M-q8_0.gguf")
        var request = GenerationRequest.user("Is the sky blue?", maxTokens: 8)
        request.responseFormat = .grammar(#"root ::= "yes" | "no""#)
        let result = try await collect(runtime.generate(request))
        await runtime.close()

        #expect(["yes", "no"].contains(result.text), "\(result.text.debugDescription)")
        #expect(result.stats?.stopReason == .endOfSequence)
    }

    @Test func jsonModeWritesAnObject() async throws {
        let runtime = try await TestModels.load("stories15M-q8_0.gguf")
        var request = GenerationRequest.user("Describe a cat as JSON.", maxTokens: 160)
        request.responseFormat = .json
        let result = try await collect(runtime.generate(request))
        await runtime.close()

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text.hasPrefix("{"), "\(text.debugDescription)")
        // A tiny model may run out of tokens mid-object; a finished reply must be valid JSON.
        if result.stats?.stopReason == .endOfSequence {
            #expect((try? JSONValue.parse(text))?.objectValue != nil, "\(text.debugDescription)")
        }
    }

    @Test func savedMemoryRestoresInAFreshRuntime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = ConversationMemoryRequest(fileURL: directory.appendingPathComponent("chat.kvstate"),
                                               minimumTokens: 8, maximumBytes: 512 << 20)
        var request = GenerationRequest.user(String(repeating: "Lily went to the park and played with her dog. ", count: 6),
                                             maxTokens: 16)
        request.memory = memory

        let first = try await TestModels.load("stories15M-q8_0.gguf")
        let original = try await collect(first.generate(request))
        await first.close()
        #expect(FileManager.default.fileExists(atPath: memory.fileURL.path(percentEncoded: false)))

        let second = try await TestModels.load("stories15M-q8_0.gguf")
        let restored = try await collect(second.generate(request))
        await second.close()

        let stats = try #require(restored.stats)
        #expect((stats.restoredPromptTokens ?? 0) > 0)
        #expect(stats.reusedPromptTokens > 0)
        #expect(restored.text == original.text)
    }

    @Test func unusableSavesAreDiscarded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("broken.kvstate")
        try Data("not a llama.cpp state".utf8).write(to: file)

        var request = GenerationRequest.user("Once upon a time", maxTokens: 4)
        request.memory = ConversationMemoryRequest(fileURL: file, minimumTokens: 100_000, maximumBytes: 1 << 20)
        let runtime = try await TestModels.load("stories260K.gguf")
        let result = try await collect(runtime.generate(request))
        await runtime.close()

        #expect(result.stats?.restoredPromptTokens == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func templatesWithoutToolsUseTheTextProtocol() async throws {
        // The tool instructions alone are ~650 tokens in this model's tiny vocabulary.
        var configuration = TestModels.cpu
        configuration.contextLength = 2048
        let runtime = try await TestModels.load("stories260K.gguf", configuration: configuration)
        var request = GenerationRequest.user("What is 2+2?", maxTokens: 4)
        request.tools = ChatTemplateParityTests.tools
        var prompt: PromptInfo?
        for try await event in runtime.generate(request) {
            if case .started(let info) = event { prompt = info }
        }
        await runtime.close()

        #expect(prompt?.toolCallFormat == .hermesJSON)
    }
}

@Suite("Saved conversation memory files")
@MainActor
struct ConversationMemoryStoreTests {
    private func makeStore() throws -> (ConversationMemoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (ConversationMemoryStore(directory: directory), directory)
    }

    private func write(_ url: URL, bytes: Int, age: TimeInterval) throws {
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                                              ofItemAtPath: url.path(percentEncoded: false))
    }

    @Test func namesSavesByConversationModelAndSettings() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = UUID()
        let configuration = TestModels.cpu
        var other = configuration
        other.contextLength = 1024
        let a = store.request(conversationID: conversation, modelID: "m", modelSize: 1, configuration: configuration, limitBytes: 1 << 30)
        let b = store.request(conversationID: conversation, modelID: "m", modelSize: 1, configuration: other, limitBytes: 1 << 30)
        let c = store.request(conversationID: conversation, modelID: "n", modelSize: 1, configuration: configuration, limitBytes: 1 << 30)

        #expect(a.fileURL != b.fileURL)
        #expect(a.fileURL != c.fileURL)
        #expect(a.fileURL.lastPathComponent.hasPrefix(conversation.uuidString))
        #expect(a.maximumBytes == (1 << 30) / 2)
    }

    @Test func evictsTheLeastRecentlyUsedFirst() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("a_x_y.kvstate")
        let recent = directory.appendingPathComponent("b_x_y.kvstate")
        try write(old, bytes: 600, age: 3_600)
        try write(recent, bytes: 600, age: 10)

        store.enforceLimit(1_000)
        #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: recent.path(percentEncoded: false)))
        #expect(store.totalBytes == 600)
    }

    @Test func removesByConversationAndByModel() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversation = UUID()
        let mine = store.request(conversationID: conversation, modelID: "m", modelSize: 1, configuration: TestModels.cpu, limitBytes: 1 << 30)
        let other = store.request(conversationID: UUID(), modelID: "n", modelSize: 1, configuration: TestModels.cpu, limitBytes: 1 << 30)
        try write(mine.fileURL, bytes: 10, age: 0)
        try write(other.fileURL, bytes: 10, age: 0)

        store.removeAll(conversationID: conversation)
        #expect(!FileManager.default.fileExists(atPath: mine.fileURL.path(percentEncoded: false)))
        store.removeAll(modelID: "n")
        #expect(!FileManager.default.fileExists(atPath: other.fileURL.path(percentEncoded: false)))
    }
}
