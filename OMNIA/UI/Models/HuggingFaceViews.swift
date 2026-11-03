import SwiftUI

/// Search public GGUF repositories on Hugging Face.
struct HuggingFaceSearchSection: View {
    @Environment(AppSettings.self) private var settings

    @State private var query = ""
    @State private var results: [HuggingFaceClient.ModelSummary] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Hugging Face", subtitle: "Search public GGUF repositories. OMNIA reads each file's header first to check its architecture and memory needs before you download.")
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search models, e.g. “Qwen3.5 GGUF”", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(search)
                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))

            if settings.offlineOnly {
                Label("Offline-only mode is on. Turn it off in Settings › Privacy to search.", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(Theme.critical)
            }
            LazyVStack(spacing: 8) {
                ForEach(results) { result in
                    NavigationLink(value: HuggingFaceRepoRoute(repo: result.id)) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(result.author).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if result.isGated {
                                Pill(text: "Requires login", symbol: "lock", tint: Theme.caution)
                            }
                            if let downloads = result.downloads {
                                Label(downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .surface(padding: 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func search() {
        let term = query.trimmed
        guard !term.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        Task {
            do {
                results = try await AppServices.shared.huggingFace.search(term)
                if results.isEmpty { errorMessage = "No GGUF repositories match “\(term)”." }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }
}

/// Files in one repository, with an on-demand fit check per file.
struct HuggingFaceRepoView: View {
    let repo: String

    @Environment(InferenceEngine.self) private var engine
    @Environment(DownloadManager.self) private var downloads
    @Environment(ModelStore.self) private var store

    @State private var files: [HuggingFaceClient.TreeEntry] = []
    @State private var detail: HuggingFaceClient.ModelDetail?
    @State private var assessments: [String: Result<(ArchitectureFacts, LoadPlan), Error>] = [:]
    @State private var inspecting: Set<String> = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// The file whose larger-than-memory download is waiting for confirmation.
    @State private var confirmingOversized: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(repo).font(.title2.weight(.semibold))
                    HStack(spacing: 8) {
                        if let license = detail?.license { Pill(text: license, symbol: "doc.text") }
                        if detail?.gated?.isGated == true { Pill(text: "Gated: login required", symbol: "lock", tint: Theme.caution) }
                    }
                    Link("View on Hugging Face", destination: HuggingFaceClient.base.appending(path: repo))
                        .font(.footnote)
                }
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(Theme.critical)
                }
                let loadable = files.filter(\.isLoadableGGUF).sorted { $0.byteSize < $1.byteSize }
                if !isLoading && loadable.isEmpty && errorMessage == nil {
                    Text("This repository has no single-file GGUF models OMNIA can load (split files and vision projectors are skipped).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 8) {
                    ForEach(loadable, id: \.path) { file in
                        fileRow(file)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .navigationTitle(repo.split(separator: "/").last.map(String.init) ?? repo)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func fileRow(_ file: HuggingFaceClient.TreeEntry) -> some View {
        let id = InstalledModel.makeID(repo: repo, fileName: file.fileName)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.fileName).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text("\(QuantizationInfo.label(fromFileName: file.fileName) ?? "GGUF") · \(ByteFormat.file(file.byteSize))\(file.sha256 == nil ? "" : " · SHA-256 published")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if store.isInstalled(repo: repo, fileName: file.fileName) {
                    Label("Downloaded", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.positive)
                } else if let item = downloads.item(for: id), item.phase.isActive || item.phase == .paused {
                    ProgressView(value: item.fraction).frame(width: 90)
                } else {
                    if assessments[file.path] == nil {
                        Button("Check Fit") { Task { await inspect(file) } }
                            .buttonStyle(.glass)
                            .disabled(inspecting.contains(file.path))
                    }
                    if exceedsMemory(file) && detail?.gated?.isGated != true {
                        Button("Download Anyway") { confirmingOversized = file.path }
                            .buttonStyle(.glass)
                            .oversizedDownloadConfirmation(
                                isPresented: Binding(get: { confirmingOversized == file.path },
                                                     set: { if !$0 { confirmingOversized = nil } }),
                                size: file.byteSize) {
                                download(file, beyondMemoryLimit: true)
                            }
                    } else {
                        Button("Download") { download(file) }
                            .buttonStyle(.glassProminent)
                            .disabled(!canDownload(file))
                    }
                }
            }
            .controlSize(.small)

            if inspecting.contains(file.path) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Reading the GGUF header…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let result = assessments[file.path] {
                switch result {
                case .success(let value):
                    HStack(spacing: 10) {
                        CompatibilityBadge(compatibility: value.1.fits ? (value.1.wasReduced ? .tight : .fits) : .tooLarge)
                        Text("\(ModelCatalog.architectureName(value.0.architecture)) · \(ParameterFormat.label(billions: value.0.parameters)) · needs \(ByteFormat.memory(value.1.estimate.total)) at \(ByteFormat.tokens(value.1.contextLength)) context")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .failure(let error):
                    Text(error.localizedDescription).font(.caption).foregroundStyle(Theme.critical)
                }
            }
        }
        .surface(padding: 12)
    }

    private func canDownload(_ file: HuggingFaceClient.TreeEntry) -> Bool {
        if detail?.gated?.isGated == true { return false }
        if case .success(let value)? = assessments[file.path] { return value.1.fits }
        return true
    }

    /// The header was read and the model doesn't fit this device's memory budget.
    private func exceedsMemory(_ file: HuggingFaceClient.TreeEntry) -> Bool {
        if case .success(let value)? = assessments[file.path] { return !value.1.fits }
        return false
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let client = AppServices.shared.huggingFace
        do {
            async let entries = client.files(repo: repo)
            async let info = client.detail(repo: repo)
            files = try await entries
            detail = try? await info
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func inspect(_ file: HuggingFaceClient.TreeEntry) async {
        inspecting.insert(file.path)
        defer { inspecting.remove(file.path) }
        do {
            let inspected = try await AppServices.shared.huggingFace.inspectGGUF(repo: repo, path: file.path)
            let facts = ArchitectureFacts(info: inspected.info, fileSize: UInt64(max(file.byteSize, 0)))
            let plan = MemoryPlanner.plan(facts, fileSize: UInt64(max(file.byteSize, 0)), requestedContext: nil,
                                          kvChoice: .automatic, profile: engine.profile,
                                          allowance: engine.currentBudget().allowance)
            assessments[file.path] = .success((facts, plan))
        } catch {
            assessments[file.path] = .failure(error)
        }
    }

    private func download(_ file: HuggingFaceClient.TreeEntry, beyondMemoryLimit: Bool = false) {
        var request = DownloadRequest(
            id: InstalledModel.makeID(repo: repo, fileName: file.fileName),
            repo: repo,
            path: file.path,
            fileName: file.fileName,
            displayName: (file.fileName as NSString).deletingPathExtension,
            developer: repo.split(separator: "/").first.map(String.init),
            expectedBytes: file.byteSize,
            sha256: file.sha256,
            license: detail?.license,
            catalogID: nil)
        if beyondMemoryLimit { request.ignoreMemoryLimit = true }
        do {
            try downloads.start(request)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
