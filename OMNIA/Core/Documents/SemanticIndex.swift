import Foundation
import Observation
import os
import SwiftData
import UIKit

private let indexLog = Logger(subsystem: "app.omnia", category: "semantic-index")

/// The embedding model OMNIA offers for the library.
enum EmbeddingCatalog {
    struct Entry: Sendable {
        let id: String
        let name: String
        let repo: String
        let fileName: String
        let sizeBytes: Int64
        let sha256: String
        let license: String
        /// Put before a search, and before each passage ("{title}" is the document's title).
        let queryPrefix: String
        let documentPrefix: String
        let contextLength: Int

        var downloadRequest: DownloadRequest {
            DownloadRequest(id: "embedding/\(repo)/\(fileName)", repo: repo, path: fileName, fileName: fileName,
                            displayName: name, developer: "Google", expectedBytes: sizeBytes, sha256: sha256,
                            license: license, catalogID: nil, embeddingModel: true)
        }
    }

    /// EmbeddingGemma 2 (Google DeepMind, Apache 2.0, September 2026): 768-dimension vectors in
    /// over 100 languages from a 310 MB file. Size and SHA-256 verified on Hugging Face on
    /// 2026-11-03; the prompts are the model card's retrieval prompts.
    static let recommended = Entry(
        id: "embeddinggemma-2-q8_0",
        name: "EmbeddingGemma 2",
        repo: "ggml-org/embeddinggemma-2-GGUF",
        fileName: "embeddinggemma-2-Q8_0.gguf",
        sizeBytes: 309_855_456,
        sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135",
        license: "Apache 2.0",
        queryPrefix: "task: search result | query: ",
        documentPrefix: "title: {title} | text: ",
        contextLength: 2048
    )
}

/// Embedding vectors stored compactly: Float16 halves the space, and cosine similarity between
/// unit vectors doesn't need more precision.
enum EmbeddingVectors {
    static func pack(_ vectors: [[Float]]) -> Data {
        let halves: [Float16] = vectors.flatMap { vector in vector.map { Float16($0) } }
        return halves.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// `count` vectors from `pack`; empty if the data doesn't hold that many whole vectors.
    static func unpack(_ data: Data, count: Int) -> [[Float]] {
        let values = data.count / MemoryLayout<Float16>.stride
        guard count > 0, values > 0, values % count == 0 else { return [] }
        let dimensions = values / count
        return data.withUnsafeBytes { raw in
            (0..<count).map { vector in
                (0..<dimensions).map { component in
                    Float(raw.loadUnaligned(fromByteOffset: (vector * dimensions + component) * MemoryLayout<Float16>.stride,
                                            as: Float16.self))
                }
            }
        }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for index in 0..<min(a.count, b.count) { sum += a[index] * b[index] }
        return sum
    }
}

/// Library passages with their meaning vectors, aligned; a passage of a document that isn't
/// indexed (yet) has no vector and ranks by keywords only.
struct IndexedChunks: Sendable {
    var chunks: [DocumentChunk] = []
    var vectors: [[Float]?] = []

    /// Plain chunks, without meaning vectors.
    init(documents: [KnowledgeDocument]) {
        for document in documents {
            let pieces = Retrieval.chunk(document.text, title: document.title)
            chunks += pieces
            vectors += Array(repeating: nil, count: pieces.count)
        }
    }

    init(chunks: [DocumentChunk] = [], vectors: [[Float]?]? = nil) {
        self.chunks = chunks
        self.vectors = vectors ?? Array(repeating: nil, count: chunks.count)
    }

    var hasVectors: Bool { vectors.contains { $0 != nil } }

    /// Each passage's cosine similarity to `query` (a normalized vector); -1 without a vector.
    func similarities(to query: [Float]) -> [Float] {
        vectors.map { $0.map { EmbeddingVectors.dot($0, query) } ?? -1 }
    }
}

/// Finds library passages by meaning: an optional embedding model turns every document chunk
/// into a vector once, stored with the document, and each question into a vector when asked.
///
/// The model loads on demand and is released after a short idle time. Embedding runs on the GPU,
/// so it stops when OMNIA leaves the screen and resumes when it returns.
@MainActor
@Observable
final class SemanticIndex {
    /// The installed embedding model.
    struct Embedder: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var fileName: String
        var sizeBytes: UInt64
        var sha256: String?
        var queryPrefix: String
        var documentPrefix: String
        var contextLength: Int

        func documentText(_ text: String, title: String) -> String {
            documentPrefix.replacingOccurrences(of: "{title}", with: title) + text
        }
    }

    private(set) var embedder: Embedder?
    /// Documents embedded so far in the indexing run in progress.
    private(set) var progress: (done: Int, total: Int)?
    private(set) var lastError: String?

    let directory: URL
    /// Creates the runtime (tests substitute a smaller model's settings).
    @ObservationIgnored var loadRuntime: @Sendable (URL, Embedder) async throws -> EmbeddingRuntime = { url, embedder in
        try await EmbeddingRuntime.load(fileURL: url, contextLength: embedder.contextLength)
    }
    @ObservationIgnored private var runtime: EmbeddingRuntime?
    @ObservationIgnored private var loading: Task<EmbeddingRuntime, Error>?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var indexingTask: Task<Void, Never>?
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    private let container: ModelContainer

    /// Seconds without use before the model is released.
    static let idleRelease: Duration = .seconds(90)
    /// Passages per embedding call while indexing, so each GPU job stays short.
    static let indexingBatch = 16

    init(container: ModelContainer, directory: URL? = nil) {
        self.container = container
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? support.appending(path: "Models/Embeddings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        ModelStore.excludeFromBackup(self.directory)
        loadRegistry()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            },
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { Task { await self?.releaseRuntime() } }
            }
        ]
    }

    var isReady: Bool { embedder != nil }

    var fileURL: URL? { embedder.map { directory.appending(path: $0.fileName) } }

    // MARK: Install

    /// Moves a verified embedding model into place and indexes the library with it.
    func install(fileAt source: URL, embedder: Embedder, moveFile: Bool) throws {
        let fileManager = FileManager.default
        let destination = directory.appending(path: embedder.fileName)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }
        if moveFile {
            try fileManager.moveItem(at: source, to: destination)
        } else {
            try fileManager.copyItem(at: source, to: destination)
        }
        ModelStore.excludeFromBackup(destination)
        if let previous = self.embedder, previous.fileName != embedder.fileName {
            try? fileManager.removeItem(at: directory.appending(path: previous.fileName))
        }
        indexingTask?.cancel()
        indexingTask = nil
        // A runtime of the previous model must never serve the new one.
        if let previous = runtime {
            runtime = nil
            Task { await previous.close() }
        }
        self.embedder = embedder
        lastError = nil
        saveRegistry()
        scheduleIndexing()
    }

    func install(fileAt source: URL, entry: EmbeddingCatalog.Entry, sha256: String?) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path(percentEncoded: false))[.size] as? NSNumber)?.uint64Value
            ?? UInt64(entry.sizeBytes)
        try install(fileAt: source, embedder: Embedder(id: entry.id, name: entry.name, fileName: entry.fileName, sizeBytes: size,
                                                       sha256: sha256, queryPrefix: entry.queryPrefix,
                                                       documentPrefix: entry.documentPrefix, contextLength: entry.contextLength),
                    moveFile: true)
    }

    /// Removes the model and the vectors it made; search goes back to keywords only.
    func remove() async {
        indexingTask?.cancel()
        indexingTask = nil
        progress = nil
        await releaseRuntime()
        guard let removed = embedder else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: removed.fileName))
        embedder = nil
        saveRegistry()
        let context = container.mainContext
        let indexed = ((try? context.fetch(FetchDescriptor<KnowledgeDocument>())) ?? []).filter { $0.embeddingModelID == removed.id }
        for document in indexed {
            document.embeddingsData = nil
            document.embeddingModelID = nil
            document.embeddingCount = nil
        }
        try? context.save()
    }

    // MARK: Search

    /// The library documents' passages with the vectors this model made for them.
    func chunks(of documents: [KnowledgeDocument]) -> IndexedChunks {
        var result = IndexedChunks()
        for document in documents {
            let pieces = Retrieval.chunk(document.text, title: document.title)
            var vectors: [[Float]] = []
            if let embedder, document.embeddingModelID == embedder.id, document.embeddingCount == pieces.count,
               let data = document.embeddingsData {
                vectors = EmbeddingVectors.unpack(data, count: pieces.count)
            }
            result.chunks += pieces
            result.vectors += vectors.count == pieces.count ? vectors.map { Optional($0) } : Array(repeating: nil, count: pieces.count)
        }
        return result
    }

    /// The meaning vector of a question, or nil when no model is installed or it can't run now
    /// (search then uses keywords only).
    func queryVector(_ text: String) async -> [Float]? {
        guard let embedder, !text.trimmed.isEmpty, !isSuspended else { return nil }
        do {
            let runtime = try await runtimeForUse()
            return try await runtime.embed([embedder.queryPrefix + text]).first
        } catch {
            indexLog.error("Query embedding failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Indexing

    /// Indexes, one after another, the documents that have no vectors from this model yet.
    func scheduleIndexing() {
        guard embedder != nil, indexingTask == nil, !isSuspended else { return }
        indexingTask = Task { [weak self] in
            // Documents added during a pass are picked up by the next one.
            while await self?.indexPending() == true {}
            self?.indexingTask = nil
        }
    }

    /// Waits for the indexing in progress, if any.
    func waitForIndexing() async {
        await indexingTask?.value
    }

    /// One pass over the documents not indexed yet. Returns true when it got through them all,
    /// so another pass can look for documents added meanwhile.
    private func indexPending() async -> Bool {
        guard let embedder else { return false }
        let context = container.mainContext
        let id = embedder.id
        let descriptor = FetchDescriptor<KnowledgeDocument>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let pending = ((try? context.fetch(descriptor)) ?? []).filter { $0.embeddingModelID != id }
        guard !pending.isEmpty else { return false }
        progress = (0, pending.count)
        defer { progress = nil }
        for (offset, document) in pending.enumerated() {
            guard !Task.isCancelled, !isSuspended, self.embedder?.id == id else { return false }
            let pieces = Retrieval.chunk(document.text, title: document.title)
            let texts = pieces.map { embedder.documentText($0.text, title: document.title) }
            do {
                var vectors: [[Float]] = []
                for start in stride(from: 0, to: texts.count, by: Self.indexingBatch) {
                    guard !Task.isCancelled, !isSuspended else { return false }
                    let runtime = try await runtimeForUse()
                    vectors += try await runtime.embed(Array(texts[start..<min(start + Self.indexingBatch, texts.count)]))
                }
                // The document may have been deleted, or the model changed, while it was read.
                guard !document.isDeleted, self.embedder?.id == id else { continue }
                document.embeddingsData = EmbeddingVectors.pack(vectors)
                document.embeddingModelID = id
                document.embeddingCount = vectors.count
                try? context.save()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                indexLog.error("Indexing stopped: \(error.localizedDescription, privacy: .public)")
                return false
            }
            progress = (offset + 1, pending.count)
        }
        return true
    }

    // MARK: Runtime

    private func runtimeForUse() async throws -> EmbeddingRuntime {
        releaseTask?.cancel()
        defer { scheduleRelease() }
        if let runtime { return runtime }
        if let loading { return try await loading.value }
        guard let embedder, let url = fileURL else { throw EmbeddingRuntime.Failure.loadFailed }
        if let available = SystemMetrics.availableMemory(), available < embedder.sizeBytes + (384 << 20) {
            throw InferenceError.insufficientMemory(required: embedder.sizeBytes + (384 << 20), available: available,
                                                    suggestion: "Searching by meaning resumes when more memory is free.")
        }
        let load = loadRuntime
        let task = Task { try await load(url, embedder) }
        loading = task
        defer { loading = nil }
        let loaded = try await task.value
        // The model may have been removed or replaced while it loaded.
        guard self.embedder == embedder else {
            await loaded.close()
            throw EmbeddingRuntime.Failure.loadFailed
        }
        runtime = loaded
        return loaded
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleRelease)
            guard !Task.isCancelled else { return }
            await self?.releaseRuntime()
        }
    }

    func releaseRuntime() async {
        releaseTask?.cancel()
        guard let runtime else { return }
        self.runtime = nil
        await runtime.close()
    }

    private func suspend() {
        isSuspended = true
        indexingTask?.cancel()
        indexingTask = nil
        Task { await releaseRuntime() }
    }

    private func resume() {
        isSuspended = false
        scheduleIndexing()
    }

    // MARK: Registry

    private var registryURL: URL { directory.appending(path: "embedder.json") }

    private func loadRegistry() {
        guard let data = try? Data(contentsOf: registryURL),
              let stored = try? JSONDecoder().decode(Embedder.self, from: data),
              FileManager.default.fileExists(atPath: directory.appending(path: stored.fileName).path(percentEncoded: false)) else { return }
        embedder = stored
    }

    private func saveRegistry() {
        if let embedder, let data = try? JSONEncoder().encode(embedder) {
            try? data.write(to: registryURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: registryURL)
        }
    }
}
