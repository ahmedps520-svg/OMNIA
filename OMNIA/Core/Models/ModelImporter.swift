import Foundation
import Observation
import UniformTypeIdentifiers

/// Imports GGUF files chosen in the Files app, opened from another app, or dropped into
/// OMNIA's Documents folder. Files are validated (GGUF signature and header) before use.
@MainActor
@Observable
final class ModelImporter {
    enum Phase: Equatable {
        case idle
        case copying(name: String, fraction: Double)
        case verifying(name: String)
        case failed(String)
        case imported(String)
    }

    private(set) var phase: Phase = .idle

    static let ggufType = UTType("org.ggml.gguf") ?? UTType(filenameExtension: "gguf") ?? .data

    private let store: ModelStore

    init(store: ModelStore) {
        self.store = store
    }

    var isBusy: Bool {
        switch phase {
        case .copying, .verifying: true
        default: false
        }
    }

    func reset() { phase = .idle }

    /// Imports a file the user picked. Files already inside OMNIA's container are moved; others are copied.
    func importFile(at url: URL) async {
        guard !isBusy else { return }
        let name = url.lastPathComponent
        guard url.pathExtension.lowercased() == "gguf" else {
            phase = .failed("\(name) isn't a GGUF model. OMNIA runs GGUF files (llama.cpp format).")
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let staging = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString).gguf")
        let isInsideContainer = url.path(percentEncoded: false).hasPrefix(store.importsInboxDirectory.path(percentEncoded: false))
        do {
            phase = .verifying(name: name)
            let header = try await Task.detached(priority: .userInitiated) {
                try GGUFInspector.inspect(fileAt: url)
            }.value
            if header.info.isEncoder {
                phase = .failed("\(name) is an image encoder, not a model. Open the model it belongs to in Models and add it under Image Support.")
                return
            }

            if isInsideContainer {
                try FileManager.default.moveItem(at: url, to: staging)
            } else {
                phase = .copying(name: name, fraction: 0)
                try await copy(from: url, to: staging) { [weak self] fraction in
                    Task { @MainActor in self?.phase = .copying(name: name, fraction: fraction) }
                }
            }
            phase = .verifying(name: name)
            let model = try store.install(
                fileAt: staging, id: InstalledModel.makeID(repo: nil, fileName: name),
                displayName: header.info.name ?? url.deletingPathExtension().lastPathComponent,
                developer: nil, repo: nil, fileName: name, sha256: nil, verification: .structureValid,
                info: header.info, license: header.info.license, origin: .imported, catalogID: nil, moveFile: true)
            phase = .imported(model.displayName)
        } catch {
            let fileManager = FileManager.default
            if isInsideContainer, fileManager.fileExists(atPath: staging.path(percentEncoded: false)) {
                // The original was moved out of Documents: put the user's only copy back.
                try? fileManager.moveItem(at: staging, to: url)
            } else {
                try? fileManager.removeItem(at: staging)
            }
            phase = .failed("\(name) couldn't be imported: \(error.localizedDescription)")
        }
    }

    /// Adds an image encoder (mmproj .gguf) the user picked to an installed model. Whether it
    /// matches the model is only known when llama.cpp first loads the pair.
    func importProjector(at url: URL, for model: InstalledModel) async {
        guard !isBusy else { return }
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let staging = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString).gguf")
        do {
            phase = .verifying(name: name)
            let isEncoder = await Task.detached(priority: .userInitiated) {
                GGUFInspector.isImageEncoder(fileAt: url)
            }.value
            guard isEncoder else { throw ProjectorError.notAnEncoder(name) }
            phase = .copying(name: name, fraction: 0)
            try await copy(from: url, to: staging) { [weak self] fraction in
                Task { @MainActor in self?.phase = .copying(name: name, fraction: fraction) }
            }
            try store.installProjector(fileAt: staging, for: model.id, repo: nil, fileName: name, sha256: nil,
                                       verification: .structureValid, moveFile: true)
            phase = .imported("Image support for \(model.displayName)")
        } catch {
            try? FileManager.default.removeItem(at: staging)
            phase = .failed("\(name) couldn't be added: \(error.localizedDescription)")
        }
    }

    /// Streams a copy with progress; a plain copy of a 10 GB file gives no feedback.
    private func copy(from source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            let total = Double((try? FileManager.default.attributesOfItem(atPath: source.path(percentEncoded: false))[.size] as? NSNumber)?.int64Value ?? 0)
            if let available = SystemMetrics.storage()?.availableForImportantUsage, Double(available) < total + 500_000_000 {
                throw DownloadError.insufficientStorage(needed: Int64(total), available: available)
            }
            var copied = 0.0
            var lastReport = 0.0
            while true {
                try Task.checkCancellation()
                let chunk: Data? = try autoreleasepool { try input.read(upToCount: 16 << 20) }
                guard let chunk, !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                copied += Double(chunk.count)
                if total > 0, copied / total - lastReport >= 0.01 {
                    lastReport = copied / total
                    progress(lastReport)
                }
            }
            progress(1)
        }.value
    }
}
