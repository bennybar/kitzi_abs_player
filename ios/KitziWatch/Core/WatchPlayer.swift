import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// The book that's loaded, in book coordinates.
struct WatchNowPlaying {
    var book: Book
    var tracks: [Track]
    var chapters: [Chapter]
    /// Playing from files on the watch (else streaming through `sessionId`).
    var isLocal: Bool
    var sessionId: String?
    var totalSec: Double {
        let sum = tracks.reduce(0) { $0 + $1.durationSec }
        return sum > 0 ? sum : (book.durationSec ?? 0)
    }
}

/// Plays one book and keeps the server in step, as the Wear OS app does: every
/// 30 s while playing, on every pause, at the end, and on demand. A report that
/// can't reach the server is kept on the watch ("pending") and sent later.
@Observable
final class WatchPlayer {
    static let shared = WatchPlayer()
    private let api = API.shared

    private(set) var nowPlaying: WatchNowPlaying?
    private(set) var isPlaying = false
    private(set) var loading = false
    /// Book position, refreshed while the app is in front.
    private(set) var position: Double = 0
    private(set) var speed = Store.speed
    /// The last sync, for the player ("Synced 14:02", "Saved on watch").
    private(set) var status: String?
    /// When the sleep timer pauses; nil when it's off.
    private(set) var sleepAt: Date?
    private(set) var sleepEndOfChapter = false

    private let av = AVPlayer()
    private var trackIndex = 0
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?
    private var ticker: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var reportTask: Task<Bool?, Never>?
    /// Listening time not yet recorded by the server.
    private var listenedSec = 0.0
    private var playingSince: Date?
    // A downloaded book's listening goes to the server as a "local" session.
    private var localSessionId: String?
    private var localStartedAt: Int64 = 0
    private var localStartSec = 0.0
    private var localListenedTotal = 0.0

    private static let syncEvery = 30.0

    private init() {
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            let item = n.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.av.currentItem else { return }
                self.trackEnded()
            }
        }
        rateObserver = Self.observePlaying(av)
        setUpRemoteCommands()
    }

    // MARK: loading

    /// Plays `book` from the newer of the watch's and the server's positions. Nil, or why it can't.
    func play(_ book: Book, fallbackSec: Double = 0) async -> String? {
        if nowPlaying?.book.id == book.id, av.currentItem != nil {
            return await resume()
        }
        guard !loading else { return nil }
        if nowPlaying != nil { await stop() }
        loading = true
        defer { loading = false }
        if let why = await startAudioSession() { return why }

        let np: WatchNowPlaying
        if let saved = WatchDownloads.shared.downloaded(book.id) {
            np = WatchNowPlaying(book: saved.book, tracks: saved.tracks, chapters: saved.chapters, isLocal: true)
        } else {
            await api.ensureFreshToken()
            guard let s = await api.openSession(book.id) else {
                return "Can't reach the server. Download the book to listen offline."
            }
            guard !s.tracks.isEmpty else { return "This book has no playable audio." }
            var b = book
            if b.durationSec == nil { b.durationSec = s.durationSec }
            np = WatchNowPlaying(book: b, tracks: s.tracks, chapters: s.chapters, isLocal: false, sessionId: s.id)
        }
        var start = await startPosition(book.id, fallback: fallbackSec)
        if start >= np.totalSec - 5 { start = 0 } // finished: from the top

        nowPlaying = np
        Store.lastBookId = book.id
        listenedSec = 0
        if np.isLocal {
            localSessionId = UUID().uuidString
            localStartedAt = Format.nowMs
            localStartSec = start
            localListenedTotal = 0
        } else {
            localSessionId = nil
        }
        let (i, off) = Self.locate(start, np.tracks)
        setTrack(i, offset: off)
        position = start
        av.playImmediately(atRate: Float(speed))
        startTicker()
        updateNowPlayingInfo()
        WatchModel.shared.updateWidget()
        return nil
    }

    /// Long-form audio on the watch plays through Bluetooth headphones: activating
    /// the session shows the system's headphone picker when none is connected.
    private func startAudioSession() async -> String? {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
            guard try await s.activate(options: []) else { return "Connect Bluetooth headphones to listen." }
            return nil
        } catch {
            return "Connect Bluetooth headphones to listen."
        }
    }

    /// The newer of the watch's saved position and the server's (if it answers within a few seconds).
    private func startPosition(_ id: String, fallback: Double) async -> Double {
        let local = Store.position(id)
        let fetch = Task { try? await api.mediaProgress(id).flatMap(Progress.from) }
        let timer = Task { try? await Task.sleep(for: .seconds(5)); fetch.cancel() }
        let server = await fetch.value
        timer.cancel()
        switch (local, server) {
        case (let l?, let s?): return l.savedAt > s.lastUpdate ? l.sec : s.currentTimeSec
        case (nil, let s?): return s.currentTimeSec
        case (let l?, nil): return l.sec
        default: return fallback
        }
    }

    private func setTrack(_ i: Int, offset: Double) {
        guard let np = nowPlaying, np.tracks.indices.contains(i) else { return }
        trackIndex = i
        let t = np.tracks[i]
        let url = t.isLocal ? WatchDownloads.shared.fileURL(for: t) : URL(string: t.url)!
        let asset = AVURLAsset(url: url, options: t.isLocal ? nil : ["AVURLAssetHTTPHeaderFieldsKey": api.mediaHeaders])
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        av.replaceCurrentItem(with: item)
        if offset > 0 { av.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    }

    private func trackEnded() {
        guard let np = nowPlaying else { return }
        if trackIndex + 1 < np.tracks.count {
            setTrack(trackIndex + 1, offset: 0)
            av.playImmediately(atRate: Float(speed))
        } else {
            Task { await bookEnded(np) }
        }
    }

    private func bookEnded(_ np: WatchNowPlaying) async {
        position = np.totalSec
        _ = await reportNow(finished: true)
        WatchModel.shared.removeFromShelf(np.book.id)
        if np.isLocal {
            // Done with it: free the space the book takes on the watch.
            await stop(report: false)
            WatchDownloads.shared.delete(np.book.id)
        }
    }

    // MARK: controls

    func togglePlay() {
        if isPlaying { pause() } else { Task { _ = await resume() } }
    }

    func pause() {
        av.pause()
    }

    /// Resumes the loaded book — from the server's position if that's newer
    /// (listened on the phone during the pause), like a fresh start does.
    func resume() async -> String? {
        guard let np = nowPlaying, !loading else { return nil }
        loading = true
        defer { loading = false }
        if let why = await startAudioSession() { return why }
        let target = await startPosition(np.book.id, fallback: currentPosition())
        let here = currentPosition()
        if nowPlaying?.book.id == np.book.id, abs(target - here) > 3, target < np.totalSec - 5 { seek(to: target) }
        av.playImmediately(atRate: Float(speed))
        return nil
    }

    func skip(_ delta: Double) {
        seek(to: currentPosition() + delta)
    }

    func seek(to sec: Double) {
        guard let np = nowPlaying else { return }
        let target = min(max(sec, 0), np.totalSec)
        let (i, off) = Self.locate(target, np.tracks)
        if i != trackIndex {
            let wasPlaying = isPlaying
            setTrack(i, offset: off)
            if wasPlaying { av.playImmediately(atRate: Float(speed)) }
        } else {
            av.seek(to: CMTime(seconds: off, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        position = target
        updateNowPlayingInfo()
    }

    func previousChapter() {
        guard let np = nowPlaying, let c = chapterIndex() else { return }
        let pos = currentPosition()
        // Within the first few seconds of a chapter, go to the previous one.
        if pos - np.chapters[c].startSec < 3, c > 0 { seek(to: np.chapters[c - 1].startSec) } else { seek(to: np.chapters[c].startSec) }
    }

    func nextChapter() {
        guard let np = nowPlaying, let c = chapterIndex(), c + 1 < np.chapters.count else { return }
        seek(to: np.chapters[c + 1].startSec)
    }

    func setSpeed(_ s: Double) {
        speed = s
        Store.speed = s
        if isPlaying { av.rate = Float(s) }
        updateNowPlayingInfo()
    }

    func chapterIndex(at pos: Double? = nil) -> Int? {
        guard let np = nowPlaying, !np.chapters.isEmpty else { return nil }
        let p = pos ?? position
        return np.chapters.lastIndex { $0.startSec <= p + 0.5 } ?? 0
    }

    var chapterTitle: String? {
        guard let np = nowPlaying, np.chapters.count > 1, let i = chapterIndex() else { return nil }
        return np.chapters[i].title
    }

    /// Where we are in the BOOK (all tracks), in seconds.
    func currentPosition() -> Double {
        guard let np = nowPlaying else { return 0 }
        let before = np.tracks.prefix(trackIndex).reduce(0) { $0 + $1.durationSec }
        let t = av.currentTime().seconds
        return before + (t.isFinite ? t : 0)
    }

    // MARK: sleep timer

    func sleep(minutes: Int) {
        sleepTask?.cancel()
        sleepEndOfChapter = false
        let at = Date().addingTimeInterval(Double(minutes) * 60)
        sleepAt = at
        sleepTask = Task {
            try? await Task.sleep(for: .seconds(at.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            pause()
            sleepAt = nil
        }
    }

    /// False when the book has no chapters.
    @discardableResult
    func sleepAtChapterEnd() -> Bool {
        guard let np = nowPlaying, let i = chapterIndex(), np.chapters.count > 1 else { return false }
        let end = i + 1 < np.chapters.count ? np.chapters[i + 1].startSec : np.totalSec
        sleepTask?.cancel()
        sleepEndOfChapter = true
        sleepAt = nil
        sleepTask = Task {
            while !Task.isCancelled {
                if currentPosition() >= end - 0.3 { pause(); sleepEndOfChapter = false; return }
                try? await Task.sleep(for: .seconds(0.5))
            }
        }
        return true
    }

    func cancelSleep() {
        sleepTask?.cancel()
        sleepAt = nil
        sleepEndOfChapter = false
    }

    // MARK: bookmarks

    /// True when the server took it.
    func addBookmark() async -> Bool {
        guard let np = nowPlaying else { return false }
        let pos = currentPosition()
        let title = chapterTitle ?? "Bookmark"
        return await api.addBookmark(np.book.id, time: (pos * 1000).rounded() / 1000, title: title)
    }

    // MARK: syncing

    private func playingChanged(_ playing: Bool) {
        guard playing != isPlaying else { return }
        accrue()
        isPlaying = playing
        playingSince = playing ? Date() : nil
        updateNowPlayingInfo()
        WatchModel.shared.updateWidget()
        if !playing, nowPlaying != nil { Task { _ = await reportNow() } }
    }

    private func accrue() {
        guard let since = playingSince else { return }
        listenedSec += Date().timeIntervalSince(since)
        playingSince = isPlaying ? Date() : nil
    }

    /// The position twice a second (for the screen) and a report every 30 s while playing.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task {
            var sinceReport = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.5))
                guard nowPlaying != nil else { continue }
                position = currentPosition()
                if isPlaying {
                    sinceReport += 0.5
                    if sinceReport >= Self.syncEvery { sinceReport = 0; _ = await reportNow() }
                }
            }
        }
    }

    /// Reports the position (and listening time) now. True when the server took it;
    /// false when it was only saved on the watch; nil when nothing is loaded.
    /// Reports run one at a time, so listening time is never sent twice.
    func reportNow(finished: Bool = false) async -> Bool? {
        let previous = reportTask
        let t = Task { () -> Bool? in
            _ = await previous?.value
            return await sendReport(finished: finished)
        }
        reportTask = t
        return await t.value
    }

    private func sendReport(finished: Bool) async -> Bool? {
        guard let np = nowPlaying else { return nil }
        let pos = finished ? np.totalSec : currentPosition()
        accrue()
        let now = Format.nowMs
        Store.savePosition(np.book.id, LocalPosition(sec: pos, savedAt: now, pending: true, finished: finished))
        WatchModel.shared.updateShelfPosition(np.book, sec: pos)

        let listened = listenedSec
        let report = API.Report(itemId: np.book.id, currentSec: pos, durationSec: np.totalSec, finished: finished,
                                paused: !isPlaying, listenedSec: listened > 0 ? listened : nil)
        var saved = false, recorded = false
        if let sid = np.sessionId {
            switch await api.syncSession(sid, report) {
            case .ok: saved = true; recorded = true
            // The session is gone (closed by the server after a long pause): the
            // position still goes through without it.
            case .gone, .refused: saved = await api.saveProgress(report)
            case .unreachable: break
            }
        } else {
            saved = await api.saveProgress(report)
            if saved, listened > 0, let lid = localSessionId {
                recorded = await api.syncLocalSession(id: lid, book: np.book, startedAt: localStartedAt, startSec: localStartSec,
                                                      report: report, totalListened: localListenedTotal + listened)
            }
        }
        if recorded {
            listenedSec -= listened
            if np.sessionId == nil { localListenedTotal += listened }
        }
        if saved {
            if let p = Store.position(np.book.id), p.savedAt == now {
                Store.savePosition(np.book.id, LocalPosition(sec: p.sec, savedAt: p.savedAt, pending: false, finished: p.finished))
            }
            status = "Synced " + Date().formatted(date: .omitted, time: .shortened)
        } else {
            status = "Saved on watch"
            WatchModel.shared.scheduleRetry()
        }
        return saved
    }

    /// Stops the book: a final report (unless it was just sent), then the session closes.
    func stop(report: Bool = true) async {
        guard let np = nowPlaying else { return }
        av.pause()
        if report { _ = await reportNow() }
        if let sid = np.sessionId { await api.closeSession(sid) }
        av.replaceCurrentItem(with: nil)
        ticker?.cancel()
        cancelSleep()
        nowPlaying = nil
        status = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        WatchModel.shared.updateWidget()
    }

    // MARK: system controls

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { _ = await self?.resume() } }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlay() }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(-30) }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(30) }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            let t = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            MainActor.assumeIsolated { self?.seek(to: t) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let np = nowPlaying else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: np.book.title,
            MPMediaItemPropertyPlaybackDuration: np.totalSec,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentPosition(),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
        ]
        if let a = np.book.author { info[MPMediaItemPropertyArtist] = a }
        if let c = chapterTitle { info[MPMediaItemPropertyAlbumTitle] = c }
        if let file = WatchDownloads.shared.coverFile(np.book.id), let img = UIImage(contentsOfFile: file.path) {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(img)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Built outside the main actor: the system calls these closures on its own queues.
    nonisolated private static func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    nonisolated private static func observePlaying(_ av: AVPlayer) -> NSKeyValueObservation {
        av.observe(\.timeControlStatus) { p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in WatchPlayer.shared.playingChanged(playing) }
        }
    }

    /// A book position as (track index, seconds into that track).
    static func locate(_ sec: Double, _ tracks: [Track]) -> (Int, Double) {
        var remaining = sec
        for (i, t) in tracks.enumerated() {
            if remaining < t.durationSec || i == tracks.count - 1 { return (i, max(remaining, 0)) }
            remaining -= t.durationSec
        }
        return (0, 0)
    }
}
