import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelStore.self) private var store
    @Environment(InferenceEngine.self) private var engine
    @Environment(SemanticIndex.self) private var semanticIndex
    @Environment(ChatService.self) private var chat
    @Environment(ModelImporter.self) private var importer
    @Environment(\.modelContext) private var context

    @State private var showClearConversations = false
    @State private var showClearCache = false
    @State private var cacheMessage: String?
    @State private var chatMemoryBytes: Int64 = 0

    private let device = AppServices.shared.device

    var body: some View {
        @Bindable var settings = settings
        Form {
            // MARK: Appearance
            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Accent color", selection: $settings.accent) {
                    ForEach(AccentChoice.allCases) { choice in
                        Label {
                            Text(choice.title)
                        } icon: {
                            Circle().fill(Theme.accent(choice)).frame(width: 14, height: 14)
                        }
                        .tag(choice)
                    }
                }
                Picker("Animations", selection: $settings.animations) {
                    ForEach(AnimationPreference.allCases) { Text($0.title).tag($0) }
                }
                Picker("Chat typeface", selection: $settings.chatTypeface) {
                    ForEach(ChatTypeface.allCases) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Chat text size")
                        Spacer()
                        Text(ByteFormat.percent(settings.chatTextScale)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $settings.chatTextScale, in: 0.85...1.3, step: 0.05)
                }
                Toggle("Show reasoning", isOn: $settings.showReasoning)
                Toggle("Show generation details", isOn: $settings.showGenerationDetails)
            }

            // MARK: Inference
            Section {
                Picker("Default model", selection: $settings.defaultModelID) {
                    Text("Most recently used").tag(String?.none)
                    ForEach(store.sortedByRecentUse) { Text($0.displayName).tag(String?.some($0.id)) }
                }
                SamplingSlider(title: "Temperature", value: $settings.generation.temperature, range: 0...2, step: 0.05)
                SamplingSlider(title: "Top P", value: $settings.generation.topP, range: 0.05...1, step: 0.01)
                Stepper("Top K: \(settings.generation.topK)", value: $settings.generation.topK, in: 0...200, step: 5)
                SamplingSlider(title: "Min P", value: $settings.generation.minP, range: 0...0.5, step: 0.01)
                SamplingSlider(title: "Repetition penalty", value: $settings.generation.repetitionPenalty, range: 1...1.5, step: 0.01)
                Stepper("Max output: \(settings.generation.maxOutputTokens) tokens", value: $settings.generation.maxOutputTokens, in: 128...16_384, step: 128)
                Picker("Context window", selection: $settings.contextLength) {
                    Text("Automatic (\(ByteFormat.tokens(engine.profile.defaultContext)))").tag(0)
                    ForEach([4096, 8192, 16_384, 32_768, 65_536, 131_072], id: \.self) { Text(ByteFormat.tokens($0)).tag($0) }
                }
                Picker("KV cache", selection: $settings.kvCache) {
                    ForEach(KVCacheChoice.allCases) { Text($0.title).tag($0) }
                }
                Toggle("GPU acceleration (Metal)", isOn: $settings.gpuAcceleration)
                Toggle("Flash attention", isOn: $settings.flashAttention)
                Toggle("Reuse prompt cache between turns", isOn: $settings.reusePromptCache)
                Toggle("Remember long chats", isOn: $settings.rememberLongChats)
                    .disabled(!settings.reusePromptCache)
                Picker("Reasoning effort", selection: $settings.reasoningEffort) {
                    ForEach(ReasoningEffort.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Tools in new conversations", isOn: $settings.toolsEnabledByDefault)
                Button("Restore Inference Defaults") { settings.resetGenerationDefaults() }
            } header: {
                Text("Inference")
            } footer: {
                Text("Context and KV cache changes apply the next time a model loads. Automatic picks the longest context and highest cache precision that fit in memory; quantized caches require flash attention. Remember long chats saves a long conversation's model memory, so reopening it continues instantly instead of re-reading it. Tools let models calculate exactly, check the date, run code in a sandbox and search attached documents. Reasoning effort sets how long reasoning models think before answering: Balanced suits most questions, Thorough is slower and uses more battery. Models that can't be told an effort level (Qwen3.6, Ornith) stop thinking after about 1,000 tokens on Light and 4,000 on Balanced, then answer; Thorough lets them think as long as they want.")
            }

            // MARK: Workspace
            Section {
                Toggle("Web access in new conversations", isOn: $settings.webAccessByDefault)
                    .disabled(settings.offlineOnly)
                PythonRuntimeRow()
            } header: {
                Text("Workspace")
            } footer: {
                Text("With web access the model can search the web (DuckDuckGo) and read pages; each conversation can turn it on or off, and it's always off in Offline-only mode. Python (Pyodide \(PythonRuntime.version), Mozilla Public License 2.0) runs code from the workspace and the model offline, with the standard library and no network access.")
            }

            // MARK: Voice
            Section {
                Toggle("Read replies aloud", isOn: $settings.readRepliesAloud)
            } header: {
                Text("Voice")
            } footer: {
                Text("Reads each finished reply aloud, skipping code, in the best voice installed for its language. Higher-quality voices can be downloaded in Settings › Accessibility › Spoken Content › Voices. Dictation and speech stay on this device.")
            }

            // MARK: Memory & performance
            Section {
                Picker("Optimization profile", selection: $settings.profilePreference) {
                    Text("Automatic (\(OptimizationProfile.resolve(device: device, preference: .automatic).title))").tag(ProfilePreference.automatic)
                    Text("Maximum quality").tag(ProfilePreference.quality)
                    Text("Efficiency").tag(ProfilePreference.efficiency)
                }
                Picker("Memory safety margin", selection: $settings.memorySafety) {
                    ForEach(MemorySafety.allCases) { Text($0.title).tag($0) }
                }
                Picker("Release idle models after", selection: $settings.idleUnloadMinutes) {
                    Text("Automatic (\(engine.profile.idleUnloadMinutes) min)").tag(-1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("Never").tag(0)
                }
                Toggle("Keep models loaded in background", isOn: $settings.keepModelsLoadedInBackground)
                Toggle("Reload model when returning", isOn: $settings.restoreModelOnForeground)
                Toggle("Thermal protection", isOn: $settings.thermalProtection)
                if BackgroundAnswer.isSupported {
                    Toggle("Keep answering in the background", isOn: $settings.answerInBackground)
                }
            } header: {
                Text("Memory & Performance")
            } footer: {
                let background: String = BackgroundAnswer.isSupported
                    ? " On this iPad a reply can keep generating after you switch apps; iOS shows its progress and a button to stop it."
                    : ""
                Text("\(engine.profile.summary) Background apps get far less memory, so releasing models when OMNIA leaves the screen prevents iOS from terminating it.\(background)")
            }

            // MARK: Storage
            Section {
                LabeledContent("Downloaded models", value: "\(store.models.filter { !$0.isSystem }.count) · \(ByteFormat.file(store.storageUsed))")
                ForEach(store.sortedByRecentUse.filter { !$0.isSystem }) { model in
                    LabeledContent(model.displayName, value: model.projector.map {
                        "\(ByteFormat.file(model.sizeBytes)) + \(ByteFormat.file($0.sizeBytes)) for images"
                    } ?? ByteFormat.file(model.sizeBytes))
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                Task {
                                    if settings.defaultModelID == model.id { settings.defaultModelID = nil }
                                    await store.delete(model)
                                }
                            }
                        }
                }
                if let embedder = semanticIndex.embedder {
                    LabeledContent("\(embedder.name) (library search)", value: ByteFormat.file(embedder.sizeBytes))
                }
                if let storage = SystemMetrics.storage() {
                    LabeledContent("Free on device", value: ByteFormat.file(storage.availableForImportantUsage))
                }
                LabeledContent("Conversations", value: conversationCount.formatted())
                LabeledContent("Saved chat memory", value: ByteFormat.file(chatMemoryBytes))
                Picker("Chat memory limit", selection: $settings.conversationMemoryLimitGB) {
                    ForEach([1.0, 2.0, 4.0, 8.0, 16.0], id: \.self) { Text("\(Int($0)) GB").tag($0) }
                }
                Button("Clear Saved Chat Memory") {
                    engine.conversationMemory.removeAll()
                    chatMemoryBytes = 0
                }
                .disabled(chatMemoryBytes == 0)
                Button("Clear Temporary Files") { showClearCache = true }
                if let cacheMessage {
                    Text(cacheMessage).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Swipe a model to delete it. Models are excluded from device backups because they can be downloaded again.")
            }

            // MARK: Privacy
            Section {
                Toggle("Offline-only mode", isOn: $settings.offlineOnly)
                Toggle("Allow downloads over cellular", isOn: $settings.allowCellularDownloads)
                    .disabled(settings.offlineOnly)
                LabeledContent("Telemetry", value: "None")
                LabeledContent("Accounts", value: "None required")
                LabeledContent("Cloud sync", value: "Off — data stays on this device")
                Button("Clear Conversation History…", role: .destructive) { showClearConversations = true }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Inference never uses the network. Offline-only mode also blocks model search and downloads, so OMNIA makes no network requests at all.")
            }

            // MARK: About
            Section("About") {
                LabeledContent("Version", value: Bundle.main.versionDescription)
                LabeledContent("Inference engine", value: "llama.cpp \(LlamaRuntime.engineVersion) (Metal)")
                LabeledContent("Device", value: "\(device.name) · \(device.identifier)")
                LabeledContent("Profile", value: engine.profile.title)
                Link("llama.cpp on GitHub", destination: URL(string: "https://github.com/ggml-org/llama.cpp")!)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .navigationTitle("Settings")
        .onAppear { chatMemoryBytes = engine.conversationMemory.totalBytes }
        .confirmationDialog("Delete all conversations?", isPresented: $showClearConversations, titleVisibility: .visible) {
            Button("Delete All Conversations", role: .destructive) {
                // Through ChatService so a running reply stops first; each deletion cascades to its messages.
                let all = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
                all.forEach { chat.delete($0) }
            }
        } message: {
            Text("Every conversation and message is permanently removed from this device. Models, prompts and documents are kept.")
        }
        .confirmationDialog("Clear temporary files?", isPresented: $showClearCache, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { clearCache() }
        } message: {
            Text("Removes exports and partial imports. Downloaded models and conversations are not affected.")
        }
    }

    private var conversationCount: Int {
        (try? context.fetchCount(FetchDescriptor<Conversation>())) ?? 0
    }

    private func clearCache() {
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory
        var removed: Int64 = 0
        if let items = try? fileManager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.fileSizeKey]) {
            for item in items {
                // Keep the staging file of an import that is still running.
                if importer.isBusy, item.lastPathComponent.hasPrefix("import-") { continue }
                removed += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                try? fileManager.removeItem(at: item)
            }
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let items = try? fileManager.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
            for item in items {
                removed += SystemMetrics.directorySize(item)
                try? fileManager.removeItem(at: item)
            }
        }
        URLCache.shared.removeAllCachedResponses()
        cacheMessage = "Freed \(ByteFormat.file(removed))."
        chatMemoryBytes = engine.conversationMemory.totalBytes
    }
}

extension Bundle {
    var versionDescription: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
