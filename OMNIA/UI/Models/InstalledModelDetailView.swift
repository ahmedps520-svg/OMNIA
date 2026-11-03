import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// An installed model: status, memory plan, per-model settings, benchmark and history.
struct InstalledModelDetailView: View {
    let modelID: String

    @Environment(ModelStore.self) private var store
    @Environment(InferenceEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(ModelImporter.self) private var importer
    @Environment(\.dismiss) private var dismiss

    @Query private var records: [InferenceRecord]
    @State private var errorMessage: String?
    @State private var benchmarkProgress: Double?
    @State private var showDelete = false
    @State private var showRemoveImages = false
    @State private var showEncoderImporter = false
    @State private var systemPrompt = ""

    init(modelID: String) {
        self.modelID = modelID
        _records = Query(filter: #Predicate<InferenceRecord> { $0.modelID == modelID }, sort: \InferenceRecord.date, order: .reverse)
    }

    private var model: InstalledModel? { store.model(id: modelID) }

    var body: some View {
        Group {
            if let model {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        header(model)
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(Theme.critical)
                                .surface(padding: 12)
                        }
                        memory(model)
                        modelSettings(model)
                        imageSupport(model)
                        performance(model)
                        fileInfo(model)
                        Button("Delete Model", systemImage: "trash", role: .destructive) { showDelete = true }
                            .buttonStyle(.glass)
                    }
                    .padding(24)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
                .background(Theme.canvas)
                .navigationTitle(model.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .confirmationDialog("Delete \(model.displayName)?", isPresented: $showDelete, titleVisibility: .visible) {
                    Button("Delete \(ByteFormat.file(model.sizeBytes))", role: .destructive) {
                        Task {
                            if settings.defaultModelID == model.id { settings.defaultModelID = nil }
                            await store.delete(model)
                            dismiss()
                        }
                    }
                } message: {
                    Text("The model file is removed from this device. Conversations that used it are kept.")
                }
                .confirmationDialog("Remove image support?", isPresented: $showRemoveImages, titleVisibility: .visible) {
                    Button("Remove Image Support", role: .destructive) {
                        Task { await store.removeProjector(from: model.id) }
                    }
                } message: {
                    Text("\(model.displayName) will read text only. The encoder file is deleted once no other model uses it.")
                }
                .fileImporter(isPresented: $showEncoderImporter, allowedContentTypes: [ModelImporter.ggufType, .data]) { result in
                    if case .success(let url) = result {
                        Task { await importer.importProjector(at: url, for: model) }
                    }
                }
                .onAppear { systemPrompt = model.settings.systemPrompt ?? "" }
            } else {
                OmniaEmptyState(title: "Model removed", message: "This model is no longer on the device.", symbol: "cube.transparent")
            }
        }
    }

    // MARK: Header

    private func header(_ model: InstalledModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.displayName).font(.omniaLargeTitle)
                Spacer()
                if engine.isLoaded(model.id) {
                    Pill(text: "Loaded", symbol: "bolt.fill", tint: Theme.positive)
                }
            }
            Text("\(model.parameterLabel) · \(model.quantization ?? "GGUF") · \(ModelCatalog.architectureName(model.facts.architecture))\(model.developer.map { " · \($0)" } ?? "")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if engine.loadingModelID == model.id {
                    ProgressView(value: engine.loadProgress).frame(width: 140)
                    Text("Loading…").font(.footnote).foregroundStyle(.secondary)
                } else if engine.isLoaded(model.id) {
                    Button("Unload", systemImage: "eject") {
                        Task { await engine.unload(model.id) }
                    }
                    .buttonStyle(.glass)
                    .disabled(engine.isGenerating)
                } else {
                    Button("Load", systemImage: "bolt") { load(model) }
                        .buttonStyle(.glassProminent)
                        .disabled(engine.isBusy)
                }
                if settings.defaultModelID != model.id {
                    Button("Set as Default", systemImage: "star") { settings.defaultModelID = model.id }
                        .buttonStyle(.glass)
                } else {
                    Label("Default model", systemImage: "star.fill").font(.footnote).foregroundStyle(.secondary)
                }
                if let progress = benchmarkProgress {
                    ProgressView(value: progress).frame(width: 100)
                    Button("Cancel") { engine.cancelBenchmark() }.buttonStyle(.glass)
                } else {
                    Button("Benchmark", systemImage: "speedometer") { benchmark(model) }
                        .buttonStyle(.glass)
                        .disabled(engine.isBusy)
                }
            }
            .controlSize(.regular)
        }
    }

    // MARK: Memory

    private func memory(_ model: InstalledModel) -> some View {
        let budget = engine.currentBudget()
        let plan = engine.loaded[model.id]?.plan ?? engine.plan(for: model, budget: budget)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Memory", subtitle: plan.fits
                          ? "Planned for \(ByteFormat.tokens(plan.contextLength)) tokens with a \(plan.kvType.label) KV cache."
                          : "Doesn't fit in the memory available right now.")
            VStack(alignment: .leading, spacing: 14) {
                MemoryBreakdownBar(estimate: plan.estimate, capacity: budget.usable, accent: .accentColor)
                HStack(spacing: 24) {
                    LabeledMetric(title: "Planned total", value: ByteFormat.memory(plan.estimate.total))
                    LabeledMetric(title: "Available for models", value: ByteFormat.memory(budget.usable))
                    if let maximum = plan.maxContextThatFits {
                        LabeledMetric(title: "Longest context that fits", value: ByteFormat.tokens(maximum))
                    }
                }
                if let measured = model.measuredGPUBytes, let context = model.measuredContext {
                    Text("Measured at last load (\(ByteFormat.tokens(context)) context): \(ByteFormat.memory(measured)) of Metal memory, \(ByteFormat.memory(model.measuredFootprint ?? 0)) added to the app's footprint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .surface()
        }
    }

    // MARK: Settings

    private func modelSettings(_ model: InstalledModel) -> some View {
        let budget = engine.currentBudget()
        let maxContext = MemoryPlanner.maxContextThatFits(model.facts, fileSize: model.sizeBytes + model.projectorReserve, kv: .q4_0,
                                                          profile: engine.profile, allowance: budget.allowance) ?? 4096
        let contextOptions = [2048, 4096, 8192, 16_384, 32_768, 65_536, 131_072, 262_144]
            .filter { $0 <= min(model.facts.trainContext, engine.profile.maximumContext) }
        let generation = settings.generation.applying(model.settings.generation)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Model Settings", subtitle: "Used whenever this model runs. Conversation settings can override sampling.")
            VStack(alignment: .leading, spacing: 16) {
                Picker("Context length", selection: Binding(
                    get: { model.settings.contextLength ?? 0 },
                    set: { value in store.updateSettings(for: model.id) { $0.contextLength = value == 0 ? nil : value } })) {
                    Text("Automatic").tag(0)
                    ForEach(contextOptions, id: \.self) { option in
                        Text("\(ByteFormat.tokens(option))\(option > maxContext ? " (too large)" : "")").tag(option)
                    }
                }
                Picker("KV cache", selection: Binding(
                    get: { model.settings.kvCache ?? .automatic },
                    set: { value in store.updateSettings(for: model.id) { $0.kvCache = value == .automatic ? nil : value } })) {
                    ForEach(KVCacheChoice.allCases) { Text($0.title).tag($0) }
                }
                if model.facts.thinkingToggle {
                    Picker("Reasoning", selection: Binding(
                        get: { model.settings.thinkingEnabled },
                        set: { value in store.updateSettings(for: model.id) { $0.thinkingEnabled = value } })) {
                        Text("Model default").tag(Bool?.none)
                        Text("On").tag(Bool?.some(true))
                        Text("Off").tag(Bool?.some(false))
                    }
                }
                let draftCandidates = store.models.filter {
                    $0.id != model.id && $0.sizeBytes < model.sizeBytes && abs($0.facts.vocabSize - model.facts.vocabSize) <= 128
                }
                if !draftCandidates.isEmpty || model.settings.draftModelID != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Speed up with", selection: Binding(
                            get: { model.settings.draftModelID },
                            set: { value in store.updateSettings(for: model.id) { $0.draftModelID = value } })) {
                            Text("Nothing").tag(String?.none)
                            ForEach(draftCandidates) { Text($0.displayName).tag(String?.some($0.id)) }
                        }
                        if model.settings.draftModelID != nil {
                            Stepper("Guess \(model.settings.draftLength ?? 6) tokens ahead", value: Binding(
                                get: { model.settings.draftLength ?? 6 },
                                set: { value in store.updateSettings(for: model.id) { $0.draftLength = value } }), in: 2...12)
                        }
                        Group {
                            if let draftID = engine.drafts[model.id], let draft = store.model(id: draftID) {
                                Text("Speculative decoding is on: \(draft.displayName) guesses ahead and \(model.displayName) checks its guesses in one pass. Replies are identical, only faster.")
                            } else {
                                Text("A smaller model with the same vocabulary guesses several tokens ahead; this model checks them in one pass, so replies come faster and stay exactly the same. Applies the next time the model loads.")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                SamplingSlider(title: "Temperature", value: Binding(
                    get: { generation.temperature },
                    set: { value in store.updateSettings(for: model.id) { settings in
                        var overrides = settings.generation ?? GenerationOverrides()
                        overrides.temperature = value
                        settings.generation = overrides
                    } }), range: 0...2, step: 0.05)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default system prompt").font(.subheadline)
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 80)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Theme.faint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onChange(of: systemPrompt) { _, value in
                            store.updateSettings(for: model.id) { $0.systemPrompt = value.trimmed.isEmpty ? nil : value }
                        }
                }
                if engine.isLoaded(model.id) {
                    Button("Reload to Apply Changes", systemImage: "arrow.clockwise") {
                        Task {
                            await engine.unload(model.id)
                            load(model)
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(engine.isGenerating)
                }
            }
            .surface()
        }
    }

    // MARK: Image support

    private func imageSupport(_ model: InstalledModel) -> some View {
        let catalog = ModelCatalog.model(id: model.catalogID)
        let request = catalog?.projectorRequest(for: model)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Image Support", subtitle: "Lets the model read photos and screenshots you attach to a message.")
            VStack(alignment: .leading, spacing: 12) {
                if let projector = model.projector {
                    Label("\(model.displayName) can see images.", systemImage: "photo")
                        .font(.subheadline.weight(.semibold))
                    LabeledValueRow(label: "Image encoder", value: projector.fileName)
                    LabeledValueRow(label: "Size", value: ByteFormat.file(projector.sizeBytes))
                    LabeledValueRow(label: "Verification", value: projector.verification == .verified
                                    ? "SHA-256 matches the publisher's hash" : "Valid GGUF (no published hash to compare)")
                    Text("The encoder loads with the first image you send, and memory planning keeps room for it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Remove Image Support", systemImage: "trash", role: .destructive) { showRemoveImages = true }
                        .buttonStyle(.glass)
                } else if let request, let item = downloads.item(for: request.id) {
                    projectorDownload(item, request: request)
                } else if let request, let projector = catalog?.projector {
                    Text("Download the image encoder published with \(catalog?.name ?? "this model") (\(ByteFormat.file(projector.sizeBytes)), verified by SHA-256). Photos and screenshots stay on this device.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Download Image Support", systemImage: "arrow.down.circle") { startDownload(request) }
                        .buttonStyle(.glassProminent)
                } else if catalog != nil {
                    Text("\(model.displayName) reads text only.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("If this model can see images, add the image encoder published with it: an mmproj .gguf file from the same repository.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Add Encoder File…", systemImage: "folder") { showEncoderImporter = true }
                        .buttonStyle(.glass)
                        .disabled(importer.isBusy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface()
        }
    }

    @ViewBuilder
    private func projectorDownload(_ item: DownloadItem, request: DownloadRequest) -> some View {
        switch item.phase {
        case .downloading:
            ProgressView(value: item.fraction) {
                Text("Downloading image support · \(Int(item.fraction * 100))%").font(.footnote)
            }
            Button("Cancel", role: .cancel) { downloads.cancel(request.id) }
                .buttonStyle(.glass)
        case .paused:
            Text("Download paused at \(Int(item.fraction * 100))%.").font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Resume", systemImage: "play.fill") { downloads.resume(request.id) }
                    .buttonStyle(.glassProminent)
                Button("Cancel", role: .cancel) { downloads.cancel(request.id) }
                    .buttonStyle(.glass)
            }
        case .verifying(let fraction):
            ProgressView(value: fraction) {
                Text("Verifying the encoder's SHA-256…").font(.footnote)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(Theme.critical)
            Button("Try Again", systemImage: "arrow.clockwise") { startDownload(request) }
                .buttonStyle(.glass)
        case .completed:
            Label("Image support installed.", systemImage: "checkmark.circle")
                .font(.footnote)
        }
    }

    private func startDownload(_ request: DownloadRequest) {
        do {
            errorMessage = nil
            try downloads.start(request)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Performance

    private func performance(_ model: InstalledModel) -> some View {
        let chats = records.filter { $0.kind != .benchmark && $0.generatedTokens > 1 }
        let averageSpeed = chats.isEmpty ? nil : chats.map(\.tokensPerSecond).reduce(0, +) / Double(chats.count)
        let averageFirstToken = chats.isEmpty ? nil : chats.map(\.timeToFirstToken).reduce(0, +) / Double(chats.count)
        let totalTokens = chats.reduce(0) { $0 + $1.generatedTokens }
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Performance", subtitle: "Measured on this device. Estimates are never shown as measurements.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                if let benchmark = model.benchmark {
                    StatTile(title: "Generation (benchmark)", value: ByteFormat.rate(benchmark.tokensPerSecond),
                             detail: "± \(String(format: "%.1f", benchmark.generationStdDev)) · \(benchmark.generatedTokens) tokens", symbol: "speedometer")
                    StatTile(title: "Prompt processing", value: ByteFormat.rate(benchmark.promptTokensPerSecond),
                             detail: "\(benchmark.promptTokens)-token prompt", symbol: "text.page")
                    StatTile(title: "Time to first token", value: ByteFormat.seconds(benchmark.timeToFirstToken), symbol: "timer")
                    StatTile(title: "Peak footprint", value: ByteFormat.memory(benchmark.peakFootprintBytes), symbol: "memorychip")
                } else {
                    StatTile(title: "Benchmark", value: "Not run", detail: "Run a benchmark to measure this model on your device.", symbol: "speedometer")
                }
                if let averageSpeed {
                    StatTile(title: "Average in chats", value: ByteFormat.rate(averageSpeed), detail: "\(chats.count) responses", symbol: "bubble.left")
                }
                if let averageFirstToken {
                    StatTile(title: "Average first token", value: ByteFormat.seconds(averageFirstToken), symbol: "bolt")
                }
                if totalTokens > 0 {
                    StatTile(title: "Tokens generated", value: totalTokens.formatted(), symbol: "number")
                }
            }
        }
    }

    // MARK: File

    private func fileInfo(_ model: InstalledModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("File")
            VStack(spacing: 10) {
                LabeledValueRow(label: "File", value: model.fileName)
                LabeledValueRow(label: "Size", value: ByteFormat.file(model.sizeBytes))
                LabeledValueRow(label: "Source", value: model.repo ?? "Imported from Files")
                LabeledValueRow(label: "Verification", value: verificationText(model))
                if let sha = model.sha256 {
                    LabeledValueRow(label: "SHA-256", value: sha, monospaced: true)
                }
                LabeledValueRow(label: "Native context", value: ByteFormat.tokens(model.facts.trainContext))
                LabeledValueRow(label: "License", value: model.license ?? "See the model card")
                LabeledValueRow(label: "Added", value: model.addedAt.formatted(date: .abbreviated, time: .shortened))
            }
            .surface()
        }
    }

    private func verificationText(_ model: InstalledModel) -> String {
        switch model.verification {
        case .verified: "SHA-256 matches the publisher's hash"
        case .structureValid: "Valid GGUF (no published hash to compare)"
        case .failed: "Failed"
        }
    }

    // MARK: Actions

    private func load(_ model: InstalledModel) {
        Task {
            do {
                errorMessage = nil
                try await engine.ensureLoaded(model)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func benchmark(_ model: InstalledModel) {
        benchmarkProgress = 0
        errorMessage = nil
        Task {
            do {
                let result = try await engine.benchmark(model) { value in
                    Task { @MainActor in benchmarkProgress = value }
                }
                let context = engine.loaded[model.id]?.info.configuration.contextLength ?? 0
                AppServices.shared.container.mainContext.insert(
                    InferenceRecord(benchmark: result, modelID: model.id, modelName: model.displayName, contextSize: context))
                try? AppServices.shared.container.mainContext.save()
            } catch is CancellationError {
                // Cancelled by the user.
            } catch {
                errorMessage = error.localizedDescription
            }
            benchmarkProgress = nil
        }
    }
}

struct LabeledMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }
}
