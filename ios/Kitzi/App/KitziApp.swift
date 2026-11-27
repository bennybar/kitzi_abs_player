import SwiftUI
import UserNotifications

@main
struct KitziApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundTasks.register()
        UNUserNotificationCenter.current().delegate = self
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

    // Shown while the app is open too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Tapped: open what it's about.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        var plain: [String: String] = [:]
        for (k, v) in info { if let k = k as? String, let v = v as? String { plain[k] = v } }
        await MainActor.run { NotificationRoute.shared.handle(plain) }
    }

    /// iOS relaunched us for finished background downloads.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Downloads.sessionId else { completionHandler(); return }
        Downloads.shared.backgroundCompletion = completionHandler
    }
}
