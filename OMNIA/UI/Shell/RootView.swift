import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(InferenceEngine.self) private var engine
    @Environment(ModelImporter.self) private var importer
    @Environment(AppNavigator.self) private var navigator
    @Environment(ClusterHost.self) private var clusterHost
    @Environment(ClusterWorker.self) private var clusterWorker

    @State private var selection: SidebarSelection?
    /// The ID the new chat's conversation gets with its first message. The new chat's screen uses
    /// it from the start, so sending keeps the same screen instead of building another.
    @State private var newChatID = UUID()
    /// Identifies this window's commands for the menu bar (see `WindowCommands`).
    @State private var windowID = UUID()
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var showOnboarding = false
    @State private var continueOnUnsupported = false
    /// On a device OMNIA isn't tuned for, it can still lend its GPU to a cluster.
    @State private var lendingOnly = false
    /// Bumped by ⌘F to put the cursor in the sidebar's search field.
    @State private var searchRequest = 0

    private let device = AppServices.shared.device

    /// A window opened for one conversation shows it full width, its sidebar a swipe away.
    init(conversation: UUID? = nil) {
        _selection = State(initialValue: conversation.map { .conversation($0) } ?? .section(.home))
        _columnVisibility = State(initialValue: conversation == nil ? .all : .detailOnly)
    }

    var body: some View {
        Group {
            if device.isSupported || continueOnUnsupported {
                mainInterface
            } else if lendingOnly || clusterWorker.isActive || clusterWorker.proposedInvitation != nil {
                NavigationStack {
                    ClusterView(lendingOnly: true)
                        .toolbar {
                            if !clusterWorker.isActive {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("Back") { lendingOnly = false }
                                }
                            }
                        }
                }
            } else {
                UnsupportedDeviceView(device: device, onLend: { lendingOnly = true }) { continueOnUnsupported = true }
            }
        }
        .clusterPrompts(navigate: { selection = .section(.cluster) })
        .preferredColorScheme(settings.appearance.colorScheme)
        .tint(Theme.accent(settings.accent))
        .onAppear {
            if !settings.hasCompletedOnboarding { showOnboarding = true }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { destination in
                settings.hasCompletedOnboarding = true
                showOnboarding = false
                if let destination { selection = .section(destination) }
            }
            .preferredColorScheme(settings.appearance.colorScheme)
            .tint(Theme.accent(settings.accent))
        }
    }

    private var mainInterface: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection, searchRequest: searchRequest)
                .navigationSplitViewColumnWidth(min: 270, ideal: 300, max: 360)
        } detail: {
            NavigationStack {
                DetailRouter(selection: $selection, newChatID: newChatID)
            }
            .id(detailIdentity)
        }
        .navigationSplitViewStyle(.balanced)
        .background(Theme.canvas)
        .overlay(alignment: .top) {
            if let notice = engine.notice {
                NoticeBanner(notice: notice) { engine.dismissNotice() }
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let storeError = PersistenceSchema.loadError {
                    // The on-disk store failed to open; conversations this session live in memory only.
                    Label("Conversations couldn't be opened (\(storeError)). New conversations won't be saved this session.",
                          systemImage: "externaldrive.badge.exclamationmark")
                        .font(.footnote)
                        .padding(12)
                        .frame(maxWidth: 560)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                        .padding(.horizontal, 16)
                }
                ImportStatusBanner()
            }
        }
        .omniaAnimation(settings.animations, value: engine.notice)
        .onChange(of: selection) { _, new in
            // The new chat became this conversation: the next new chat starts with a fresh ID.
            if new == .conversation(newChatID) { newChatID = UUID() }
        }
        .onChange(of: navigator.request, initial: true) { _, request in
            guard let request else { return }
            if let conversation = request.conversation {
                selection = .conversation(conversation)
            } else if let section = request.section {
                selection = .section(section)
            }
            navigator.handled(request)
        }
        .focusedSceneValue(\.windowCommands, WindowCommands(
            window: windowID,
            newChat: { selection = .section(.chat) },
            show: { selection = .section($0) },
            searchConversations: {
                columnVisibility = .all
                searchRequest += 1
            }))
    }

    /// Each section and each conversation gets its own navigation stack, so switching never shows
    /// what another one had pushed. A new chat already has its conversation's identity: when its
    /// first message creates the conversation, the screen stays.
    private var detailIdentity: String {
        switch selection {
        case .section(.chat): "chat-\(newChatID.uuidString)"
        case .section(let section): section.rawValue
        case .conversation(let id): "chat-\(id.uuidString)"
        case nil: "home"
        }
    }
}

struct DetailRouter: View {
    @Binding var selection: SidebarSelection?
    /// The conversation ID the new chat's first message creates.
    var newChatID = UUID()

    var body: some View {
        switch selection {
        case .section(.home), nil:
            HomeView(selection: $selection)
        case .section(.chat), .conversation:
            // One branch for both: a new chat becoming its conversation stays the same view.
            ChatView(conversationID: conversationID, newConversationID: newChatID, selection: $selection)
        case .section(.models):
            ModelsView(selection: $selection)
        case .section(.cluster):
            ClusterView()
        case .section(.compare):
            CompareView()
        case .section(.library):
            LibraryView(selection: $selection)
        case .section(.performance):
            PerformanceView()
        case .section(.settings):
            SettingsView()
        }
    }

    private var conversationID: UUID? {
        if case .conversation(let id) = selection { return id }
        return nil
    }
}

/// Progress and results of importing a model from Files.
struct ImportStatusBanner: View {
    @Environment(ModelImporter.self) private var importer

    var body: some View {
        Group {
            switch importer.phase {
            case .idle:
                EmptyView()
            case let .copying(name, fraction):
                banner(symbol: "square.and.arrow.down", text: "Importing \(name)", progress: fraction)
            case let .verifying(name):
                banner(symbol: "checkmark.shield", text: "Verifying \(name)", progress: nil)
            case let .failed(message):
                banner(symbol: "exclamationmark.triangle", text: message, progress: nil, dismissible: true)
            case let .imported(name):
                banner(symbol: "checkmark.circle", text: "\(name) is ready to use offline.", progress: nil, dismissible: true)
            }
        }
        .padding(.bottom, 12)
    }

    private func banner(symbol: String, text: String, progress: Double?, dismissible: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.tint)
                Text(text).font(.subheadline).lineLimit(3)
                Spacer(minLength: 8)
                if dismissible {
                    Button { importer.reset() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            if let progress {
                ProgressView(value: progress).progressViewStyle(.linear)
            }
        }
        .padding(14)
        .frame(maxWidth: 520)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 16)
    }
}
