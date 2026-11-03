import SwiftData
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    /// Changes when ⌘F asks for the search field.
    var searchRequest = 0

    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @FocusState private var searchFocused: Bool
    @Environment(ChatService.self) private var chat
    @Environment(InferenceEngine.self) private var engine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(ModelStore.self) private var store
    @Environment(DownloadManager.self) private var downloads

    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var search = ""
    @State private var searchMatches: Set<UUID>?
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var deleting: Conversation?
    @State private var exporting: Conversation?

    private var filtered: [Conversation] {
        guard let matches = searchMatches, !search.trimmed.isEmpty else { return conversations }
        return conversations.filter { matches.contains($0.id) }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(SidebarSection.allCases) { section in
                    NavigationLink(value: SidebarSelection.section(section)) {
                        Label(section.title, systemImage: section.symbol)
                    }
                    .badge(section == .models && downloads.hasActiveDownloads ? Text(Image(systemName: "arrow.down")) : nil)
                }
            }

            let pinned = filtered.filter(\.isPinned)
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { conversation in row(conversation) }
                }
            }

            let recent = filtered.filter { !$0.isPinned }.prefix(search.isEmpty ? 40 : 200)
            if !recent.isEmpty {
                Section(search.isEmpty ? "Recent" : "Results") {
                    ForEach(Array(recent)) { conversation in row(conversation) }
                }
            } else if !search.trimmed.isEmpty && pinned.isEmpty {
                Text("No conversations match “\(search)”.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search conversations")
        .searchFocused($searchFocused)
        .onChange(of: searchRequest) { searchFocused = true }
        .onChange(of: search) { _, query in
            searchMatches = ConversationSearch.matches(query, in: context)
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .alert("Rename Conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let renaming, !renameText.trimmed.isEmpty {
                    renaming.title = renameText.trimmed
                    chat.save()
                }
                renaming = nil
            }
        }
        .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Conversation", role: .destructive) {
                if let deleting {
                    if selection == .conversation(deleting.id) { selection = .section(.chat) }
                    chat.delete(deleting)
                }
                deleting = nil
            }
        } message: {
            Text("Its messages are removed from this device permanently.")
        }
        .sheet(item: $exporting) { conversation in
            ExportSheet(conversations: [conversation])
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            OmniaMark(size: 28)
            OmniaWordmark(size: 17)
            Spacer()
            Button {
                selection = .section(.chat)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.medium))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("New Conversation")
            .help("New chat (⌘N)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let live = engine.live {
                StatusDot(color: .accentColor, pulsing: true)
                Text("Generating · \(live.modelName)").lineLimit(1)
            } else if let loaded = engine.loadedModels.first {
                StatusDot(color: Theme.positive)
                Text(loaded.info.displayName).lineLimit(1)
            } else if engine.loadingModelID != nil {
                ProgressView().controlSize(.mini)
                Text("Loading model…")
            } else {
                StatusDot(color: .secondary)
                Text(store.models.isEmpty ? "No models yet" : "No model loaded")
            }
            Spacer(minLength: 6)
            if !store.models.isEmpty {
                Label(connectivity.isOnline ? "Ready offline" : "Offline", systemImage: connectivity.isOnline ? "checkmark.icloud" : "icloud.slash")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(connectivity.isOnline ? Color.secondary : Theme.positive)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func row(_ conversation: Conversation) -> some View {
        NavigationLink(value: SidebarSelection.conversation(conversation.id)) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if chat.isGenerating(conversation.id) {
                        StatusDot(color: .accentColor, pulsing: true)
                    }
                    Text(conversation.title).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let model = conversation.modelName {
                        Text(model).lineLimit(1)
                    }
                    Text("·")
                    Text(conversation.updatedAt.relativeDescription).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .contextMenu {
            if supportsMultipleWindows {
                Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                    openWindow(id: OMNIAApp.mainWindow, value: conversation.id)
                }
                Divider()
            }
            Button(conversation.isPinned ? "Unpin" : "Pin", systemImage: conversation.isPinned ? "pin.slash" : "pin") {
                conversation.isPinned.toggle()
                chat.save()
            }
            Button("Rename", systemImage: "pencil") {
                renameText = conversation.title
                renaming = conversation
            }
            Button("Export…", systemImage: "square.and.arrow.up") { exporting = conversation }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = conversation }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = conversation }
            Button(conversation.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
                conversation.isPinned.toggle()
                chat.save()
            }
            .tint(.orange)
        }
    }
}

/// Searches titles and message text; returns matching conversation IDs.
enum ConversationSearch {
    @MainActor
    static func matches(_ query: String, in context: ModelContext) -> Set<UUID>? {
        let term = query.trimmed
        guard !term.isEmpty else { return nil }
        var ids = Set<UUID>()
        let titleDescriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.title.localizedStandardContains(term) })
        if let titled = try? context.fetch(titleDescriptor) { ids.formUnion(titled.map(\.id)) }
        var messageDescriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.content.localizedStandardContains(term) })
        messageDescriptor.fetchLimit = 500
        if let messages = try? context.fetch(messageDescriptor) {
            ids.formUnion(messages.compactMap { $0.conversation?.id })
        }
        return ids
    }
}

/// Lets the user pick a format, then shares the exported file.
struct ExportSheet: View {
    let conversations: [Conversation]
    @Environment(\.dismiss) private var dismiss
    @State private var format: ConversationExporter.Format = .markdown
    @State private var fileURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(ConversationExporter.Format.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(format == .markdown
                         ? "Readable in any notes or Markdown app."
                         : "Complete data including reasoning and generation statistics.")
                }
                Section {
                    if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("Share \(conversations.count == 1 ? "Conversation" : "\(conversations.count) Conversations")",
                                  systemImage: "square.and.arrow.up")
                        }
                    } else if let errorMessage {
                        Text(errorMessage).foregroundStyle(Theme.critical)
                    } else {
                        ProgressView()
                    }
                } footer: {
                    Text("Exports are created on this device. Nothing is uploaded unless you choose a destination.")
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: format) { prepare() }
        }
        .presentationDetents([.medium])
    }

    private func prepare() {
        do {
            fileURL = try ConversationExporter.file(for: conversations, format: format)
            errorMessage = nil
        } catch {
            fileURL = nil
            errorMessage = error.localizedDescription
        }
    }
}
