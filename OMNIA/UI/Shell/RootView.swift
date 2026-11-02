import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(InferenceEngine.self) private var engine
    @Environment(ModelImporter.self) private var importer

    @State private var selection: SidebarSelection? = .section(.home)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showOnboarding = false
    @State private var continueOnUnsupported = false

    private let device = AppServices.shared.device

    var body: some View {
        Group {
            if device.isSupported || continueOnUnsupported {
                mainInterface
            } else {
                UnsupportedDeviceView(device: device) { continueOnUnsupported = true }
            }
        }
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
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 270, ideal: 300, max: 360)
        } detail: {
            NavigationStack {
                DetailRouter(selection: $selection)
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
    }

    /// Each section gets its own navigation stack; conversations share the chat stack.
    private var detailIdentity: String {
        switch selection {
        case .section(let section): section.rawValue
        case .conversation(let id): "chat-\(id.uuidString)"
        case nil: "home"
        }
    }
}

struct DetailRouter: View {
    @Binding var selection: SidebarSelection?

    var body: some View {
        switch selection {
        case .section(.home), nil:
            HomeView(selection: $selection)
        case .section(.chat):
            ChatView(conversationID: nil, selection: $selection)
        case .conversation(let id):
            ChatView(conversationID: id, selection: $selection)
        case .section(.models):
            ModelsView(selection: $selection)
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
