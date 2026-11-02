import SwiftUI

struct MessageRow: View {
    struct Actions {
        var copy: () -> Void
        var regenerate: () -> Void
        var continueReply: () -> Void
        var beginEdit: () -> Void
        var commitEdit: () -> Void
        var cancelEdit: () -> Void
        var delete: () -> Void
        var canMutate: Bool
    }

    let message: Message
    let live: ChatService.LiveReply?
    let isLast: Bool
    let isEditing: Bool
    @Binding var editText: String
    let actions: Actions

    var body: some View {
        switch message.role {
        case .user: UserMessageView(message: message, isEditing: isEditing, editText: $editText, actions: actions)
        case .assistant: AssistantMessageView(message: message, live: live, isLast: isLast, actions: actions)
        case .system, .tool: EmptyView()
        }
    }
}

// MARK: - User

struct UserMessageView: View {
    let message: Message
    let isEditing: Bool
    @Binding var editText: String
    let actions: MessageRow.Actions

    @Environment(AppSettings.self) private var settings
    @ScaledMetric(relativeTo: .body) private var baseSize: CGFloat = 17

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 8) {
                if !message.attachments.isEmpty {
                    ForEach(message.attachments) { attachment in
                        Label(attachment.name, systemImage: attachment.kind.symbol)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.faint, in: Capsule())
                    }
                }
                if isEditing {
                    editor
                } else if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(size: baseSize * settings.chatTextScale, design: settings.chatTypeface.design))
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .contextMenu {
                            Button("Copy", systemImage: "doc.on.doc", action: actions.copy)
                            if actions.canMutate {
                                Button("Edit", systemImage: "pencil", action: actions.beginEdit)
                                Button("Delete", systemImage: "trash", role: .destructive, action: actions.delete)
                            }
                        }
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 10) {
            TextField("Message", text: $editText, axis: .vertical)
                .lineLimit(1...12)
                .font(.system(size: baseSize * settings.chatTextScale, design: settings.chatTypeface.design))
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.accentColor.opacity(0.5)))
            HStack(spacing: 10) {
                Button("Cancel", action: actions.cancelEdit)
                    .buttonStyle(.glass)
                Button("Save & Regenerate", action: actions.commitEdit)
                    .buttonStyle(.glassProminent)
                    .disabled(editText.trimmed.isEmpty)
            }
            .controlSize(.small)
            Text("Later messages in this conversation will be replaced.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 620)
    }
}

// MARK: - Assistant

struct AssistantMessageView: View {
    let message: Message
    let live: ChatService.LiveReply?
    let isLast: Bool
    let actions: MessageRow.Actions

    @Environment(AppSettings.self) private var settings
    @Environment(InferenceEngine.self) private var engine
    @State private var showDetails = false
    @State private var copied = false

    private var isStreaming: Bool { live != nil }
    private var content: String { live?.displayContent ?? message.content }
    private var reasoning: String? { live.map { $0.parsed.reasoning ?? (($0.parsed.isReasoning) ? "" : nil) } ?? message.reasoning }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let live, live.isPreparing || (live.raw.isEmpty && live.prefix.isEmpty) {
                PreparingIndicator(live: live)
            }

            if settings.showReasoning, let reasoning {
                ReasoningDisclosure(text: reasoning, isThinking: live?.parsed.isReasoning ?? false,
                                    duration: thinkingDuration)
            }

            if !content.isEmpty {
                MarkdownView(text: content, isStreaming: isStreaming, typeface: settings.chatTypeface, scale: settings.chatTextScale)
            }

            if let error = message.errorMessage, !isStreaming, message.state != .complete {
                Label(error, systemImage: message.state == .failed ? "exclamationmark.triangle" : "pause.circle")
                    .font(.footnote)
                    .foregroundStyle(message.state == .failed ? Theme.critical : Theme.caution)
            }

            if !isStreaming {
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showDetails) {
            if let stats = message.stats {
                GenerationDetailsSheet(stats: stats, modelName: message.modelName)
            }
        }
    }

    private var thinkingDuration: Double? {
        guard let live else { return nil }
        if live.parsed.isReasoning { return nil }
        return live.firstTokenAt.map { Date().timeIntervalSince($0) }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 4) {
            iconButton(copied ? "checkmark" : "doc.on.doc", label: "Copy") {
                actions.copy()
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            if actions.canMutate {
                iconButton("arrow.clockwise", label: "Regenerate", action: actions.regenerate)
                if canContinue {
                    iconButton("arrow.right.circle", label: "Continue Generating", action: actions.continueReply)
                }
            }
            Menu {
                if message.stats != nil {
                    Button("Generation Details", systemImage: "chart.bar.xaxis") { showDetails = true }
                }
                ShareLink(item: message.content) { Label("Share", systemImage: "square.and.arrow.up") }
                if actions.canMutate {
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive, action: actions.delete)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")

            if settings.showGenerationDetails, let stats = message.stats {
                Button {
                    showDetails = true
                } label: {
                    GenerationSummary(stats: stats, modelName: message.modelName)
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }

    private var canContinue: Bool {
        guard let stats = message.stats else { return message.state == .interrupted }
        return stats.stopReason.canContinue || message.state == .interrupted
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: - Live indicators

struct PreparingIndicator: View {
    let live: ChatService.LiveReply
    @Environment(InferenceEngine.self) private var engine
    @Environment(ModelStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }

    private var label: String {
        if let id = engine.loadingModelID {
            let name = store.model(id: id)?.displayName ?? "model"
            return "Loading \(name) · \(Int(engine.loadProgress * 100))%"
        }
        if let progress = live.promptProgress, progress < 1 {
            return "Reading your message · \(Int(progress * 100))%"
        }
        return live.isPreparing ? "Preparing…" : "Thinking…"
    }
}

struct ReasoningDisclosure: View {
    let text: String
    let isThinking: Bool
    var duration: Double?

    @State private var expanded = false
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle")
                        .symbolEffect(.pulse, isActive: isThinking)
                    Text(isThinking ? "Thinking…" : "Reasoning")
                        .font(.footnote.weight(.semibold))
                    if !isThinking, !text.isEmpty {
                        Text("· \(text.split(separator: " ").count) words")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded || (isThinking && !text.isEmpty) {
                Text(isThinking && !expanded ? String(text.suffix(400)) : text)
                    .font(.system(.footnote, design: settings.chatTypeface.design))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.faint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .lineLimit(isThinking && !expanded ? 4 : nil)
            }
        }
    }
}

// MARK: - Generation statistics

struct GenerationSummary: View {
    let stats: GenerationStats
    let modelName: String?

    var body: some View {
        HStack(spacing: 6) {
            if let modelName { Text(modelName).lineLimit(1) }
            Text("·")
            Text(ByteFormat.rate(stats.tokensPerSecond))
            Text("·")
            Text("\(stats.generatedTokens) tokens")
            Text("·")
            Text("\(ByteFormat.tokens(stats.contextUsed))/\(ByteFormat.tokens(stats.contextSize))")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
}

struct GenerationDetailsSheet: View {
    let stats: GenerationStats
    let modelName: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Model") {
                    LabeledValueRow(label: "Model", value: modelName ?? stats.modelName)
                    LabeledValueRow(label: "Result", value: stats.stopReason.label)
                }
                Section("Speed (measured on this device)") {
                    LabeledValueRow(label: "Generation", value: ByteFormat.rate(stats.tokensPerSecond))
                    LabeledValueRow(label: "Prompt processing", value: stats.promptTokensPerSecond > 0 ? ByteFormat.rate(stats.promptTokensPerSecond) : "Cached")
                    LabeledValueRow(label: "Time to first token", value: ByteFormat.seconds(stats.timeToFirstToken))
                    LabeledValueRow(label: "Total time", value: ByteFormat.seconds(stats.totalDuration))
                }
                Section("Tokens") {
                    LabeledValueRow(label: "Generated", value: "\(stats.generatedTokens)")
                    LabeledValueRow(label: "Prompt", value: "\(stats.promptTokens)")
                    LabeledValueRow(label: "Reused from cache", value: "\(stats.reusedPromptTokens)")
                    LabeledValueRow(label: "Context used", value: "\(stats.contextUsed) of \(stats.contextSize) (\(ByteFormat.percent(stats.contextUtilization)))")
                    if let trimmed = stats.trimmedTurns {
                        LabeledValueRow(label: "Earlier turns trimmed", value: "\(trimmed)")
                    }
                }
            }
            .navigationTitle("Generation Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
