import Foundation

enum ByteFormat {
    private static let memoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.zeroPadsFractionDigits = false
        return formatter
    }()

    private static let fileFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    /// RAM-style sizes (binary units), e.g. "9.4 GB".
    static func memory(_ bytes: UInt64) -> String {
        memoryFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func memory(_ bytes: Int64) -> String {
        memoryFormatter.string(fromByteCount: bytes)
    }

    /// Storage-style sizes (decimal units, as the Files app shows them).
    static func file(_ bytes: Int64) -> String {
        fileFormatter.string(fromByteCount: bytes)
    }

    static func file(_ bytes: UInt64) -> String {
        fileFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    /// Compact token counts: "512", "8K", "32K", "128K".
    static func tokens(_ count: Int) -> String {
        if count >= 1024 && count % 1024 == 0 { return "\(count / 1024)K" }
        if count >= 10_000 { return String(format: "%.0fK", Double(count) / 1000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1000) }
        return "\(count)"
    }

    static func rate(_ tokensPerSecond: Double) -> String {
        tokensPerSecond >= 100 ? String(format: "%.0f tok/s", tokensPerSecond) : String(format: "%.1f tok/s", tokensPerSecond)
    }

    static func seconds(_ value: Double) -> String {
        if value < 1 { return String(format: "%.0f ms", value * 1000) }
        if value < 60 { return String(format: "%.1f s", value) }
        let minutes = Int(value) / 60
        let seconds = Int(value) % 60
        return "\(minutes)m \(seconds)s"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        "\(fileFormatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }
}

extension Date {
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: .now)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// First line, shortened to roughly `limit` characters at a word boundary.
    func titleSnippet(limit: Int = 48) -> String {
        let line = trimmed.components(separatedBy: .newlines).first?.trimmed ?? ""
        guard line.count > limit else { return line }
        let cut = line.prefix(limit)
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) + "…" }
        return String(cut) + "…"
    }
}
