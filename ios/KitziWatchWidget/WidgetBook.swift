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

    static func load() -> WidgetBook? {
        UserDefaults(suiteName: appGroup)?.data(forKey: key).flatMap { try? JSONDecoder().decode(WidgetBook.self, from: $0) }
    }
}
