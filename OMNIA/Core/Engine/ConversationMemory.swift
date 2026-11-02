import CryptoKit
import Foundation

/// Where one conversation's model memory (its KV cache) is saved for one loaded configuration.
struct ConversationMemoryRequest: Hashable, Sendable {
    let fileURL: URL
    /// Short conversations aren't saved: re-reading them is quick anyway.
    let minimumTokens: Int
    /// A single save larger than this is skipped.
    let maximumBytes: Int64
}

/// Saved model memory for conversations, so reopening a long chat continues instantly instead of
/// re-reading its whole history.
///
/// Files are named `<conversation>_<model>_<configuration>.kvstate`, so a save is only restored
/// into the exact model file and runtime settings that produced it (llama.cpp also validates the
/// cache layout when loading). The total size is capped; the least recently used saves go first.
/// The folder is in Caches: iOS may purge it, which only costs a re-read.
@MainActor
final class ConversationMemoryStore {
    static let fileExtension = "kvstate"
    /// Below this many tokens a conversation is re-read faster than a save can pay off.
    static let minimumTokens = 1_500

    let directory: URL

    init(directory: URL = ConversationMemoryStore.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    nonisolated static var defaultDirectory: URL {
        URL.cachesDirectory.appendingPathComponent("ConversationMemory", isDirectory: true)
    }

    func request(conversationID: UUID, modelID: String, modelSize: UInt64,
                 configuration: RuntimeConfiguration, limitBytes: Int64) -> ConversationMemoryRequest {
        let name = "\(conversationID.uuidString)_\(Self.tag(modelID))_\(Self.tag(Self.fingerprint(modelSize, configuration))).\(Self.fileExtension)"
        return ConversationMemoryRequest(fileURL: directory.appendingPathComponent(name),
                                         minimumTokens: Self.minimumTokens,
                                         maximumBytes: max(0, limitBytes / 2))
    }

    /// Marks a save as just used, so it's the last to be evicted.
    func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path(percentEncoded: false))
    }

    var totalBytes: Int64 { files().reduce(0) { $0 + $1.size } }

    /// Deletes the least recently used saves until the total fits in `limitBytes`.
    func enforceLimit(_ limitBytes: Int64) {
        var entries = files().sorted { $0.modified < $1.modified }
        var total = entries.reduce(0) { $0 + $1.size }
        while total > limitBytes, let oldest = entries.first {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            entries.removeFirst()
        }
    }

    func removeAll(conversationID: UUID) {
        remove { $0.hasPrefix(conversationID.uuidString + "_") }
    }

    func removeAll(modelID: String) {
        let marker = "_\(Self.tag(modelID))_"
        remove { $0.contains(marker) }
    }

    func removeAll() {
        remove { _ in true }
    }

    // MARK: Helpers

    private func remove(where matches: (String) -> Bool) {
        for entry in files() where matches(entry.url.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry.url)
        }
        // Interrupted saves.
        let partials = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in partials where url.pathExtension == "partial" && matches(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func files() -> [(url: URL, size: Int64, modified: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == Self.fileExtension,
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }

    nonisolated static func fingerprint(_ modelSize: UInt64, _ configuration: RuntimeConfiguration) -> String {
        "\(modelSize)|\(configuration.contextLength)|\(configuration.kvCacheType.rawValue)|\(configuration.flashAttention)"
    }

    /// A short, stable identifier (SHA-256 prefix) usable in file names.
    nonisolated static func tag(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
