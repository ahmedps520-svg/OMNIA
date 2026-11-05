import Foundation
import Observation
import os
import SwiftData
import UIKit

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
        /// Tools offered for this reply; their call markup is hidden from the text.
        var toolsActive = false
        var toolNames: [String] = []
        /// Tool calls completed so far, and the tool running now ("Calculating").
        var steps: [ToolStep] = []
        var runningTool: String?
        /// Reasoning from earlier rounds of a reply that used tools.
        var priorReasoning: [String] = []

        var displayContent: String {
            prefix + (toolsActive ? ToolCallParser.visibleText(parsed.content, streaming: true) : parsed.content)
        }

        /// The tool call the model is writing now. Its markup is hidden from the reply, so without
        /// this a long call (code to run, say) would look like a reply that stopped.
        var composingCall: PendingToolCall? {
            guard toolsActive, runningTool == nil else { return nil }
            return ToolCallParser.pendingCall(in: parsed.content, tools: toolNames)
        }
    }

    /// Generation rounds per reply; the last one offers no tools, so the model has to answer.
    static let maxToolRounds = 6

    private(set) var live: LiveReply?
    /// Most recent error per conversation, shown inline in the chat.
    private(set) var errors: [UUID: String] = [:]

    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var lastParse = Date.distantPast
    @ObservationIgnored private var lastPersist = Date.distantPast
    /// Set by Stop: no further tool rounds start after the current step.
    @ObservationIgnored private var stopRequested = false
    /// Called with each reply that finished on its own (not stopped or failed); reads it aloud
    /// when that's turned on.
    @ObservationIgnored var onReplyCompleted: ((Message) -> Void)?
    /// The task letting the reply in progress generate in the background (iPad).
    @ObservationIgnored private var backgroundAnswer: BackgroundAnswer?

    /// The reply in progress may go on generating while OMNIA is in the background.
    var holdsBackgroundGPU: Bool { backgroundAnswer?.holdsGPU ?? false }

    private let engine: InferenceEngine
    private let store: ModelStore
    private let settings: AppSettings
    private let container: ModelContainer
    /// Finds document passages by meaning, when the library has an embedding model.
    private let semanticIndex: SemanticIndex?
    /// Runs the code the model writes (run_code), in a sandbox without network.
    private let codeRunner: CodeRunner?
    /// Searches and reads the web for the model, when a conversation allows it.
    private let webReader: WebReader?

    init(engine: InferenceEngine, store: ModelStore, settings: AppSettings, container: ModelContainer,
         semanticIndex: SemanticIndex? = nil, codeRunner: CodeRunner? = nil, webReader: WebReader? = nil) {
        self.engine = engine
        self.store = store
        self.settings = settings
        self.container = container
        self.semanticIndex = semanticIndex
        self.codeRunner = codeRunner
        self.webReader = webReader
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
        engine.conversationMemory.removeAll(conversationID: conversation.id)
        context.delete(conversation)
        save()
    }

    // MARK: Actions

    /// Sends a user message and streams the reply. Creates the conversation on first send.
    /// `images` holds the pictures of the `.image` attachments, by attachment ID.
    @discardableResult
    func send(_ text: String, attachments: [AttachmentRecord], images: [UUID: Data] = [:], in existing: Conversation?,
              modelID: String?) -> Conversation? {
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
        let attachedIDs = Set(attachments.filter { $0.kind == .image }.map(\.id))
        user.images = images.filter { attachedIDs.contains($0.key) }
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
        stopRequested = true
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

        live = LiveReply(conversationID: conversation.id, messageID: reply.id, prefix: prefix)
        stopRequested = false
        lastParse = .distantPast
        lastPersist = .now
        let conversationID = conversation.id
        // On iPads with background GPU access the reply goes on if OMNIA leaves the screen. iOS only
        // grants this in response to a tap, so it's asked for here, before anything is awaited.
        if settings.answerInBackground, !model.isSystem {
            backgroundAnswer = BackgroundAnswer.begin(title: "Writing a reply", modelName: model.displayName,
                                                      maxTokens: settings.generation.maxOutputTokens) { [weak self] in
                self?.stop()
            }
        }
        // With documents attached and an embedding model installed, the question is also matched
        // by meaning: its vector is computed first (shown as "Preparing").
        let question = conversation.orderedMessages.last { $0.role == .user && $0.id != reply.id }?.content ?? ""
        let index = conversation.documentIDs.isEmpty ? nil : semanticIndex.flatMap { $0.isReady ? $0 : nil }
        generationTask = Task { [weak self] in
            let queryVector = await index?.queryVector(question)
            guard let self else { return }
            guard let conversation = self.fetchConversation(conversationID) else {
                self.endBackgroundAnswer(success: false)
                self.live = nil
                self.generationTask = nil
                return
            }
            let prepared = self.makeRequest(for: conversation, reply: reply, model: model, prefix: prefix,
                                            queryVector: queryVector)
            self.live?.toolsActive = !prepared.tools.isEmpty
            self.live?.toolNames = prepared.tools.map { $0.definition.name }
            await self.run(model: model, request: prepared.request, tools: prepared.tools, conversationID: conversationID,
                           reply: reply, prefix: prefix)
        }
    }

    /// The request for `reply`: sampling settings, prompt turns, reasoning, response format and tools.
    private func makeRequest(for conversation: Conversation, reply: Message, model: InstalledModel, prefix: String,
                             queryVector: [Float]?) -> (request: GenerationRequest, tools: [any ChatTool]) {
        let persona = persona(for: conversation)
        var generation = settings.generation.applying(model.settings.generation)
        if let temperature = persona?.temperature { generation.temperature = temperature }
        generation = generation.applying(conversation.overrides)

        let contextTokens = engine.loaded[model.id]?.info.configuration.contextLength
            ?? engine.plan(for: model).contextLength
        // The conversation's tools. Continuing a cut-off reply only extends its text, so it gets no
        // new tool rounds, but its system prompt still names them, as it did for the reply so far.
        let offered = conversation.jsonMode || !toolsEnabled(for: conversation) ? [] : availableTools(for: conversation)
        let turns = buildTurns(for: conversation, excluding: reply, model: model, persona: persona,
                               contextTokens: contextTokens, queryVector: queryVector,
                               toolNames: offered.map { $0.definition.name })
        var request = GenerationRequest(turns: turns, assistantPrefix: prefix.isEmpty ? nil : prefix,
                                        sampling: SamplingParameters(generation), maxTokens: generation.maxOutputTokens)
        // JSON mode needs the reply to be the object itself, so reasoning is switched off.
        if model.facts.thinkingToggle {
            let reasoning = conversation.jsonMode ? ReasoningPreference.off : reasoningPreference(for: conversation, model: model)
            request.templateVariables = reasoning.templateVariables(effort: settings.reasoningEffort)
        }
        if conversation.jsonMode { request.responseFormat = .json }
        // Templates without effort levels (Qwen3.5 and 3.6, Ornith) let the model think as long as
        // it likes; the runtime ends such a block at this many tokens.
        request.reasoningBudget = settings.reasoningEffort.thinkingBudget
        let tools = prefix.isEmpty ? offered : []
        request.tools = tools.map { $0.definition }
        request.memoryKey = conversation.id
        return (request, tools)
    }

    /// Generates a reply. When the model calls tools, runs them and generates again with their
    /// results, until it answers without a call or the round limit is reached.
    private func run(model: InstalledModel, request: GenerationRequest, tools: [any ChatTool],
                     conversationID: UUID, reply: Message, prefix: String) async {
        var request = request
        var combined: GenerationStats?
        var succeeded = false
        do {
            for round in 0..<Self.maxToolRounds {
                if round == Self.maxToolRounds - 1 { request.tools = [] }
                let stream = try await engine.generate(with: model, request: request)
                live?.isPreparing = false
                var format: ToolCallFormat?
                var finished: GenerationStats?
                for try await event in stream {
                    switch event {
                    case .started(let prompt):
                        live?.opensInReasoning = prompt.opensInReasoning
                        format = prompt.toolCallFormat
                    case .promptProgress(let progress):
                        live?.promptProgress = progress
                        backgroundAnswer?.readPrompt(progress)
                    case .text(let text):
                        live?.raw += text
                        live?.chunks += 1
                        backgroundAnswer?.wrote(live?.chunks ?? 0)
                        if live?.firstTokenAt == nil { live?.firstTokenAt = .now }
                        if Date().timeIntervalSince(lastParse) > 0.066 { reparse() }
                        if Date().timeIntervalSince(lastPersist) > 4 { persistPartial(reply, prefix: prefix, conversationID: conversationID) }
                    case .finished(let stats):
                        finished = stats
                    }
                }
                guard let stats = finished else { break }
                combined = combined.map { $0.merged(with: stats) } ?? stats
                reparse()

                guard !request.tools.isEmpty, stats.stopReason == .endOfSequence, !stopRequested,
                      let current = live,
                      let parsed = ToolCallParser.parse(Self.toolText(current, format: format), format: format,
                                                        tools: request.tools) else {
                    let ended = combined ?? stats
                    finalize(reply, stats: ended, prefix: prefix, conversationID: conversationID)
                    succeeded = ended.stopReason == .endOfSequence || ended.stopReason == .maxTokens
                    break
                }

                // Run the calls, then hand their results back for the next round.
                if let reasoning = current.parsed.reasoning, !reasoning.isEmpty { live?.priorReasoning.append(reasoning) }
                var results: [ChatTurn] = []
                for call in parsed.calls {
                    live?.runningTool = tools.first { $0.definition.name == call.name }?.activity ?? "Running \(call.name)"
                    let step = await ToolRunner.run(call, round: round, preface: parsed.preface, tools: tools)
                    live?.steps.append(step)
                    results.append(ChatTurn(role: .tool, content: step.result, toolCallID: step.id, toolName: step.name))
                }
                live?.runningTool = nil
                live?.raw = ""
                live?.parsed = .empty
                live?.opensInReasoning = false
                persistPartial(reply, prefix: prefix, conversationID: conversationID)
                if stopRequested {
                    var stopped = combined ?? stats
                    stopped.stopReason = .cancelled
                    finalize(reply, stats: stopped, prefix: prefix, conversationID: conversationID)
                    break
                }
                request.turns.append(ChatTurn(role: .assistant, content: parsed.preface, toolCalls: parsed.calls))
                request.turns += results
            }
        } catch {
            reparse()
            if let conversation = fetchConversation(conversationID) {
                fail(reply, in: conversation, error: error)
            }
        }
        endBackgroundAnswer(success: succeeded)
        live = nil
        generationTask = nil
    }

    /// Gives the GPU back to iOS once the reply has stopped generating.
    private func endBackgroundAnswer(success: Bool) {
        guard let answer = backgroundAnswer else { return }
        backgroundAnswer = nil
        answer.finish(success: success)
        engine.backgroundGenerationEnded()
    }

    /// Where a model's tool calls appear. Harmony (gpt-oss) and Muse Glimmer write them as separate
    /// messages, which the reasoning parser sets aside; the other formats write them in the answer.
    private static func toolText(_ reply: LiveReply, format: ToolCallFormat?) -> String {
        switch format {
        case .harmony, .atem: reply.raw
        default: reply.parsed.content
        }
    }

    private func reparse() {
        guard var current = live else { return }
        current.parsed = ReasoningParser.parse(current.raw, opensInReasoning: current.opensInReasoning)
        live = current
        lastParse = .now
    }

    /// The reply's text without tool-call markup, and all of its reasoning so far.
    private func visibleParts(of current: LiveReply, streaming: Bool) -> (content: String, reasoning: String?) {
        let parsed = streaming ? current.parsed : ReasoningParser.parse(current.raw, opensInReasoning: current.opensInReasoning)
        let content = current.toolsActive ? ToolCallParser.visibleText(parsed.content, streaming: streaming) : parsed.content
        let reasoning = (current.priorReasoning + [parsed.reasoning ?? ""]).filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (content, reasoning.isEmpty ? nil : reasoning)
    }

    private func persistPartial(_ reply: Message, prefix: String, conversationID: UUID) {
        guard let current = live else { return }
        lastPersist = .now
        // The conversation (and this reply with it) may have been deleted while generating.
        guard fetchConversation(conversationID) != nil else { return }
        let parts = visibleParts(of: current, streaming: true)
        reply.content = prefix + parts.content
        if prefix.isEmpty { reply.reasoning = parts.reasoning }
        if !current.steps.isEmpty { reply.toolSteps = current.steps }
        save()
    }

    private func finalize(_ reply: Message, stats: GenerationStats, prefix: String, conversationID: UUID) {
        // Touching a model deleted with its conversation during generation crashes SwiftData.
        guard fetchConversation(conversationID) != nil else { return }
        let parts = live.map { visibleParts(of: $0, streaming: false) } ?? (content: "", reasoning: nil)
        reply.content = prefix + parts.content
        if prefix.isEmpty {
            reply.reasoning = parts.reasoning
        } else if let more = parts.reasoning {
            reply.reasoning = [reply.reasoning, more].compactMap { $0 }.joined(separator: "\n\n")
        }
        if let steps = live?.steps, !steps.isEmpty { reply.toolSteps = steps }
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
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            reply.errorMessage = stats.interruption?.pauseMessage(device: device)
                ?? "Paused because OMNIA left the screen, or this \(device) ran low on memory or got too hot. Tap Continue to resume."
        }
        if let conversation = fetchConversation(conversationID) {
            conversation.updatedAt = .now
        }
        if stats.generatedTokens > 0 {
            context.insert(InferenceRecord(stats: stats, kind: .chat))
        }
        save()
        if reply.state == .complete {
            onReplyCompleted?(reply)
        }
    }

    private func fail(_ reply: Message, in conversation: Conversation, error: Error) {
        if let partial = live {
            let parts = visibleParts(of: partial, streaming: false)
            if !parts.content.isEmpty {
                reply.content = partial.prefix + parts.content
                reply.reasoning = parts.reasoning ?? reply.reasoning
            }
            if !partial.steps.isEmpty { reply.toolSteps = partial.steps }
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

    // MARK: Tools

    func toolsEnabled(for conversation: Conversation) -> Bool {
        conversation.toolsEnabled ?? settings.toolsEnabledByDefault
    }

    /// Web search and page reading, which only happen when allowed and never in Offline-only mode.
    func webAccessEnabled(for conversation: Conversation) -> Bool {
        !settings.offlineOnly && (conversation.webAccessEnabled ?? settings.webAccessByDefault)
    }

    /// The tools offered in this conversation. Document search appears when documents are
    /// attached, web search and page reading when web access is on.
    private func availableTools(for conversation: Conversation) -> [any ChatTool] {
        var tools: [any ChatTool] = [CalculatorTool(), DateTimeTool()]
        if let codeRunner {
            tools.append(RunCodeTool(runner: codeRunner, languages: CodeRunner.Language.allCases.filter { codeRunner.isAvailable($0) }))
        }
        if let webReader, webAccessEnabled(for: conversation) {
            tools += [WebSearchTool(reader: webReader), OpenURLTool(reader: webReader)] as [any ChatTool]
        }
        if !conversation.documentIDs.isEmpty {
            let ids = conversation.documentIDs
            let descriptor = FetchDescriptor<KnowledgeDocument>(predicate: #Predicate { ids.contains($0.id) })
            let indexed = indexedChunks(of: (try? context.fetch(descriptor)) ?? [])
            if !indexed.chunks.isEmpty {
                var embed: (@Sendable (String) async -> [Float]?)?
                if indexed.hasVectors, let index = semanticIndex {
                    embed = { query in await index.queryVector(query) }
                }
                tools.append(DocumentSearchTool(indexed: indexed, embed: embed))
            }
        }
        return tools
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

    /// What a model is told when nobody wrote it a system prompt: where it runs, what OMNIA does with
    /// its answers, and the tools it has. Without it, models don't know their tools or the workspace.
    nonisolated static func defaultSystemPrompt(device: String, tools: [String], date: Date) -> String {
        var parts = [
            "You are OMNIA, a private assistant running entirely on the user's \(device). Today is \(date.formatted(date: .complete, time: .omitted)).",
            "Answer directly. Think as much as the task needs, then commit to an answer instead of second-guessing settled points.",
            "When you write code, a document or any file, give its complete content in one fenced code block tagged with its language (swift, html, markdown, python…). OMNIA's workspace shows every block: web pages, SVG and Markdown render live, and JavaScript and Python run on the device. Swift can't be built here, so give complete files the user can paste into Xcode or Swift Playgrounds."
        ]
        if !tools.isEmpty {
            parts.append("You can call these tools: \(tools.joined(separator: ", ")). Use one whenever it makes the answer more reliable, for example run_code to check code or compute exactly, and say what you found. Never claim you have no tools.")
        }
        return parts.joined(separator: "\n\n")
    }

    private func systemPrompt(for conversation: Conversation, model: InstalledModel, persona: Persona?) -> String {
        if let custom = conversation.systemPrompt?.trimmed, !custom.isEmpty { return custom }
        if let persona, !persona.systemPrompt.trimmed.isEmpty { return persona.systemPrompt }
        if let modelPrompt = model.settings.systemPrompt?.trimmed, !modelPrompt.isEmpty { return modelPrompt }
        return ""
    }

    private func buildTurns(for conversation: Conversation, excluding reply: Message, model: InstalledModel,
                            persona: Persona?, contextTokens: Int, queryVector: [Float]? = nil,
                            toolNames: [String] = []) -> [ChatTurn] {
        let history = conversation.orderedMessages.filter { $0.id != reply.id }
        let lastUserText = history.last(where: { $0.role == .user })?.content ?? ""
        // Roughly 3.5 characters per token; documents may use up to ~45% of the window.
        let documentBudget = Int(Double(contextTokens) * 3.5 * 0.45)

        var system = systemPrompt(for: conversation, model: model, persona: persona)
        if system.isEmpty {
            system = Self.defaultSystemPrompt(device: engine.device.isPad ? "iPad" : "iPhone", tools: toolNames, date: .now)
        }
        if !conversation.documentIDs.isEmpty {
            let excerpts = knowledgeExcerpts(ids: conversation.documentIDs, query: lastUserText, queryVector: queryVector,
                                             budget: documentBudget / 2)
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
                var turn = ChatTurn(role: .user, content: expand(message, budget: documentBudget))
                turn.images = message.orderedImages.map(\.data)
                turns.append(turn)
            case .assistant:
                // Tools used for this reply, in the order they ran, so the model knows what it found.
                let steps = message.toolSteps
                for round in Set(steps.map(\.round)).sorted() {
                    let roundSteps = steps.filter { $0.round == round }
                    turns.append(ChatTurn(role: .assistant, content: roundSteps.first?.preface ?? "",
                                          toolCalls: roundSteps.map(\.call)))
                    for step in roundSteps {
                        turns.append(ChatTurn(role: .tool, content: step.result, toolCallID: step.id, toolName: step.name))
                    }
                }
                guard !message.content.trimmed.isEmpty else { continue }
                turns.append(ChatTurn(role: .assistant, content: message.content))
            case .system, .tool:
                continue
            }
        }
        Self.limitImages(&turns, supported: model.supportsImages, keep: Self.imageLimit(contextTokens: contextTokens))
        return turns
    }

    /// Images a prompt carries at most: each takes up to 1,024 tokens (a quarter of smaller
    /// contexts), so images never fill more than about half the window.
    nonisolated static func imageLimit(contextTokens: Int) -> Int {
        min(4, max(1, contextTokens / 2048))
    }

    /// Keeps the newest `keep` images (none when the model can't see images). Every image left
    /// out becomes a short note in its turn, so the model knows something was shown.
    nonisolated static func limitImages(_ turns: inout [ChatTurn], supported: Bool, keep: Int) {
        var remaining = supported ? max(0, keep) : 0
        for index in turns.indices.reversed() where !turns[index].images.isEmpty {
            let count = turns[index].images.count
            let kept = min(count, remaining)
            remaining -= kept
            guard kept < count else { continue }
            let dropped = count - kept
            turns[index].images = Array(turns[index].images.prefix(kept))
            let note: String
            if supported {
                note = dropped == 1 ? "[An image shown here was left out to save memory.]"
                    : "[\(dropped) images shown here were left out to save memory.]"
            } else {
                note = dropped == 1 ? "[The user attached an image, but this model can't view images.]"
                    : "[The user attached \(dropped) images, but this model can't view images.]"
            }
            let content = turns[index].content
            turns[index].content = content.isEmpty ? note : note + "\n\n" + content
        }
    }

    /// Inlines attached files, or only their most relevant passages when they are too long.
    /// Images aren't text: they travel with the turn itself.
    private func expand(_ message: Message, budget: Int) -> String {
        let attachments = message.attachments.filter { $0.kind != .image }
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

    private func knowledgeExcerpts(ids: [UUID], query: String, queryVector: [Float]?, budget: Int) -> String {
        let descriptor = FetchDescriptor<KnowledgeDocument>(predicate: #Predicate { ids.contains($0.id) })
        guard let documents = try? context.fetch(descriptor), !documents.isEmpty else { return "" }
        let indexed = indexedChunks(of: documents)
        let selected = Retrieval.search(query, in: indexed.chunks, similarities: queryVector.map(indexed.similarities),
                                        limit: 8, characterBudget: budget)
        return selected.map { "[\($0.documentTitle), part \($0.index + 1)]\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// The documents' passages, with meaning vectors when the library has an embedding model.
    private func indexedChunks(of documents: [KnowledgeDocument]) -> IndexedChunks {
        semanticIndex?.chunks(of: documents) ?? IndexedChunks(documents: documents)
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
