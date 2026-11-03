import Foundation
import Observation
import os

private let downloadLog = Logger(subsystem: "app.omnia", category: "downloads")

struct DownloadRequest: Codable, Hashable, Sendable {
    var id: String
    var repo: String
    /// Path of the file inside the repository.
    var path: String
    var fileName: String
    var displayName: String
    var developer: String?
    var expectedBytes: Int64
    /// SHA-256 published by the Hub for this file (the Git LFS object id).
    var sha256: String?
    var license: String?
    var catalogID: String?
    /// For an image encoder: the installed model it's for (it isn't a model of its own).
    var projectorFor: String? = nil
    /// The library's embedding model (see `SemanticIndex`), not a chat model.
    var embeddingModel: Bool? = nil
    /// For a model that is a folder of files (MLX): they download one after another, each
    /// verified, and the folder is installed once all are in. `fileName` names the folder,
    /// `expectedBytes` is the total, and `path` and `sha256` aren't used.
    var files: [ModelFile]? = nil
    /// The repository commit to download from; nil means the latest.
    var revision: String? = nil
    /// Downloaded although it's larger than the memory budget: it may load beyond the limit.
    var ignoreMemoryLimit: Bool? = nil
}

/// One file of a model that is a folder.
struct ModelFile: Codable, Hashable, Sendable {
    /// Path in the repository, and in the installed folder.
    var path: String
    var bytes: Int64
    /// SHA-256 the Hub publishes for large (Git LFS) files; small ones have none.
    var sha256: String?
}

enum DownloadPhase: Equatable, Sendable {
    case downloading
    case paused
    case verifying(Double)
    case failed(String)
    case completed

    var isActive: Bool {
        switch self {
        case .downloading, .verifying: true
        default: false
        }
    }
}

struct DownloadItem: Identifiable, Sendable {
    var request: DownloadRequest
    var phase: DownloadPhase
    var receivedBytes: Int64
    var totalBytes: Int64
    var bytesPerSecond: Double = 0
    var startedAt: Date = .now
    /// For a folder: the file downloading now, and the bytes of the files already verified.
    var fileIndex = 0
    var completedBytes: Int64 = 0

    var id: String { request.id }
    var fraction: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }
    var remainingSeconds: Double? {
        guard bytesPerSecond > 1, totalBytes > receivedBytes else { return nil }
        return Double(totalBytes - receivedBytes) / bytesPerSecond
    }
}

enum DownloadError: LocalizedError {
    case insufficientStorage(needed: Int64, available: Int64)
    case alreadyDownloading
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case let .insufficientStorage(needed, available):
            "Not enough storage: this model needs \(ByteFormat.file(needed)) and \(ByteFormat.file(available)) is free. Delete unused models in Settings › Storage."
        case .alreadyDownloading:
            "This model is already downloading."
        case let .sizeMismatch(expected, actual):
            "The download is incomplete (\(ByteFormat.file(actual)) of \(ByteFormat.file(expected))). It was removed; please try again."
        case .checksumMismatch:
            "The file's SHA-256 doesn't match the publisher's hash. It was removed to protect you from a corrupted model."
        }
    }
}

/// Downloads models with a background URLSession so transfers continue while OMNIA is
/// suspended, survive relaunches, can be paused and resumed, and are verified before use.
@MainActor
@Observable
final class DownloadManager: NSObject {
    nonisolated static let sessionIdentifier = "app.omnia.model-downloads"

    private(set) var items: [String: DownloadItem] = [:]
    var onInstalled: ((InstalledModel) -> Void)?
    /// Image support finished installing for these models.
    var onProjectorInstalled: (([InstalledModel]) -> Void)?

    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var pausing: Set<String> = []
    @ObservationIgnored private var cancelling: Set<String> = []
    @ObservationIgnored private var restartedOnce: Set<String> = []
    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?
    @ObservationIgnored private var speedReference: [String: (date: Date, bytes: Int64)] = [:]
    private let store: ModelStore
    private let semanticIndex: SemanticIndex?
    private let settings: AppSettings
    private nonisolated let progressThrottle = OSAllocatedUnfairLock<[String: TimeInterval]>(initialState: [:])

    var sortedItems: [DownloadItem] {
        items.values.sorted { $0.startedAt < $1.startedAt }
    }

    var hasActiveDownloads: Bool { items.values.contains { $0.phase.isActive } }

    init(store: ModelStore, semanticIndex: SemanticIndex? = nil, settings: AppSettings) {
        self.store = store
        self.semanticIndex = semanticIndex
        self.settings = settings
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForResource = 60 * 60 * 24 * 7
        configuration.httpMaximumConnectionsPerHost = 2
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "app.omnia.downloads.delegate"
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        try? FileManager.default.createDirectory(at: Self.stagingDirectory, withIntermediateDirectories: true)
        ModelStore.excludeFromBackup(Self.stagingDirectory)
        restoreState()
        reattachRunningTasks()
    }

    // MARK: Paths

    nonisolated static var stagingDirectory: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    nonisolated static func stagingURL(for id: String) -> URL {
        stagingDirectory.appending(path: ModelStore.storageName(repo: nil, fileName: id) + ".part")
    }

    /// A folder's file, downloaded and waiting to be verified.
    nonisolated static func stagingURL(for id: String, file index: Int) -> URL {
        stagingDirectory.appending(path: ModelStore.storageName(repo: nil, fileName: id) + ".part\(index)")
    }

    /// Where a folder's verified files gather until it's installed.
    nonisolated static func folderStagingURL(for id: String) -> URL {
        stagingDirectory.appending(path: ModelStore.storageName(repo: nil, fileName: id) + ".folder", directoryHint: .isDirectory)
    }

    /// A task's description: the download's ID, then the file's index for a folder.
    nonisolated static func taskDescription(id: String, file: Int?) -> String {
        file.map { "\(id)\n\($0)" } ?? id
    }

    nonisolated static func parseTaskDescription(_ description: String) -> (id: String, file: Int?) {
        let parts = description.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count == 2, let index = Int(parts[1]) else { return (description, nil) }
        return (String(parts[0]), index)
    }

    private static func resumeDataURL(for id: String) -> URL {
        stagingDirectory.appending(path: ModelStore.storageName(repo: nil, fileName: id) + ".resume")
    }

    private static var stateURL: URL { stagingDirectory.appending(path: "downloads.json") }

    // MARK: Public API

    func item(for id: String) -> DownloadItem? { items[id] }

    func start(_ request: DownloadRequest) throws {
        if settings.offlineOnly { throw HuggingFaceClient.ClientError.offlineMode }
        if let existing = items[request.id], existing.phase.isActive { throw DownloadError.alreadyDownloading }
        if let storage = SystemMetrics.storage() {
            let margin: Int64 = 1_000_000_000
            if storage.availableForImportantUsage < request.expectedBytes + margin {
                throw DownloadError.insufficientStorage(needed: request.expectedBytes + margin,
                                                        available: storage.availableForImportantUsage)
            }
        }
        deleteResumeData(request.id)
        launch(request, resumeData: nil)
    }

    func pause(_ id: String) {
        guard let task = tasks[id] else { return }
        pausing.insert(id)
        task.cancel { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                // The transfer may have finished just before the pause landed; don't
                // clobber a newer task or a verification in progress.
                if self.tasks[id] === task { self.tasks[id] = nil }
                guard self.items[id]?.phase == .downloading else {
                    self.pausing.remove(id)
                    return
                }
                if let data { self.saveResumeData(data, for: id) }
                self.items[id]?.phase = .paused
                self.items[id]?.bytesPerSecond = 0
                self.saveState()
            }
        }
    }

    func resume(_ id: String) {
        guard let item = items[id] else { return }
        if settings.offlineOnly {
            items[id]?.phase = .failed(HuggingFaceClient.ClientError.offlineMode.localizedDescription)
            return
        }
        launch(item.request, resumeData: loadResumeData(for: id))
    }

    func cancel(_ id: String) {
        // Only a live task reports back; a flag left for a paused/failed item would swallow
        // the next failure of a fresh download of the same model.
        if let task = tasks[id] {
            cancelling.insert(id)
            task.cancel()
        }
        let fileIndex = items[id]?.fileIndex
        tasks[id] = nil
        items[id] = nil
        deleteResumeData(id)
        try? FileManager.default.removeItem(at: Self.stagingURL(for: id))
        if let fileIndex {
            try? FileManager.default.removeItem(at: Self.stagingURL(for: id, file: fileIndex))
        }
        try? FileManager.default.removeItem(at: Self.folderStagingURL(for: id))
        saveState()
    }

    func dismiss(_ id: String) {
        guard let item = items[id], !item.phase.isActive else { return }
        items[id] = nil
        saveState()
    }

    /// Bytes still to be written by active downloads (for storage planning).
    var pendingBytes: Int64 {
        items.values.filter { $0.phase.isActive || $0.phase == .paused }
            .reduce(0) { $0 + max(0, $1.totalBytes - $1.receivedBytes) }
    }

    // MARK: Internals

    private func launch(_ request: DownloadRequest, resumeData: Data?) {
        let previous = items[request.id]
        // A folder carries on with the file it had reached; the files before it are verified.
        let fileIndex = request.files == nil ? 0 : (previous?.fileIndex ?? 0)
        let completed = request.files == nil ? 0 : (previous?.completedBytes ?? 0)
        let file = request.files.flatMap { fileIndex < $0.count ? $0[fileIndex] : nil }
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var urlRequest = URLRequest(url: HuggingFaceClient.downloadURL(repo: request.repo, path: file?.path ?? request.path,
                                                                           revision: request.revision ?? "main"))
            urlRequest.allowsCellularAccess = settings.allowCellularDownloads
            urlRequest.allowsExpensiveNetworkAccess = settings.allowCellularDownloads
            task = session.downloadTask(with: urlRequest)
        }
        task.taskDescription = Self.taskDescription(id: request.id, file: request.files == nil ? nil : fileIndex)
        task.countOfBytesClientExpectsToReceive = file?.bytes ?? request.expectedBytes
        task.priority = URLSessionTask.highPriority
        tasks[request.id] = task
        items[request.id] = DownloadItem(
            request: request,
            phase: .downloading,
            receivedBytes: resumeData == nil ? completed : (previous?.receivedBytes ?? completed),
            totalBytes: request.expectedBytes,
            startedAt: previous?.startedAt ?? .now,
            fileIndex: fileIndex,
            completedBytes: completed
        )
        speedReference[request.id] = nil
        task.resume()
        saveState()
        downloadLog.info("Started \(request.id, privacy: .public) resume=\(resumeData != nil)")
    }

    private func reattachRunningTasks() {
        session.getAllTasks { [weak self] running in
            let pairs = running.compactMap { task -> (String, URLSessionDownloadTask)? in
                guard let download = task as? URLSessionDownloadTask, let description = download.taskDescription else { return nil }
                return (DownloadManager.parseTaskDescription(description).id, download)
            }
            Task { @MainActor in
                guard let self else { return }
                for (id, task) in pairs {
                    self.tasks[id] = task
                    if self.items[id] != nil { self.items[id]?.phase = .downloading }
                }
                // Anything recorded as downloading without a live task was interrupted, unless it had
                // finished and OMNIA was terminated while verifying it: verify the staged file again.
                for (id, item) in self.items where item.phase == .downloading && self.tasks[id] == nil {
                    let file = item.request.files == nil ? nil : item.fileIndex
                    let staged = file.map { DownloadManager.stagingURL(for: id, file: $0) } ?? DownloadManager.stagingURL(for: id)
                    if FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)) {
                        self.handleDownloaded(id, file: file, stagedAt: staged)
                    } else {
                        self.items[id]?.phase = self.loadResumeData(for: id) != nil ? .paused : .failed("The download was interrupted. Tap retry to start again.")
                    }
                }
                self.saveState()
            }
        }
    }

    fileprivate func updateProgress(_ id: String, file: Int?, received: Int64, expected: Int64) {
        guard var item = items[id], item.phase == .downloading else { return }
        if item.request.files != nil {
            // A folder's progress spans its files; a late report from a finished file is ignored.
            guard file == item.fileIndex else { return }
            item.receivedBytes = item.completedBytes + received
        } else {
            item.receivedBytes = received
            if expected > 0 { item.totalBytes = expected }
        }
        let total = item.receivedBytes
        let now = Date()
        if let reference = speedReference[id] {
            let elapsed = now.timeIntervalSince(reference.date)
            if elapsed >= 1 {
                let instant = Double(total - reference.bytes) / elapsed
                item.bytesPerSecond = item.bytesPerSecond == 0 ? instant : item.bytesPerSecond * 0.7 + instant * 0.3
                speedReference[id] = (now, total)
            }
        } else {
            speedReference[id] = (now, total)
        }
        items[id] = item
    }

    fileprivate func handleFailure(_ id: String, resumeData: Data?, wasCancelled: Bool, message: String) {
        tasks[id] = nil
        if cancelling.remove(id) != nil { return }
        if pausing.remove(id) != nil { return } // handled by the pause completion
        if let resumeData { saveResumeData(resumeData, for: id) }
        guard items[id] != nil else { return }
        items[id]?.bytesPerSecond = 0
        if wasCancelled {
            items[id]?.phase = .paused
        } else {
            items[id]?.phase = resumeData != nil ? .paused : .failed(message)
        }
        saveState()
    }

    fileprivate func handleHTTPFailure(_ id: String, status: Int) {
        tasks[id] = nil
        guard let item = items[id] else { return }
        // Signed CDN links expire; a stale resume link gets 403/410. Restart cleanly once.
        if (status == 403 || status == 410 || status == 416) && loadResumeData(for: id) != nil && !restartedOnce.contains(id) {
            restartedOnce.insert(id)
            deleteResumeData(id)
            launch(item.request, resumeData: nil)
            return
        }
        let message: String
        switch status {
        case 401, 403: message = HuggingFaceClient.ClientError.gated(item.request.repo).localizedDescription
        case 404: message = HuggingFaceClient.ClientError.notFound.localizedDescription
        default: message = "The server responded with HTTP \(status)."
        }
        items[id]?.phase = .failed(message)
        deleteResumeData(id)
        saveState()
    }

    fileprivate func handleDownloaded(_ id: String, file: Int?, stagedAt staged: URL) {
        if let file {
            handleFolderFile(id, file: file, stagedAt: staged)
            return
        }
        if case .verifying? = items[id]?.phase { return } // already being verified (relaunch recovery)
        tasks[id] = nil
        restartedOnce.remove(id)
        deleteResumeData(id)
        guard let item = items[id] else {
            try? FileManager.default.removeItem(at: staged)
            return
        }
        items[id]?.phase = .verifying(0)
        items[id]?.receivedBytes = item.totalBytes
        items[id]?.bytesPerSecond = 0
        saveState()
        let request = item.request

        Task.detached(priority: .utility) { [weak self] in
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: staged.path(percentEncoded: false))
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                if request.expectedBytes > 0, size != request.expectedBytes {
                    throw DownloadError.sizeMismatch(expected: request.expectedBytes, actual: size)
                }
                var digest: String?
                if let expected = request.sha256?.lowercased(), !expected.isEmpty {
                    let computed = try ModelStore.sha256(of: staged) { fraction in
                        Task { @MainActor in self?.items[request.id]?.phase = .verifying(fraction) }
                    }
                    guard computed == expected else { throw DownloadError.checksumMismatch }
                    digest = computed
                }
                let verifiedDigest = digest
                if request.embeddingModel == true {
                    _ = try GGUFInspector.inspect(fileAt: staged)
                    try await MainActor.run {
                        guard let self else { return }
                        guard let index = self.semanticIndex else { throw EmbeddingRuntime.Failure.loadFailed }
                        try index.install(fileAt: staged, entry: EmbeddingCatalog.recommended, sha256: verifiedDigest)
                        self.items[request.id]?.phase = .completed
                        self.saveState()
                    }
                    try? await Task.sleep(for: .seconds(4))
                    await MainActor.run {
                        if self?.items[request.id]?.phase == .completed { self?.items[request.id] = nil }
                    }
                    return
                }
                if let owner = request.projectorFor {
                    guard GGUFInspector.isImageEncoder(fileAt: staged) else {
                        throw ProjectorError.notAnEncoder(request.fileName)
                    }
                    try await MainActor.run {
                        guard let self else { return }
                        let models = try self.store.installProjector(
                            fileAt: staged, for: owner, repo: request.repo, fileName: request.fileName,
                            sha256: verifiedDigest, verification: verifiedDigest != nil ? .verified : .structureValid,
                            moveFile: true)
                        self.items[request.id]?.phase = .completed
                        self.saveState()
                        self.onProjectorInstalled?(models)
                    }
                    try? await Task.sleep(for: .seconds(4))
                    await MainActor.run {
                        if self?.items[request.id]?.phase == .completed { self?.items[request.id] = nil }
                    }
                    return
                }
                let inspected = try GGUFInspector.inspect(fileAt: staged)
                try await MainActor.run {
                    guard let self else { return }
                    let model = try self.store.install(
                        fileAt: staged, id: request.id, displayName: request.displayName,
                        developer: request.developer, repo: request.repo, fileName: request.fileName,
                        sha256: verifiedDigest, verification: verifiedDigest != nil ? .verified : .structureValid,
                        info: inspected.info, license: request.license,
                        origin: request.catalogID != nil ? .catalog : .huggingFace,
                        catalogID: request.catalogID, moveFile: true)
                    self.items[request.id]?.phase = .completed
                    self.saveState()
                    if request.ignoreMemoryLimit == true {
                        self.store.updateSettings(for: model.id) { $0.ignoreMemoryLimit = true }
                    }
                    self.onInstalled?(model)
                }
                try? await Task.sleep(for: .seconds(4))
                await MainActor.run {
                    if self?.items[request.id]?.phase == .completed { self?.items[request.id] = nil }
                }
            } catch {
                try? FileManager.default.removeItem(at: staged)
                await MainActor.run {
                    self?.items[request.id]?.phase = .failed(error.localizedDescription)
                    self?.saveState()
                }
            }
        }
    }

    /// Verifies one of a folder's files, moves it into the folder, then downloads the next file
    /// or, after the last, installs the folder.
    private func handleFolderFile(_ id: String, file index: Int, stagedAt staged: URL) {
        guard let item = items[id], let files = item.request.files, index == item.fileIndex, index < files.count else {
            try? FileManager.default.removeItem(at: staged)
            return
        }
        if case .verifying = item.phase { return } // already being verified (relaunch recovery)
        tasks[id] = nil
        restartedOnce.remove(id)
        deleteResumeData(id)
        items[id]?.phase = .verifying(0)
        items[id]?.receivedBytes = item.completedBytes + files[index].bytes
        items[id]?.bytesPerSecond = 0
        saveState()
        let request = item.request
        let file = files[index]

        Task.detached(priority: .utility) { [weak self] in
            do {
                try DownloadManager.verify(staged, bytes: file.bytes, sha256: file.sha256) { fraction in
                    Task { @MainActor in self?.items[id]?.phase = .verifying(fraction) }
                }
                let destination = DownloadManager.folderStagingURL(for: id).appending(path: file.path)
                let fileManager = FileManager.default
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: staged, to: destination)
                await MainActor.run {
                    guard let self, self.items[id] != nil else { return }
                    self.items[id]?.completedBytes += file.bytes
                    self.items[id]?.fileIndex = index + 1
                    if index + 1 < files.count {
                        self.launch(request, resumeData: nil)
                    } else {
                        self.installFolder(request)
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: staged)
                await MainActor.run {
                    self?.items[id]?.phase = .failed(error.localizedDescription)
                    self?.saveState()
                }
            }
        }
    }

    /// Checks a downloaded file's size and, when the publisher gives one, its SHA-256.
    nonisolated private static func verify(_ url: URL, bytes: Int64, sha256: String?,
                                           progress: @escaping @Sendable (Double) -> Void) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if bytes > 0, size != bytes { throw DownloadError.sizeMismatch(expected: bytes, actual: size) }
        guard let expected = sha256?.lowercased(), !expected.isEmpty else { return }
        guard try ModelStore.sha256(of: url, progress: progress) == expected else { throw DownloadError.checksumMismatch }
    }

    /// Installs a folder whose files are all verified: checks it's a model MLX can run, moves it
    /// into the Models directory and registers it.
    private func installFolder(_ request: DownloadRequest) {
        let id = request.id
        let folder = Self.folderStagingURL(for: id)
        // A file missing from the folder (storage cleaned up meanwhile) is fetched again.
        if let files = request.files,
           let missing = files.firstIndex(where: { !FileManager.default.fileExists(atPath: folder.appending(path: $0.path).path(percentEncoded: false)) }) {
            items[id]?.fileIndex = missing
            items[id]?.completedBytes = files[..<missing].reduce(0) { $0 + $1.bytes }
            launch(request, resumeData: nil)
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            do {
                let info = try MLXModelInspector.inspect(folderAt: folder)
                try await MainActor.run {
                    guard let self else { return }
                    let model = try self.store.installFolder(
                        at: folder, id: id, displayName: request.displayName, developer: request.developer,
                        repo: request.repo, folderName: request.fileName, info: info,
                        verification: request.files?.contains { $0.sha256 != nil } == true ? .verified : .structureValid,
                        license: request.license, origin: request.catalogID != nil ? .catalog : .huggingFace,
                        catalogID: request.catalogID)
                    self.items[id]?.phase = .completed
                    self.saveState()
                    if request.ignoreMemoryLimit == true {
                        self.store.updateSettings(for: model.id) { $0.ignoreMemoryLimit = true }
                    }
                    self.onInstalled?(model)
                }
                try? await Task.sleep(for: .seconds(4))
                await MainActor.run {
                    if self?.items[id]?.phase == .completed { self?.items[id] = nil }
                }
            } catch {
                try? FileManager.default.removeItem(at: folder)
                await MainActor.run {
                    self?.items[id]?.fileIndex = 0
                    self?.items[id]?.completedBytes = 0
                    self?.items[id]?.phase = .failed(error.localizedDescription)
                    self?.saveState()
                }
            }
        }
    }

    fileprivate func finishBackgroundEvents() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }

    // MARK: Persistence

    private struct PersistedItem: Codable {
        var request: DownloadRequest
        var receivedBytes: Int64
        var totalBytes: Int64
        var state: String
        var message: String?
        /// Folders only; absent in state saved before folders.
        var fileIndex: Int?
        var completedBytes: Int64?
    }

    private func saveState() {
        let persisted = items.values.compactMap { item -> PersistedItem? in
            let state: String
            var message: String?
            switch item.phase {
            case .completed: return nil
            case .failed(let reason):
                state = "failed"
                message = reason
            case .paused: state = "paused"
            case .downloading, .verifying: state = "downloading"
            }
            return PersistedItem(request: item.request, receivedBytes: item.receivedBytes, totalBytes: item.totalBytes,
                                 state: state, message: message, fileIndex: item.fileIndex, completedBytes: item.completedBytes)
        }
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    private func restoreState() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let persisted = try? JSONDecoder().decode([PersistedItem].self, from: data) else { return }
        for entry in persisted {
            let request = entry.request
            let installed: Bool
            if request.embeddingModel == true {
                installed = semanticIndex?.embedder?.fileName == request.fileName
            } else if request.projectorFor != nil {
                installed = store.isProjectorInstalled(repo: request.repo, fileName: request.fileName)
            } else {
                installed = store.isInstalled(repo: request.repo, fileName: request.fileName)
            }
            guard !installed else { continue }
            let phase: DownloadPhase
            switch entry.state {
            case "failed": phase = .failed(entry.message ?? "Download failed.")
            case "paused": phase = .paused
            default: phase = .downloading
            }
            items[entry.request.id] = DownloadItem(request: entry.request, phase: phase,
                                                   receivedBytes: entry.receivedBytes, totalBytes: entry.totalBytes,
                                                   fileIndex: entry.fileIndex ?? 0, completedBytes: entry.completedBytes ?? 0)
        }
    }

    private func saveResumeData(_ data: Data, for id: String) {
        try? data.write(to: Self.resumeDataURL(for: id), options: .atomic)
    }

    private func loadResumeData(for id: String) -> Data? {
        try? Data(contentsOf: Self.resumeDataURL(for: id))
    }

    private func deleteResumeData(_ id: String) {
        try? FileManager.default.removeItem(at: Self.resumeDataURL(for: id))
    }
}

// MARK: - URLSession delegate (called on the session's private queue)

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription else { return }
        let (id, file) = Self.parseTaskDescription(description)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: location)
            Task { @MainActor in self.handleHTTPFailure(id, status: status) }
            return
        }
        // The temporary file is deleted when this method returns: move it synchronously.
        let staged = file.map { Self.stagingURL(for: id, file: $0) } ?? Self.stagingURL(for: id)
        do {
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: location, to: staged)
            Task { @MainActor in self.handleDownloaded(id, file: file, stagedAt: staged) }
        } catch {
            let message = "Couldn't keep the downloaded file: \(error.localizedDescription)"
            Task { @MainActor in self.handleFailure(id, resumeData: nil, wasCancelled: false, message: message) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let description = downloadTask.taskDescription else { return }
        let (id, file) = Self.parseTaskDescription(description)
        let now = Date().timeIntervalSinceReferenceDate
        let shouldReport = progressThrottle.withLock { last -> Bool in
            if let previous = last[id], now - previous < 0.25 { return false }
            last[id] = now
            return true
        }
        guard shouldReport else { return }
        Task { @MainActor in self.updateProgress(id, file: file, received: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let description = task.taskDescription, let error else { return }
        let id = Self.parseTaskDescription(description).id
        let nsError = error as NSError
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        let message = error.localizedDescription
        Task { @MainActor in self.handleFailure(id, resumeData: resumeData, wasCancelled: cancelled, message: message) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.finishBackgroundEvents() }
    }
}
