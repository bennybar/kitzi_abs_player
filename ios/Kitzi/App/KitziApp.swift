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
        if let url = env["KITZI_ACHEW_URL"] {
            Task {
                if url == "clear" {
                    Achew.shared.clear()
                    AppSettings.shared.achewEnabled = false
                } else {
                    try? await Achew.shared.connect(url: url, username: env["KITZI_ACHEW_USER"] ?? "", password: env["KITZI_ACHEW_PASS"] ?? "")
                    AppSettings.shared.achewEnabled = true
                }
            }
        }
        if let url = env["KITZI_SHELFARR_URL"], let token = env["KITZI_SHELFARR_TOKEN"] {
            Task {
                try? await Shelfarr.shared.connect(url: url, token: token, username: env["KITZI_SHELFARR_USER"] ?? "", password: env["KITZI_SHELFARR_PASS"] ?? "")
                AppSettings.shared.showShelfarrTab = true
            }
        }
        #endif
        _ = Downloads.shared
        _ = Player.shared
        PhoneLink.shared.start()
        #if DEBUG
        Task { await PhoneLink.shared.runDebugHooks() }
        #endif
        return true
    }

    /// iOS relaunched us for finished background downloads.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Downloads.sessionId else { completionHandler(); return }
        Downloads.shared.backgroundCompletion = completionHandler
    }
}
