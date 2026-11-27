import SwiftUI
import WatchKit

@main
struct KitziWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                // The watch face widget: open on the player (else the latest book).
                .onOpenURL { url in
                    guard url.host == "player", WatchModel.shared.signedIn else { return }
                    if WatchPlayer.shared.nowPlaying != nil {
                        WatchNav.shared.path = [.player]
                    } else if let s = WatchModel.shared.shelf.first {
                        WatchNav.shared.path = [.book(s.id)]
                    }
                }
                .environment(WatchModel.shared)
                .environment(WatchPlayer.shared)
                .environment(WatchDownloads.shared)
                .environment(WatchLink.shared)
        }
        .onChange(of: phase) { _, p in
            WatchPlayer.shared.screenActive = p == .active
            if p == .background { WatchModel.shared.scheduleRefresh() }
            guard p == .active else { return }
            Store.set(Date().timeIntervalSince1970, "last_used")
            guard WatchModel.shared.signedIn else { return }
            Task { await WatchModel.shared.refreshIfStale() }
        }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        WatchLink.shared.start()
        _ = WatchDownloads.shared
        _ = WatchPlayer.shared
        WatchModel.shared.scheduleRefresh()
        #if DEBUG
        // Test hook (simulator only): sign in from the environment.
        let env = ProcessInfo.processInfo.environment
        if let server = env["KITZI_TEST_SERVER"], let user = env["KITZI_TEST_USER"], let pass = env["KITZI_TEST_PASS"], !Session.shared.signedIn {
            Task { try? await WatchModel.shared.signIn(server: server, username: user, password: pass) }
        }
        Task { await DebugHooks.run() }
        #endif
    }

    /// Woken in the background: finished downloads, files from the phone, or the
    /// retry of positions that couldn't be sent.
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let t as WKURLSessionRefreshBackgroundTask:
                WatchDownloads.shared.hold(t)
            case let t as WKWatchConnectivityRefreshBackgroundTask:
                WatchLink.shared.hold(t)
            case let t as WKApplicationRefreshBackgroundTask:
                Task {
                    await WatchModel.shared.backgroundRefresh()
                    t.setTaskCompletedWithSnapshot(false)
                }
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
