import CryptoKit
import Foundation
import Observation
import os

private let storeLog = Logger(subsystem: "app.omnia", category: "models")

enum ProjectorError: LocalizedError {
    case modelRemoved
    case notAnEncoder(String)

    var errorDescription: String? {
        switch self {
        case .modelRemoved:
            "The model this image support belongs to was removed."
        case .notAnEncoder(let name):
            "\(name) isn't an image encoder. Choose the mmproj .gguf file published with this model."
        }
    }
}

/// Registry of GGUF models stored on this device (Application Support/Models).
///
/// Model files are excluded from iCloud/iTunes backup: they are large and can always be
/// downloaded again. The registry itself is a small JSON file next to them.
@MainActor
@Observable
final class ModelStore {
    private(set) var models: [InstalledModel] = []
    private(set) var storageUsed: Int64 = 0

    /// Notified before a model's file is deleted so the engine can unload it first.
    @ObservationIgnored var willDeleteModel: ((InstalledModel) async -> Void)?
    /// Notified after a model gains or loses its image encoder, so a loaded copy can follow.
    @ObservationIgnored var projectorDidChange: ((InstalledModel) async -> Void)?

    let modelsDirectory: URL
    let importsInboxDirectory: URL
    private let registryURL: URL

    /// - Parameter directory: Where models and the registry live (tests); defaults to
    ///   Application Support/Models.
    init(directory: URL? = nil) {
        let fileManager = FileManager.default
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        modelsDirectory = directory ?? support.appending(path: "Models", directoryHint: .isDirectory)
        registryURL = modelsDirectory.appending(path: "registry.json")
        let documents = (try? fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        importsInboxDirectory = documents
        try? fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        ModelStore.excludeFromBackup(modelsDirectory)
        load()
    }

    // MARK: Lookup

    func model(id: String?) -> InstalledModel? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    func fileURL(for model: InstalledModel) -> URL {
        modelsDirectory.appending(path: model.relativePath)
    }

    func isInstalled(repo: String, fileName: String) -> Bool {
        models.contains { $0.repo == repo && $0.fileName == fileName }
    }

    /// The model's image encoder file, when image support is installed.
    func projectorURL(for model: InstalledModel) -> URL? {
        model.projector.map { modelsDirectory.appending(path: $0.relativePath) }
    }

    func isProjectorInstalled(repo: String?, fileName: String) -> Bool {
        let relative = ModelStore.projectorStorageName(repo: repo, fileName: fileName)
        return models.contains { $0.projector?.relativePath == relative }
    }

    var sortedByRecentUse: [InstalledModel] {
        models.sorted { ($0.lastUsedAt ?? $0.addedAt) > ($1.lastUsedAt ?? $1.addedAt) }
    }

    // MARK: Mutation

    func update(_ model: InstalledModel) {
        guard let index = models.firstIndex(where: { $0.id == model.id }) else { return }
        models[index] = model
        save()
    }

    func updateSettings(for id: String, _ change: (inout ModelSettings) -> Void) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        change(&models[index].settings)
        save()
    }

    func markUsed(_ id: String) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        models[index].lastUsedAt = .now
        save()
    }

    func recordLoad(_ id: String, info: LoadedModelInfo) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        models[index].measuredFootprint = info.measuredFootprintBytes
        models[index].measuredGPUBytes = info.measuredGPUBytes
        models[index].measuredContext = info.configuration.contextLength
        save()
    }

    func recordBenchmark(_ id: String, measurement: BenchmarkMeasurement, context: Int) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        models[index].benchmark = measurement
        models[index].benchmarkDate = .now
        models[index].benchmarkContext = context
        save()
    }

    /// Moves a verified GGUF file into the Models directory and registers it.
    @discardableResult
    func install(fileAt source: URL, id: String, displayName: String, developer: String?, repo: String?,
                 fileName: String, sha256: String?, verification: VerificationState, info: GGUFModelInfo,
                 license: String?, origin: ModelSource, catalogID: String?, moveFile: Bool) throws -> InstalledModel {
        let fileManager = FileManager.default
        let relative = ModelStore.storageName(repo: repo, fileName: fileName)
        let destination = modelsDirectory.appending(path: relative)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }
        if moveFile {
            try fileManager.moveItem(at: source, to: destination)
        } else {
            try fileManager.copyItem(at: source, to: destination)
        }
        ModelStore.excludeFromBackup(destination)

        let size = (try? fileManager.attributesOfItem(atPath: destination.path(percentEncoded: false))[.size] as? NSNumber)?.uint64Value ?? 0
        let model = InstalledModel(
            id: id,
            displayName: displayName,
            developer: developer,
            repo: repo,
            fileName: fileName,
            relativePath: relative,
            sizeBytes: size,
            sha256: sha256,
            verification: verification,
            quantization: info.quantizationLabel ?? QuantizationInfo.label(fromFileName: fileName),
            facts: ArchitectureFacts(info: info, fileSize: size),
            license: license ?? info.license,
            source: origin,
            catalogID: catalogID,
            addedAt: .now
        )
        models.removeAll { $0.id == id }
        models.append(model)
        save()
        refreshStorage()
        storeLog.info("Installed \(id, privacy: .public) (\(size) bytes)")
        return model
    }

    /// Moves a verified MLX model folder into the Models directory and registers it.
    @discardableResult
    func installFolder(at source: URL, id: String, displayName: String, developer: String?, repo: String?,
                       folderName: String, info: MLXModelInfo, verification: VerificationState,
                       license: String?, origin: ModelSource, catalogID: String?) throws -> InstalledModel {
        let fileManager = FileManager.default
        let relative = ModelStore.storageName(repo: repo, fileName: folderName)
        let destination = modelsDirectory.appending(path: relative, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
        ModelStore.excludeFromBackup(destination)

        let model = InstalledModel(
            id: id, displayName: displayName, developer: developer, repo: repo, fileName: folderName,
            relativePath: relative, sizeBytes: UInt64(max(SystemMetrics.directorySize(destination), 0)), sha256: nil,
            verification: verification, quantization: info.quantizationLabel, facts: info.facts, license: license,
            source: origin, catalogID: catalogID, addedAt: .now, format: .mlx)
        models.removeAll { $0.id == id }
        models.append(model)
        save()
        refreshStorage()
        storeLog.info("Installed MLX \(id, privacy: .public) (\(model.sizeBytes) bytes)")
        return model
    }

    func delete(_ model: InstalledModel) async {
        guard !model.isSystem else { return }
        await willDeleteModel?(model)
        try? FileManager.default.removeItem(at: fileURL(for: model))
        models.removeAll { $0.id == model.id }
        save()
        if let projector = model.projector { removeProjectorFileIfUnused(projector.relativePath) }
        refreshStorage()
    }

    // MARK: Image encoders

    /// Moves a verified image encoder into the Models directory and gives it to `modelID`, plus
    /// any other installed copy of the same catalog model that has none (they share the file).
    @discardableResult
    func installProjector(fileAt source: URL, for modelID: String, repo: String?, fileName: String,
                          sha256: String?, verification: VerificationState, moveFile: Bool) throws -> [InstalledModel] {
        guard let owner = model(id: modelID) else { throw ProjectorError.modelRemoved }
        let fileManager = FileManager.default
        let relative = ModelStore.projectorStorageName(repo: repo, fileName: fileName)
        let destination = modelsDirectory.appending(path: relative)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }
        if moveFile {
            try fileManager.moveItem(at: source, to: destination)
        } else {
            try fileManager.copyItem(at: source, to: destination)
        }
        ModelStore.excludeFromBackup(destination)
        let size = (try? fileManager.attributesOfItem(atPath: destination.path(percentEncoded: false))[.size] as? NSNumber)?.uint64Value ?? 0
        let projector = InstalledProjector(fileName: fileName, relativePath: relative, sizeBytes: size, sha256: sha256,
                                           repo: repo, verification: verification)

        var replaced: [String] = []
        var updated: [InstalledModel] = []
        for index in models.indices {
            let candidate = models[index]
            let isSibling = owner.catalogID != nil && candidate.catalogID == owner.catalogID && candidate.projector == nil
            guard candidate.id == modelID || isSibling else { continue }
            if let old = candidate.projector?.relativePath, old != relative { replaced.append(old) }
            models[index].projector = projector
            updated.append(models[index])
        }
        save()
        for path in replaced { removeProjectorFileIfUnused(path) }
        refreshStorage()
        storeLog.info("Installed image encoder \(relative, privacy: .public) for \(updated.count) model(s)")
        let notify = projectorDidChange
        Task { for model in updated { await notify?(model) } }
        return updated
    }

    /// Turns image input off for a model. The encoder file is deleted once no model uses it.
    func removeProjector(from modelID: String) async {
        guard let index = models.firstIndex(where: { $0.id == modelID }), let projector = models[index].projector else { return }
        models[index].projector = nil
        save()
        await projectorDidChange?(models[index])
        removeProjectorFileIfUnused(projector.relativePath)
        refreshStorage()
    }

    private func removeProjectorFileIfUnused(_ relativePath: String) {
        guard !models.contains(where: { $0.projector?.relativePath == relativePath }) else { return }
        try? FileManager.default.removeItem(at: modelsDirectory.appending(path: relativePath))
    }

    /// Lists models built into the system (Apple's on-device model) while they're available.
    /// They aren't written to the registry.
    func refreshSystemModels() {
        let available = AppleFoundationBackend.availability == .available
        let listed = models.contains { $0.id == AppleFoundationBackend.modelID }
        if available, !listed {
            models.append(.appleFoundation)
        } else if !available, listed {
            models.removeAll { $0.isSystem }
        }
    }

    // MARK: Maintenance

    /// Drops registry entries whose files disappeared and registers stray GGUF files. Image
    /// encoders are never models: one no model uses is a leftover and is deleted.
    func reconcile() {
        let fileManager = FileManager.default
        let missing = models.filter { !$0.isSystem && !fileManager.fileExists(atPath: fileURL(for: $0).path(percentEncoded: false)) }
        if !missing.isEmpty {
            storeLog.warning("Removing \(missing.count) registry entries with missing files")
            models.removeAll { model in missing.contains { $0.id == model.id } }
            save()
        }
        for index in models.indices {
            guard let url = projectorURL(for: models[index]),
                  !fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            storeLog.warning("Image encoder missing for \(self.models[index].id, privacy: .public)")
            models[index].projector = nil
            save()
        }
        let known = Set(models.map(\.relativePath) + models.compactMap(\.projector?.relativePath))
        if let contents = try? fileManager.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: nil) {
            for url in contents where url.pathExtension.lowercased() == "gguf" && !known.contains(url.lastPathComponent) {
                guard let inspected = try? GGUFInspector.inspect(fileAt: url) else { continue }
                let info = inspected.info
                if info.isEncoder {
                    try? fileManager.removeItem(at: url)
                    continue
                }
                let size = (try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? NSNumber)?.uint64Value ?? 0
                let model = InstalledModel(
                    id: InstalledModel.makeID(repo: nil, fileName: url.lastPathComponent),
                    displayName: info.name ?? url.deletingPathExtension().lastPathComponent,
                    developer: nil, repo: nil, fileName: url.lastPathComponent, relativePath: url.lastPathComponent,
                    sizeBytes: size, sha256: nil, verification: .structureValid,
                    quantization: info.quantizationLabel, facts: ArchitectureFacts(info: info, fileSize: size),
                    license: info.license, source: .imported, catalogID: nil, addedAt: .now)
                models.append(model)
            }
            save()
        }
        refreshStorage()
    }

    func refreshStorage() {
        let directory = modelsDirectory
        Task.detached(priority: .utility) {
            let size = SystemMetrics.directorySize(directory)
            await MainActor.run { self.storageUsed = size }
        }
    }

    /// GGUF files the user placed in OMNIA's Documents folder via the Files app or Finder.
    func inboxCandidates() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: importsInboxDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents.filter { $0.pathExtension.lowercased() == "gguf" }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: registryURL) else { return }
        do {
            models = try JSONDecoder.omnia.decode([InstalledModel].self, from: data)
        } catch {
            storeLog.error("Registry unreadable, rebuilding: \(error.localizedDescription, privacy: .public)")
            models = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder.omnia.encode(models.filter { !$0.isSystem })
            try data.write(to: registryURL, options: .atomic)
        } catch {
            storeLog.error("Registry save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Helpers

    /// Pure: also used from DownloadManager's nonisolated URLSession delegate callbacks.
    nonisolated static func storageName(repo: String?, fileName: String) -> String {
        let prefix = repo.map { $0.replacingOccurrences(of: "/", with: "__") + "__" } ?? ""
        let raw = prefix + fileName
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    /// Encoders imported from Files get their own prefix, so they can't replace a model file.
    nonisolated static func projectorStorageName(repo: String?, fileName: String) -> String {
        storageName(repo: repo ?? "imported-encoders", fileName: fileName)
    }

    static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }

    /// Streams a file through SHA-256. Reports progress in 0…1.
    nonisolated static func sha256(of url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? NSNumber)?.doubleValue ?? 0
        var hasher = SHA256()
        var processed = 0.0
        var lastReport = 0.0
        while true {
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 16 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            processed += Double(chunk.count)
            if total > 0, processed / total - lastReport > 0.01 {
                lastReport = processed / total
                progress?(lastReport)
            }
            try Task.checkCancellation()
        }
        progress?(1)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension JSONEncoder {
    static var omnia: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var omnia: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
