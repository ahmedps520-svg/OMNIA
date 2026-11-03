import ActivityKit
import SwiftUI
import WidgetKit

@main
struct OMNIAWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ModelDownloadLiveActivity()
    }
}

/// A model download's progress on the Lock Screen and in the Dynamic Island.
struct ModelDownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ModelDownloadAttributes.self) { context in
            DownloadLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseSymbol(phase: context.state.phase)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.title3.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.modelName)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: context.state.fraction)
                        Text(DownloadStatus.detail(context.state, isStale: context.isStale))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                PhaseSymbol(phase: context.state.phase)
            } compactTrailing: {
                Text(context.state.fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            } minimal: {
                ProgressView(value: context.state.fraction)
                    .progressViewStyle(.circular)
            }
        }
    }
}

struct DownloadLockScreenView: View {
    let context: ActivityViewContext<ModelDownloadAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PhaseSymbol(phase: context.state.phase)
                    .font(.title3)
                Text(context.attributes.modelName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(context.state.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.headline.monospacedDigit())
            }
            ProgressView(value: context.state.fraction)
            Text(DownloadStatus.detail(context.state, isStale: context.isStale))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

struct PhaseSymbol: View {
    let phase: ModelDownloadAttributes.Phase

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(phase == .failed ? Color.orange : Color.accentColor)
    }

    private var symbol: String {
        switch phase {
        case .downloading: "arrow.down.circle.fill"
        case .paused: "pause.circle.fill"
        case .verifying: "checkmark.shield.fill"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

enum DownloadStatus {
    static func detail(_ state: ModelDownloadAttributes.ContentState, isStale: Bool) -> String {
        let sizes = "\(bytes(state.receivedBytes)) of \(bytes(state.totalBytes))"
        switch state.phase {
        case .downloading: return isStale ? "\(sizes) · continues in the background" : sizes
        case .paused: return "Paused at \(sizes)"
        case .verifying: return "Checking the file…"
        case .finished: return "Downloaded and verified. Ready offline."
        case .failed: return "The download stopped. Open OMNIA to retry."
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
