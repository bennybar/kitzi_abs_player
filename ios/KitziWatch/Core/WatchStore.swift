import Foundation
import WidgetKit

/// Small persisted values (the same helper the iPhone app has, which the shared
/// API code uses), plus what only the watch keeps: the shelf and its positions.
enum Store {
    static let d = UserDefaults.standard
    /// Shared with the watch face widget.
    static let group = UserDefaults(suiteName: WidgetBook.appGroup)

    static func string(_ k: String) -> String? { d.string(forKey: k) }
    static func set(_ v: Any?, _ k: String) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
    static func double(_ k: String) -> Double? { d.object(forKey: k) as? Double }
    static func bool(_ k: String) -> Bool { d.bool(forKey: k) }

    static var username: String? {
        get { string("username") }
        set { set(newValue, "username") }
    }

    static var lastBookId: String? {
        get { string("last_book") }
        set { set(newValue, "last_book") }
    }

    /// Downloads may use the watch's cellular connection (off: Wi-Fi, or the
    /// phone's connection, whichever watchOS picks).
    static var downloadsUseCellular: Bool {
        get { bool("downloads_cellular") }
        set { set(newValue, "downloads_cellular") }
    }

    static var speed: Double {
        get { double("speed") ?? 1 }
        set { set(newValue, "speed") }
    }

    static var shelf: [ShelfBook] {
        get { d.data(forKey: "shelf").flatMap { try? JSONDecoder().decode([ShelfBook].self, from: $0) } ?? [] }
        set { set(try? JSONEncoder().encode(newValue), "shelf") }
    }

    // MARK: positions

    static func position(_ id: String) -> LocalPosition? {
        d.data(forKey: "pos:\(id)").flatMap { try? JSONDecoder().decode(LocalPosition.self, from: $0) }
    }

    static func savePosition(_ id: String, _ p: LocalPosition) {
        set(try? JSONEncoder().encode(p), "pos:\(id)")
    }

    static var pendingIds: [String] {
        d.dictionaryRepresentation().keys.filter { $0.hasPrefix("pos:") }.map { String($0.dropFirst(4)) }
            .filter { position($0)?.pending == true }
    }

    /// Signing out forgets the account's positions and shelf; downloads stay.
    static func signOut() {
        for key in d.dictionaryRepresentation().keys where key.hasPrefix("pos:") || key == "shelf" || key == "username" {
            d.removeObject(forKey: key)
        }
        WidgetBook.save(nil)
    }
}

/// A book on the Continue Listening shelf.
struct ShelfBook: Codable, Identifiable, Hashable {
    var book: Book
    var currentTimeSec: Double
    var lastUpdate: Int64
    var id: String { book.id }
    var durationSec: Double { book.durationSec ?? 0 }
}

/// Where this watch last was in a book, and whether the server has it yet.
/// `savedAt` is in the server's clock (Format.nowMs), like the iPhone's.
struct LocalPosition: Codable {
    var sec: Double
    var savedAt: Int64
    var pending: Bool
    var finished: Bool
}

extension WidgetBook {
    /// Saves what the watch face shows and asks it to redraw.
    static func save(_ b: WidgetBook?) {
        Store.group?.set(b.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
