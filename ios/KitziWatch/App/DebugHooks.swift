#if DEBUG
import Foundation
import UIKit

/// Simulator test runs, driven by the environment (never in release builds).
/// KITZI_W_TEST lists the steps; each prints "KITZITEST …" lines.
/// KITZI_W_SCREEN opens a screen for screenshots.
enum DebugHooks {
    private static var ran = false
    /// The progress check gets no answer (a slow link): see WatchPlayer.startPosition.
    static var serverSilent = false
    /// Streams can't reach anything (rebuilt items stall too).
    static var deadNetwork = false

    static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard !ran else { return }
        ran = true
        let steps = (env["KITZI_W_TEST"] ?? "").split(separator: ",").map(String.init)
        if steps.contains("phonelogin") && !WatchModel.shared.signedIn {
            do { try await WatchModel.shared.signInWithPhone(); log("phonelogin ok signedIn=\(WatchModel.shared.signedIn)") }
            catch { log("phonelogin failed: \(error.localizedDescription)") }
        }
        for _ in 0..<40 where !WatchModel.shared.signedIn { try? await Task.sleep(for: .seconds(0.5)) }
        if !steps.isEmpty { log("signedIn=\(WatchModel.shared.signedIn) base=\(API.shared.base ?? "-")") }
        for step in steps {
            switch step {
            case "shelf": await shelf()
            case "stream": await stream()
            case "deepstream": await deepStream()
            case "pending": await pending()
            case "download": await download()
            case "receive": await receive()
            case "receivefake": await receiveFake()
            case "dlkill": await downloadThenDie()
            case "dlresume": await downloadResumed()
            case "remote": await remote()
            case "staleresume": await staleResume()
            case "pausedseek": await pausedSeek()
            case "streambreak": await streamBreak()
            case "dlfail": await downloadFail()
            case "streamdead": await streamDead()
            case "autodl": await autoDownload()
            case "phonelink": await phoneLink()
            case "signoutpending": await signOutPending()
            case "dlkeep": await downloadsScreenData()
            case "dlcancel": for id in WatchDownloads.shared.activeIds { WatchDownloads.shared.cancel(id) }; log("dlcancel active=\(WatchDownloads.shared.activeIds.count)")
            case "dlclear": for id in WatchDownloads.shared.downloadedIds + WatchDownloads.shared.activeIds { WatchDownloads.shared.delete(id) }; log("dlclear done")
            case "signout": await WatchModel.shared.signOut(); log("signout signedIn=\(WatchModel.shared.signedIn)")
            default: break
            }
        }
        if !steps.isEmpty { log("done") }
        if let screen = env["KITZI_W_SCREEN"] {
            await WatchModel.shared.refreshShelf()
            let first = WatchModel.shared.shelf.first
            switch screen {
            case "book": if let first { WatchNav.shared.path = [.book(first.id)] }
            case "player":
                if let first {
                    _ = await WatchPlayer.shared.play(first.book, fallbackSec: first.currentTimeSec, fallbackAt: first.lastUpdate)
                    WatchPlayer.shared.pause()
                    WatchNav.shared.path = [.player]
                }
            case "remote": WatchNav.shared.path = [.remote]
            case "settings": WatchNav.shared.path = [.settings]
            case "downloads": WatchNav.shared.path = [.downloads]
            case "library": WatchNav.shared.path = [.library]
            default: break
            }
        }
    }

    static func log(_ s: String) { print("KITZITEST \(s)") }

    private static func serverPos(_ id: String) async -> (Double, Int64)? {
        guard let p = try? await API.shared.mediaProgress(id).flatMap(Progress.from) else { return nil }
        return (p.currentTimeSec, p.lastUpdate)
    }

    private static func shelf() async {
        let ok = await WatchModel.shared.refreshShelf()
        let s = WatchModel.shared.shelf
        log("shelf ok=\(ok) count=\(s.count) first=\(s.first?.book.title ?? "-") at=\(Int(s.first?.currentTimeSec ?? -1))")
        if let id = s.first?.id, let base = API.shared.base, let url = URL(string: "\(base)/api/items/\(id)/cover?width=200&format=jpeg") {
            let r = try? await URLSession.shared.data(for: API.shared.authorized(url))
            let http = r?.1 as? HTTPURLResponse
            log("cover status=\(http?.statusCode ?? -1) type=\(http?.value(forHTTPHeaderField: "Content-Type") ?? "-") bytes=\(r?.0.count ?? -1) image=\(r.flatMap { UIImage(data: $0.0) } != nil) loaded=\(await Covers.load(id) != nil)")
        }
        let w = WidgetBook.load()
        log("widget title=\(w?.title ?? "-") progress=\(w?.progress ?? -1)")
    }

    /// Streams the latest book for a few seconds, checks the report, and puts the
    /// position back where it was.
    private static func stream() async {
        guard let s = WatchModel.shared.shelf.first else { log("stream skipped: empty shelf"); return }
        let before = await serverPos(s.id)
        let p = WatchPlayer.shared
        if let why = await p.play(s.book, fallbackSec: s.currentTimeSec) { log("stream play failed: \(why)"); return }
        try? await Task.sleep(for: .seconds(1))
        let start = p.currentPosition()
        log("stream loaded isLocal=\(p.nowPlaying?.isLocal ?? false) tracks=\(p.nowPlaying?.tracks.count ?? 0) chapters=\(p.nowPlaying?.chapters.count ?? 0) start=\(Int(start)) server=\(Int(before?.0 ?? -1))")
        try? await Task.sleep(for: .seconds(8))
        log("stream after 8s playing=\(p.isPlaying) moved=\(String(format: "%.1f", p.currentPosition() - start)) chapter=\(p.chapterTitle ?? "-")")
        p.skip(30)
        log("stream skip+30 moved=\(String(format: "%.1f", p.currentPosition() - start))")
        p.setSpeed(1.5)
        try? await Task.sleep(for: .seconds(2))
        log("stream speed rate=\(p.isPlaying ? "playing" : "paused") speed=\(p.speed)")
        p.setSpeed(1)
        p.pause()
        try? await Task.sleep(for: .seconds(4))
        let after = await serverPos(s.id)
        log("stream paused status=\(p.status ?? "-") local=\(Int(p.currentPosition())) server=\(Int(after?.0 ?? -1)) pending=\(Store.position(s.id)?.pending ?? false)")
        // Back to where it was.
        p.seek(to: before?.0 ?? start)
        _ = await p.reportNow()
        await p.stop(report: false)
        let restored = await serverPos(s.id)
        log("stream restored server=\(Int(restored?.0 ?? -1)) wanted=\(Int(before?.0 ?? -1)) nowPlaying=\(p.nowPlaying == nil ? "nil" : "set")")
    }

    /// Streams from near the end of the book (where a file's index and a long
    /// way in used to take minutes), timing how long audio takes to start.
    private static func deepStream() async {
        guard let s = WatchModel.shared.shelf.first else { log("deepstream skipped: empty shelf"); return }
        let before = await serverPos(s.id)
        let p = WatchPlayer.shared
        var t0 = Date()
        if let why = await p.play(s.book, fallbackSec: s.currentTimeSec) { log("deepstream play failed: \(why)"); return }
        for _ in 0..<300 where !p.debugAudible { try? await Task.sleep(for: .milliseconds(100)) }
        log("deepstream start audible=\(p.debugAudible) after=\(String(format: "%.1f", Date().timeIntervalSince(t0)))s at=\(Int(p.currentPosition()))")
        let total = p.nowPlaying?.totalSec ?? 0
        let target = total - 1500
        t0 = Date()
        p.seek(to: target)
        try? await Task.sleep(for: .milliseconds(300))
        for _ in 0..<300 where !(p.debugAudible && !p.jumping) { try? await Task.sleep(for: .milliseconds(100)) }
        log("deepstream seek to=\(Int(target)) of=\(Int(total)) audible=\(p.debugAudible) after=\(String(format: "%.1f", Date().timeIntervalSince(t0)))s at=\(Int(p.currentPosition())) recoveries=\(p.debugRecoveries)")
        for i in 0..<6 {
            try? await Task.sleep(for: .seconds(1))
            log("deepstream t+\(i + 1)s at=\(String(format: "%.1f", p.currentPosition())) off=\(String(format: "%.1f", p.currentPosition() - target - Date().timeIntervalSince(t0)))")
        }
        // A fresh start from there (the server starts the stream at that place).
        p.pause()
        let deep = p.currentPosition()
        _ = await p.reportNow()
        await p.stop(report: false)
        t0 = Date()
        if let why = await p.play(s.book, fallbackSec: deep) { log("deepstream replay failed: \(why)"); return }
        for _ in 0..<600 where !p.debugAudible { try? await Task.sleep(for: .milliseconds(100)) }
        log("deepstream fresh start wanted=\(String(format: "%.1f", deep)) audible=\(p.debugAudible) after=\(String(format: "%.1f", Date().timeIntervalSince(t0)))s at=\(String(format: "%.1f", p.currentPosition()))")
        try? await Task.sleep(for: .seconds(4))
        log("deepstream fresh +4s at=\(String(format: "%.1f", p.currentPosition()))")
        // Short skips around a fresh start (back past where the stream began).
        for d in [-30.0, -30, -30, 30, 30, 30, 30] {
            let from = p.currentPosition(); let t = Date()
            p.skip(d)
            try? await Task.sleep(for: .seconds(4))
            log("deepstream skip \(Int(d)) moved=\(String(format: "%.1f", p.currentPosition() - from - Date().timeIntervalSince(t))) audible=\(p.debugAudible)")
        }
        p.pause()
        p.seek(to: before?.0 ?? 0)
        _ = await p.reportNow()
        await p.stop(report: false)
        let restored = await serverPos(s.id)
        log("deepstream restored server=\(Int(restored?.0 ?? -1)) wanted=\(Int(before?.0 ?? -1))")
    }

    /// An old pending position must not overwrite a newer one on the server.
    private static func pending() async {
        guard let s = WatchModel.shared.shelf.first, let server = await serverPos(s.id) else { log("pending skipped"); return }
        Store.savePosition(s.id, LocalPosition(sec: server.0 + 999, savedAt: server.1 - 60_000, pending: true, finished: false))
        let clean = await WatchModel.shared.flushPending()
        let now = await serverPos(s.id)
        log("pending old clean=\(clean) serverKept=\(Int(now?.0 ?? -1) == Int(server.0)) stillPending=\(Store.position(s.id)?.pending ?? false)")
        // A newer one (the same position) is sent.
        Store.savePosition(s.id, LocalPosition(sec: server.0, savedAt: Format.nowMs + 1000, pending: true, finished: false))
        let clean2 = await WatchModel.shared.flushPending()
        let now2 = await serverPos(s.id)
        log("pending new clean=\(clean2) server=\(Int(now2?.0 ?? -1)) wanted=\(Int(server.0)) stillPending=\(Store.position(s.id)?.pending ?? false)")
    }

    /// Downloads the shortest book in the library, plays it from the watch, then
    /// removes it (and the progress the test made, if it had none before).
    private static func download() async {
        guard let lib = try? await API.shared.libraries().first(where: { $0.mediaType == "book" }),
              let item = try? await API.shared.libraryItems(library: lib.id, page: 1, limit: 1, sort: "media.duration", desc: false).items.first,
              let book = Book.from(item) else { log("download skipped: no library"); return }
        let had = await serverPos(book.id)
        let d = WatchDownloads.shared
        log("download start \(book.title) \(Int(book.durationSec ?? 0))s error=\(await d.start(book.id) ?? "-")")
        var last = ""
        for _ in 0..<600 {
            if d.isDownloaded(book.id) || d.state(book.id) == .failed { break }
            let s = "\(d.state(book.id))"
            if s != last { last = s }
            try? await Task.sleep(for: .seconds(0.5))
        }
        let m = d.downloaded(book.id)
        log("download state=\(d.state(book.id)) tracks=\(m?.tracks.count ?? 0) files=\(m?.tracks.allSatisfy { FileManager.default.fileExists(atPath: d.fileURL(for: $0).path) } ?? false) cover=\(d.coverFile(book.id) != nil)")
        let p = WatchPlayer.shared
        if let why = await p.play(book) { log("download play failed: \(why)") } else {
            try? await Task.sleep(for: .seconds(5))
            log("download local isLocal=\(p.nowPlaying?.isLocal ?? false) playing=\(p.isPlaying) pos=\(String(format: "%.1f", p.currentPosition()))")
            p.pause()
            try? await Task.sleep(for: .seconds(3))
            log("download report status=\(p.status ?? "-") server=\(Int(await serverPos(book.id)?.0 ?? -1))")
            await p.stop(report: false)
        }
        d.delete(book.id)
        try? await Task.sleep(for: .seconds(1))
        log("download removed state=\(d.state(book.id)) dirGone=\(!FileManager.default.fileExists(atPath: WatchDownloads.booksDir.appendingPathComponent(book.id).path))")
        if had == nil {
            let code = try? await API.shared.send("/api/me/progress/\(book.id)", method: "DELETE").0
            log("download progress cleaned code=\(code ?? -1)")
        }
        await WatchModel.shared.refreshShelf()
    }

    /// Starts a big download and kills the app part way through, as watchOS might.
    /// S3: the server doesn't answer in time, the watch has an old position, the
    /// shelf a newer one: playback must start at the shelf's.
    private static func staleResume() async {
        guard let s = WatchModel.shared.shelf.first, let server = await serverPos(s.id) else { log("staleresume skipped"); return }
        let old = max(server.0 - 600, 0)
        Store.savePosition(s.id, LocalPosition(sec: old, savedAt: server.1 - 86_400_000, pending: false, finished: false))
        serverSilent = true
        let p = WatchPlayer.shared
        if let why = await p.play(s.book, fallbackSec: s.currentTimeSec, fallbackAt: s.lastUpdate) { log("staleresume play failed: \(why)") }
        serverSilent = false
        let start = p.currentPosition()
        log("staleresume start=\(Int(start)) shelf=\(Int(s.currentTimeSec)) oldWatch=\(Int(old)) ok=\(abs(start - s.currentTimeSec) < 3)")
        p.pause()
        try? await Task.sleep(for: .seconds(1))
        await restore(s.id, server.0)
    }

    /// S4: a skip while paused (after a long pause) must survive Play.
    private static func pausedSeek() async {
        guard let s = WatchModel.shared.shelf.first, let server = await serverPos(s.id) else { log("pausedseek skipped"); return }
        let p = WatchPlayer.shared
        if let why = await p.play(s.book, fallbackSec: s.currentTimeSec, fallbackAt: s.lastUpdate) { log("pausedseek play failed: \(why)"); return }
        try? await Task.sleep(for: .seconds(4))
        p.pause()
        try? await Task.sleep(for: .seconds(3))
        let paused = p.currentPosition()
        p.skip(-60)
        let target = p.currentPosition()
        p.debugLongPause()
        _ = await p.resume()
        try? await Task.sleep(for: .seconds(2))
        let now = p.currentPosition()
        log("pausedseek paused=\(Int(paused)) target=\(Int(target)) afterPlay=\(Int(now)) ok=\(now >= target - 1 && now < target + 6)")
        p.pause()
        try? await Task.sleep(for: .seconds(1))
        await restore(s.id, server.0)
    }

    /// S1/S2/S5: a stream whose connection dies: no listening time while stuck,
    /// the position stays right, and the watchdog rebuilds it and plays on.
    private static func streamBreak() async {
        guard let s = WatchModel.shared.shelf.first, let server = await serverPos(s.id) else { log("streambreak skipped"); return }
        let p = WatchPlayer.shared
        if let why = await p.play(s.book, fallbackSec: s.currentTimeSec, fallbackAt: s.lastUpdate) { log("streambreak play failed: \(why)"); return }
        try? await Task.sleep(for: .seconds(5))
        let before = p.currentPosition()
        p.debugBreakStream()
        try? await Task.sleep(for: .seconds(2))
        let l1 = p.debugListened, pos1 = p.currentPosition()
        try? await Task.sleep(for: .seconds(10))
        let l2 = p.debugListened, pos2 = p.currentPosition()
        log("streambreak stuck before=\(Int(before)) pos=\(Int(pos1))/\(Int(pos2)) buffering=\(p.buffering) playing=\(p.isPlaying) listenedGrew=\(String(format: "%.1f", l2 - l1))")
        try? await Task.sleep(for: .seconds(15))
        let pos3 = p.currentPosition()
        try? await Task.sleep(for: .seconds(4))
        let pos4 = p.currentPosition()
        log("streambreak after recoveries=\(p.debugRecoveries) pos=\(Int(pos3))->\(Int(pos4)) advancing=\(pos4 > pos3 + 1) noJumpBack=\(pos3 >= before - 1) error=\(p.streamError ?? "-")")
        p.pause()
        try? await Task.sleep(for: .seconds(1))
        await restore(s.id, server.0)
    }

    /// R3: a failed download leaves no files and stays listed with its book.
    private static func downloadFail() async {
        guard let lib = try? await API.shared.libraries().first(where: { $0.mediaType == "book" }),
              let item = try? await API.shared.libraryItems(library: lib.id, page: 1, limit: 1, sort: "media.duration", desc: true).items.first,
              let book = Book.from(item) else { log("dlfail skipped"); return }
        let d = WatchDownloads.shared
        _ = await d.start(book.id)
        try? await Task.sleep(for: .seconds(8))
        d.debugFail(book.id)
        let dir = WatchDownloads.booksDir.appendingPathComponent(book.id)
        try? await Task.sleep(for: .seconds(3))
        log("dlfail state=\(d.state(book.id)) listed=\(d.activeIds.contains(book.id)) planned=\(d.planned(book.id) != nil) folderGone=\(!FileManager.default.fileExists(atPath: dir.path))")
        d.delete(book.id)
        log("dlfail removed state=\(d.state(book.id)) planned=\(d.planned(book.id) != nil)")
    }

    /// S2: a connection that stays dead: three rebuilds, then it pauses and says
    /// so, with the position kept; Play afterwards (connection back) plays on.
    private static func streamDead() async {
        guard let s = WatchModel.shared.shelf.first, let server = await serverPos(s.id) else { log("streamdead skipped"); return }
        let p = WatchPlayer.shared
        if let why = await p.play(s.book, fallbackSec: s.currentTimeSec, fallbackAt: s.lastUpdate) { log("streamdead play failed: \(why)"); return }
        try? await Task.sleep(for: .seconds(4))
        let before = p.currentPosition()
        deadNetwork = true
        p.debugBreakStream()
        for _ in 0..<200 where p.streamError == nil { try? await Task.sleep(for: .seconds(1)) }
        try? await Task.sleep(for: .seconds(3))
        log("streamdead gaveUp error=\(p.streamError ?? "-") playing=\(p.isPlaying) pos=\(Int(p.currentPosition())) before=\(Int(before)) saved=\(Int(Store.position(s.id)?.sec ?? -1))")
        deadNetwork = false
        _ = await p.resume()
        try? await Task.sleep(for: .seconds(6))
        log("streamdead replay error=\(p.streamError ?? "-") playing=\(p.isPlaying) buffering=\(p.buffering) pos=\(Int(p.currentPosition()))")
        p.pause()
        try? await Task.sleep(for: .seconds(1))
        await restore(s.id, server.0)
    }

    /// Item 15: the storage limit refuses a big book; streaming queues a download
    /// when "Download What I Play" is on.
    private static func autoDownload() async {
        guard let lib = try? await API.shared.libraries().first(where: { $0.mediaType == "book" }),
              let big = try? await API.shared.libraryItems(library: lib.id, page: 1, limit: 1, sort: "media.duration", desc: true).items.first,
              let bigBook = Book.from(big), let s = WatchModel.shared.shelf.first else { log("autodl skipped"); return }
        let d = WatchDownloads.shared
        Store.storageLimitGB = 1
        let refused = await d.start(bigBook.id)
        let silent = await d.start(bigBook.id, auto: true)
        log("autodl limit manual=\(refused ?? "-") auto=\(silent ?? "nil") state=\(d.state(bigBook.id))")
        Store.storageLimitGB = 0
        Store.autoDownload = true
        _ = await WatchPlayer.shared.play(s.book, fallbackSec: s.currentTimeSec, fallbackAt: s.lastUpdate)
        try? await Task.sleep(for: .seconds(6))
        // Not while streaming (the book was fetched twice at once): on the pause.
        log("autodl streamed isLocal=\(WatchPlayer.shared.nowPlaying?.isLocal ?? true) download=\(d.state(s.id)) ok=\(d.state(s.id) == .none)")
        WatchPlayer.shared.pause()
        try? await Task.sleep(for: .seconds(3))
        log("autodl paused download=\(d.state(s.id)) ok=\(d.state(s.id) != .none)")
        await WatchPlayer.shared.stop(report: false)
        d.delete(s.id)
        Store.autoDownload = false
        log("autodl cleaned state=\(d.state(s.id))")
    }

    /// Item 5 and 9: the iPhone's state arrives without asking; playing the same
    /// book here pauses it there.
    private static func phoneLink() async {
        let link = WatchLink.shared
        for _ in 0..<60 where link.pushedState == nil { try? await Task.sleep(for: .seconds(1)) }
        guard let s = link.pushedState else { log("phonelink no push reachable=\(link.reachable)"); return }
        log("phonelink pushed title=\(s.title) playing=\(s.isPlaying) sentAt=\(s.sentAt != nil)")
        guard s.isPlaying, let item = try? await API.shared.item(s.itemId), let book = Book.from(item),
              let before = await serverPos(book.id) else { log("phonelink phone not playing"); return }
        let p = WatchPlayer.shared
        _ = await p.play(book, fallbackSec: s.positionSec, fallbackAt: 0)
        for _ in 0..<15 where link.pushedState?.isPlaying != false { try? await Task.sleep(for: .seconds(1)) }
        log("phonelink watch playing=\(p.isPlaying) phonePaused=\(link.pushedState?.isPlaying == false)")
        p.pause()
        try? await Task.sleep(for: .seconds(1))
        await restore(book.id, before.0)
    }

    /// R1: with listening that can't be sent, sign-out stops and says so.
    private static func signOutPending() async {
        let id = "kitzi-test-missing-item"
        Store.savePosition(id, LocalPosition(sec: 10, savedAt: Format.nowMs, pending: true, finished: false))
        let out = await WatchModel.shared.signOut()
        log("signoutpending signedOut=\(out) stillSignedIn=\(WatchModel.shared.signedIn) keptPending=\(Store.position(id)?.pending ?? false)")
        Store.set(nil, "pos:\(id)")
    }

    /// Puts the server (and the watch) back at `sec` and closes the book.
    private static func restore(_ id: String, _ sec: Double) async {
        let p = WatchPlayer.shared
        p.seek(to: sec)
        _ = await p.reportNow()
        await p.stop(report: false)
        let now = await serverPos(id)
        log("restored server=\(Int(now?.0 ?? -1)) wanted=\(Int(sec))")
    }

    /// For the Downloads screen: the two shortest books downloaded and kept, and the
    /// longest one left downloading.
    private static func downloadsScreenData() async {
        guard let lib = try? await API.shared.libraries().first(where: { $0.mediaType == "book" }),
              let short = try? await API.shared.libraryItems(library: lib.id, page: 1, limit: 2, sort: "media.duration", desc: false).items,
              let long = try? await API.shared.libraryItems(library: lib.id, page: 1, limit: 1, sort: "media.duration", desc: true).items.first
        else { log("dlkeep skipped"); return }
        let d = WatchDownloads.shared
        for item in short { if let b = Book.from(item) { _ = await d.start(b.id) } }
        for _ in 0..<120 where !short.compactMap({ Book.from($0)?.id }).allSatisfy(d.isDownloaded) { try? await Task.sleep(for: .seconds(1)) }
        if let b = Book.from(long) { _ = await d.start(b.id) }
        try? await Task.sleep(for: .seconds(6))
        log("dlkeep on watch=\(d.downloadedIds.count) active=\(d.activeIds.count)")
    }

    private static func downloadThenDie() async {
        guard let lib = try? await API.shared.libraries().first(where: { $0.mediaType == "book" }),
              let item = try? await API.shared.libraryItems(library: lib.id, page: 1, limit: 1, sort: "media.duration", desc: true).items.first,
              let book = Book.from(item) else { log("dlkill skipped"); return }
        let d = WatchDownloads.shared
        log("dlkill free=\(Format.size(WatchDownloads.freeBytes ?? -1)) start \(book.title) size=\(Format.size(book.sizeBytes ?? 0)) error=\(await d.start(book.id) ?? "-")")
        for _ in 0..<240 {
            if case .running(let f) = d.state(book.id), f > 0.05 { break }
            try? await Task.sleep(for: .seconds(0.5))
        }
        log("dlkill killing at \(d.state(book.id))")
        Store.set(book.id, "debug_dl_book")
        Store.d.synchronize()
        exit(0)
    }

    /// After the kill: the download must carry on and finish (then it's removed).
    private static func downloadResumed() async {
        guard let id = Store.string("debug_dl_book") else { log("dlresume nothing"); return }
        let d = WatchDownloads.shared
        try? await Task.sleep(for: .seconds(2))
        log("dlresume relaunched state=\(d.state(id))")
        var last = -1
        for _ in 0..<1200 {
            if d.isDownloaded(id) || d.state(id) == .failed { break }
            if case .running(let f) = d.state(id), Int(f * 10) != last { last = Int(f * 10); log("dlresume \(last * 10)%") }
            try? await Task.sleep(for: .seconds(0.5))
        }
        let m = d.downloaded(id)
        log("dlresume final state=\(d.state(id)) tracks=\(m?.tracks.count ?? 0) files=\(m?.tracks.allSatisfy { FileManager.default.fileExists(atPath: d.fileURL(for: $0).path) } ?? false)")
        d.delete(id)
        Store.set(nil, "debug_dl_book")
        try? await Task.sleep(for: .seconds(1))
        log("dlresume removed state=\(d.state(id))")
    }

    /// Waits for a book the iPhone sends (its test hook seeds and sends one).
    private static func receive() async {
        let d = WatchDownloads.shared
        for _ in 0..<240 {
            if let id = d.downloadedIds.first, let m = d.downloaded(id) {
                let ok = m.tracks.allSatisfy { FileManager.default.fileExists(atPath: d.fileURL(for: $0).path) }
                log("receive got \(m.book.title) tracks=\(m.tracks.count) files=\(ok) chapters=\(m.chapters.count) cover=\(d.coverFile(id) != nil)")
                d.delete(id)
                try? await Task.sleep(for: .seconds(1))
                log("receive removed state=\(d.state(id))")
                return
            }
            try? await Task.sleep(for: .seconds(0.5))
        }
        log("receive timed out states=\(d.states)")
    }

    /// The watch's side of a book sent from the iPhone, with files made here (the
    /// simulator doesn't carry WatchConnectivity files between devices).
    private static func receiveFake() async {
        guard let s = WatchModel.shared.shelf.first else { log("receivefake skipped"); return }
        let id = s.id
        let tracks = (0..<2).map { Track(index: $0, url: "\(id)/track\($0).mp3", mimeType: "audio/mpeg", durationSec: 60, isLocal: true) }
        let m = WatchBookManifest(book: s.book, tracks: tracks, chapters: [Chapter(title: "One", startSec: 0), Chapter(title: "Two", startSec: 60)])
        func temp(_ n: Int) -> URL {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? Data(repeating: UInt8(n), count: 1000).write(to: u)
            return u
        }
        let d = WatchDownloads.shared
        d.received(id, index: 1, manifest: m, file: temp(1))   // out of order, as transfers can arrive
        log("receivefake after 1 of 2 state=\(d.state(id)) downloaded=\(d.isDownloaded(id))")
        d.received(id, index: nil, manifest: nil, file: temp(9))  // the cover
        d.received(id, index: 0, manifest: m, file: temp(0))
        let back = d.downloaded(id)
        try? await Task.sleep(for: .seconds(3))
        log("receivefake after 2 of 2 state=\(d.state(id)) tracks=\(back?.tracks.count ?? 0) chapters=\(back?.chapters.count ?? 0) cover=\(d.coverFile(id).flatMap { UIImage(contentsOfFile: $0.path) } != nil)")
        d.received(id, index: 0, manifest: m, file: temp(0))      // a duplicate after it's done
        log("receivefake duplicate state=\(d.state(id))")
        d.delete(id)
        try? await Task.sleep(for: .seconds(1))
        log("receivefake removed state=\(d.state(id)) dirGone=\(!FileManager.default.fileExists(atPath: WatchDownloads.booksDir.appendingPathComponent(id).path))")
    }

    private static func remote() async {
        let link = WatchLink.shared
        for _ in 0..<20 where !link.reachable { try? await Task.sleep(for: .seconds(0.5)) }
        guard let s = await link.phoneState() else { log("remote no state reachable=\(link.reachable)"); return }
        log("remote state title=\(s.title) playing=\(s.isPlaying) speed=\(s.speed) pos=\(Int(s.positionSec)) chapter=\(s.chapter ?? "-")")
        let faster = await link.phoneState(command: .speed, value: 1.75)
        log("remote speed now=\(faster?.speed ?? -1)")
        _ = await link.phoneState(command: .speed, value: s.speed)
        let sleep = await link.phoneState(command: .sleep, value: 15)
        log("remote sleep remaining=\(Int(sleep?.sleepRemainingSec ?? -1))")
        let off = await link.phoneState(command: .sleepOff)
        log("remote sleepOff remaining=\(off?.sleepRemainingSec.map { String(Int($0)) } ?? "nil") speedRestored=\(off?.speed ?? -1)")
    }
}
#endif
