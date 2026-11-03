import Charts
import SwiftData
import SwiftUI

/// The local knowledge library: documents whose text is stored on device and retrieved
/// passage-by-passage when a conversation references them.
struct DocumentLibrary: View {
    @Environment(\.modelContext) private var context
    @Environment(SemanticIndex.self) private var semanticIndex
    @Environment(DownloadManager.self) private var downloads
    @Query(sort: \KnowledgeDocument.createdAt, order: .reverse) private var documents: [KnowledgeDocument]
    @State private var showImporter = false
    @State private var errorMessage: String?
    @State private var isImporting = false
    @State private var preview: KnowledgeDocument?
    @State private var showRemoveEmbedder = false

    var body: some View {
        List {
            meaningSection
            Section {
                if documents.isEmpty {
                    Text("Add PDFs, Markdown, text or code. Then attach them to a conversation in its settings: OMNIA retrieves the relevant passages on device for every question.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(documents) { document in
                    Button {
                        preview = document
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: document.kind.symbol)
                                .frame(width: 30, height: 30)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(document.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text("\(document.characterCount.formatted()) characters · \(ByteFormat.file(Int64(document.byteSize))) · \(document.createdAt.relativeDescription)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    offsets.map { documents[$0] }.forEach { context.delete($0) }
                    try? context.save()
                }
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.critical)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isImporting {
                    ProgressView()
                } else {
                    Button("Add Documents", systemImage: "plus") { showImporter = true }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: DocumentExtractor.supportedTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            isImporting = true
            Task {
                for url in urls {
                    do {
                        let extracted = try await Task.detached(priority: .userInitiated) {
                            try DocumentExtractor.extract(from: url)
                        }.value
                        let title = url.deletingPathExtension().lastPathComponent
                        context.insert(KnowledgeDocument(title: title, fileName: url.lastPathComponent, kind: extracted.kind,
                                                         text: extracted.text, byteSize: extracted.byteSize))
                        errorMessage = nil
                    } catch {
                        errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
                    }
                }
                try? context.save()
                isImporting = false
                semanticIndex.scheduleIndexing()
            }
        }
        .confirmationDialog("Stop searching by meaning?", isPresented: $showRemoveEmbedder, titleVisibility: .visible) {
            Button("Remove Embedding Model", role: .destructive) {
                Task { await semanticIndex.remove() }
            }
        } message: {
            Text("The model and the document index it built are deleted. Search goes back to matching words.")
        }
        .sheet(item: $preview) { document in
            NavigationStack {
                ScrollView {
                    Text(document.text.prefix(20_000))
                        .font(.callout)
                        .textSelection(.enabled)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(document.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { preview = nil } } }
            }
        }
    }
}

extension DocumentLibrary {
    /// The optional embedding model: download, indexing progress, removal.
    @ViewBuilder
    var meaningSection: some View {
        let entry = EmbeddingCatalog.recommended
        let request = entry.downloadRequest
        Section {
            if let embedder = semanticIndex.embedder {
                let indexed = documents.filter { $0.embeddingModelID == embedder.id }.count
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Searching by meaning with \(embedder.name)").font(.subheadline.weight(.semibold))
                        Text("\(indexed) of \(documents.count) documents indexed · \(ByteFormat.file(embedder.sizeBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.tint)
                }
                if let progress = semanticIndex.progress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                        Text("Indexing \(progress.done + 1) of \(progress.total)…").font(.caption)
                    }
                }
                if let error = semanticIndex.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.caution)
                }
                Button("Remove Embedding Model", systemImage: "trash", role: .destructive) { showRemoveEmbedder = true }
            } else if let item = downloads.item(for: request.id) {
                switch item.phase {
                case .downloading, .verifying:
                    ProgressView(value: item.fraction) {
                        Text("Downloading \(entry.name) · \(Int(item.fraction * 100))%").font(.caption)
                    }
                    Button("Cancel", role: .cancel) { downloads.cancel(request.id) }
                case .paused:
                    Button("Resume Download", systemImage: "play.fill") { downloads.resume(request.id) }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.critical)
                    Button("Try Again", systemImage: "arrow.clockwise") { startDownload(request) }
                case .completed:
                    Label("\(entry.name) is installed.", systemImage: "checkmark.circle")
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Search by meaning").font(.subheadline.weight(.semibold))
                    Text("Find passages that answer a question in other words or another language, not only ones with matching words. Downloads \(entry.name) (\(ByteFormat.file(entry.sizeBytes)), \(entry.license)) once; documents are indexed on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Download \(entry.name)", systemImage: "arrow.down.circle") { startDownload(request) }
            }
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
}

/// Every measured inference on this device, aggregated per model.
struct InferenceHistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \InferenceRecord.date, order: .reverse) private var records: [InferenceRecord]
    @State private var showClear = false

    private struct ModelSummary: Identifiable {
        let id: String
        let name: String
        let runs: Int
        let tokens: Int
        let averageSpeed: Double
        let averageFirstToken: Double
    }

    private var summaries: [ModelSummary] {
        let measured: [InferenceRecord] = records.filter { $0.kind != .benchmark && $0.generatedTokens > 1 }
        let grouped: [String: [InferenceRecord]] = Dictionary(grouping: measured, by: { $0.modelID })
        var result: [ModelSummary] = []
        for (id, items) in grouped {
            let count = Double(items.count)
            let tokens: Int = items.reduce(0) { $0 + $1.generatedTokens }
            let speed: Double = items.reduce(0.0) { $0 + $1.tokensPerSecond } / count
            let firstToken: Double = items.reduce(0.0) { $0 + $1.timeToFirstToken } / count
            result.append(ModelSummary(id: id, name: items.first?.modelName ?? id, runs: items.count,
                                       tokens: tokens, averageSpeed: speed, averageFirstToken: firstToken))
        }
        return result.sorted { $0.runs > $1.runs }
    }

    var body: some View {
        List {
            if records.isEmpty {
                Text("Every response, comparison and benchmark is recorded here with its measured speed. Nothing leaves the device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !summaries.isEmpty {
                Section("By Model") {
                    ForEach(summaries) { summary in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary.name).font(.subheadline.weight(.semibold))
                            Text("\(summary.runs) responses · \(summary.tokens.formatted()) tokens · avg \(ByteFormat.rate(summary.averageSpeed)) · first token \(ByteFormat.seconds(summary.averageFirstToken))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Speed Over Time") {
                    Chart(records.filter { $0.kind != .benchmark && $0.generatedTokens > 1 }.prefix(200)) { record in
                        PointMark(x: .value("Date", record.date), y: .value("Tokens per second", record.tokensPerSecond))
                            .foregroundStyle(by: .value("Model", record.modelName))
                            .symbolSize(24)
                    }
                    .chartYAxisLabel("tok/s")
                    .frame(height: 220)
                    .padding(.vertical, 8)
                }
            }
            Section("Recent") {
                ForEach(records.prefix(100)) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.modelName).font(.subheadline)
                            Text("\(record.kind.rawValue.capitalized) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(ByteFormat.rate(record.tokensPerSecond)).font(.subheadline.monospacedDigit())
                            Text("\(record.generatedTokens) tokens").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear History", systemImage: "trash") { showClear = true }
                    .disabled(records.isEmpty)
            }
        }
        .confirmationDialog("Clear inference history?", isPresented: $showClear, titleVisibility: .visible) {
            Button("Clear \(records.count) Records", role: .destructive) {
                try? context.delete(model: InferenceRecord.self)
                try? context.save()
            }
        }
    }
}
