import SwiftUI
import UniformTypeIdentifiers

struct InstalledModelRoute: Hashable {
    let id: String
}

struct HuggingFaceRepoRoute: Hashable {
    let repo: String
}

struct ModelsView: View {
    @Binding var selection: SidebarSelection?

    enum Tab: String, CaseIterable, Identifiable {
        case installed, discover, huggingFace
        var id: String { rawValue }
        var title: String {
            switch self {
            case .installed: "On Device"
            case .discover: "Recommended"
            case .huggingFace: "Hugging Face"
            }
        }
    }

    @Environment(ModelStore.self) private var store
    @Environment(DownloadManager.self) private var downloads
    @Environment(ModelImporter.self) private var importer
    @Environment(InferenceEngine.self) private var engine

    @State private var tab: Tab = .discover
    @State private var showImporter = false
    @State private var didChooseInitialTab = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MemoryBudgetHeader()

                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)

                switch tab {
                case .installed: installed
                case .discover: DiscoverModelsSection()
                case .huggingFace: HuggingFaceSearchSection()
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .navigationTitle("Models")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Import from Files…", systemImage: "folder") { showImporter = true }
                    Button("Import from OMNIA Folder", systemImage: "tray.and.arrow.down") { importInbox() }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(importer.isBusy)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [ModelImporter.ggufType, .data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await importer.importFile(at: url) }
            }
        }
        .navigationDestination(for: CatalogModel.self) { model in
            CatalogModelDetailView(model: model)
        }
        .navigationDestination(for: InstalledModelRoute.self) { route in
            InstalledModelDetailView(modelID: route.id)
        }
        .navigationDestination(for: HuggingFaceRepoRoute.self) { route in
            HuggingFaceRepoView(repo: route.repo)
        }
        .onAppear {
            guard !didChooseInitialTab else { return }
            didChooseInitialTab = true
            tab = store.models.isEmpty && downloads.items.isEmpty ? .discover : .installed
        }
    }

    @ViewBuilder
    private var installed: some View {
        if !downloads.items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Downloads", subtitle: "Downloads continue in the background and are verified with SHA-256 before use.")
                ForEach(downloads.sortedItems) { item in
                    DownloadRow(item: item)
                }
            }
        }

        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("On This Device", subtitle: "\(store.models.count) \(store.models.count == 1 ? "model" : "models") · \(ByteFormat.file(store.storageUsed)) · available offline")
            if store.models.isEmpty {
                OmniaEmptyState(
                    title: "No models yet",
                    message: "Download a recommended model, search Hugging Face, or import a GGUF file from the Files app. Copy GGUF files into On My iPad › OMNIA to import them without the network.",
                    symbol: "cube.transparent",
                    actionTitle: "See Recommendations",
                    action: { tab = .discover })
                .frame(minHeight: 280)
            } else {
                VStack(spacing: 10) {
                    ForEach(store.sortedByRecentUse) { model in
                        NavigationLink(value: InstalledModelRoute(id: model.id)) {
                            InstalledModelRow(model: model)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func importInbox() {
        let candidates = store.inboxCandidates()
        guard !candidates.isEmpty else {
            engine.post("tray", "No GGUF files found. In the Files app, copy models into On My iPad › OMNIA, then try again.")
            return
        }
        Task {
            for url in candidates {
                await importer.importFile(at: url)
            }
        }
    }
}

// MARK: - Budget header

struct MemoryBudgetHeader: View {
    @Environment(InferenceEngine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(PerformanceMonitor.self) private var monitor

    private let device = AppServices.shared.device

    var body: some View {
        let budget = engine.currentBudget()
        let loaded = engine.loadedModels
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name).font(.headline)
                    Text("\(engine.profile.title) profile · \(ByteFormat.memory(budget.usable)) available for models")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let storage = SystemMetrics.storage() {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(ByteFormat.file(storage.availableForImportantUsage)).font(.headline).monospacedDigit()
                        Text("storage free").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            MemoryBreakdownBar(
                segments: loaded.map { entry in
                    MemoryBreakdownBar.Segment(label: entry.info.displayName, bytes: entry.plan.estimate.total, color: .accentColor)
                },
                capacity: budget.usable
            )
            Text(budget.isMeasured
                 ? "Limits are measured live from iOS (app memory limit, Metal working set and physical memory) with a safety margin, so a model is never loaded if it risks being terminated."
                 : "Running in the Simulator: memory limits are estimated and inference runs on the CPU.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .surface()
    }
}

// MARK: - Rows

struct InstalledModelRow: View {
    let model: InstalledModel
    @Environment(InferenceEngine.self) private var engine
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(engine.isLoaded(model.id) ? 0.18 : 0.08))
                    .frame(width: 42, height: 42)
                Image(systemName: engine.isLoaded(model.id) ? "cpu.fill" : "cube")
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName).font(.headline).lineLimit(1)
                    if settings.defaultModelID == model.id {
                        Pill(text: "Default", tint: .accentColor)
                    }
                    if model.supportsImages {
                        Pill(text: "Images", symbol: "photo")
                    }
                }
                Text("\(model.parameterLabel) · \(model.quantization ?? "GGUF") · \(ModelCatalog.architectureName(model.facts.architecture)) · \(ByteFormat.file(model.sizeBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if engine.loadingModelID == model.id {
                    ProgressView(value: engine.loadProgress).frame(width: 70)
                } else if engine.isLoaded(model.id) {
                    Pill(text: "Loaded", symbol: "bolt.fill", tint: Theme.positive)
                } else {
                    Pill(text: model.verification == .verified ? "Verified" : "Ready", symbol: "checkmark.seal", tint: .secondary)
                }
                if let benchmark = model.benchmark {
                    Text(ByteFormat.rate(benchmark.tokensPerSecond)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .surface(padding: 14)
        .contentShape(Rectangle())
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.request.displayName).font(.headline).lineLimit(1)
                    Text(status).font(.caption).foregroundStyle(statusColor).lineLimit(3)
                }
                Spacer(minLength: 12)
                controls
            }
            switch item.phase {
            case .downloading, .paused:
                ProgressView(value: item.fraction)
            case .verifying(let fraction):
                ProgressView(value: fraction)
                    .tint(Theme.positive)
            default:
                EmptyView()
            }
        }
        .surface(padding: 14)
    }

    private var status: String {
        switch item.phase {
        case .downloading:
            var parts = ["\(ByteFormat.file(item.receivedBytes)) of \(ByteFormat.file(item.totalBytes))"]
            if item.bytesPerSecond > 0 { parts.append(ByteFormat.speed(item.bytesPerSecond)) }
            if let remaining = item.remainingSeconds { parts.append("\(ByteFormat.seconds(remaining)) left") }
            return parts.joined(separator: " · ")
        case .paused:
            return "Paused · \(ByteFormat.file(item.receivedBytes)) of \(ByteFormat.file(item.totalBytes))"
        case .verifying:
            return "Verifying SHA-256 and GGUF structure…"
        case .failed(let message):
            return message
        case .completed:
            return "Verified and installed"
        }
    }

    private var statusColor: Color {
        switch item.phase {
        case .failed: Theme.critical
        case .completed: Theme.positive
        default: .secondary
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 6) {
            switch item.phase {
            case .downloading:
                Button { downloads.pause(item.id) } label: { Image(systemName: "pause.fill") }
                    .accessibilityLabel("Pause")
                Button(role: .destructive) { downloads.cancel(item.id) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Cancel")
            case .paused:
                Button { downloads.resume(item.id) } label: { Image(systemName: "play.fill") }
                    .accessibilityLabel("Resume")
                Button(role: .destructive) { downloads.cancel(item.id) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Cancel")
            case .failed:
                Button { downloads.resume(item.id) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Retry")
                Button { downloads.dismiss(item.id) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Dismiss")
            case .verifying, .completed:
                EmptyView()
            }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
    }
}
