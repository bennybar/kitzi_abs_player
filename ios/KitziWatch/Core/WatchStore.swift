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

    /// The streaming session open on the server, until it's closed. An HLS
    /// stream keeps hundreds of MB there: one the watch couldn't close (no
    /// signal, the app ended) is closed the next time it plays.
    static var openStream: String? {
        get { string("open_stream") }
        set { set(newValue, "open_stream") }
    }

    /// Downloads may use the watch's cellular connection (off: Wi-Fi, or the
    /// phone's connection, whichever watchOS picks).
    static var downloadsUseCellular: Bool {
        get { bool("downloads_cellular") }
        set { set(newValue, "downloads_cellular") }
    }

    /// A book streamed on the watch is also downloaded (watchOS fetches it when it
    /// suits it, often while charging), so it plays offline next time.
    static var autoDownload: Bool {
        get { bool("auto_download") }
        set { set(newValue, "auto_download") }
    }

    /// The most the watch's downloads may take, in GB (0: no limit).
    static var storageLimitGB: Int {
        get { d.integer(forKey: "storage_limit_gb") }
        set { set(newValue, "storage_limit_gb") }
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
    /// Saves what the watch face shows and asks it to redraw, only when it would
    /// show something else: another book, play/pause, or a time left more than a
    /// minute away from what the face works out itself (while playing it counts on
    /// at the speed; a skip, a seek or a new speed makes the difference).
    static func save(_ b: WidgetBook?) {
        let now = Date()
        var b = b
        if b?.isPlaying == true { b?.savedAt = now; b?.speed = WatchPlayer.shared.speed }
        let shown = last.map { $0.at(now) }
        if let s = shown, let b, s.title == b.title, s.isPlaying == b.isPlaying, abs(s.remainingSec - b.remainingSec) < 60 { return }
        if shown == nil, b == nil, loaded { return }
        loaded = true
        last = b
        Store.group?.set(b.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// What the face was last given (nil: nothing yet, or no book).
    private static var last: WidgetBook? = load()
    private static var loaded = false
}
