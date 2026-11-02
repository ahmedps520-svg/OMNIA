import SwiftData
import SwiftUI

/// Two models, one prompt, side by side. On iPhone the answers stack vertically.
struct CompareView: View {
    @Environment(CompareService.self) private var compare
    @Environment(ModelStore.self) private var store
    @Environment(InferenceEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var prompt = ""
    @State private var systemPrompt = ""
    @State private var showSystemPrompt = false
    @FocusState private var promptFocused: Bool

    var body: some View {
        @Bindable var compare = compare
        VStack(spacing: 0) {
            if store.models.count < 1 {
                OmniaEmptyState(title: "Download models to compare",
                                message: "Compare sends the same prompt to two models and shows both answers with measured speed.",
                                symbol: "rectangle.split.2x1")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        pickers
                        if sizeClass == .compact {
                            VStack(spacing: 14) {
                                CompareColumn(side: compare.left, title: name(compare.left.modelID))
                                CompareColumn(side: compare.right, title: name(compare.right.modelID))
                            }
                        } else {
                            HStack(alignment: .top, spacing: 14) {
                                CompareColumn(side: compare.left, title: name(compare.left.modelID))
                                CompareColumn(side: compare.right, title: name(compare.right.modelID))
                            }
                        }
                    }
                    .padding(.horizontal, sizeClass == .compact ? 16 : 24)
                    .padding(.vertical, 18)
                }
                composer
            }
        }
        .background(Theme.canvas)
        .navigationTitle("Compare")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ComparisonHistoryView()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Comparison History")
            }
        }
        .onAppear {
            let models = store.sortedByRecentUse
            if compare.left.modelID == nil { compare.left.modelID = models.first?.id }
            if compare.right.modelID == nil { compare.right.modelID = models.dropFirst().first?.id ?? models.first?.id }
        }
    }

    private var pickers: some View {
        @Bindable var compare = compare
        return HStack(spacing: 12) {
            modelPicker(title: "Model A", selection: $compare.left.modelID)
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
            modelPicker(title: "Model B", selection: $compare.right.modelID)
            Spacer()
        }
    }

    private func modelPicker(title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("Choose…").tag(String?.none)
            ForEach(store.sortedByRecentUse) { model in
                Text(model.displayName).tag(String?.some(model.id))
            }
        }
        .pickerStyle(.menu)
        .disabled(compare.isRunning)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if showSystemPrompt {
                TextField("System prompt (optional)", text: $systemPrompt, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    withAnimation { showSystemPrompt.toggle() }
                } label: {
                    Image(systemName: showSystemPrompt ? "text.badge.minus" : "text.badge.plus")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("System Prompt")

                TextField("Prompt both models…", text: $prompt, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($promptFocused)
                    .padding(.vertical, 7)

                Button {
                    if compare.isRunning {
                        compare.stop()
                    } else {
                        compare.run(prompt: prompt, systemPrompt: systemPrompt)
                    }
                } label: {
                    Image(systemName: compare.isRunning ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!compare.isRunning && (!compare.canRun || prompt.trimmed.isEmpty))
                .accessibilityLabel(compare.isRunning ? "Stop" : "Compare")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
            Text("Models run one after another so each gets the full GPU and timings stay comparable.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, sizeClass == .compact ? 12 : 24)
        .padding(.vertical, 10)
        .frame(maxWidth: 900)
    }

    private func name(_ id: String?) -> String {
        store.model(id: id)?.displayName ?? "No model"
    }
}

struct CompareColumn: View {
    let side: CompareService.Side
    let title: String

    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                stateLabel
            }
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            if let reasoning = side.parsed.reasoning, settings.showReasoning {
                ReasoningDisclosure(text: reasoning, isThinking: side.parsed.isReasoning)
            }
            if side.parsed.content.isEmpty {
                Text(placeholder)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            } else {
                MarkdownView(text: side.parsed.content, isStreaming: side.state == .generating,
                             typeface: settings.chatTypeface, scale: settings.chatTextScale)
            }
            if let stats = side.stats {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                HStack(spacing: 16) {
                    LabeledMetric(title: "Speed", value: ByteFormat.rate(stats.tokensPerSecond))
                    LabeledMetric(title: "First token", value: ByteFormat.seconds(stats.timeToFirstToken))
                    LabeledMetric(title: "Tokens", value: "\(stats.generatedTokens)")
                    LabeledMetric(title: "Total", value: ByteFormat.seconds(stats.totalDuration))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .surface()
    }

    private var placeholder: String {
        switch side.state {
        case .idle: "The answer will appear here."
        case .waiting: "Waiting for its turn…"
        case .preparing: "Loading model and reading the prompt…"
        case .generating, .done: ""
        case .failed(let message): message
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch side.state {
        case .preparing, .generating:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.positive)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.critical)
        default:
            EmptyView()
        }
    }
}

struct ComparisonHistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ComparisonRecord.date, order: .reverse) private var records: [ComparisonRecord]

    var body: some View {
        List {
            if records.isEmpty {
                Text("Comparisons you run are saved here.").foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                NavigationLink {
                    ComparisonRecordView(record: record)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.prompt).lineLimit(2)
                        Text("\(record.leftModelName) vs \(record.rightModelName) · \(record.date.relativeDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { records[$0] }.forEach { context.delete($0) }
                try? context.save()
            }
        }
        .navigationTitle("Comparisons")
    }
}

struct ComparisonRecordView: View {
    let record: ComparisonRecord
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(record.prompt).font(.headline).surface()
                let layout = sizeClass == .compact ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                layout {
                    column(record.leftModelName, record.leftResponse, record.leftStats)
                    column(record.rightModelName, record.rightResponse, record.rightStats)
                }
            }
            .padding(24)
        }
        .background(Theme.canvas)
        .navigationTitle("Comparison")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func column(_ name: String, _ response: String, _ stats: GenerationStats?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(name).font(.headline)
            MarkdownView(text: response)
            if let stats {
                GenerationSummary(stats: stats, modelName: nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .surface()
    }
}
