import SwiftData
import SwiftUI

@main
struct OMNIAApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private let services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            RootView()
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
                .modelContainer(services.container)
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    Task { await services.importer.importFile(at: url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: services.engine.sceneDidEnterBackground()
            case .active: services.engine.sceneWillEnterForeground()
            default: break
            }
        }
    }
}
