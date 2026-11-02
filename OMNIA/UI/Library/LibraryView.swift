import SwiftData
import SwiftUI

/// Conversations, folders, prompt templates, personalities, documents and inference history.
struct LibraryView: View {
    @Binding var selection: SidebarSelection?

    enum LibraryTab: String, CaseIterable, Identifiable {
        case conversations, prompts, personas, documents, history
        var id: String { rawValue }
        var title: String {
            switch self {
            case .conversations: "Conversations"
            case .prompts: "Prompts"
            case .personas: "Personalities"
            case .documents: "Documents"
            case .history: "History"
            }
        }
    }

    @State private var section: LibraryTab = .conversations

    var body: some View {
        VStack(spacing: 0) {
            Picker("Library", selection: $section) {
                ForEach(LibraryTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 760)

            switch section {
            case .conversations: ConversationLibrary(selection: $selection)
            case .prompts: PromptLibrary(selection: $selection)
            case .personas: PersonaLibrary()
            case .documents: DocumentLibrary()
            case .history: InferenceHistoryView()
            }
        }
        .background(Theme.canvas)
        .navigationTitle("Library")
    }
}

// MARK: - Conversations

struct ConversationLibrary: View {
    @Binding var selection: SidebarSelection?

    @Environment(\.modelContext) private var context
    @Environment(ChatService.self) private var chat
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \Folder.name) private var folders: [Folder]

    @State private var search = ""
    @State private var folderFilter: UUID?
    @State private var modelFilter: String?
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var exportAll = false
    @State private var showClearConfirm = false

    private var filtered: [Conversation] {
        var result = conversations
        if let folderFilter { result = result.filter { $0.folder?.id == folderFilter } }
        if let modelFilter { result = result.filter { $0.modelName == modelFilter } }
        if !search.trimmed.isEmpty, let matches = ConversationSearch.matches(search, in: context) {
            result = result.filter { matches.contains($0.id) }
        }
        return result
    }

    private var modelNames: [String] {
        Array(Set(conversations.compactMap(\.modelName))).sorted()
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Menu {
                        Button("All Folders") { folderFilter = nil }
                        ForEach(folders) { folder in
                            Button(folder.name) { folderFilter = folder.id }
                        }
                        Divider()
                        Button("New Folder…", systemImage: "folder.badge.plus") { showNewFolder = true }
                    } label: {
                        Label(folders.first { $0.id == folderFilter }?.name ?? "All Folders", systemImage: "folder")
                    }
                    Spacer()
                    Menu {
                        Button("All Models") { modelFilter = nil }
                        ForEach(modelNames, id: \.self) { name in
                            Button(name) { modelFilter = name }
                        }
                    } label: {
                        Label(modelFilter ?? "All Models", systemImage: "cube")
                    }
                }
                .font(.subheadline)
            }

            if !folders.isEmpty && folderFilter == nil {
                Section("Folders") {
                    ForEach(folders) { folder in
                        Button {
                            folderFilter = folder.id
                        } label: {
                            HStack {
                                Label(folder.name, systemImage: "folder")
                                Spacer()
                                Text("\(folder.conversations.count)").foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in
                        offsets.map { folders[$0] }.forEach { context.delete($0) }
                        try? context.save()
                    }
                }
            }

            Section("\(filtered.count) Conversations") {
                ForEach(filtered) { conversation in
                    Button {
                        selection = .conversation(conversation.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                if conversation.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
                                Text(conversation.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            }
                            Text(conversation.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text("\(conversation.modelName ?? "No model") · \(conversation.messages.count) messages · \(conversation.updatedAt.relativeDescription)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                    .contextMenu {
                        Menu("Move to Folder", systemImage: "folder") {
                            Button("None") { conversation.folder = nil; chat.save() }
                            ForEach(folders) { folder in
                                Button(folder.name) { conversation.folder = folder; chat.save() }
                            }
                        }
                        Button(conversation.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
                            conversation.isPinned.toggle()
                            chat.save()
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { chat.delete(conversation) }
                    }
                }
                .onDelete { offsets in
                    offsets.map { filtered[$0] }.forEach { chat.delete($0) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .searchable(text: $search, prompt: "Search titles and messages")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Export All…", systemImage: "square.and.arrow.up") { exportAll = true }
                        .disabled(conversations.isEmpty)
                    Button("New Folder…", systemImage: "folder.badge.plus") { showNewFolder = true }
                    Divider()
                    Button("Delete All Conversations…", systemImage: "trash", role: .destructive) { showClearConfirm = true }
                        .disabled(conversations.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $exportAll) { ExportSheet(conversations: filtered) }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                if !newFolderName.trimmed.isEmpty {
                    context.insert(Folder(name: newFolderName.trimmed))
                    try? context.save()
                }
                newFolderName = ""
            }
        }
        .confirmationDialog("Delete all conversations?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Delete \(conversations.count) Conversations", role: .destructive) {
                conversations.forEach { chat.delete($0) }
                selection = .section(.library)
            }
        } message: {
            Text("This permanently removes every conversation from this device.")
        }
    }
}

// MARK: - Prompts

struct PromptLibrary: View {
    @Binding var selection: SidebarSelection?
    @Environment(\.modelContext) private var context
    @Query(sort: \PromptTemplate.title) private var templates: [PromptTemplate]
    @State private var editing: PromptTemplate?
    @State private var creating = false

    var body: some View {
        List {
            let categories = Array(Set(templates.map(\.category))).sorted()
            ForEach(categories, id: \.self) { category in
                Section(category) {
                    ForEach(templates.filter { $0.category == category }) { template in
                        Button {
                            editing = template
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(template.title).font(.subheadline.weight(.semibold))
                                Text(template.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                context.delete(template)
                                try? context.save()
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Prompt", systemImage: "plus") { creating = true }
            }
        }
        .sheet(item: $editing) { template in
            PromptEditor(template: template)
        }
        .sheet(isPresented: $creating) {
            PromptEditor(template: nil)
        }
    }
}

struct PromptEditor: View {
    let template: PromptTemplate?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var category = "General"
    @State private var bodyText = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Category", text: $category)
                Section("Prompt") {
                    TextEditor(text: $bodyText).frame(minHeight: 200)
                }
            }
            .navigationTitle(template == nil ? "New Prompt" : "Edit Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let template {
                            template.title = title
                            template.category = category
                            template.body = bodyText
                        } else {
                            context.insert(PromptTemplate(title: title, body: bodyText, category: category))
                        }
                        try? context.save()
                        dismiss()
                    }
                    .disabled(title.trimmed.isEmpty || bodyText.trimmed.isEmpty)
                }
            }
            .onAppear {
                if let template {
                    title = template.title
                    category = template.category
                    bodyText = template.body
                }
            }
        }
    }
}

// MARK: - Personas

struct PersonaLibrary: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Persona.createdAt) private var personas: [Persona]
    @State private var editing: Persona?
    @State private var creating = false

    var body: some View {
        List {
            Section {
                ForEach(personas) { persona in
                    Button {
                        editing = persona
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: persona.symbol)
                                .frame(width: 32, height: 32)
                                .background(Color.accentColor.opacity(0.12), in: Circle())
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(persona.name).font(.subheadline.weight(.semibold))
                                Text(persona.systemPrompt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    offsets.map { personas[$0] }.forEach { context.delete($0) }
                    try? context.save()
                }
            } footer: {
                Text("Choose a personality for any conversation in its settings.")
            }
        }
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Personality", systemImage: "plus") { creating = true }
            }
        }
        .sheet(item: $editing) { persona in PersonaEditor(persona: persona) }
        .sheet(isPresented: $creating) { PersonaEditor(persona: nil) }
    }
}

struct PersonaEditor: View {
    let persona: Persona?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "person.crop.circle"
    @State private var prompt = ""
    @State private var useTemperature = false
    @State private var temperature = 0.7

    private let symbols = ["person.crop.circle", "circle.hexagongrid", "chart.bar.doc.horizontal", "chevron.left.forwardslash.chevron.right",
                           "text.quote", "graduationcap", "text.alignleft", "lightbulb", "globe", "heart.text.square"]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Symbol", selection: $symbol) {
                    ForEach(symbols, id: \.self) { Label($0, systemImage: $0).labelStyle(.iconOnly).tag($0) }
                }
                Section("Instructions") {
                    TextEditor(text: $prompt).frame(minHeight: 180)
                }
                Section {
                    Toggle("Custom temperature", isOn: $useTemperature)
                    if useTemperature {
                        SamplingSlider(title: "Temperature", value: $temperature, range: 0...2, step: 0.05)
                    }
                }
            }
            .navigationTitle(persona == nil ? "New Personality" : name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let persona {
                            persona.name = name
                            persona.symbol = symbol
                            persona.systemPrompt = prompt
                            persona.temperature = useTemperature ? temperature : nil
                        } else {
                            context.insert(Persona(name: name, symbol: symbol, systemPrompt: prompt, temperature: useTemperature ? temperature : nil))
                        }
                        try? context.save()
                        dismiss()
                    }
                    .disabled(name.trimmed.isEmpty || prompt.trimmed.isEmpty)
                }
            }
            .onAppear {
                if let persona {
                    name = persona.name
                    symbol = persona.symbol
                    prompt = persona.systemPrompt
                    useTemperature = persona.temperature != nil
                    temperature = persona.temperature ?? 0.7
                }
            }
        }
    }
}
