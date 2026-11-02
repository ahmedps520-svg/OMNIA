import Foundation
import Observation
import SwiftData

/// Sends one prompt to two models and streams both answers.
///
/// The models run one after the other, never at the same time: each gets the whole GPU, so
/// the timings are comparable. If both don't fit in memory together, the engine swaps them.
@MainActor
@Observable
final class CompareService {
    enum SideState: Equatable {
        case idle, waiting, preparing, generating, done
        case failed(String)
    }

    struct Side: Equatable {
        var modelID: String?
        var raw = ""
        var opensInReasoning = false
        var parsed = ParsedReply.empty
        var stats: GenerationStats?
        var state: SideState = .idle
        var promptProgress: Double?

        mutating func reset() {
            raw = ""
            parsed = .empty
            stats = nil
            state = .idle
            promptProgress = nil
        }
    }

    var left = Side()
    var right = Side()
    private(set) var isRunning = false
    private(set) var lastPrompt = ""

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelled = false

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

    var canRun: Bool {
        !isRunning && left.modelID != nil && right.modelID != nil && !engine.isBusy
    }

    func run(prompt: String, systemPrompt: String) {
        guard canRun, let leftModel = store.model(id: left.modelID), let rightModel = store.model(id: right.modelID) else { return }
        let text = prompt.trimmed
        guard !text.isEmpty else { return }
        lastPrompt = text
        left.reset()
        right.reset()
        left.state = .waiting
        right.state = .waiting
        isRunning = true
        cancelled = false

        var turns: [ChatTurn] = []
        if !systemPrompt.trimmed.isEmpty { turns.append(ChatTurn(role: .system, content: systemPrompt.trimmed)) }
        turns.append(ChatTurn(role: .user, content: text))
        let generation = settings.generation

        task = Task { [weak self] in
            guard let self else { return }
            await self.generate(side: \.left, model: leftModel, turns: turns, generation: generation)
            if !self.cancelled {
                await self.generate(side: \.right, model: rightModel, turns: turns, generation: generation)
            } else {
                self.right.state = .idle
            }
            self.saveRecord(prompt: text, system: systemPrompt, leftModel: leftModel, rightModel: rightModel)
            self.isRunning = false
            self.task = nil
        }
    }

    func stop() {
        cancelled = true
        engine.stopGeneration()
    }

    private func generate(side: ReferenceWritableKeyPath<CompareService, Side>, model: InstalledModel,
                          turns: [ChatTurn], generation: GenerationSettings) async {
        self[keyPath: side].state = .preparing
        var request = GenerationRequest(turns: turns, sampling: SamplingParameters(generation.applying(model.settings.generation)),
                                        maxTokens: generation.maxOutputTokens)
        // Comparisons start from a clean cache so prompt timings are fair.
        request.reusePromptCache = false
        do {
            let stream = try await engine.generate(with: model, request: request)
            for try await event in stream {
                switch event {
                case .started(let prompt):
                    self[keyPath: side].opensInReasoning = prompt.opensInReasoning
                case .promptProgress(let progress):
                    self[keyPath: side].promptProgress = progress
                case .text(let text):
                    self[keyPath: side].state = .generating
                    self[keyPath: side].raw += text
                    let current = self[keyPath: side]
                    self[keyPath: side].parsed = ReasoningParser.parse(current.raw, opensInReasoning: current.opensInReasoning)
                case .finished(let stats):
                    self[keyPath: side].stats = stats
                    if stats.generatedTokens > 0 {
                        container.mainContext.insert(InferenceRecord(stats: stats, kind: .compare))
                    }
                }
            }
            let current = self[keyPath: side]
            self[keyPath: side].parsed = ReasoningParser.parse(current.raw, opensInReasoning: current.opensInReasoning)
            self[keyPath: side].state = .done
        } catch {
            self[keyPath: side].state = .failed(error.localizedDescription)
        }
    }

    private func saveRecord(prompt: String, system: String, leftModel: InstalledModel, rightModel: InstalledModel) {
        guard left.stats != nil || right.stats != nil else { return }
        let record = ComparisonRecord(prompt: prompt, systemPrompt: system.trimmed.isEmpty ? nil : system,
                                      left: (leftModel.id, leftModel.displayName), right: (rightModel.id, rightModel.displayName))
        record.leftResponse = left.parsed.content
        record.rightResponse = right.parsed.content
        record.leftStats = left.stats
        record.rightStats = right.stats
        container.mainContext.insert(record)
        try? container.mainContext.save()
    }
}
