import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    /// Pictures one message can carry.
    static let maxImagesPerMessage = 4

    let conversationID: UUID?
    @Binding var selection: SidebarSelection?

    @Environment(ChatService.self) private var chat
    @Environment(ModelStore.self) private var store
    @Environment(InferenceEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var sizeClass

    @Query private var results: [Conversation]
    @Query(sort: \PromptTemplate.title) private var templates: [PromptTemplate]

    @State private var draft = ""
    @State private var attachments: [AttachmentRecord] = []
    @State private var images: [UUID: Data] = [:]
    @State private var draftModelID: String?
    @State private var showSettings = false
    @State private var showImporter = false
    @State private var showPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var workspace = WorkspaceController(browser: AppServices.shared.browser, runner: AppServices.shared.codeRunner)
    @State private var showExport = false
    @State private var attachmentError: String?
    @State private var editing: Message?
    @State private var editText = ""
    @State private var isNearBottom = true

    init(conversationID: UUID?, selection: Binding<SidebarSelection?>) {
        self.conversationID = conversationID
        _selection = selection
        let target = conversationID ?? UUID()
        _results = Query(filter: #Predicate<Conversation> { $0.id == target })
    }

    private var conversation: Conversation? { results.first }
    private var messages: [Message] { conversation?.orderedMessages ?? [] }
    private var activeModel: InstalledModel? {
        if let conversation { return chat.model(for: conversation) }
        return store.model(id: draftModelID) ?? chat.defaultModel
    }
    private var isGenerating: Bool { chat.isGenerating(conversation?.id) }

    var body: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                ChatEmptyState(model: activeModel, templates: Array(templates.prefix(6))) { template in
                    draft = template.body
                } onBrowseModels: {
                    selection = .section(.models)
                }
            } else {
                transcript
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                if let error = errorText {
                    errorBanner(error)
                } else if let model = activeModel, !images.isEmpty, !model.supportsImages {
                    imageSupportNotice(model)
                }
                ComposerView(
                    text: $draft,
                    attachments: $attachments,
                    images: $images,
                    isGenerating: isGenerating,
                    canSend: canSend,
                    placeholder: activeModel.map { "Message \($0.displayName)" } ?? "Download a model to start",
                    contextUsage: contextUsage,
                    onSend: send,
                    onStop: { chat.stop() },
                    onAttachPhotos: { showPhotoPicker = true },
                    onAttachFiles: { showImporter = true },
                    onPasteImage: pasteImages
                )
            }
        }
        .navigationTitle(conversation?.title ?? "New Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showSettings) {
            if let conversation {
                ConversationSettingsSheet(conversation: conversation)
            }
        }
        .sheet(isPresented: $showExport) {
            if let conversation { ExportSheet(conversations: [conversation]) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: DocumentExtractor.supportedTypes + ImageInput.supportedTypes,
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelection,
                      maxSelectionCount: Self.maxImagesPerMessage, matching: .images)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []
            Task { await addPhotos(items) }
        }
        .onChange(of: conversation?.id) { _, _ in
            editing = nil
            refreshWorkspace()
        }
        .onChange(of: messages.count) { _, _ in refreshWorkspace() }
        .onChange(of: isGenerating) { _, generating in
            if !generating { refreshWorkspace() }
        }
        .onAppear {
            refreshWorkspace()
            workspace.attach = { record in attachments.append(record) }
        }
        .environment(workspace)
        .inspector(isPresented: $workspace.isPresented) {
            WorkspaceView(controller: workspace)
                .inspectorColumnWidth(min: 340, ideal: 460, max: 760)
        }
    }

    /// The conversation's finished code blocks, for the workspace's Code tab.
    private func refreshWorkspace() {
        let finished = messages.filter { $0.id != chat.live?.messageID }
        workspace.artifacts = CodeArtifact.extract(from: finished)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(messages) { message in
                        MessageRow(
                            message: message,
                            live: chat.live?.messageID == message.id ? chat.live : nil,
                            isLast: message.id == messages.last?.id,
                            isEditing: editing?.id == message.id,
                            editText: $editText,
                            actions: actions(for: message)
                        )
                        .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, sizeClass == .compact ? 16 : 28)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 120
            } action: { _, nearBottom in
                isNearBottom = nearBottom
            }
            .onChange(of: chat.live?.displayContent.count) { _, _ in
                if isNearBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.smooth) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ModelPickerMenu(selectedID: activeModel?.id) { model in
                if let conversation {
                    chat.setModel(model, for: conversation)
                } else {
                    draftModelID = model.id
                }
            } onManage: {
                selection = .section(.models)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                workspace.isPresented.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .accessibilityLabel("Workspace")
            .help("Code, previews and the browser")
            .keyboardShortcut("\\", modifiers: [.command, .option])
            if conversation != nil {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Conversation Settings")

                Menu {
                    if let conversation {
                        Button(conversation.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
                            conversation.isPinned.toggle()
                            chat.save()
                        }
                        Button("Export…", systemImage: "square.and.arrow.up") { showExport = true }
                        Divider()
                        Button("Delete Conversation", systemImage: "trash", role: .destructive) {
                            selection = .section(.chat)
                            chat.delete(conversation)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    // MARK: Actions

    private var canSend: Bool {
        activeModel != nil && !isGenerating && !chat.isBusy && (!draft.trimmed.isEmpty || !attachments.isEmpty)
    }

    private var errorText: String? {
        guard let id = conversation?.id else { return attachmentError }
        return chat.errors[id] ?? attachmentError
    }

    private var contextUsage: Double? {
        if let live = chat.live, live.conversationID == conversation?.id, let stats = engine.lastStats, stats.contextSize > 0 {
            return stats.contextUtilization
        }
        guard let stats = messages.last(where: { $0.stats != nil })?.stats else { return nil }
        return stats.contextUtilization
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        let files = attachments
        let pictures = images
        draft = ""
        attachments = []
        images = [:]
        attachmentError = nil
        let result = chat.send(text, attachments: files, images: pictures, in: conversation, modelID: draftModelID)
        if conversation == nil, let created = result {
            selection = .conversation(created.id)
        }
    }

    private func actions(for message: Message) -> MessageRow.Actions {
        MessageRow.Actions(
            copy: { UIPasteboard.general.string = message.content },
            regenerate: {
                guard let conversation else { return }
                chat.regenerate(message, in: conversation)
            },
            continueReply: {
                guard let conversation else { return }
                chat.continueReply(message, in: conversation)
            },
            beginEdit: {
                editText = message.content
                editing = message
            },
            commitEdit: {
                guard let conversation else { return }
                let text = editText
                editing = nil
                chat.edit(message, to: text, in: conversation)
            },
            cancelEdit: { editing = nil },
            delete: {
                guard let conversation else { return }
                chat.delete(message, in: conversation)
            },
            canMutate: !chat.isBusy
        )
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                for url in urls {
                    if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                        await addImage(named: url.lastPathComponent) {
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            return try Data(contentsOf: url)
                        }
                        continue
                    }
                    do {
                        let extracted = try await Task.detached(priority: .userInitiated) {
                            try DocumentExtractor.extract(from: url)
                        }.value
                        attachments.append(AttachmentRecord(name: url.lastPathComponent, kind: extracted.kind,
                                                            byteSize: extracted.byteSize, text: extracted.text))
                        attachmentError = nil
                    } catch {
                        attachmentError = error.localizedDescription
                    }
                }
            }
        case .failure(let error):
            attachmentError = error.localizedDescription
        }
    }

    // MARK: Images

    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for (offset, item) in items.enumerated() {
            let name = items.count == 1 ? "Photo" : "Photo \(offset + 1)"
            await addImage(named: name) {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw ImageInput.ImageError.unreadable
                }
                return data
            }
        }
    }

    /// Images copied in another app. Reading them may show iOS's paste permission prompt.
    private func pasteImages() {
        let pasted = UIPasteboard.general.images ?? []
        guard !pasted.isEmpty else { return }
        Task {
            for (offset, image) in pasted.enumerated() {
                await addImage(named: pasted.count == 1 ? "Pasted Image" : "Pasted Image \(offset + 1)") {
                    // PNG has no orientation tag: draw the image upright first.
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = image.scale
                    let upright = UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in
                        image.draw(at: .zero)
                    }
                    return upright
                }
            }
        }
    }

    /// Prepares a picture for the model off the main thread and adds it to the draft.
    private func addImage(named name: String, load: @escaping @Sendable () async throws -> Data) async {
        guard attachments.filter({ $0.kind == .image }).count < Self.maxImagesPerMessage else {
            attachmentError = "A message can include up to \(Self.maxImagesPerMessage) images."
            return
        }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try ImageInput.prepare(try await load())
            }.value
            let record = AttachmentRecord(name: name, kind: .image, byteSize: prepared.data.count, text: "")
            images[record.id] = prepared.data
            attachments.append(record)
            attachmentError = nil
            if let model = activeModel { engine.prepareImages(for: model) }
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    private func imageSupportNotice(_ model: InstalledModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash").foregroundStyle(Theme.caution)
            Text("\(model.displayName) can't see images; it will only be told they're attached. Add image support in Models, or pick a model that has it.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Models") { selection = .section(.models) }
                .font(.footnote.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: 820)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution)
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                attachmentError = nil
                if let id = conversation?.id { chat.clearError(id) }
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: 820)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }
}

// MARK: - Model picker

struct ModelPickerMenu: View {
    let selectedID: String?
    var onSelect: (InstalledModel) -> Void
    var onManage: () -> Void

    @Environment(ModelStore.self) private var store
    @Environment(InferenceEngine.self) private var engine

    var body: some View {
        Menu {
            if store.models.isEmpty {
                Text("No models downloaded")
            }
            ForEach(store.sortedByRecentUse) { model in
                Button {
                    onSelect(model)
                } label: {
                    if model.id == selectedID {
                        Label(model.displayName, systemImage: "checkmark")
                    } else {
                        Text(model.displayName)
                    }
                    Text(model.isSystem ? "Built into iOS"
                         : engine.isLoaded(model.id) ? "Loaded · \(model.parameterLabel)" : "\(model.parameterLabel) · \(ByteFormat.file(model.sizeBytes))")
                }
            }
            Divider()
            Button("Manage Models…", systemImage: "cube.transparent", action: onManage)
        } label: {
            HStack(spacing: 6) {
                if let id = selectedID, engine.loadingModelID == id {
                    ProgressView().controlSize(.mini)
                } else {
                    StatusDot(color: selectedID.map { engine.isLoaded($0) } == true ? Theme.positive : Color.secondary.opacity(0.5))
                }
                Text(store.model(id: selectedID)?.displayName ?? "Choose a Model")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

// MARK: - Empty state

struct ChatEmptyState: View {
    let model: InstalledModel?
    let templates: [PromptTemplate]
    var onTemplate: (PromptTemplate) -> Void
    var onBrowseModels: () -> Void

    @Environment(AppSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 60)
                OmniaMark(size: 64, animated: settings.animations == .full)
                if let model {
                    VStack(spacing: 6) {
                        Text("How can I help?")
                            .font(.title2.weight(.semibold))
                        Text("\(model.displayName) · runs entirely on this device")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !templates.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                            ForEach(templates) { template in
                                Button {
                                    onTemplate(template)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(template.title).font(.subheadline.weight(.semibold))
                                        Text(template.category).font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .surface(padding: 12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: 640)
                    }
                } else {
                    VStack(spacing: 8) {
                        Text("No model on this device yet")
                            .font(.title2.weight(.semibold))
                        Text("Download a recommended model once; after that, OMNIA works completely offline.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button("Browse Models", action: onBrowseModels)
                        .buttonStyle(.glassProminent)
                }
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
    }
}
