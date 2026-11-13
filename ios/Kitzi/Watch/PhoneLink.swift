import Foundation
import Observation
import WatchConnectivity

/// The iPhone's side of the Kitzi watch app: signs the watch in, sends it
/// downloaded books, and takes its remote control commands.
@Observable
final class PhoneLink: NSObject {
    static let shared = PhoneLink()

    /// A paired Apple Watch has the Kitzi app.
    private(set) var watchReady = false
    /// Files still on their way to the watch, per book.
    private(set) var sending: [String: Int] = [:]

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func updateReady() {
        let s = WCSession.default
        watchReady = s.activationState == .activated && s.isPaired && s.isWatchAppInstalled
        // Transfers carry on while Kitzi is closed: pick up the ones still going.
        guard s.activationState == .activated else { return }
        var left: [String: Int] = [:]
        for t in s.outstandingFileTransfers {
            if let id = t.file.metadata?["itemId"] as? String { left[id, default: 0] += 1 }
        }
        sending = left
    }

    /// How far the book's files have got to the watch (0…1), while it's sending.
    func sendProgress(_ id: String) -> Double? {
        guard sending[id] != nil else { return nil }
        var done: Int64 = 0, total: Int64 = 0
        for t in WCSession.default.outstandingFileTransfers where t.file.metadata?["itemId"] as? String == id {
            done += t.progress.completedUnitCount
            total += t.progress.totalUnitCount
        }
        return total > 0 ? Double(done) / Double(total) : 0
    }

    // MARK: send a downloaded book

    /// Queues the book's files for the watch. They go in the background (over
    /// Bluetooth, or Wi-Fi when both are on it) and continue while Kitzi is closed.
    func send(_ id: String) -> Bool {
        guard watchReady, sending[id] == nil, let saved = Downloads.shared.downloaded(id),
              let manifest = try? JSONEncoder().encode(WatchBookManifest(book: saved.book, tracks: saved.tracks, chapters: saved.chapters))
        else { return false }
        var count = 0
        for (i, t) in saved.tracks.enumerated() {
            let file = Downloads.shared.fileURL(for: t)
            guard FileManager.default.fileExists(atPath: file.path) else { return false }
            WCSession.default.transferFile(file, metadata: [WatchMsg.kind: WatchMsg.track, "itemId": id, "index": i, "manifest": manifest])
            count += 1
        }
        if let cover = Downloads.shared.localCover(id) {
            WCSession.default.transferFile(cover, metadata: [WatchMsg.kind: WatchMsg.cover, "itemId": id])
            count += 1
        }
        sending[id] = count
        return true
    }

    private func transferEnded(_ id: String, error: Error?) {
        guard let left = sending[id] else { return }
        if let error {
            // The other files of the book are no use without this one.
            for t in WCSession.default.outstandingFileTransfers where t.file.metadata?["itemId"] as? String == id { t.cancel() }
            sending[id] = nil
            Toast.show("Couldn't send the book to your watch: \(error.localizedDescription)")
        } else {
            sending[id] = left > 1 ? left - 1 : nil
            if left == 1 { Toast.show("The book is on your watch") }
        }
    }

    // MARK: requests from the watch

    private func reply(to message: [String: Any]) async -> [String: Any] {
        switch message[WatchMsg.kind] as? String {
        case WatchMsg.login:
            return await loginReply()
        case WatchMsg.command:
            if let raw = message["cmd"] as? String, let cmd = RemoteCommand(rawValue: raw) {
                await perform(cmd, value: message["value"] as? Double)
            }
            return stateReply()
        default:
            return stateReply()
        }
    }

    private func loginReply() async -> [String: Any] {
        guard Session.shared.signedIn, let base = Session.shared.baseURL else { return ["error": "signed_out"] }
        guard let me = try? await API.shared.me(), let token = me.str("token") else { return ["error": "unsupported"] }
        let login = WatchLogin(baseURL: base, token: token, username: me.str("username"), headers: Session.shared.customHeaders)
        guard let data = try? JSONEncoder().encode(login) else { return ["error": "unsupported"] }
        return ["login": data]
    }

    private func stateReply() -> [String: Any] {
        let p = Player.shared
        guard let np = p.nowPlaying else { return [:] }
        p.refreshPosition()
        let chapter = p.currentChapter()
        let sleep = SleepTimer.shared
        let state = PhoneState(
            itemId: np.book.id, title: np.book.title, author: np.book.author,
            chapter: np.chapters.count > 1 ? chapter?.title : nil,
            chapterStartSec: chapter?.startSec, chapterEndSec: chapter?.endSec,
            positionSec: p.position, durationSec: np.totalSec, isPlaying: p.isPlaying, speed: p.speed,
            sleepRemainingSec: sleepRemaining(sleep),
            sleepEndOfChapter: sleep.mode == .endOfChapter,
            skipBackSec: AppSettings.shared.seekBackSec, skipForwardSec: AppSettings.shared.seekForwardSec)
        guard let data = try? JSONEncoder().encode(state) else { return [:] }
        return ["state": data]
    }

    /// Worked out from the end time: the timer's own count only moves on its next tick.
    private func sleepRemaining(_ sleep: SleepTimer) -> Double? {
        switch sleep.mode {
        case .off: nil
        case .duration(let ends): max(ends.timeIntervalSinceNow, 0)
        case .endOfChapter: sleep.remainingSec
        }
    }

    private func perform(_ cmd: RemoteCommand, value: Double?) async {
        let p = Player.shared
        guard p.nowPlaying != nil else { return }
        switch cmd {
        case .toggle: p.togglePlay()
        case .back: p.skip(-Double(AppSettings.shared.seekBackSec))
        case .forward: p.skip(Double(AppSettings.shared.seekForwardSec))
        case .previousChapter: p.previousChapter()
        case .nextChapter: p.nextChapter()
        case .speed: if let value { p.setSpeed(value) }
        case .sleep: if let value { SleepTimer.shared.start(minutes: Int(value)) }
        case .sleepEndOfChapter: SleepTimer.shared.startEndOfChapter()
        case .sleepOff: SleepTimer.shared.cancel()
        case .bookmark:
            guard let np = p.nowPlaying else { return }
            p.refreshPosition()
            let pos = p.position
            _ = await LibraryStore.shared.bookmarkOp(.init(kind: "add", itemId: np.book.id, timeSec: (pos * 1000).rounded() / 1000,
                                                           title: p.currentChapter()?.title ?? "Bookmark"))
        }
    }
}

/// WatchConnectivity calls back on its own queue: everything hops to the main actor.
extension PhoneLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in updateReady() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in updateReady() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Switched to another watch: start over with it.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        // Only plain values cross the actor hop.
        let kind = message[WatchMsg.kind] as? String
        let cmd = message["cmd"] as? String
        let value = message["value"] as? Double
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in
            var m: [String: Any] = [:]
            m[WatchMsg.kind] = kind
            m["cmd"] = cmd
            m["value"] = value
            nonisolated(unsafe) let answer = await self.reply(to: m)
            reply(answer)
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let id = fileTransfer.file.metadata?["itemId"] as? String else { return }
        Task { @MainActor in transferEnded(id, error: error) }
    }
}

#if DEBUG
/// Simulator test hooks (never in release builds).
extension PhoneLink {
    func runDebugHooks() async {
        let env = ProcessInfo.processInfo.environment
        guard env["KITZI_TEST_SENDWATCH"] != nil || env["KITZI_TEST_LOADBOOK"] != nil else { return }
        for _ in 0..<90 where LibraryStore.shared.books.isEmpty || !watchReady { try? await Task.sleep(for: .seconds(1)) }
        print("KITZITEST phone watchReady=\(watchReady) books=\(LibraryStore.shared.books.count)")
        if env["KITZI_TEST_LOADBOOK"] != nil {
            let inProgress = LibraryStore.shared.books.first { (LibraryStore.shared.progress[$0.id]?.progress ?? 0) > 0 && LibraryStore.shared.progress[$0.id]?.isFinished != true }
            if let b = inProgress ?? LibraryStore.shared.books.first {
                let err = await Player.shared.play(b, startPlaying: false)
                print("KITZITEST phone loaded \(b.title) err=\(err ?? "-")")
            }
        }
        // A fake downloaded book (two small "tracks" and a cover), sent to the watch.
        guard env["KITZI_TEST_SENDWATCH"] != nil, let book = LibraryStore.shared.books.first else { return }
        let id = book.id
        let dir = Downloads.booksDir.appendingPathComponent(id)
        let had = FileManager.default.fileExists(atPath: dir.path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var tracks: [Track] = []
        for i in 0..<2 {
            let t = Track(index: i, url: "\(id)/track\(i).mp3", mimeType: "audio/mpeg", durationSec: 60, isLocal: true)
            if !had { try? Data(repeating: UInt8(i), count: 300_000).write(to: Downloads.shared.fileURL(for: t)) }
            tracks.append(t)
        }
        let manifest = DownloadedBook(book: book, tracks: tracks, chapters: [Chapter(title: "One", startSec: 0), Chapter(title: "Two", startSec: 60)])
        if !had {
            try? JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("book.json"))
            try? Data(repeating: 1, count: 2000).write(to: dir.appendingPathComponent("cover.jpg"))
        }
        print("KITZITEST phone send \(book.title) queued=\(send(id))")
        for _ in 0..<240 where sending[id] != nil { try? await Task.sleep(for: .seconds(0.5)) }
        print("KITZITEST phone send finished outstanding=\(sending[id] ?? 0)")
        if !had { try? FileManager.default.removeItem(at: dir) }
    }
}
#endif
