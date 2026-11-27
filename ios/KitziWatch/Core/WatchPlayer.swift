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
    /// Playing or waiting for data (the button shows Pause either way).
    private(set) var isPlaying = false
    /// Waiting for data from the server (a stream on a slow link).
    private(set) var buffering = false
    private(set) var loading = false
    /// Why a stream stopped after it couldn't be recovered ("Lost the connection").
    private(set) var streamError: String?
    /// Book position, refreshed while the app is in front.
    private(set) var position: Double = 0 {
        // The chapter, kept apart: what shows only the chapter redraws when it
        // changes, not with every position tick.
        didSet { let i = chapterIndex(at: position); if i != currentChapter { currentChapter = i } }
    }
    /// The chapter the position is in (nil: no chapters).
    private(set) var currentChapter: Int?
    private(set) var speed = Store.speed
    /// The last sync, for the player ("Synced 14:02", "Saved on watch").
    private(set) var status: String?
    /// When the sleep timer pauses; nil when it's off.
    private(set) var sleepAt: Date?
    private(set) var sleepEndOfChapter = false

    private let av = AVPlayer()
    private var trackIndex = 0
    /// Where a seek is taking the current track, until it gets there: a new
    /// track's time reads 0 while it loads, which would report the track's start.
    private var seekTarget: Double?
    /// What the current stream item had fetched at the watchdog's last look.
    private var loadedBytes: Int64 = 0
    /// Where the server had the book at the last start-position check (nil: no answer).
    private var serverStart: Double?
    /// A long jump is opening its new stream (see jumpStream).
    private(set) var jumping = false
    /// Counts the books started and stopped, so a jump still in flight knows
    /// the playback it began in has gone.
    private var runs = 0
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    private var ticker: Task<Void, Never>?
    /// Seconds of playing since the last periodic report.
    @ObservationIgnored private var sinceReport = 0.0
    private var sleepTask: Task<Void, Never>?
    private var reportTask: Task<Bool?, Never>?
    /// Listening time not yet recorded by the server.
    private var listenedSec = 0.0
    /// When sound started coming out (nil while paused or buffering): only
    /// that counts as listening time.
    private var playingSince: Date?
    private var audible = false
    /// When the book was last paused (a short pause skips the server check on resume).
    private var pausedAt: Date?
    /// Set while `stop()` runs: its pause mustn't send another report.
    private var stopping = false
    /// Played again once an interruption (a call, Siri) ends, if it was playing.
    private var resumeAfterInterruption = false
    // The stream watchdog (see `watchStream`).
    /// The token the current streamed item was made with: a newer one means the
    /// item's requests would be refused, so it's rebuilt.
    private var itemToken: String?
    private var stalledSince: Date?
    private var recoveries = 0
    private var recovering = false
    /// The app is on screen (not wrist-down or in the background): the position
    /// on screen is only worth refreshing then.
    @ObservationIgnored var screenActive = true {
        // Wrist raised: the time on screen is current at once (the ticker was
        // sleeping its wrist-down step), and it counts at the screen's pace again.
        didSet {
            guard screenActive, !oldValue, nowPlaying != nil else { return }
            position = currentPosition()
            if isPlaying { startTicker() }
        }
    }
    /// A streamed book to download once listening stops ("Download What I Play"):
    /// downloading it while streaming it fetched the book twice at once.
    @ObservationIgnored private var downloadWhenPaused: String?
    /// The lock screen's cover, read from disk once per book.
    @ObservationIgnored private var artwork: (id: String, art: MPMediaItemArtwork)?
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
        Self.setUpRemoteCommands()
        interruptionObserver = Self.observeInterruptions()
    }

    // MARK: loading

    /// Plays `book` from the newer of the watch's and the server's positions. Nil, or why it can't.
    /// `fallbackSec`/`fallbackAt`: where the shelf says the book is, and when that
    /// was saved (server clock): used when the server can't be asked in time.
    func play(_ book: Book, fallbackSec: Double = 0, fallbackAt: Int64 = 0) async -> String? {
        if nowPlaying?.book.id == book.id, av.currentItem != nil {
            return await resume()
        }
        // Busy before the old book stops: a second tap meanwhile mustn't start
        // another load (and open a second server session).
        guard !loading else { return nil }
        loading = true
        defer { loading = false }
        runs += 1
        if nowPlaying != nil { await stop() }
        if let why = await startAudioSession() { return why }

        let np: WatchNowPlaying
        var start: Double
        if let saved = WatchDownloads.shared.downloaded(book.id) {
            np = WatchNowPlaying(book: saved.book, tracks: saved.tracks, chapters: saved.chapters, isLocal: true)
            start = await startPosition(book.id, fallback: fallbackSec, fallbackAt: fallbackAt, wait: 5)
        } else {
            await api.ensureFreshToken()
            // A stream needs the network anyway, so it can wait longer for the
            // position than a downloaded book (maybe offline) should.
            start = await startPosition(book.id, fallback: fallbackSec, fallbackAt: fallbackAt, wait: 15)
            if let d = book.durationSec { start = PositionRules.startOrTop(start, total: d) }
            // The server prepares the stream where IT has the book. Starting
            // elsewhere (a newer place saved on the watch), it gets that first.
            if serverStart.map({ abs($0 - start) > 5 }) ?? true {
                _ = await api.saveProgress(API.Report(itemId: book.id, currentSec: start, durationSec: book.durationSec,
                                                      finished: false, paused: true, listenedSec: nil))
            }
            if let left = Store.openStream { Task { await api.closeSession(left) } }
            guard let s = await api.openSession(book.id, hls: true) else {
                endAudioSession()
                return "Can't reach the server. Download the book to listen offline."
            }
            guard !s.tracks.isEmpty else { endAudioSession(); return "This book has no playable audio." }
            var b = book
            if b.durationSec == nil { b.durationSec = s.durationSec }
            np = WatchNowPlaying(book: b, tracks: s.tracks, chapters: s.chapters, isLocal: false, sessionId: s.id)
            Store.openStream = s.id
        }
        start = PositionRules.startOrTop(start, total: np.totalSec) // finished: from the top

        nowPlaying = np
        Store.lastBookId = book.id
        listenedSec = 0
        sinceReport = 0
        streamError = nil
        recoveries = 0
        stalledSince = nil
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
        startPlayback()
        startTicker()
        updateNowPlayingInfo()
        WatchModel.shared.updateWidget()
        didStart(book.id, streamed: !np.isLocal)
        return nil
    }

    /// Playing started here: the iPhone pauses the same book, and a streamed book
    /// is queued to download when that's on (Settings).
    private func didStart(_ id: String, streamed: Bool) {
        Task { await WatchLink.shared.pausePhone(ifPlaying: id) }
        downloadWhenPaused = streamed && Store.autoDownload ? id : nil
    }

    /// The streamed book's download starts once listening stops (see downloadWhenPaused).
    private func startPendingDownload() {
        guard let id = downloadWhenPaused else { return }
        downloadWhenPaused = nil
        Task { _ = await WatchDownloads.shared.start(id, auto: true) }
    }

    /// The iPhone started this book: pause it here.
    func pauseIfPlaying(_ id: String) {
        if nowPlaying?.book.id == id, isPlaying { pause() }
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

    private func endAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The newest of the watch's saved position, the server's (if it answers within
    /// `wait` seconds) and, when the server doesn't answer, the shelf's (`fallback`,
    /// saved at `fallbackAt`). Timestamps are all in the server's clock.
    private func startPosition(_ id: String, fallback: Double, fallbackAt: Int64, wait: Double) async -> Double {
        let local = Store.position(id)
        let fetch = Task { try? await api.mediaProgress(id).flatMap(Progress.from) }
        let timer = Task { try? await Task.sleep(for: .seconds(wait)); fetch.cancel() }
        var server = await fetch.value
        timer.cancel()
        serverStart = server?.currentTimeSec
        #if DEBUG
        if DebugHooks.serverSilent { server = nil }
        #endif
        return PositionRules.start(local: local.map { .init(sec: $0.sec, at: $0.savedAt) },
                                   server: server.map { .init(sec: $0.currentTimeSec, at: $0.lastUpdate) },
                                   fallback: fallback, fallbackAt: fallbackAt)
    }

    private func setTrack(_ i: Int, offset: Double) {
        guard let np = nowPlaying, np.tracks.indices.contains(i) else { return }
        trackIndex = i
        let t = np.tracks[i]
        var url = t.isLocal ? WatchDownloads.shared.fileURL(for: t) : URL(string: t.url)!
        #if DEBUG
        if DebugHooks.deadNetwork, !t.isLocal { url = URL(string: "http://10.255.255.1/stalled.mp3")! }
        #endif
        if !t.isLocal { itemToken = Session.shared.accessToken }
        let asset = AVURLAsset(url: url, options: t.isLocal ? nil : ["AVURLAssetHTTPHeaderFieldsKey": api.mediaHeaders])
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        av.replaceCurrentItem(with: item)
        loadedBytes = 0
        seekTarget = offset > 0 ? offset : nil
        if offset > 0 { exactSeek(offset, in: t) }
    }

    private func trackEnded() {
        guard let np = nowPlaying else { return }
        if trackIndex + 1 < np.tracks.count {
            setTrack(trackIndex + 1, offset: 0)
            startPlayback()
        } else {
            Task { await bookEnded(np) }
        }
    }

    private func bookEnded(_ np: WatchNowPlaying) async {
        position = np.totalSec
        _ = await reportNow(finished: true)
        WatchModel.shared.removeFromShelf(np.book.id)
        // Done: the session closes (a streamed one too), and a downloaded book
        // frees its space on the watch.
        await stop(report: false)
        if np.isLocal { WatchDownloads.shared.delete(np.book.id) }
    }

    /// Starts the loaded item. A stream gets AVPlayer's buffering first (playing
    /// "immediately" on a slow link only stalls straight away).
    private func startPlayback() {
        if nowPlaying?.isLocal == true {
            av.playImmediately(atRate: Float(speed))
        } else {
            av.defaultRate = Float(speed)
            av.play()
        }
    }

    // MARK: controls

    func togglePlay() {
        if isPlaying { pause() } else { Task { _ = await resume() } }
    }

    func pause() {
        av.pause()
        // Paused (by you, the sleep timer, or a stream that gave up): not a
        // moment's pause AVPlayer reports while a stream starts.
        startPendingDownload()
    }

    /// Resumes the loaded book — from the server's position if that's newer
    /// (listened on the phone during the pause), like a fresh start does.
    func resume() async -> String? {
        guard let np = nowPlaying, !loading else { return nil }
        // Streamed until now, and downloaded since: plays on from the file (no
        // stream to keep open, nothing more to fetch).
        if !np.isLocal, !jumping, WatchDownloads.shared.isDownloaded(np.book.id) {
            let book = np.book
            await stop()
            return await play(book)
        }
        loading = true
        defer { loading = false }
        // A long jump still opening its stream: Play carries on from it.
        while jumping { try? await Task.sleep(for: .milliseconds(50)) }
        if let why = await startAudioSession() { return why }
        let gaveUp = streamError != nil
        streamError = nil
        recoveries = 0
        stalledSince = nil
        // After a short pause nothing can have moved elsewhere: play at once.
        let shortPause = pausedAt.map { Date().timeIntervalSince($0) < 60 } ?? false
        if !shortPause {
            let target = await startPosition(np.book.id, fallback: currentPosition(), fallbackAt: 0, wait: 3)
            let here = currentPosition()
            if nowPlaying?.book.id == np.book.id, PositionRules.shouldJump(to: target, from: here, total: np.totalSec) {
                if !np.isLocal, abs(target - here) > 45 {
                    Task { await WatchLink.shared.pausePhone(ifPlaying: np.book.id) }
                    await api.ensureFreshToken()
                    await jumpStream(to: target, play: true, run: runs)
                    return nil
                }
                seek(to: target)
            }
        }
        guard nowPlaying?.book.id == np.book.id else { return nil }
        Task { await WatchLink.shared.pausePhone(ifPlaying: np.book.id) }
        // A stream that failed, or whose sign-in has been renewed since (the old
        // one expires after an hour): rebuild it where it is.
        if !np.isLocal {
            await api.ensureFreshToken()
            if gaveUp || av.currentItem == nil || av.currentItem?.status == .failed || itemToken != Session.shared.accessToken {
                let (i, off) = Self.locate(currentPosition(), np.tracks)
                setTrack(i, offset: off)
            }
        }
        startPlayback()
        return nil
    }

    /// To the exact second in a downloaded file or an HLS stream (short segments:
    /// cheap). In a file streamed as it is, an exact seek can make AVFoundation
    /// read from the start up to that point (an MP3 has no index), so that lands
    /// on the nearest point it can reach directly.
    private func exactSeek(_ sec: Double, in track: Track) {
        let t = CMTime(seconds: sec, preferredTimescale: 600)
        if track.isLocal || track.url.contains(".m3u8") { av.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) } else { av.seek(to: t) }
    }

    func skip(_ delta: Double) {
        seek(to: currentPosition() + delta)
    }

    func seek(to sec: Double) {
        guard let np = nowPlaying else { return }
        let target = min(max(sec, 0), np.totalSec)
        let (i, off) = Self.locate(target, np.tracks)
        // A long jump in an HLS stream goes through a new stream (see jumpStream).
        if np.tracks[i].url.contains(".m3u8"), abs(target - currentPosition()) > 45 {
            guard !loading, !jumping else { return }
            let wasPlaying = isPlaying
            // Tied to this run of the book here and now: started later, it could
            // attach itself to the next one.
            let run = runs
            jumping = true
            // The book is at the target from this moment (as a seek in place is).
            seekTarget = off
            position = target
            if !wasPlaying {
                Store.savePosition(np.book.id, LocalPosition(sec: target, savedAt: Format.nowMs, pending: true, finished: false))
                WatchModel.shared.updateShelfPosition(np.book, sec: target)
            }
            updateNowPlayingInfo()
            Task { await jumpStream(to: target, play: wasPlaying, run: run) }
            return
        }
        if i != trackIndex {
            let wasPlaying = isPlaying
            setTrack(i, offset: off)
            if wasPlaying { startPlayback() }
        } else {
            seekTarget = off
            exactSeek(off, in: np.tracks[i])
        }
        position = target
        // Moved while paused: that's now the newest place in the book, so Play
        // (which checks for a newer position) keeps it instead of jumping back.
        if !isPlaying {
            Store.savePosition(np.book.id, LocalPosition(sec: target, savedAt: Format.nowMs, pending: true, finished: false))
            WatchModel.shared.updateShelfPosition(np.book, sec: target)
        }
        updateNowPlayingInfo()
    }

    /// A long jump in an HLS stream. The server only has the segments around
    /// where its stream started: asked for others it answers "not found" while
    /// it restarts, and the player skips ahead past them (27 s late, ten hours
    /// away). So the server is told the new place and a new stream opens there,
    /// which starts exact, as a first start does.
    private func jumpStream(to target: Double, play: Bool, run: Int) async {
        jumping = true
        defer { jumping = false }
        guard run == runs, let np = nowPlaying else { return }
        stopping = true // its pause isn't a report of its own
        av.pause()
        seekTarget = Self.locate(target, np.tracks).1 // the book is at the target from here on
        position = target
        _ = await reportNow() // the listening so far, and the new place
        stopping = false
        let s = await api.openSession(np.book.id, hls: true)
        guard run == runs, nowPlaying?.book.id == np.book.id else {
            // Closed (or another book) meanwhile: the new stream isn't needed.
            if let orphan = s?.id { Task { await api.closeSession(orphan) } }
            return
        }
        if let s, !s.tracks.isEmpty {
            // The session in use now: a "gone" answer to the report above may have
            // replaced the one this jump started from (closing that one left the
            // replacement open on the server).
            if let old = nowPlaying?.sessionId { Task { await api.closeSession(old) } }
            nowPlaying?.sessionId = s.id
            nowPlaying?.tracks = s.tracks
            Store.openStream = s.id
        }
        guard let tracks = nowPlaying?.tracks else { return }
        let (i, off) = Self.locate(target, tracks)
        setTrack(i, offset: off)
        if play { startPlayback() }
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
        av.defaultRate = Float(s)
        if isPlaying { av.rate = Float(s) }
        updateNowPlayingInfo()
    }

    func chapterIndex(at pos: Double? = nil) -> Int? {
        guard let np = nowPlaying, !np.chapters.isEmpty else { return nil }
        let p = pos ?? position
        return np.chapters.lastIndex { $0.startSec <= p + 0.5 } ?? 0
    }

    /// The chapter the position is in: (start, end), nil without chapters.
    var chapterBounds: (start: Double, end: Double)? {
        guard let np = nowPlaying, np.chapters.count > 1, let i = currentChapter, np.chapters.indices.contains(i) else { return nil }
        let end = i + 1 < np.chapters.count ? np.chapters[i + 1].startSec : np.totalSec
        return (np.chapters[i].startSec, end)
    }

    var chapterTitle: String? {
        guard let np = nowPlaying, np.chapters.count > 1, let i = currentChapter, np.chapters.indices.contains(i) else { return nil }
        return np.chapters[i].title
    }

    /// Where we are in the BOOK (all tracks), in seconds.
    func currentPosition() -> Double {
        guard let np = nowPlaying else { return 0 }
        let before = np.tracks.prefix(trackIndex).reduce(0) { $0 + $1.durationSec }
        var t = av.currentTime().seconds
        if !t.isFinite { t = 0 }
        if let target = seekTarget {
            if abs(t - target) < 1.5 || av.timeControlStatus == .playing {
                seekTarget = nil // landed (or playing on from where it is)
            } else {
                t = target // still on its way: that's where the book is
            }
        }
        return before + t
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
                let pos = currentPosition()
                if pos >= end - 0.3 { pause(); sleepEndOfChapter = false; return }
                // Asleep until shortly before the end (at most a minute at a time: a
                // seek or a speed change moves it), then close checks.
                let left = (end - pos) / max(speed, 0.5)
                try? await Task.sleep(for: .seconds(left > 3 ? min(left - 2, 60) : 0.5))
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

    /// What it's waiting on, for the player ("Buffering…"); nil when it isn't.
    var waitLabel: String? {
        if loading || jumping { return "Opening…" }
        guard buffering else { return nil }
        return recoveries > 0 ? "Reconnecting…" : "Buffering…"
    }

    // MARK: syncing

    /// `status`: AVPlayer.TimeControlStatus's raw value.
    private func statusChanged(_ status: Int) {
        let s = AVPlayer.TimeControlStatus(rawValue: status) ?? .paused
        accrue()
        audible = s == .playing
        playingSince = audible ? Date() : nil
        buffering = s == .waitingToPlayAtSpecifiedRate
        let playing = s != .paused
        guard playing != isPlaying else { return }
        isPlaying = playing
        pausedAt = playing ? nil : Date()
        updateNowPlayingInfo()
        WatchModel.shared.updateWidget()
        if playing { startTicker() }
        if !playing, nowPlaying != nil, !stopping { Task { _ = await reportNow() } }
    }

    /// Adds the time sound was coming out (not buffering) to the listening time.
    private func accrue() {
        guard let since = playingSince else { return }
        listenedSec += Date().timeIntervalSince(since)
        playingSince = audible ? Date() : nil
    }

    /// The position twice a second (for the screen), a report every 30 s while
    /// playing, and the stream watchdog. Only while playing: paused, nothing
    /// moves (a seek sets the position itself), and it starts again on Play.
    private func startTicker() {
        ticker?.cancel()
        ticker = Task {
            while !Task.isCancelled {
                // Twice a second on screen; wrist down or in the background only
                // the reports and the watchdog need it (every few seconds).
                let step = screenActive ? 0.5 : 5
                try? await Task.sleep(for: .seconds(step))
                guard !Task.isCancelled, let np = nowPlaying else { continue }
                position = currentPosition()
                guard isPlaying else { return }
                // (Kept across restarts of the ticker: a wrist raise restarts it,
                // and must not put the next report off.)
                sinceReport += step
                if sinceReport >= Self.syncEvery { sinceReport = 0; _ = await reportNow() }
                if !np.isLocal { await watchStream(np) }
            }
        }
    }

    /// A stream that failed, or has been waiting for data too long (a dropped
    /// connection, a network change, an expired sign-in), is rebuilt where it is,
    /// with a renewed sign-in, waiting longer each time. After the last try it
    /// pauses and says so. Its position is never touched: a stuck item still
    /// reports where it really is.
    private func watchStream(_ np: WatchNowPlaying) async {
        guard !recovering, !loading else { return }
        let failed = av.currentItem?.status == .failed
        if av.timeControlStatus == .playing && !failed {
            stalledSince = nil
            recoveries = 0
            return
        }
        // Still loading (bytes are arriving): slow isn't stuck. Rebuilding now
        // would throw away what's been fetched and start it again.
        let bytes = av.currentItem?.accessLog()?.events.reduce(Int64(0)) { $0 + $1.numberOfBytesTransferred } ?? 0
        if !failed, bytes > loadedBytes {
            loadedBytes = bytes
            stalledSince = nil
            return
        }
        let since = stalledSince ?? Date()
        stalledSince = since
        let limit = PositionRules.stallLimit(attempt: recoveries)
        guard failed || Date().timeIntervalSince(since) >= (limit ?? 60) else { return }
        guard limit != nil else {
            av.pause()
            streamError = "Lost the connection. Tap Play to try again."
            stalledSince = nil
            return
        }
        recovering = true
        defer { recovering = false }
        recoveries += 1
        let pos = currentPosition()
        await api.ensureFreshToken()
        // Paused or another book meanwhile: leave it.
        guard nowPlaying?.book.id == np.book.id, isPlaying, let tracks = nowPlaying?.tracks else { return }
        let (i, off) = Self.locate(pos, tracks)
        setTrack(i, offset: off)
        startPlayback()
        stalledSince = Date()
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
        // While playing, the shelf is only updated in memory (it's written to disk
        // when listening stops, not with every report).
        WatchModel.shared.updateShelfPosition(np.book, sec: pos, persist: !isPlaying || finished)

        let listened = listenedSec
        let report = API.Report(itemId: np.book.id, currentSec: pos, durationSec: np.totalSec, finished: finished,
                                paused: !isPlaying, listenedSec: listened > 0 ? listened : nil)
        var saved = false, recorded = false
        if let sid = np.sessionId {
            switch await api.syncSession(sid, report) {
            case .ok: saved = true; recorded = true
            // The session is gone (closed by the server after a long pause): the
            // position still goes through without it.
            case .gone:
                saved = await api.saveProgress(report)
                // Closed by the server (a restart, a long pause): a new one records
                // the listening time again. Same tracks: its URLs replace the old
                // ones, which may have belonged to the closed session.
                // Only for the session still in use: one replaced meanwhile (a long
                // jump) answers "gone" too, and its replacement must not get another.
                if nowPlaying?.sessionId == sid, let s = await api.openSession(np.book.id, hls: true) {
                    if nowPlaying?.book.id == np.book.id, nowPlaying?.sessionId == sid {
                        nowPlaying?.sessionId = s.id
                        if s.tracks.count == np.tracks.count { nowPlaying?.tracks = s.tracks }
                        Store.openStream = s.id
                    } else if let orphan = s.id {
                        Task { await api.closeSession(orphan) }
                    }
                }
            case .refused: saved = await api.saveProgress(report)
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
        runs += 1
        stopping = true
        defer { stopping = false }
        av.pause()
        if report { _ = await reportNow() }
        // Closing needs no answer: don't hold the screen on a slow connection.
        // (Store.openStream stays until then: a close that didn't get through is
        // sent again at the next play.)
        if let sid = np.sessionId {
            Task { if await api.closeSession(sid), Store.openStream == sid { Store.openStream = nil } }
        }
        av.replaceCurrentItem(with: nil)
        seekTarget = nil
        ticker?.cancel()
        startPendingDownload()
        cancelSleep()
        nowPlaying = nil
        status = nil
        streamError = nil
        buffering = false
        itemToken = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        WatchModel.shared.updateWidget()
        endAudioSession()
    }

    // MARK: system controls

    /// Built outside the main actor: MediaPlayer calls these on its own queue.
    nonisolated private static func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in
            Task { @MainActor in _ = await WatchPlayer.shared.resume() }
            return .success
        }
        c.pauseCommand.addTarget { _ in
            Task { @MainActor in WatchPlayer.shared.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in WatchPlayer.shared.togglePlay() }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in WatchPlayer.shared.skip(-30) }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { _ in
            Task { @MainActor in WatchPlayer.shared.skip(30) }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { e in
            let t = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor in WatchPlayer.shared.seek(to: t) }
            return .success
        }
    }

    /// A call or Siri pauses the audio: play again afterwards if the system says to.
    nonisolated private static func observeInterruptions() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            let shouldResume = options?.contains(.shouldResume) ?? false
            Task { @MainActor in WatchPlayer.shared.interrupted(began: type == .began, shouldResume: shouldResume) }
        }
    }

    private func interrupted(began: Bool, shouldResume: Bool) {
        if began {
            resumeAfterInterruption = isPlaying
        } else {
            if resumeAfterInterruption, shouldResume, nowPlaying != nil { Task { _ = await resume() } }
            resumeAfterInterruption = false
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
        if artwork?.id != np.book.id, let file = WatchDownloads.shared.coverFile(np.book.id), let img = UIImage(contentsOfFile: file.path) {
            artwork = (np.book.id, Self.makeArtwork(img))
        }
        if let a = artwork, a.id == np.book.id { info[MPMediaItemPropertyArtwork] = a.art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Built outside the main actor: the system calls these closures on its own queues.
    nonisolated private static func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    nonisolated private static func observePlaying(_ av: AVPlayer) -> NSKeyValueObservation {
        av.observe(\.timeControlStatus) { p, _ in
            let status = p.timeControlStatus.rawValue
            Task { @MainActor in WatchPlayer.shared.statusChanged(status) }
        }
    }

    #if DEBUG
    // Test hooks (simulator only, see DebugHooks).
    var debugListened: Double { listenedSec + (playingSince.map { Date().timeIntervalSince($0) } ?? 0) }
    var debugRecoveries: Int { recoveries }
    var debugAudible: Bool { audible }
    func debugLongPause() { pausedAt = Date(timeIntervalSinceNow: -3600) }
    /// Swaps the playing item for one that never answers (a dead connection), at
    /// the same place, as a dropped link would leave it.
    func debugBreakStream() {
        let off = av.currentTime().seconds
        let item = AVPlayerItem(url: URL(string: "http://10.255.255.1/stalled.mp3")!)
        av.replaceCurrentItem(with: item)
        av.seek(to: CMTime(seconds: off, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        av.play()
    }
    #endif

    /// A book position as (track index, seconds into that track).
    static func locate(_ sec: Double, _ tracks: [Track]) -> (Int, Double) {
        PositionRules.locate(sec, durations: tracks.map(\.durationSec))
    }
}
