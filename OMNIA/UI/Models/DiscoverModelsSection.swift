import SwiftUI

/// Device-specific recommendations and the verified catalog, with a fit assessment per model.
struct DiscoverModelsSection: View {
    @Environment(InferenceEngine.self) private var engine
    @Environment(DownloadManager.self) private var downloads
    @Environment(ModelStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var mode: RecommendationMode?
    @State private var showIncompatible = false
    @State private var errorMessage: String?
    /// Planning every catalog file takes thousands of planner steps; this section redraws far
    /// more often than what they depend on changes (a download's progress, a cluster heartbeat).
    @State private var catalogFit = Memo<PlanningInputs, CatalogFit>()
    @State private var recommendations = Memo<RecommendationKey, Recommendation?>()

    private let device = AppServices.shared.device

    /// Every catalog model by where it runs, for one set of planning inputs.
    private struct CatalogFit {
        typealias Entry = (model: CatalogModel, best: (CatalogVariant, VariantAssessment)?)
        var fitting: [Entry]
        var onCluster: [Entry]
        var tooLarge: [Entry]
        /// The largest version of each `onCluster` model that the cluster can run.
        var clusterFits: [String: CatalogVariant]
    }

    private struct RecommendationKey: Hashable {
        var inputs: PlanningInputs
        var mode: RecommendationMode
    }

    var body: some View {
        let inputs = PlanningInputs(engine: engine, settings: settings)
        let budget = inputs.budget
        let profile = engine.profile
        let fit = catalogFit.value(for: inputs) {
            Self.fit(engine: engine, device: device, profile: profile, budget: budget)
        }
        let fitting = fit.fitting
        let onCluster = fit.onCluster
        let tooLarge = fit.tooLarge
        let clusterFits = fit.clusterFits

        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Recommended for \(device.name)", subtitle: "Every model is judged by its real file size, architecture, context and runtime memory on this device — never by parameter count alone.")
                Picker("Priority", selection: Binding(get: { mode ?? profile.defaultRecommendation }, set: { mode = $0 })) {
                    ForEach(RecommendationMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                let current = mode ?? profile.defaultRecommendation
                Text(current.explanation).font(.caption).foregroundStyle(.secondary)
                if let recommendation = recommendations.value(for: RecommendationKey(inputs: inputs, mode: current), compute: {
                    ModelCatalog.recommend(current, device: device, profile: profile, budget: budget)
                }) {
                    VStack(alignment: .leading, spacing: 12) {
                        RecommendationCard(recommendation: recommendation, device: device)
                        HStack {
                            NavigationLink(value: recommendation.model) {
                                Text("Details")
                            }
                            .buttonStyle(.glass)
                            DownloadButton(model: recommendation.model, variant: recommendation.variant, errorMessage: $errorMessage)
                        }
                    }
                } else {
                    Text("Nothing in the catalog fits the memory available right now. Close other apps or import a smaller model.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .surface()
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(Theme.critical)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Catalog", subtitle: "\(fitting.count) of \(ModelCatalog.curated.count) verified models fit this device. Files come from public Hugging Face repositories and are checked against their published SHA-256.")
                LazyVStack(spacing: 10) {
                    ForEach(fitting, id: \.model.id) { entry in
                        NavigationLink(value: entry.model) {
                            CatalogModelRow(model: entry.model, best: entry.best)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !onCluster.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader("Runs on your cluster", subtitle: "Too large for \(device.name) alone, these fit across the devices in your cluster right now. Each row names the largest version that fits.")
                    LazyVStack(spacing: 10) {
                        ForEach(onCluster, id: \.model.id) { entry in
                            NavigationLink(value: entry.model) {
                                CatalogModelRow(model: entry.model, best: nil, clusterVariant: clusterFits[entry.model.id])
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if !tooLarge.isEmpty {
                DisclosureGroup(isExpanded: $showIncompatible) {
                    LazyVStack(spacing: 10) {
                        ForEach(tooLarge, id: \.model.id) { entry in
                            NavigationLink(value: entry.model) {
                                CatalogModelRow(model: entry.model, best: nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    Text("Too large for this device (\(tooLarge.count))").font(.omniaSection)
                }
            }
        }
    }

    @MainActor
    private static func fit(engine: InferenceEngine, device: DeviceProfile, profile: OptimizationProfile,
                            budget: MemoryBudget) -> CatalogFit {
        let assessed: [CatalogFit.Entry] = ModelCatalog.curated.map { model in
            (model: model, best: ModelCatalog.bestVariant(of: model, device: device, profile: profile, budget: budget))
        }
        let fitting = assessed.filter { $0.best != nil }.sorted { $0.model.qualityScore > $1.model.qualityScore }
        let beyondDevice = assessed.filter { $0.best == nil }
        let fits = clusterFits(beyondDevice.map(\.model), engine: engine, budget: budget)
        return CatalogFit(
            fitting: fitting,
            onCluster: beyondDevice.filter { fits[$0.model.id] != nil }.sorted { $0.model.qualityScore > $1.model.qualityScore },
            tooLarge: beyondDevice.filter { fits[$0.model.id] == nil },
            clusterFits: fits)
    }

    /// For models too large for this device: the largest version the cluster hosted here can run
    /// now, by model ID. Empty without workers.
    @MainActor
    private static func clusterFits(_ models: [CatalogModel], engine: InferenceEngine,
                                    budget: MemoryBudget) -> [String: CatalogVariant] {
        guard let devices = engine.clusterDevices?(), !devices.isEmpty else { return [:] }
        // Memory of every device together: a quick bound before planning.
        let pooled = devices.reduce(budget.allowance.resident) { $0 + $1.memoryBudget }
        var fits: [String: CatalogVariant] = [:]
        for model in models {
            for variant in model.variants.sorted(by: { $0.sizeBytes > $1.sizeBytes })
            where !variant.isMLX && UInt64(variant.sizeBytes) < pooled {
                if engine.clusterPlan(facts: model.facts, fileSize: UInt64(variant.sizeBytes), budget: budget) != nil {
                    fits[model.id] = variant
                    break
                }
            }
        }
        return fits
    }
}

struct CatalogModelRow: View {
    let model: CatalogModel
    let best: (CatalogVariant, VariantAssessment)?
    /// For a model too large for this device: the largest version the cluster can run.
    var clusterVariant: CatalogVariant? = nil

    @Environment(ModelStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(model.name).font(.headline)
                    if store.models.contains(where: { $0.catalogID == model.id }) {
                        Pill(text: "Downloaded", symbol: "checkmark", tint: Theme.positive)
                    }
                }
                Text("\(model.developer) · \(model.parameterLabel) · \(model.architectureLabel) · \(ByteFormat.tokens(model.facts.trainContext)) context")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(model.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    ForEach(model.tags, id: \.self) { Pill(text: $0) }
                    if model.projector != nil {
                        Pill(text: "Sees images", symbol: "photo")
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if let best {
                    CompatibilityBadge(compatibility: best.1.compatibility)
                    Text("\(best.0.quant) · \(ByteFormat.file(best.0.sizeBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("≈ \(Int(best.1.estimatedTokensPerSecond)) tok/s · \(ByteFormat.memory(best.1.plan.estimate.total))")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else if let clusterVariant {
                    Pill(text: "Runs on your cluster", symbol: "point.3.connected.trianglepath.dotted", tint: Theme.positive)
                    Text("Up to \(clusterVariant.quant) · \(ByteFormat.file(clusterVariant.sizeBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    CompatibilityBadge(compatibility: .tooLarge)
                    if let smallest = model.variants.min(by: { $0.sizeBytes < $1.sizeBytes }) {
                        Text("Smallest \(ByteFormat.file(smallest.sizeBytes))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .surface(padding: 14)
        .contentShape(Rectangle())
    }
}

/// Starts, shows or opens a catalog download.
struct DownloadButton: View {
    let model: CatalogModel
    let variant: CatalogVariant
    @Binding var errorMessage: String?
    /// Larger than this device's memory budget: the download takes a confirmation, and the
    /// installed model is allowed to load beyond the limit.
    var exceedsMemory = false

    @Environment(DownloadManager.self) private var downloads
    @Environment(ModelStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var confirming = false

    var body: some View {
        let request = model.downloadRequest(for: variant)
        if store.isInstalled(repo: model.repo, fileName: variant.fileName) {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.positive)
                .font(.subheadline.weight(.medium))
        } else if let item = downloads.item(for: request.id), item.phase.isActive || item.phase == .paused {
            HStack(spacing: 8) {
                ProgressView(value: item.fraction).frame(width: 90)
                Text(ByteFormat.percent(item.fraction)).font(.caption).monospacedDigit()
            }
        } else if exceedsMemory {
            Button {
                confirming = true
            } label: {
                Label("Download Anyway", systemImage: "exclamationmark.triangle")
            }
            .buttonStyle(.glass)
            .disabled(settings.offlineOnly)
            .oversizedDownloadConfirmation(isPresented: $confirming, size: variant.sizeBytes) {
                var oversized = request
                oversized.ignoreMemoryLimit = true
                start(oversized)
            }
        } else {
            Button {
                start(request)
            } label: {
                Label("Download \(ByteFormat.file(variant.sizeBytes))", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.glassProminent)
            .disabled(settings.offlineOnly)
        }
    }

    private func start(_ request: DownloadRequest) {
        do {
            errorMessage = nil
            try downloads.start(request)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension View {
    /// Asks before downloading a model larger than this device's memory budget, saying what
    /// running it will be like.
    @MainActor
    func oversizedDownloadConfirmation(isPresented: Binding<Bool>, size: Int64, download: @escaping () -> Void) -> some View {
        confirmationDialog("Larger than this device's memory", isPresented: isPresented, titleVisibility: .visible) {
            Button("Download \(ByteFormat.file(size)) Anyway", action: download)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("OMNIA will load it with a short \(ByteFormat.tokens(InferenceEngine.beyondLimitContext)) context. Replies come slowly and use more battery, and iOS may close OMNIA if memory runs out. You can turn this off in the model's settings.")
        }
    }
}
