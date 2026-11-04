import SwiftUI

/// What the menu bar and keyboard shortcuts act on in the window in front.
struct WindowCommands {
    var newChat: () -> Void
    var show: (SidebarSection) -> Void
    var searchConversations: () -> Void
}

/// Commands for the chat in front.
struct ChatCommands {
    var switchModel: () -> Void
}

extension FocusedValues {
    @Entry var windowCommands: WindowCommands?
    @Entry var chatCommands: ChatCommands?
}

extension SidebarSection {
    /// ⌘1 to ⌘7, in sidebar order. Settings is ⌘, as in every app.
    static let numbered: [SidebarSection] = [.home, .chat, .models, .cluster, .compare, .library, .performance]
}

/// The menu bar and keyboard shortcuts (holding ⌘ lists them).
struct OMNIACommands: Commands {
    let chat: ChatService
    @FocusedValue(\.windowCommands) private var window
    @FocusedValue(\.chatCommands) private var chatInFront
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { window?.newChat() }
                .keyboardShortcut("n")
                .disabled(window == nil)
            Button("New Window") { openWindow(id: OMNIAApp.mainWindow) }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { window?.show(.settings) }
                .keyboardShortcut(",")
                .disabled(window == nil)
        }
        CommandMenu("Chat") {
            Button("Stop Generating") { chat.stop() }
                .keyboardShortcut(".")
                .disabled(!chat.isBusy)
            Button("Switch Model…") { chatInFront?.switchModel() }
                .keyboardShortcut("k")
                .disabled(chatInFront == nil)
            Button("Search Conversations") { window?.searchConversations() }
                .keyboardShortcut("f")
                .disabled(window == nil)
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(SidebarSection.numbered.enumerated()), id: \.element) { index, section in
                Button(section.title) { window?.show(section) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(window == nil)
            }
        }
    }
}

/// ⌘K: pick the chat's model by typing part of its name; Return takes the first match.
struct ModelSwitcher: View {
    let selectedID: String?
    var onSelect: (InstalledModel) -> Void

    @Environment(ModelStore.self) private var store
    @Environment(InferenceEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [InstalledModel] {
        let models = store.sortedByRecentUse
        guard !query.trimmed.isEmpty else { return models }
        return models.filter { $0.displayName.localizedStandardContains(query.trimmed) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(matches) { model in
                    Button {
                        choose(model)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                Text(model.isSystem ? "Built into iOS"
                                     : engine.isLoaded(model.id) ? "Loaded · \(model.parameterLabel)"
                                     : "\(model.parameterLabel) · \(ByteFormat.file(model.sizeBytes))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.id == selectedID {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if matches.isEmpty {
                    Text(store.models.isEmpty ? "No models downloaded." : "No model matches “\(query)”.")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Model name")
            .onSubmit(of: .search) {
                if let first = matches.first { choose(first) }
            }
            .navigationTitle("Switch Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func choose(_ model: InstalledModel) {
        onSelect(model)
        dismiss()
    }
}
