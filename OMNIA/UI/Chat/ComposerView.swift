import SwiftUI

/// The floating message composer: attachments, a growing text field and a send / stop button.
struct ComposerView: View {
    @Binding var text: String
    @Binding var attachments: [AttachmentRecord]
    var isGenerating: Bool
    var canSend: Bool
    var placeholder: String
    var contextUsage: Double?
    var onSend: () -> Void
    var onStop: () -> Void
    var onAttach: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: attachment.kind.symbol)
                                Text(attachment.name).lineLimit(1)
                                Text(ByteFormat.file(Int64(attachment.byteSize))).foregroundStyle(.tertiary)
                                Button {
                                    attachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Remove \(attachment.name)")
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .glassEffect(.regular, in: .capsule)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button(action: onAttach) {
                    Image(systemName: "paperclip")
                        .font(.body.weight(.medium))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Attach Files")
                .help("Attach text, code or PDF files")

                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.vertical, 7)
                    .submitLabel(.send)
                    .onKeyPress(.return, phases: .down) { press in
                        // Return sends on hardware keyboards; Shift-Return inserts a new line.
                        if press.modifiers.contains(.shift) { return .ignored }
                        if canSend { onSend() }
                        return .handled
                    }

                if let contextUsage, contextUsage > 0.01 {
                    ContextRing(fraction: contextUsage)
                        .padding(.bottom, 9)
                }

                Button {
                    isGenerating ? onStop() : onSend()
                } label: {
                    Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(isGenerating || canSend ? Color(uiColor: .systemBackground) : Color.secondary)
                        .frame(width: 34, height: 34)
                        .background(isGenerating || canSend ? Color.accentColor : Color.secondary.opacity(0.2), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(!isGenerating && !canSend)
                .keyboardShortcut(isGenerating ? .cancelAction : .init(.return, modifiers: .command))
                .accessibilityLabel(isGenerating ? "Stop Generating" : "Send")
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        }
        .padding(.horizontal, sizeClass == .compact ? 12 : 24)
        .padding(.bottom, 10)
        .padding(.top, 6)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
    }
}

/// Tiny ring showing how full the context window is.
struct ContextRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(1, fraction))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .help("Context window \(ByteFormat.percent(fraction)) full")
        .accessibilityLabel("Context window \(ByteFormat.percent(fraction)) full")
    }

    private var color: Color {
        fraction > 0.9 ? Theme.critical : fraction > 0.7 ? Theme.caution : Color.accentColor
    }
}
