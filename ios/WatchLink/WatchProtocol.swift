import Foundation

/// What the iPhone app and the watch app say to each other over WatchConnectivity.
/// Compiled into both.
nonisolated enum WatchMsg {
    /// Every message has a "kind".
    static let kind = "kind"

    /// Watch → phone: "sign me in". The reply is a `WatchLogin` (or an "error").
    static let login = "login"
    /// Watch → phone: what the iPhone is playing. The reply carries "state" (a `PhoneState`), or nothing.
    static let state = "state"
    /// Watch → phone: a remote control command ("cmd", a `RemoteCommand`; "value" for speed and sleep).
    /// The reply is the state after it.
    static let command = "command"

    /// Phone → watch file transfers: one per track, then the cover. Metadata
    /// carries the book ("manifest", a `WatchBookManifest`) and which file it is.
    static let track = "track"
    static let cover = "cover"
}

/// The iPhone's sign-in, handed to the watch. Not the phone's own access/refresh
/// tokens (refresh tokens rotate, so two devices sharing one log each other out):
/// the account's long-lived API token from /api/me, as the Wear OS app does.
struct WatchLogin: Codable {
    var baseURL: String
    var token: String
    var username: String?
    var headers: [String: String]
}

/// A downloaded book: what's needed to play it with no network. The same shape as
/// the iPhone's DownloadedBook, so a book sent from the phone carries it as is.
struct WatchBookManifest: Codable {
    var book: Book
    var tracks: [Track]   // url = path relative to the books folder
    var chapters: [Chapter]
}

/// What the iPhone is playing, for the watch's remote.
struct PhoneState: Codable, Equatable {
    var itemId: String
    var title: String
    var author: String?
    var chapter: String?
    var chapterStartSec: Double?
    var chapterEndSec: Double?
    var positionSec: Double
    var durationSec: Double
    var isPlaying: Bool
    var speed: Double
    /// Seconds until the sleep timer pauses; nil when it's off.
    var sleepRemainingSec: Double?
    var sleepEndOfChapter: Bool
    var skipBackSec: Int
    var skipForwardSec: Int
}

enum RemoteCommand: String, Codable {
    case toggle, back, forward, previousChapter, nextChapter, bookmark
    /// value: the speed.
    case speed
    /// value: minutes.
    case sleep
    case sleepEndOfChapter, sleepOff
}
