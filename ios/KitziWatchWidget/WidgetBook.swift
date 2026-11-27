import Foundation

/// What the watch face shows: the book being listened to. Written by the watch
/// app into the shared app group, read by the widget. Compiled into both.
struct WidgetBook: Codable {
    static let appGroup = "group.com.bennybar.kitzi"
    static let key = "widget_book"

    var title: String
    var author: String?
    var progress: Double
    var remainingSec: Double
    var isPlaying: Bool
    /// Playing: the speed and when this was saved, so the face can count on by
    /// itself (its timeline has an entry every few minutes) without a reload.
    var speed: Double? = nil
    var savedAt: Date? = nil

    /// As it is at `date` (playing: moved on at the speed since it was saved).
    func at(_ date: Date) -> WidgetBook {
        guard isPlaying, let savedAt, remainingSec > 0, progress < 1 else { return self }
        let total = remainingSec / max(1 - progress, 0.0001)
        let moved = max(date.timeIntervalSince(savedAt), 0) * (speed ?? 1)
        var b = self
        b.remainingSec = max(remainingSec - moved, 0)
        b.progress = min((total - b.remainingSec) / max(total, 1), 1)
        return b
    }

    static func load() -> WidgetBook? {
        UserDefaults(suiteName: appGroup)?.data(forKey: key).flatMap { try? JSONDecoder().decode(WidgetBook.self, from: $0) }
    }
}
