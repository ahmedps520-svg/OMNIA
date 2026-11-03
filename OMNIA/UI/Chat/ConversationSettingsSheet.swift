import SwiftData
import SwiftUI

/// Per-conversation instructions, personality, reasoning, sampling and knowledge sources.
struct ConversationSettingsSheet: View {
    @Bindable var conversation: Conversation

    @Environment(\.dismiss) private var dismiss
    @Environment(ChatService.self) private var chat
    @Environment(ModelStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @Query(sort: \Persona.createdAt) private var personas: [Persona]
    @Query(sort: \KnowledgeDocument.createdAt, order: .reverse) private var documents: [KnowledgeDocument]
    @Query(sort: \Folder.name) private var folders: [Folder]

    @State private var systemPrompt = ""
    @State private var overrides = GenerationOverrides()

    private var model: InstalledModel? { chat.model(for: conversation) }
    private var effective: GenerationSettings {
        settings.generation.applying(model?.settings.generation).applying(overrides)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Personality", selection: Binding(get: { conversation.personaID }, set: { conversation.personaID = $0 })) {
                        Text("None").tag(UUID?.none)
                        ForEach(personas) { persona in
                            Label(persona.name, systemImage: persona.symbol).tag(UUID?.some(persona.id))
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("System prompt").font(.subheadline)
                        TextEditor(text: $systemPrompt)
                            .frame(minHeight: 110)
                            .font(.callout)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(Theme.faint, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("A system prompt here takes precedence over the personality and the model's default instructions.")
                }

                if let model, model.facts.thinkingToggle {
                    Section {
                        Picker("Reasoning", selection: Binding(get: { conversation.thinkingEnabled }, set: { conversation.thinkingEnabled = $0 })) {
                            Text("Model default").tag(Bool?.none)
                            Text("On").tag(Bool?.some(true))
                            Text("Off").tag(Bool?.some(false))
                        }
                    } footer: {
                        Text("\(model.displayName) can think before answering. Turning it off gives faster, shorter replies.")
                    }
                }

                Section {
                    Toggle("Tools", isOn: Binding(get: { chat.toolsEnabled(for: conversation) },
                                                  set: { conversation.toolsEnabled = $0 }))
                        .disabled(conversation.jsonMode)
                    Toggle("JSON mode", isOn: $conversation.jsonMode)
                } header: {
                    Text("Capabilities")
                } footer: {
                    Text("Tools let the model calculate exactly, check the date and time, and search the documents attached below. JSON mode makes every reply a single JSON object; tools and reasoning are off while it's on.")
                }

                Section {
                    SamplingSlider(title: "Temperature", value: binding(\.temperature, fallback: effective.temperature), range: 0...2, step: 0.05)
                    SamplingSlider(title: "Top P", value: binding(\.topP, fallback: effective.topP), range: 0.05...1, step: 0.01)
                    SamplingSlider(title: "Min P", value: binding(\.minP, fallback: effective.minP), range: 0...0.5, step: 0.01)
                    Stepper("Top K: \(overrides.topK ?? effective.topK)", value: Binding(
                        get: { overrides.topK ?? effective.topK },
                        set: { overrides.topK = $0 }), in: 0...200, step: 5)
                    SamplingSlider(title: "Repetition penalty", value: binding(\.repetitionPenalty, fallback: effective.repetitionPenalty), range: 1...1.5, step: 0.01)
                    Stepper("Max output: \(overrides.maxOutputTokens ?? effective.maxOutputTokens) tokens", value: Binding(
                        get: { overrides.maxOutputTokens ?? effective.maxOutputTokens },
                        set: { overrides.maxOutputTokens = $0 }), in: 128...16_384, step: 128)
                    if !overrides.isEmpty {
                        Button("Use Default Sampling") { overrides = GenerationOverrides() }
                    }
                } header: {
                    Text("Sampling")
                } footer: {
                    Text("Overrides apply to this conversation only. Defaults live in Settings › Inference and per-model settings.")
                }

                Section {
                    if documents.isEmpty {
                        Text("Add documents in Library › Documents to ground answers in your own files.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(documents) { document in
                        Toggle(isOn: Binding(
                            get: { conversation.documentIDs.contains(document.id) },
                            set: { enabled in
                                if enabled { conversation.documentIDs.append(document.id) }
                                else { conversation.documentIDs.removeAll { $0 == document.id } }
                            })) {
                            Label(document.title, systemImage: document.kind.symbol)
                        }
                    }
                } header: {
                    Text("Knowledge")
                } footer: {
                    Text("Relevant passages from the selected documents are retrieved on device for each message.")
                }

                Section("Organize") {
                    Picker("Folder", selection: Binding(get: { conversation.folder?.id }, set: { id in
                        conversation.folder = folders.first { $0.id == id }
                    })) {
                        Text("None").tag(UUID?.none)
                        ForEach(folders) { folder in Text(folder.name).tag(UUID?.some(folder.id)) }
                    }
                    Toggle("Pinned", isOn: $conversation.isPinned)
                }
            }
            .navigationTitle("Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        apply()
                        dismiss()
                    }
                }
            }
            .onAppear {
                systemPrompt = conversation.systemPrompt ?? ""
                overrides = conversation.overrides ?? GenerationOverrides()
            }
        }
        .presentationDetents([.large])
    }

    private func binding(_ keyPath: WritableKeyPath<GenerationOverrides, Double?>, fallback: Double) -> Binding<Double> {
        Binding(get: { overrides[keyPath: keyPath] ?? fallback }, set: { overrides[keyPath: keyPath] = $0 })
    }

    private func apply() {
        conversation.systemPrompt = systemPrompt.trimmed.isEmpty ? nil : systemPrompt
        conversation.overrides = overrides
        chat.save()
    }
}

struct SamplingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
