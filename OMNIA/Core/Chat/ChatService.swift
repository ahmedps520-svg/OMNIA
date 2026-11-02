import Foundation
import Observation
import os
import SwiftData

private let chatLog = Logger(subsystem: "app.omnia", category: "chat")

/// Runs conversations: builds prompts from SwiftData history, streams replies from the engine,
/// and persists them. Generation continues if the user navigates away from the chat.
@MainActor
@Observable
final class ChatService {
    /// The reply currently streaming.
    struct LiveReply: Equatable {
        var conversationID: UUID
        var messageID: UUID
        /// Content already present before this run (Continue generation).
        var prefix: String
        var raw = ""
        var opensInReasoning = false
        var parsed = ParsedReply.empty
        var promptProgress: Double?
        var isPreparing = true
        var startedAt = Date()
        var firstTokenAt: Date?
        var chunks = 0

        var displayContent: String { prefix + parsed.content }
    }

    private(set) var live: LiveReply?
    /// Most recent error per conversation, shown inline in the chat.
    private(set) var errors: [UUID: String] = [:]

    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var lastParse = Date.distantPast
    @ObservationIgnored private var lastPersist = Date.distantPast

    private let engine: InferenceEngine
    private let store: ModelStore
    private let settings: AppSettings
    private let container: ModelContainer

    init(engine: InferenceEngine, store: ModelStore, settings: AppSettings, container: ModelContainer) {
        self.engine = engine
        self.store = store
        self.settings = settings
        self.container = container
    }

    private var context: ModelContext { container.mainContext }

    var isBusy: Bool { live != nil }

    func isGenerating(_ conversationID: UUID?) -> Bool {
        guard let conversationID else { return false }
        return live?.conversationID == conversationID
    }

    func clearError(_ conversationID: UUID) { errors[conversationID] = nil }

    // MARK: Model selection

    func model(for conversation: Conversation?) -> InstalledModel? {
        if let id = conversation?.modelID, let model = store.model(id: id) { return model }
        return defaultModel
    }

    var defaultModel: InstalledModel? {
        if let id = settings.defaultModelID, let model = store.model(id: id) { return model }
        return store.sortedByRecentUse.first
    }

    // MARK: Conversations

    func createConversation(modelID: String?) -> Conversation {
        let model = store.model(id: modelID) ?? defaultModel
        let conversation = Conversation(modelID: model?.id, modelName: model?.displayName)
        context.insert(conversation)
        save()
        return conversation
    }

    func setModel(_ model: InstalledModel, for conversation: Conversation) {
        conversation.modelID = model.id
        conversation.modelName = model.displayName
        save()
    }

    func delete(_ conversation: Conversation) {
        if live?.conversationID == conversation.id { stop() }
        context.delete(conversation)
        save()
    }

    // MARK: Actions

    /// Sends a user message and streams the reply. Creates the conversation on first send.
    @discardableResult
    func send(_ text: String, attachments: [AttachmentRecord], in existing: Conversation?, modelID: String?) -> Conversation? {
        let trimmed = text.trimmed
        guard !trimmed.isEmpty || !attachments.isEmpty else { return existing }
        let conversation = existing ?? createConversation(modelID: modelID)
        guard live == nil else {
            errors[conversation.id] = InferenceError.busy.localizedDescription
            return conversation
        }
        errors[conversation.id] = nil

        let user = Message(role: .user, content: trimmed, position: nextPosition(in: conversation))
        user.attachments = attachments
        conversation.messages.append(user)
        if conversation.messages.filter({ $0.role == .user }).count == 1 {
            let source = trimmed.isEmpty ? (attachments.first?.name ?? "Attachment") : trimmed
            conversation.title = source.titleSnippet()
        }
        let reply = makeReply(in: conversation)
        conversation.updatedAt = .now
        save()
        start(conversation: conversation, reply: reply, prefix: "")
        return conversation
    }

    /// Replaces an assistant reply (and anything after it) with a fresh one.
    func regenerate(_ message: Message, in conversation: Conversation) {
        guard live == nil, message.role == .assistant else { return }
        removeMessages(in: conversation, from: message.position)
        let reply = makeReply(in: conversation)
        save()
        start(conversation: conversation, reply: reply, prefix: "")
    }

    /// Edits a user message, discards everything after it and answers again.
    func edit(_ message: Message, to newText: String, in conversation: Conversation) {
        let trimmed = newText.trimmed
        guard live == nil, message.role == .user, !trimmed.isEmpty else { return }
        message.content = trimmed
        removeMessages(in: conversation, from: message.position + 1)
        let reply = makeReply(in: conversation)
        conversation.updatedAt = .now
        save()
        start(conversation: conversation, reply: reply, prefix: "")
    }

    /// Continues a reply that stopped early (output limit, Stop, interruption).
    func continueReply(_ message: Message, in conversation: Conversation) {
        guard live == nil, message.role == .assistant else { return }
        // A reply that stopped inside its reasoning has no answer to extend: start it again.
        if message.content.trimmed.isEmpty {
            regenerate(message, in: conversation)
            return
        }
        message.state = .streaming
        message.errorMessage = nil
        save()
        start(conversation: conversation, reply: message, prefix: message.content)
    }

    func stop() {
        engine.stopGeneration()
    }

    func delete(_ message: Message, in conversation: Conversation) {
        guard live?.messageID != message.id else { return }
        conversation.messages.removeAll { $0.id == message.id }
        context.delete(message)
        save()
    }

    // MARK: Generation

    private func makeReply(in conversation: Conversation) -> Message {
        let model = model(for: conversation)
        let reply = Message(role: .assistant, content: "", position: nextPosition(in: conversation),
                            modelID: model?.id, modelName: model?.displayName, state: .streaming)
        conversation.messages.append(reply)
        return reply
    }

    private func start(conversation: Conversation, reply: Message, prefix: String) {
        guard let model = model(for: conversation) else {
            fail(reply, in: conversation, error: InferenceError.noModelSelected)
            return
        }
        reply.modelID = model.id
        reply.modelName = model.displayName
        if conversation.modelID == nil {
            conversation.modelID = model.id
            conversation.modelName = model.displayName
        }

        let persona = persona(for: conversation)
        var generation = settings.generation.applying(model.settings.generation)
        if let temperature = persona?.temperature { generation.temperature = temperature }
        generation = generation.applying(conversation.overrides)

        let contextTokens = engine.loaded[model.id]?.info.configuration.contextLength
            ?? engine.plan(for: model).contextLength
        let turns = buildTurns(for: conversation, excluding: reply, model: model, persona: persona, contextTokens: contextTokens)
        var request = GenerationRequest(turns: turns, assistantPrefix: prefix.isEmpty ? nil : prefix,
                                        sampling: SamplingParameters(generation), maxTokens: generation.maxOutputTokens)
        if model.facts.thinkingToggle {
            request.templateVariables = reasoningPreference(for: conversation, model: model).templateVariables
        }

        live = LiveReply(conversationID: conversation.id, messageID: reply.id, prefix: prefix)
        lastParse = .distantPast
        lastPersist = .now
        let conversationID = conversation.id
        generationTask = Task { [weak self] in
            await self?.run(model: model, request: request, conversationID: conversationID, reply: reply, prefix: prefix)
        }
    }

    private func run(model: InstalledModel, request: GenerationRequest, conversationID: UUID, reply: Message, prefix: String) async {
        do {
            let stream = try await engine.generate(with: model, request: request)
            live?.isPreparing = false
            for try await event in stream {
                switch event {
                case .started(let prompt):
                    live?.opensInReasoning = prompt.opensInReasoning
                case .promptProgress(let progress):
                    live?.promptProgress = progress
                case .text(let text):
                    live?.raw += text
                    live?.chunks += 1
                    if live?.firstTokenAt == nil { live?.firstTokenAt = .now }
                    if Date().timeIntervalSince(lastParse) > 0.066 { reparse() }
                    if Date().timeIntervalSince(lastPersist) > 4 { persistPartial(reply, prefix: prefix, conversationID: conversationID) }
                case .finished(let stats):
                    reparse()
                    finalize(reply, stats: stats, prefix: prefix, conversationID: conversationID)
                }
            }
        } catch {
            reparse()
            if let conversation = fetchConversation(conversationID) {
                fail(reply, in: conversation, error: error)
            }
        }
        live = nil
        generationTask = nil
    }

    private func reparse() {
        guard var current = live else { return }
        current.parsed = ReasoningParser.parse(current.raw, opensInReasoning: current.opensInReasoning)
        live = current
        lastParse = .now
    }

    private func persistPartial(_ reply: Message, prefix: String, conversationID: UUID) {
        guard let current = live else { return }
        lastPersist = .now
        // The conversation (and this reply with it) may have been deleted while generating.
        guard fetchConversation(conversationID) != nil else { return }
        reply.content = prefix + current.parsed.content
        if prefix.isEmpty { reply.reasoning = current.parsed.reasoning }
        save()
    }

    private func finalize(_ reply: Message, stats: GenerationStats, prefix: String, conversationID: UUID) {
        // Touching a model deleted with its conversation during generation crashes SwiftData.
        guard fetchConversation(conversationID) != nil else { return }
        let parsed = live.map { ReasoningParser.parse($0.raw, opensInReasoning: $0.opensInReasoning) } ?? .empty
        reply.content = prefix + parsed.content
        if prefix.isEmpty {
            reply.reasoning = parsed.reasoning
        } else if let more = parsed.reasoning {
            reply.reasoning = [reply.reasoning, more].compactMap { $0 }.joined(separator: "\n\n")
        }
        var combined = stats
        if !prefix.isEmpty, let previous = reply.stats {
            combined.generatedTokens += previous.generatedTokens
        }
        reply.stats = combined
        switch stats.stopReason {
        case .endOfSequence, .maxTokens: reply.state = .complete
        case .failed: reply.state = .failed
        case .cancelled, .interrupted, .contextFull: reply.state = .interrupted
        }
        if stats.stopReason == .interrupted, reply.errorMessage == nil {
            reply.errorMessage = "Paused to protect the device (background, memory or temperature). Tap Continue to resume."
        }
        if let conversation = fetchConversation(conversationID) {
            conversation.updatedAt = .now
        }
        if stats.generatedTokens > 0 {
            context.insert(InferenceRecord(stats: stats, kind: .chat))
        }
        save()
    }

    private func fail(_ reply: Message, in conversation: Conversation, error: Error) {
        if let partial = live, !partial.parsed.content.isEmpty {
            reply.content = partial.prefix + partial.parsed.content
            reply.reasoning = partial.parsed.reasoning ?? reply.reasoning
        }
        if let inferenceError = error as? InferenceError, case .backgroundExecution = inferenceError {
            reply.state = .interrupted
        } else {
            reply.state = reply.content.isEmpty ? .failed : .interrupted
        }
        reply.errorMessage = error.localizedDescription
        errors[conversation.id] = error.localizedDescription
        chatLog.error("Generation failed: \(error.localizedDescription, privacy: .public)")
        save()
    }

    // MARK: Prompt construction

    func reasoningPreference(for conversation: Conversation, model: InstalledModel) -> ReasoningPreference {
        let enabled = conversation.thinkingEnabled ?? model.settings.thinkingEnabled
        switch enabled {
        case .some(true): return .on
        case .some(false): return .off
        case .none: return .automatic
        }
    }

    private func persona(for conversation: Conversation) -> Persona? {
        guard let id = conversation.personaID else { return nil }
        var descriptor = FetchDescriptor<Persona>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func systemPrompt(for conversation: Conversation, model: InstalledModel, persona: Persona?) -> String {
        if let custom = conversation.systemPrompt?.trimmed, !custom.isEmpty { return custom }
        if let persona, !persona.systemPrompt.trimmed.isEmpty { return persona.systemPrompt }
        if let modelPrompt = model.settings.systemPrompt?.trimmed, !modelPrompt.isEmpty { return modelPrompt }
        return ""
    }

    private func buildTurns(for conversation: Conversation, excluding reply: Message, model: InstalledModel,
                            persona: Persona?, contextTokens: Int) -> [ChatTurn] {
        let history = conversation.orderedMessages.filter { $0.id != reply.id }
        let lastUserText = history.last(where: { $0.role == .user })?.content ?? ""
        // Roughly 3.5 characters per token; documents may use up to ~45% of the window.
        let documentBudget = Int(Double(contextTokens) * 3.5 * 0.45)

        var system = systemPrompt(for: conversation, model: model, persona: persona)
        if !conversation.documentIDs.isEmpty {
            let excerpts = knowledgeExcerpts(ids: conversation.documentIDs, query: lastUserText, budget: documentBudget / 2)
            if !excerpts.isEmpty {
                system += (system.isEmpty ? "" : "\n\n")
                    + "Use these excerpts from the user's documents when they are relevant, and name the document you rely on.\n\n"
                    + excerpts
            }
        }

        var turns: [ChatTurn] = []
        if !system.isEmpty { turns.append(ChatTurn(role: .system, content: system)) }
        for message in history {
            switch message.role {
            case .user:
                turns.append(ChatTurn(role: .user, content: expand(message, budget: documentBudget)))
            case .assistant:
                guard !message.content.trimmed.isEmpty else { continue }
                turns.append(ChatTurn(role: .assistant, content: message.content))
            case .system, .tool:
                continue
            }
        }
        return turns
    }

    /// Inlines attached files, or only their most relevant passages when they are too long.
    private func expand(_ message: Message, budget: Int) -> String {
        let attachments = message.attachments
        guard !attachments.isEmpty else { return message.content }
        let perFile = max(2_000, budget / attachments.count)
        var text = message.content
        for attachment in attachments {
            var body = attachment.text
            var note = ""
            if body.count > perFile {
                let chunks = Retrieval.chunk(body, title: attachment.name)
                let selected = Retrieval.search(message.content.isEmpty ? attachment.name : message.content,
                                                in: chunks, limit: 10, characterBudget: perFile)
                body = selected.map { "[Excerpt \($0.index + 1)]\n\($0.text)" }.joined(separator: "\n\n")
                note = "\n(The file is long; only the passages most relevant to the question are included.)"
            }
            if attachment.kind == .code {
                let language = DocumentExtractor.fenceLanguage(for: attachment.name)
                text += "\n\nAttached file `\(attachment.name)`:\n```\(language)\n\(body)\n```\(note)"
            } else {
                text += "\n\n--- Attached file: \(attachment.name) ---\n\(body)\n--- End of \(attachment.name) ---\(note)"
            }
        }
        return text
    }

    private func knowledgeExcerpts(ids: [UUID], query: String, budget: Int) -> String {
        let descriptor = FetchDescriptor<KnowledgeDocument>(predicate: #Predicate { ids.contains($0.id) })
        guard let documents = try? context.fetch(descriptor), !documents.isEmpty else { return "" }
        let chunks = documents.flatMap { Retrieval.chunk($0.text, title: $0.title) }
        let selected = Retrieval.search(query, in: chunks, limit: 8, characterBudget: budget)
        return selected.map { "[\($0.documentTitle), part \($0.index + 1)]\n\($0.text)" }.joined(separator: "\n\n")
    }

    // MARK: Helpers

    private func nextPosition(in conversation: Conversation) -> Int {
        (conversation.messages.map(\.position).max() ?? -1) + 1
    }

    private func removeMessages(in conversation: Conversation, from position: Int) {
        let doomed = conversation.messages.filter { $0.position >= position }
        conversation.messages.removeAll { $0.position >= position }
        doomed.forEach { context.delete($0) }
    }

    private func fetchConversation(_ id: UUID) -> Conversation? {
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func save() {
        do {
            try context.save()
        } catch {
            chatLog.error("Save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
