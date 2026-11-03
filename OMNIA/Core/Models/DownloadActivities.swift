import ActivityKit
import Foundation
import Observation

/// Shows model downloads on the Lock Screen and in the Dynamic Island. iOS suspends OMNIA while a
/// background download runs, so an activity goes stale until OMNIA runs again; iOS wakes it when
/// the file has arrived, to verify it, and the activity catches up then.
@MainActor
final class DownloadActivities {
    private let downloads: DownloadManager
    /// When each activity was last updated with progress (phase changes always go through).
    private var updated: [String: (date: Date, phase: ModelDownloadAttributes.Phase)] = [:]
    private var started = false

    /// How often progress may update an activity; Live Activities are for occasional updates.
    static let progressInterval: TimeInterval = 5
    /// After this long without an update, the activity says the download continues in the background.
    static let staleAfter: TimeInterval = 60

    init(downloads: DownloadManager) {
        self.downloads = downloads
    }

    func start() {
        guard !started else { return }
        started = true
        observe()
        sync()
    }

    private func observe() {
        withObservationTracking {
            _ = downloads.items
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.observe()
            }
        }
    }

    private func sync() {
        let items = downloads.items
        var shown = Set<String>()
        for activity in Activity<ModelDownloadAttributes>.activities {
            let id = activity.attributes.downloadID
            shown.insert(id)
            if let item = items[id] {
                update(activity, with: item)
            } else {
                // Cancelled or dismissed.
                updated[id] = nil
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
        for item in items.values where !shown.contains(item.id) && item.phase == .downloading {
            request(item)
        }
    }

    private func request(_ item: DownloadItem) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = Self.state(of: item)
        let attributes = ModelDownloadAttributes(downloadID: item.id, modelName: item.request.displayName)
        do {
            _ = try Activity.request(attributes: attributes,
                                     content: ActivityContent(state: state, staleDate: .now.addingTimeInterval(Self.staleAfter)),
                                     pushType: nil)
            updated[item.id] = (.now, state.phase)
        } catch {
            // Live Activities are off for OMNIA, or iOS declined (too many, not in the foreground).
        }
    }

    private func update(_ activity: Activity<ModelDownloadAttributes>, with item: DownloadItem) {
        let state = Self.state(of: item)
        let previous = updated[item.id]
        let now = Date.now
        switch state.phase {
        case .finished, .failed:
            updated[item.id] = nil
            Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(now.addingTimeInterval(15 * 60))) }
        case .downloading, .paused, .verifying:
            if let previous, previous.phase == state.phase, now.timeIntervalSince(previous.date) < Self.progressInterval { return }
            updated[item.id] = (now, state.phase)
            let stale = state.phase == .downloading ? now.addingTimeInterval(Self.staleAfter) : nil
            Task { await activity.update(ActivityContent(state: state, staleDate: stale)) }
        }
    }

    private static func state(of item: DownloadItem) -> ModelDownloadAttributes.ContentState {
        let phase: ModelDownloadAttributes.Phase = switch item.phase {
        case .downloading: .downloading
        case .paused: .paused
        case .verifying: .verifying
        case .completed: .finished
        case .failed: .failed
        }
        return ModelDownloadAttributes.ContentState(receivedBytes: item.receivedBytes, totalBytes: item.totalBytes, phase: phase)
    }
}
