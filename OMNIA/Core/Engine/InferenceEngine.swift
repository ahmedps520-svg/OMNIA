import Foundation
import Observation
import os
import UIKit

private let engineLog = Logger(subsystem: "app.omnia", category: "engine")

/// A notice shown briefly to the user (e.g. "Model unloaded to free memory").
struct EngineNotice: Identifiable, Equatable, Sendable {
    let id = UUID()
    let symbol: String
    let message: String
}

/// Live state of the generation in progress.
struct LiveGeneration: Equatable, Sendable {
    var modelID: String
    var modelName: String
    var startedAt: Date
    var promptProgress: Double?
    var generatedChunks: Int
    var firstTokenAt: Date?
}

/// Owns every loaded model. Decides what can be loaded from measured memory limits, unloads
/// automatically under pressure, in the background and when idle, and serializes generation
/// (one GPU, one response at a time).
@MainActor
@Observable
final class InferenceEngine {
    struct LoadedModel: Identifiable {
        let id: String
        let backend: any InferenceBackend
        let plan: LoadPlan
        var lastUsed: Date
        /// How the model is spread when it runs on the cluster this device hosts.
        var cluster: ClusterPlan? = nil
        var info: LoadedModelInfo { backend.info }
    }

    private(set) var loaded: [String: LoadedModel] = [:]
    private(set) var loadingModelID: String?
    private(set) var loadProgress: Double = 0
    private(set) var live: LiveGeneration?
    private(set) var isBenchmarking = false
    private(set) var notice: EngineNotice?
    private(set) var lastStats: GenerationStats?
    /// Draft model attached to each loaded model (speculative decoding), by model ID.
    private(set) var drafts: [String: String] = [:]

    @ObservationIgnored private var activeBackend: (any InferenceBackend)?
    @ObservationIgnored private var activeMemoryURL: URL?
    @ObservationIgnored private var inBackground = false
    /// In the background with a reply still generating there: releasing models waits for it.
    @ObservationIgnored private var backgroundDeferred = false

    typealias BackendLoader = @Sendable (_ model: InstalledModel, _ file: URL, _ configuration: RuntimeConfiguration,
                                         _ progress: @escaping @Sendable (Double) -> Void) async throws -> any InferenceBackend
    /// Creates the backend for a model: llama.cpp. Tests substitute scripted backends.
    @ObservationIgnored var loadBackend: BackendLoader = { model, file, configuration, progress in
        if model.isMLX {
            return try await MLXRuntime.load(model: model, folder: file, configuration: configuration, progress: progress)
        }
        // The image encoder lives next to the model file (both in the Models directory).
        let projector = model.projector.map { file.deletingLastPathComponent().appending(path: $0.relativePath) }
        return try await LlamaRuntime.load(modelID: model.id, displayName: model.displayName, fileURL: file,
                                           projectorURL: projector, configuration: configuration, progress: progress)
    }
    /// The devices of the cluster this device hosts, ready to take layers (empty or nil without one).
    @ObservationIgnored var clusterDevices: (@MainActor () -> [ClusterDevice])?
    /// Told which workers dropped out of a model, so the next plan leaves them out until they
    /// check in again.
    @ObservationIgnored var onClusterDevicesLost: (@MainActor ([String]) -> Void)?
    @ObservationIgnored private var idleTimer: Timer?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var backgroundUnloadWork: DispatchWorkItem?
    @ObservationIgnored private var unloadedForBackground: [String] = []
    @ObservationIgnored private var loadTask: Task<LoadedModel, Error>?

    private let store: ModelStore
    private let settings: AppSettings
    let device: DeviceProfile
    private let monitor: PerformanceMonitor
    /// Saved model memory of long conversations (see `ConversationMemoryStore`).
    let conversationMemory: ConversationMemoryStore

    init(store: ModelStore, settings: AppSettings, device: DeviceProfile, monitor: PerformanceMonitor,
         conversationMemory: ConversationMemoryStore = ConversationMemoryStore()) {
        self.store = store
        self.settings = settings
        self.device = device
        self.monitor = monitor
        self.conversationMemory = conversationMemory
        monitor.onMemoryPressure = { [weak self] level in self?.handleMemoryPressure(level) }
        monitor.onThermalChange = { [weak self] state in self?.handleThermalChange(state) }
        store.willDeleteModel = { [weak self] model in
            await self?.unload(model.id)
            await self?.conversationMemory.removeAll(modelID: model.id)
        }
        store.projectorDidChange = { [weak self] model in
            await self?.projectorChanged(model)
        }
        scheduleIdleCheck()
    }

    private var conversationMemoryLimit: Int64 {
        Int64(max(0, settings.conversationMemoryLimitGB) * 1_073_741_824)
    }

    var profile: OptimizationProfile { OptimizationProfile.resolve(device: device, preference: settings.profilePreference) }
    var isGenerating: Bool { live != nil }
    var isBusy: Bool { live != nil || isBenchmarking || loadingModelID != nil }
    var loadedModels: [LoadedModel] { loaded.values.sorted { $0.lastUsed > $1.lastUsed } }

    func isLoaded(_ id: String) -> Bool { loaded[id] != nil }

    // MARK: Budget & planning

    /// Limits measured as if every loaded model were released.
    func currentBudget() -> MemoryBudget {
        let reclaimable = loaded.values.reduce(UInt64(0)) { $0 + $1.info.measuredFootprintBytes }
        return MemoryPlanner.budget(device: device, profile: profile, safety: settings.memorySafety, reclaimable: reclaimable)
    }

    /// Plans a load for `model` using its own settings, then the global defaults.
    /// With `keepingLoaded`, memory already promised to other loaded models is set aside.
    func plan(for model: InstalledModel, budget: MemoryBudget? = nil, keepingLoaded: Bool = false) -> LoadPlan {
        if model.isSystem { return Self.systemPlan }
        var allowance = (budget ?? currentBudget()).allowance
        if keepingLoaded {
            for other in loaded.values where other.id != model.id {
                allowance = allowance.reserving(other.plan.estimate)
            }
        }
        let requested = model.settings.contextLength ?? (settings.contextLength > 0 ? settings.contextLength : nil)
        // With image support installed, room is kept for the image encoder, which loads with the
        // first image.
        return MemoryPlanner.plan(model.facts, fileSize: model.sizeBytes + model.projectorReserve, requestedContext: requested,
                                  kvChoice: model.settings.kvCache ?? settings.kvCache, profile: profile,
                                  allowance: allowance, flashAttention: settings.flashAttention)
    }

    /// The best layout for `model` over this device and its cluster's workers, or nil without
    /// workers, for models the cluster can't run (MLX, Apple's), or when it doesn't fit even there.
    func clusterPlan(for model: InstalledModel, budget: MemoryBudget? = nil) -> ClusterPlan? {
        guard !model.isMLX, !model.isSystem else { return nil }
        // The image encoder, when installed, loads here with the first image.
        return clusterPlan(facts: model.facts, fileSize: model.sizeBytes, hostReserve: model.projectorReserve,
                           contextLength: model.settings.contextLength, kvChoice: model.settings.kvCache, budget: budget)
    }

    /// The same for a GGUF file that isn't installed yet (a catalog download).
    func clusterPlan(facts: ArchitectureFacts, fileSize: UInt64, hostReserve: UInt64 = 0, contextLength: Int? = nil,
                     kvChoice: KVCacheChoice? = nil, budget: MemoryBudget? = nil) -> ClusterPlan? {
        guard RPCBridge.isAvailable, let workers = clusterDevices?(), !workers.isEmpty else { return nil }
        let budget = budget ?? currentBudget()
        let kept = hostReserve + ClusterPlanner.hostMargin
        let resident = budget.allowance.resident > kept ? budget.allowance.resident - kept : 0
        let host = ClusterDevice(id: "host", name: device.name, endpoint: nil, deviceIndex: 0, memoryBudget: resident,
                                 bandwidthGBs: device.memoryBandwidthGBs, latencyMs: 0)
        let requested = min(contextLength ?? (settings.contextLength > 0 ? settings.contextLength : profile.defaultContext),
                            profile.maximumContext)
        let kvTypes = MemoryPlanner.allowedKVTypes(kvChoice ?? settings.kvCache, profile: profile,
                                                   flashAttention: settings.flashAttention)
        return ClusterPlanner.plan(facts, fileSize: fileSize, requestedContext: requested, kvTypes: kvTypes,
                                   microBatch: profile.microBatchSize, flashAttention: settings.flashAttention,
                                   host: host, workers: workers, spread: settings.clusterSpread)
    }

    /// Whether `model` would load on the cluster rather than this device alone: when it doesn't
    /// fit here, or (if chosen in Settings) when the cluster runs it clearly faster.
    private func prefersCluster(_ candidate: ClusterPlan, over local: LoadPlan, model: InstalledModel) -> Bool {
        // A plan that keeps everything here is the local planner's call, not the cluster's.
        guard !candidate.workers.isEmpty else { return false }
        if !local.fits { return true }
        guard settings.clusterUse == .whenFaster else { return false }
        let alone = MemoryPlanner.estimatedTokensPerSecond(fileSize: model.sizeBytes, facts: model.facts, device: device)
        return candidate.estimatedTokensPerSecond > alone * 1.25
    }

    // MARK: Loading

    /// Returns the loaded backend for `model`, loading it (and unloading others) if needed.
    @discardableResult
    func ensureLoaded(_ model: InstalledModel) async throws -> LoadedModel {
        if var existing = loaded[model.id] {
            existing.lastUsed = .now
            loaded[model.id] = existing
            return existing
        }
        if let task = loadTask, loadingModelID == model.id {
            return try await task.value
        }
        guard loadingModelID == nil else { throw InferenceError.busy }

        // Apple's on-device model: iOS loads and manages it, so there's no file or memory plan.
        if model.isSystem {
            if case .unavailable(let reason) = AppleFoundationBackend.availability {
                throw InferenceError.loadFailed(reason)
            }
            let entry = LoadedModel(id: model.id, backend: AppleFoundationBackend(), plan: Self.systemPlan, lastUsed: .now)
            loaded[model.id] = entry
            return entry
        }

        let fileURL = store.fileURL(for: model)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            throw InferenceError.modelFileMissing(model.displayName)
        }

        // Keep other models only if everything fits together; otherwise release least recently used.
        var loadPlan = self.plan(for: model, keepingLoaded: true)
        if !loadPlan.fits || loadPlan.wasReduced {
            for victim in loaded.values.sorted(by: { $0.lastUsed < $1.lastUsed }) {
                await unload(victim.id)
                loadPlan = self.plan(for: model, keepingLoaded: true)
                if loadPlan.fits && !loadPlan.wasReduced { break }
            }
        }
        // The cluster this device hosts takes the model when it can't fit here (or, if chosen, when
        // the cluster runs it clearly faster). It plans for this device's whole budget, so every
        // other model is released first.
        var cluster: ClusterPlan?
        if let candidate = clusterPlan(for: model), prefersCluster(candidate, over: loadPlan, model: model) {
            for other in loaded.values { await unload(other.id) }
            cluster = clusterPlan(for: model) ?? candidate
        }
        if let cluster {
            loadPlan = LoadPlan(contextLength: cluster.contextLength, kvType: cluster.kvType,
                                estimate: MemoryEstimate(weights: cluster.host.bytes, kvCache: 0, compute: 0, overhead: 0,
                                                         contextLength: cluster.contextLength, kvType: cluster.kvType),
                                fits: true, requestedContext: loadPlan.requestedContext, maxContextThatFits: nil)
            let devices = cluster.shares.count == 2 ? "this device and 1 more" : "this device and \(cluster.shares.count - 1) more"
            post("point.3.connected.trianglepath.dotted", "\(model.displayName) loads across \(devices) of your cluster, with a \(ByteFormat.tokens(cluster.contextLength)) context (about \(Int(cluster.estimatedTokensPerSecond.rounded())) tokens per second, estimated).")
        }

        // The user may load a model larger than the budget anyway: with a short context, iOS decides.
        let beyondLimit = cluster == nil && !loadPlan.fits && model.settings.ignoreMemoryLimit == true
        guard loadPlan.fits || beyondLimit else {
            let budget = currentBudget()
            let clusterHint = RPCBridge.isAvailable && !model.isMLX
                ? (clusterDevices?().isEmpty == false
                    ? " Your cluster can't hold it either; add devices to it, or "
                    : " Host a cluster (Cluster in the sidebar) to run it across your other devices, or ")
                : " "
            throw InferenceError.insufficientMemory(
                required: loadPlan.estimate.total, available: budget.usable,
                suggestion: "Choose a smaller quantization." + clusterHint + "turn on Load Beyond the Memory Limit in the model's settings to try it anyway.")
        }
        if beyondLimit {
            // The planner's requested context already respects the model's trained length.
            loadPlan.contextLength = max(loadPlan.contextLength, min(Self.beyondLimitContext, loadPlan.requestedContext))
            loadPlan.estimate = MemoryPlanner.estimate(model.facts, fileSize: model.sizeBytes + model.projectorReserve,
                                                       context: loadPlan.contextLength, kv: loadPlan.kvType,
                                                       microBatch: profile.microBatchSize, flashAttention: settings.flashAttention)
            post("exclamationmark.triangle", "\(model.displayName) is larger than OMNIA's memory budget, so it loads with a \(ByteFormat.tokens(loadPlan.contextLength)) context. Replies may be slow, and iOS may close OMNIA if memory runs out.")
        }

        // Speculative decoding: the chosen draft model joins only if it fits beside this one (never
        // on a cluster, whose memory is already spoken for).
        let draft = cluster == nil ? draftPlan(for: model, loadPlan: loadPlan) : nil
        if let draft {
            loadPlan.estimate.weights += draft.estimate.weights
            loadPlan.estimate.kvCache += draft.estimate.kvCache
            loadPlan.estimate.compute += draft.estimate.compute
            loadPlan.estimate.overhead += draft.estimate.overhead
        }

        var configuration = RuntimeConfiguration(
            contextLength: loadPlan.contextLength,
            batchSize: profile.batchSize,
            microBatchSize: profile.microBatchSize,
            threads: profile.threads(for: device),
            gpuOffload: settings.gpuAcceleration,
            kvCacheType: loadPlan.kvType,
            flashAttention: settings.flashAttention
        )
        // Hybrid models undo rejected draft tokens from recurrent-state snapshots.
        if let draft, model.facts.recurrentStateBytes > 0 {
            configuration.rollbackDepth = draft.length + 1
        }
        configuration.cluster = cluster?.placement
        loadingModelID = model.id
        loadProgress = 0
        engineLog.info("Loading \(model.id, privacy: .public) ctx=\(loadPlan.contextLength) kv=\(loadPlan.kvType.rawValue, privacy: .public) est=\(loadPlan.estimate.total) devices=\(cluster?.shares.count ?? 1)")

        let plannedLoad = loadPlan
        let plannedCluster = cluster
        let loader = loadBackend
        let task = Task<LoadedModel, Error> { [weak self] in
            let backend = try await loader(model, fileURL, configuration) { value in
                Task { @MainActor in self?.loadProgress = value }
            }
            return LoadedModel(id: model.id, backend: backend, plan: plannedLoad, lastUsed: .now, cluster: plannedCluster)
        }
        loadTask = task
        defer {
            loadingModelID = nil
            loadTask = nil
        }
        let entry: LoadedModel
        do {
            entry = try await task.value
        } catch InferenceError.clusterDeviceLost(let name) {
            onClusterDevicesLost?(RPCBridge.failedEndpoints())
            throw InferenceError.clusterDeviceLost(name)
        }

        // Measured safety net: if iOS reports too little headroom left, undo the load now
        // rather than risk the app being terminated during generation. A model loaded beyond the
        // limit has no headroom by definition: the user chose that risk.
        if !beyondLimit, let remaining = SystemMetrics.availableMemory(), remaining < profile.minimumHeadroomAfterLoad {
            await entry.backend.close()
            engineLog.error("Load undone: only \(remaining) bytes of headroom left")
            throw InferenceError.insufficientMemory(
                required: plannedLoad.estimate.total, available: plannedLoad.estimate.total,
                suggestion: "iOS left only \(ByteFormat.memory(remaining)) for OMNIA after loading, so the model was released. Try a shorter context or a smaller quantization.")
        }

        if let draft, let runtime = entry.backend as? LlamaRuntime {
            do {
                try await runtime.attachDraft(fileURL: store.fileURL(for: draft.model),
                                              displayName: draft.model.displayName, length: draft.length)
                if let remaining = SystemMetrics.availableMemory(), remaining < profile.minimumHeadroomAfterLoad {
                    await runtime.detachDraft()
                    post("bolt.slash", "\(draft.model.displayName) was released to leave iOS enough memory, so replies won't use speculative decoding.")
                } else {
                    drafts[model.id] = draft.model.id
                }
            } catch {
                post("bolt.slash", "Speculative decoding is off for \(model.displayName): \(error.localizedDescription)")
            }
        }

        loaded[model.id] = entry
        store.recordLoad(model.id, info: entry.info)
        store.markUsed(model.id)
        if plannedLoad.wasReduced {
            post("arrow.down.right.and.arrow.up.left", "Context set to \(ByteFormat.tokens(plannedLoad.contextLength)) tokens so \(model.displayName) fits in memory.")
        }
        return entry
    }

    /// The draft model to load with `model`, when one is chosen, installed and fits in what this
    /// model leaves free. Its estimate includes the rollback snapshots hybrid models need.
    private func draftPlan(for model: InstalledModel, loadPlan: LoadPlan)
        -> (model: InstalledModel, length: Int, estimate: MemoryEstimate)? {
        guard let id = model.settings.draftModelID, id != model.id, let draft = store.model(id: id),
              FileManager.default.fileExists(atPath: store.fileURL(for: draft).path(percentEncoded: false)) else {
            return nil
        }
        let length = min(max(model.settings.draftLength ?? 6, 2), 16)
        var estimate = MemoryPlanner.estimate(draft.facts, fileSize: draft.sizeBytes, context: loadPlan.contextLength,
                                              kv: .f16, flashAttention: settings.flashAttention)
        estimate.overhead += UInt64(length + 1) * (model.facts.recurrentStateBytes + draft.facts.recurrentStateBytes)
        var allowance = currentBudget().allowance
        for other in loaded.values where other.id != model.id {
            allowance = allowance.reserving(other.plan.estimate)
        }
        guard allowance.reserving(loadPlan.estimate).admits(estimate) else {
            post("bolt.slash", "\(draft.displayName) doesn't fit beside \(model.displayName), so replies won't use speculative decoding.")
            return nil
        }
        return (draft, length, estimate)
    }

    func unload(_ id: String) async {
        drafts[id] = nil
        guard let entry = loaded.removeValue(forKey: id) else { return }
        if let active = activeBackend, active === entry.backend { entry.backend.interrupt(.unload) }
        await entry.backend.close()
        engineLog.info("Unloaded \(id, privacy: .public)")
    }

    func unloadAll(reason: String? = nil) async {
        for id in Array(loaded.keys) { await unload(id) }
        if let reason { post("memorychip", reason) }
    }

    /// A worker left the cluster. A model with layers on it can't run any more: its connection is
    /// dropped (so a reply in progress fails at once instead of waiting out a timeout) and, when
    /// idle, the model is released. The next reply plans again with the devices that are left.
    func clusterWorkerLeft(endpoint: String) async {
        for entry in loaded.values where entry.cluster?.workers.contains(where: { $0.device.endpoint == endpoint }) == true {
            RPCBridge.disconnect(endpoint)
            if live?.modelID != entry.id { await unload(entry.id) }
        }
    }

    // MARK: Generation

    /// Streams a reply from `model`. Loads it first when needed.
    func generate(with model: InstalledModel, request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, Error> {
        guard live == nil, !isBenchmarking else { throw InferenceError.busy }
        if monitor.thermalState == .critical && settings.thermalProtection { throw InferenceError.thermalLimit }
        let entry = try await ensureLoaded(model)
        var request = request
        if !settings.reusePromptCache { request.reusePromptCache = false }
        request.pacing = currentPacing()
        activeMemoryURL = nil
        if let key = request.memoryKey, settings.rememberLongChats, request.reusePromptCache {
            conversationMemory.enforceLimit(conversationMemoryLimit)
            let memory = conversationMemory.request(conversationID: key, modelID: model.id, modelSize: model.sizeBytes,
                                                    configuration: entry.info.configuration,
                                                    limitBytes: conversationMemoryLimit)
            request.memory = memory
            activeMemoryURL = memory.fileURL
        }
        let backend = entry.backend
        activeBackend = backend
        live = LiveGeneration(modelID: model.id, modelName: model.displayName, startedAt: .now,
                              promptProgress: nil, generatedChunks: 0, firstTokenAt: nil)
        monitor.setDetailedSampling(true)
        let upstream = backend.generate(request)

        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                do {
                    for try await event in upstream {
                        self?.observe(event)
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                    // A Metal command buffer that failed (iOS took the GPU away, for one) leaves
                    // llama.cpp's GPU context failing every step until it's recreated, and a
                    // cluster model whose worker dropped out has lost part of itself: reload the
                    // model for the next reply.
                    if let failure = error as? InferenceError, failure.needsReload {
                        if case .clusterDeviceLost = failure {
                            self?.onClusterDevicesLost?(RPCBridge.failedEndpoints())
                        }
                        await self?.unload(model.id)
                    }
                }
                self?.finishGeneration()
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    backend.interrupt(.user)
                    task.cancel()
                }
            }
        }
    }

    func stopGeneration() {
        activeBackend?.interrupt(.user)
    }

    private func observe(_ event: GenerationEvent) {
        switch event {
        case .started:
            break
        case .promptProgress(let progress):
            live?.promptProgress = progress
        case .text:
            if live?.firstTokenAt == nil { live?.firstTokenAt = .now }
            live?.generatedChunks += 1
        case .finished(let stats):
            lastStats = stats
        }
    }

    private func finishGeneration() {
        if let id = live?.modelID { loaded[id]?.lastUsed = .now }
        // A save restored or written for this conversation was just used: evict it last.
        if let url = activeMemoryURL { conversationMemory.touch(url) }
        activeMemoryURL = nil
        live = nil
        activeBackend = nil
        monitor.setDetailedSampling(false)
    }

    private func currentPacing() -> Duration {
        guard settings.thermalProtection else { return .zero }
        return monitor.thermalState == .serious ? profile.seriousThermalPacing : .zero
    }

    // MARK: Benchmark

    func benchmark(_ model: InstalledModel, progress: @escaping @Sendable (Double) -> Void) async throws -> BenchmarkMeasurement {
        guard live == nil, !isBenchmarking else { throw InferenceError.busy }
        let entry = try await ensureLoaded(model)
        isBenchmarking = true
        activeBackend = entry.backend
        monitor.setDetailedSampling(true)
        defer {
            isBenchmarking = false
            activeBackend = nil
            monitor.setDetailedSampling(false)
        }
        let result = try await entry.backend.benchmark(promptLength: 512, generateLength: 128, repetitions: 3, progress: progress)
        store.recordBenchmark(model.id, measurement: result, context: entry.info.configuration.contextLength)
        return result
    }

    func cancelBenchmark() {
        if isBenchmarking { activeBackend?.interrupt(.user) }
    }

    func countTokens(_ text: String, modelID: String?) async -> Int {
        if let modelID, let entry = loaded[modelID] { return await entry.backend.countTokens(text) }
        return max(1, text.utf8.count / 4)
    }

    func resetPromptCache(for modelID: String) async {
        await loaded[modelID]?.backend.resetCache()
    }

    /// Context for a model loaded beyond the memory limit: enough for a real exchange, and as
    /// little extra memory as that allows.
    static let beyondLimitContext = 4096

    /// The plan for a model built into the system: its fixed context and no memory of OMNIA's.
    static let systemPlan = LoadPlan(
        contextLength: AppleFoundationBackend.contextSize, kvType: .f16,
        estimate: MemoryEstimate(weights: 0, kvCache: 0, compute: 0, overhead: 0, contextLength: AppleFoundationBackend.contextSize, kvType: .f16),
        fits: true, requestedContext: AppleFoundationBackend.contextSize, maxContextThatFits: AppleFoundationBackend.contextSize)

    // MARK: Images

    /// Loads a loaded model's image encoder ahead of time, so a message with a photo starts
    /// sooner. Nothing happens for a model that isn't loaded or has no image support.
    func prepareImages(for model: InstalledModel) {
        guard model.supportsImages, let runtime = loaded[model.id]?.backend as? LlamaRuntime else { return }
        Task { await runtime.prepareVision() }
    }

    /// Image support was added or removed: a loaded copy picks up the change without reloading.
    private func projectorChanged(_ model: InstalledModel) async {
        guard let runtime = loaded[model.id]?.backend as? LlamaRuntime else { return }
        await runtime.setProjector(store.projectorURL(for: model))
    }

    // MARK: System events

    private func handleMemoryPressure(_ level: MemoryPressureLevel) {
        guard level != .normal, !loaded.isEmpty else { return }
        engineLog.warning("Memory pressure: \(level.rawValue, privacy: .public)")
        Task {
            if level == .critical {
                activeBackend?.interrupt(.memoryPressure)
                await unloadAll(reason: "iOS reported critical memory pressure, so OMNIA released its models to keep the system stable.")
            } else {
                // Release everything that isn't generating right now.
                let idle = loaded.values.filter { entry in
                    guard let active = activeBackend else { return true }
                    return active !== entry.backend
                }.map(\.id)
                for id in idle { await unload(id) }
                if !idle.isEmpty { post("memorychip", "Released idle models after a memory warning.") }
            }
        }
    }

    private func handleThermalChange(_ state: ProcessInfo.ThermalState) {
        guard settings.thermalProtection else { return }
        switch state {
        case .critical:
            if let active = activeBackend {
                active.interrupt(.thermal)
                post("thermometer.high", "Generation paused: the device is very hot. You can continue once it cools.")
            }
        case .serious:
            activeBackend?.setPacing(profile.seriousThermalPacing)
        default:
            activeBackend?.setPacing(.zero)
        }
    }

    /// `keepGenerating`: a continued processing task holds the GPU (iPad), so the reply in progress
    /// goes on; the usual background steps wait until it ends (`backgroundGenerationEnded`).
    func sceneDidEnterBackground(keepGenerating: Bool = false) {
        inBackground = true
        if keepGenerating {
            backgroundDeferred = true
            return
        }
        enterBackground()
    }

    /// MLX ends the app if iOS takes the GPU away mid-step, so an MLX reply stops as soon as OMNIA
    /// starts leaving the screen, unless a background task holds the GPU. (llama.cpp survives a
    /// failed step, so it stops on entering the background.)
    func sceneWillResignActive(keepGenerating: Bool) {
        guard !keepGenerating, let active = activeBackend, active is MLXRuntime else { return }
        active.interrupt(.background)
        // A moment of background time for the step in flight to finish before iOS suspends OMNIA.
        let task = UIApplication.shared.beginBackgroundTask(withName: "OMNIA.mlx-stop")
        Task { @MainActor in
            for _ in 0..<100 where self.live != nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    /// A reply generated in the background has ended and its task has given back the GPU.
    func backgroundGenerationEnded() {
        guard inBackground, backgroundDeferred else { return }
        backgroundDeferred = false
        enterBackground()
    }

    private func enterBackground() {
        // GPU work is not permitted in the background: stop cleanly before iOS rejects it.
        activeBackend?.interrupt(.background)
        guard !loaded.isEmpty, !settings.keepModelsLoadedInBackground else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "OMNIA.unload") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    self.unloadedForBackground = Array(self.loaded.keys)
                    await self.unloadAll()
                    self.endBackgroundTask()
                }
            }
        }
        backgroundUnloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + profile.backgroundUnloadDelay, execute: work)
    }

    func sceneWillEnterForeground() {
        inBackground = false
        backgroundDeferred = false
        backgroundUnloadWork?.cancel()
        backgroundUnloadWork = nil
        endBackgroundTask()
        guard settings.restoreModelOnForeground, let id = unloadedForBackground.first,
              let model = store.model(id: id) else { return }
        unloadedForBackground = []
        Task { try? await ensureLoaded(model) }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func scheduleIdleCheck() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.unloadIdleModels() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func unloadIdleModels() {
        let minutes = settings.idleUnloadMinutes < 0 ? profile.idleUnloadMinutes : settings.idleUnloadMinutes
        guard minutes > 0, !isBusy else { return }
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        let idle = loaded.values.filter { $0.lastUsed < cutoff }.map(\.id)
        guard !idle.isEmpty else { return }
        Task {
            for id in idle { await unload(id) }
            post("moon.zzz", "Released \(idle.count == 1 ? "an idle model" : "\(idle.count) idle models") after \(minutes) minutes to save memory and battery.")
        }
    }

    // MARK: Notices

    func post(_ symbol: String, _ message: String) {
        let notice = EngineNotice(symbol: symbol, message: message)
        self.notice = notice
        Task {
            try? await Task.sleep(for: .seconds(6))
            if self.notice?.id == notice.id { self.notice = nil }
        }
    }

    func dismissNotice() { notice = nil }
}
