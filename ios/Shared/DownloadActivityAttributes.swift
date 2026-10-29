import ActivityKit
import Foundation

/// The downloads Live Activity (Dynamic Island + Lock Screen). Shared by the app,
/// which starts/updates/ends it, and the widget extension, which draws it.
nonisolated struct DownloadActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        /// The book downloading now.
        var title: String
        /// 0...1 for that book.
        var fraction: Double
        /// Books still waiting after this one.
        var queued: Int
        /// True once everything finished — shown briefly before the activity ends.
        var done: Bool
        /// With `done`: the last download failed or was cancelled.
        var failed: Bool
    }
}
