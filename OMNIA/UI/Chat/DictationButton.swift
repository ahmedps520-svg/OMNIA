import SwiftUI

/// The composer's microphone: dictates into the message on device, the words appearing as
/// they're recognized.
struct DictationButton: View {
    @Binding var text: String
    /// The composer it dictates into: the microphone serves one composer at a time.
    let owner: UUID

    @Environment(DictationService.self) private var dictation
    @Environment(\.openURL) private var openURL
    @State private var failure: String?
    @State private var needsPermission = false

    private var isDictating: Bool { dictation.isDictating(for: owner) }
    private var state: DictationService.State { isDictating ? dictation.state : .idle }
    /// Another window's composer is starting or finishing, so the microphone is busy for a moment.
    private var isBusyElsewhere: Bool {
        !isDictating && (dictation.state == .preparing || dictation.state == .finishing)
    }

    var body: some View {
        Button(action: toggle) {
            Group {
                switch state {
                case .idle:
                    Image(systemName: "mic")
                case .recording:
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative)
                        .foregroundStyle(.red)
                case .preparing, .finishing:
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(.body.weight(.medium))
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(state == .finishing || isBusyElsewhere)
        .accessibilityLabel(isDictating ? "Stop Dictation" : "Dictate")
        .help(isDictating ? "Stop dictation" : "Dictate your message. Speech is recognized on this device.")
        .alert("Can't Dictate", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            if needsPermission, let settings = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(settings) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
        .onDisappear {
            if isDictating {
                Task { await dictation.stop() }
            }
        }
    }

    private func toggle() {
        if isDictating {
            Task { await dictation.stop() }
            return
        }
        let draft = text
        Task {
            do {
                try await dictation.start(for: owner) { dictated in
                    text = DictationService.appending(dictated, to: draft)
                }
            } catch is CancellationError {
                // Stopped while starting.
            } catch {
                needsPermission = (error as? DictationService.Failure) == .microphoneDenied
                failure = error.localizedDescription
            }
        }
    }
}
