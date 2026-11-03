import SwiftData
import SwiftUI

@main
struct OMNIAApp: App {
    /// Every window is a main window; one opened for a conversation carries its ID.
    static let mainWindow = "main"

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let services = AppServices.shared

    var body: some Scene {
        WindowGroup(id: Self.mainWindow, for: UUID.self) { $conversation in
            RootView(conversation: conversation)
                .environment(services.settings)
                .environment(services.monitor)
                .environment(services.connectivity)
                .environment(services.store)
                .environment(services.downloads)
                .environment(services.importer)
                .environment(services.engine)
                .environment(services.chat)
                .environment(services.compare)
                .environment(services.semanticIndex)
                .environment(services.python)
                .environment(services.speech)
                .environment(services.dictation)
                .environment(services.navigator)
                .modelContainer(services.container)
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    Task { await services.importer.importFile(at: url) }
                }
        }
        .commands {
            OMNIACommands(chat: services.chat)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive:
                services.engine.sceneWillResignActive(keepGenerating: services.chat.holdsBackgroundGPU)
            case .background:
                services.engine.sceneDidEnterBackground(keepGenerating: services.chat.holdsBackgroundGPU)
                // Reading aloud goes on with the screen locked; listening doesn't.
                Task { await services.dictation.stop() }
            case .active:
                services.engine.sceneWillEnterForeground()
                services.store.refreshSystemModels()
            default: break
            }
        }
    }
}
