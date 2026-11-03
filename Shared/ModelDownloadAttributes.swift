import ActivityKit
import Foundation

/// A model download on the Lock Screen and in the Dynamic Island. Compiled into the app and the
/// widget extension.
struct ModelDownloadAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var receivedBytes: Int64
        var totalBytes: Int64
        var phase: Phase

        var fraction: Double {
            totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0
        }
    }

    enum Phase: String, Codable, Hashable {
        case downloading, paused, verifying, finished, failed
    }

    var downloadID: String
    var modelName: String
}
