import Foundation
import Observation
import WatchKit

/// The watch app's state: the sign-in, the Continue Listening shelf and the
/// positions saved here, with the same rules as the Wear OS app.
@Observable
final class WatchModel {
    static let shared = WatchModel()

    private(set) var signedIn = Session.shared.signedIn
    /// Continue Listening, as last fetched (shown at once, offline too).
    private(set) var shelf: [ShelfBook] = Store.shelf
    private(set) var refreshing = false
    /// Whether the last refresh reached the server; nil before the first.
    private(set) var online: Bool?

    // MARK: sign in

    enum LoginError: Error, LocalizedError {
        case phoneUnreachable, phoneSignedOut, unsupported, failed(String)
        var errorDescription: String? {
            switch self {
            case .phoneUnreachable: "Open Kitzi on your iPhone and try again."
            case .phoneSignedOut: "Sign in to Kitzi on your iPhone first."
            case .unsupported: "Your server doesn't allow this. Sign in on the watch instead."
            case .failed(let s): s
            }
        }
    }

    /// Signs in with the iPhone's account (its long-lived API token, see WatchLogin).
    func signInWithPhone() async throws {
        let reply = try await WatchLink.shared.request([WatchMsg.kind: WatchMsg.login])
        if let data = reply["login"] as? Data, let login = try? JSONDecoder().decode(WatchLogin.self, from: data) {
            Session.shared.customHeaders = login.headers
            Session.shared.signIn(base: login.baseURL, access: login.token, refresh: nil)
            Store.username = login.username
            signedIn = true
            await refreshShelf()
            return
        }
        throw (reply["error"] as? String) == "signed_out" ? LoginError.phoneSignedOut : LoginError.unsupported
    }

    /// Signs in on the watch itself (its own session, with its own refresh token).
    func signIn(server: String, username: String, password: String) async throws {
        switch await API.shared.login(base: server, username: username, password: password) {
        case .ok:
            Store.username = username
            signedIn = true
            await refreshShelf()
        case .wrongCredentials: throw LoginError.failed("Wrong username or password.")
        case .unreachable: throw LoginError.failed("Can't reach the server.")
        case .notAudiobookshelf: throw LoginError.failed("That isn't an Audiobookshelf server.")
        case .serverError: throw LoginError.failed("The server had a problem. Try again.")
        }
    }

    func signOut() async {
        await WatchPlayer.shared.stop()
        _ = await flushPending()
        if Session.shared.refreshToken != nil { await API.shared.logout() }
        Session.shared.clear()
        Store.signOut()
        shelf = []
        signedIn = false
    }

    // MARK: shelf

    /// Re-fetches Continue Listening. Positions saved on the watch since win over older server ones.
    @discardableResult
    func refreshShelf() async -> Bool {
        guard signedIn, !refreshing else { return false }
        refreshing = true
        defer { refreshing = false }
        guard let items = try? await API.shared.getJSON("/api/me/items-in-progress?limit=25") as? JSON,
              let me = try? await API.shared.me() else {
            online = false
            signedIn = !Session.shared.expired
            return false
        }
        online = true
        var progress: [String: Progress] = [:]
        for m in me.objs("mediaProgress") { if let p = Progress.from(m) { progress[p.itemId] = p } }
        // Finished anywhere (here, the phone, the web): its download goes, so the
        // watch doesn't fill up with books that are done. Not the loaded one.
        let loaded = WatchPlayer.shared.nowPlaying?.book.id
        for (id, p) in progress where p.isFinished && id != loaded && WatchDownloads.shared.isDownloaded(id) {
            WatchDownloads.shared.delete(id)
        }
        shelf = items.objs("libraryItems").compactMap { item -> ShelfBook? in
            guard item.str("mediaType") == "book", let book = Book.from(item) else { return nil }
            let p = progress[book.id]
            guard p?.isFinished != true, let p, p.currentTimeSec > 0 else { return nil }
            var s = ShelfBook(book: book, currentTimeSec: p.currentTimeSec, lastUpdate: p.lastUpdate)
            if s.book.durationSec == nil, p.durationSec > 0 { s.book.durationSec = p.durationSec }
            if let local = Store.position(book.id), local.savedAt > p.lastUpdate {
                s.currentTimeSec = local.sec
                s.lastUpdate = local.savedAt
            }
            return s
        }
        .sorted { $0.lastUpdate > $1.lastUpdate }
        Store.shelf = shelf
        updateWidget()
        return true
    }

    /// A book finished on the watch leaves the shelf at once (the server agrees on the next refresh).
    func removeFromShelf(_ id: String) {
        shelf.removeAll { $0.id == id }
        Store.shelf = shelf
        updateWidget()
    }

    /// The watch's own newer position for a book (after listening here).
    func updateShelfPosition(_ book: Book, sec: Double) {
        if let i = shelf.firstIndex(where: { $0.id == book.id }) {
            shelf[i].currentTimeSec = sec
            shelf[i].lastUpdate = Format.nowMs
        } else {
            shelf.append(ShelfBook(book: book, currentTimeSec: sec, lastUpdate: Format.nowMs))
        }
        shelf.sort { $0.lastUpdate > $1.lastUpdate }
        Store.shelf = shelf
        updateWidget()
    }

    /// The watch face shows the loaded book, else the latest one on the shelf.
    func updateWidget() {
        let p = WatchPlayer.shared
        if let np = p.nowPlaying {
            let total = max(np.totalSec, 1)
            WidgetBook.save(WidgetBook(title: np.book.title, author: np.book.author, progress: p.position / total,
                                       remainingSec: max(total - p.position, 0), isPlaying: p.isPlaying))
        } else if let s = shelf.first {
            let total = max(s.durationSec, 1)
            WidgetBook.save(WidgetBook(title: s.book.title, author: s.book.author, progress: s.currentTimeSec / total,
                                       remainingSec: max(total - s.currentTimeSec, 0), isPlaying: false))
        } else {
            WidgetBook.save(nil)
        }
    }

    // MARK: offline positions

    /// Sends positions saved while offline. A newer position on the server (listened
    /// on another device since) wins and is kept. Skips the book that's playing: its
    /// own reports carry it. True when nothing is left pending.
    func flushPending() async -> Bool {
        let playing = WatchPlayer.shared.isPlaying ? WatchPlayer.shared.nowPlaying?.book.id : nil
        var clean = true
        for id in Store.pendingIds where id != playing {
            guard let local = Store.position(id) else { continue }
            if let server = try? await API.shared.mediaProgress(id).flatMap(Progress.from), server.lastUpdate > local.savedAt {
                Store.savePosition(id, LocalPosition(sec: local.sec, savedAt: local.savedAt, pending: false, finished: local.finished))
                continue
            }
            let duration = shelf.first { $0.id == id }?.book.durationSec ?? WatchDownloads.shared.downloaded(id)?.book.durationSec
            let report = API.Report(itemId: id, currentSec: local.sec, durationSec: duration, finished: local.finished, paused: true, listenedSec: nil)
            if await API.shared.saveProgress(report) {
                if Store.position(id)?.savedAt == local.savedAt {
                    Store.savePosition(id, LocalPosition(sec: local.sec, savedAt: local.savedAt, pending: false, finished: local.finished))
                }
            } else {
                clean = false
            }
        }
        if !clean { scheduleRetry() }
        return clean
    }

    /// Tries the pending positions again in a while, even if the app isn't open.
    func scheduleRetry() {
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(15 * 60), userInfo: nil,
                                                         scheduledCompletion: Self.ignore)
    }

    /// Not main-actor code: watchOS calls the completion on its own queue.
    nonisolated private static let ignore: @Sendable (Error?) -> Void = { _ in }

    /// Everything the "Sync now" button does: report the playing book, push what's pending, re-fetch the shelf.
    func syncNow() async -> Bool {
        let reported = await WatchPlayer.shared.reportNow()
        let flushed = await flushPending()
        let fetched = await refreshShelf()
        return reported != false && flushed && fetched
    }
}
