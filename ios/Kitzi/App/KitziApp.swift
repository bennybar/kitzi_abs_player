import SwiftUI

@main
struct KitziApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundTasks.register()
        #if DEBUG
        // Test hook: sign in from the environment (simulator runs only).
        let env = ProcessInfo.processInfo.environment
        if let server = env["KITZI_TEST_SERVER"], let user = env["KITZI_TEST_USER"], let pass = env["KITZI_TEST_PASS"], !Session.shared.signedIn {
            Task { _ = await API.shared.login(base: server, username: user, password: pass) }
        }
        #endif
        _ = Downloads.shared
        _ = Player.shared
        return true
    }

    /// iOS relaunched us for finished background downloads.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Downloads.sessionId else { completionHandler(); return }
        Downloads.shared.backgroundCompletion = completionHandler
    }
}
