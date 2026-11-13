#if DEBUG
import Foundation
import UIKit

/// Simulator test runs, driven by the environment (never in release builds).
/// KITZI_W_TEST lists the steps; each prints "KITZITEST …" lines.
/// KITZI_W_SCREEN opens a screen for screenshots.
enum DebugHooks {
    private static var ran = false

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
            case "pending": await pending()
            case "download": await download()
            case "receive": await receive()
            case "receivefake": await receiveFake()
            case "remote": await remote()
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
                    _ = await WatchPlayer.shared.play(first.book, fallbackSec: first.currentTimeSec)
                    WatchPlayer.shared.pause()
                    WatchNav.shared.path = [.player]
                }
            case "remote": WatchNav.shared.path = [.remote]
            case "settings": WatchNav.shared.path = [.settings]
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
        log("download start \(book.title) \(Int(book.durationSec ?? 0))s ok=\(await d.start(book.id))")
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
