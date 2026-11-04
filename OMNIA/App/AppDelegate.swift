import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // A cluster device that vanishes mid-write must fail the write, not end the app (SIGPIPE's
        // default). llama.cpp's sockets opt out too; this covers every other socket.
        signal(SIGPIPE, SIG_IGN)
        AppServices.shared.start()
        return true
    }

    /// Called when model downloads finished while OMNIA was suspended or not running.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionIdentifier else {
            completionHandler()
            return
        }
        AppServices.shared.downloads.backgroundCompletionHandler = completionHandler
    }
}
