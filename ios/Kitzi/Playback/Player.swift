import AVFoundation
import Foundation
import MediaPlayer
import Network
import Observation
import QuartzCore
import UIKit

/// The book that's loaded, in book coordinates.
struct NowPlaying: Equatable {
    var book: Book
    var tracks: [Track]
    var chapters: [Chapter]
    var isLocal: Bool
    var serverDurationSec: Double?
    var totalSec: Double {
        let sum = tracks.reduce(0) { $0 + $1.durationSec }
        return sum > 0 ? sum : (serverDurationSec ?? book.durationSec ?? 0)
    }
    /// HLS transcode URLs belong to a server session and die with it.
    var sessionScoped: Bool { !isLocal && tracks.contains { $0.url.contains("/hls/") } }
}

struct ChapterInfo {
    var index: Int
    var title: String
    var startSec: Double
    var endSec: Double
    var elapsedSec: Double
    var durationSec: Double { endSec - startSec }
}

/// Where this device last was in a book, and whether the server has it yet.
struct LocalPosition {
    var sec: Double
    var savedAt: Int64
    var pending: Bool
    var finished: Bool
}

/// Plays one book (all its tracks) and keeps the server in step, with the same
/// rules as the Android app:
/// - the position is reported every 30 s while playing (backing off after
///   failures), on pause, after a seek (debounced), at a track change and at the
///   end — and only when it moved;
/// - reports run one at a time, so listening time is never sent twice;
/// - listening time counts only while audio is actually playing;
/// - a report that can't reach the server is kept here ("pending") and pushed
///   when the network is back;
/// - a streamed book's server session closes on pause and reopens on resume, and
///   a resume (or a book auto-loaded at launch) checks the server first, so
///   progress made on another device is never overwritten.
@Observable
final class Player {
    static let shared = Player()
    private let api = API.shared
    private let library = LibraryStore.shared

    private(set) var nowPlaying: NowPlaying?
    /// The user's intent (the play/pause button). Audio may still be buffering.
    private(set) var isPlaying = false
    private(set) var preparing = false
    /// Book position, refreshed twice a second.
    private(set) var position: Double = 0
    private(set) var speed: Double = Store.double("playback_speed") ?? 1
    /// Where the last jump (seek of more than a few seconds) started, for "Last position".
    private(set) var positionBeforeLastJump: Double?
    private(set) var lastError: String?
    /// Bumped on every user seek (the end-of-chapter sleep timer re-targets on it).
    private(set) var seekGeneration = 0
    private(set) var online = true

    private let av = AVPlayer()
    private var trackIndex = 0
    private var sessionId: String?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var kvo: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemKVO: NSKeyValueObservation?
    private var syncLoop: Task<Void, Never>?
    private var seekReport: Task<Void, Never>?
    private var pausedAt: Date?
    /// Moved since the last save (played or seeked): only then is it reported.
    private var dirty = false
    /// Loaded without playing (cold start) or after a long pause: check the server on resume.
    private var needsServerCheck = false
    private var wasPlayingBeforeInterruption = false
    /// A server check (has this book moved on elsewhere?) is in flight: until it
    /// answers, nothing is saved or reported, so a stale position can't overwrite
    /// newer progress.
    private var serverCheckPending = false
    /// The id unsent listening time is persisted under (see UnsentListening).
    private var unsentId = UUID().uuidString
    /// Every load gets a number; work started for an older load is dropped.
    private var loadGeneration = 0
    /// The item's first seek waits until it can be seeked.
    private var pendingSeek: Double?
    private var itemReady = false
    private var failedSyncs = 0

    // Listening time not yet recorded by the server (seconds of audio actually heard).
    private var listenedSec = 0.0
    private var audibleSince: CFTimeInterval?
    // A downloaded book's listening is reported as a "local" session.
    private var localSession: (id: String, startedAt: Int64, startSec: Double, total: Double)?
    /// Reports run one after another (never two at once).
    private var reportChain: Task<Bool, Never>?

    private let pathMonitor = NWPathMonitor()

    private init() {
        av.automaticallyWaitsToMinimizeStalling = true
        configureAudioSession()
        configureRemoteCommands()
        tickEvery(0.5)
        kvo.append(Self.observeTimeControl(av))
        Self.watchNetwork(pathMonitor)
    }

    // MARK: system callbacks (built in nonisolated code: they arrive on other queues)

    nonisolated private static func watchNetwork(_ monitor: NWPathMonitor) {
        monitor.pathUpdateHandler = { path in
            let up = path.status == .satisfied
            Task { @MainActor in Player.shared.networkChanged(up) }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    nonisolated private static func observeTimeControl(_ av: AVPlayer) -> NSKeyValueObservation {
        av.observe(\.timeControlStatus, options: [.new]) { p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in Player.shared.timeControlChanged(status) }
        }
    }

    nonisolated private static func observeItem(_ item: AVPlayerItem) -> NSKeyValueObservation {
        item.observe(\.status, options: [.new]) { i, _ in
            let status = i.status
            Task { @MainActor in Player.shared.itemStatusChanged(item: ObjectIdentifier(i), status) }
        }
    }

    /// Built outside the main actor: iOS calls the artwork closure on its own queue.
    nonisolated private static func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    private func networkChanged(_ up: Bool) {
        let was = online
        online = up
        if up && !was { Task { await flushPending(); await library.flushPendingBookmarks() } }
    }

    /// Audio actually playing or not: listening time follows this, not the button.
    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        if status == .playing {
            if audibleSince == nil { audibleSince = CACurrentMediaTime() }
        } else {
            accrue(stopping: true)
            // Paused by the system (another app took the audio) while we meant to
            // play — but not the pause AVPlayer does at the end of each track.
            if status == .paused, isPlaying, itemReady, !atItemEnd { markPaused(intentional: false) }
        }
    }

    private var atItemEnd: Bool {
        guard let item = av.currentItem, item.duration.isNumeric else { return false }
        return av.currentTime().seconds >= item.duration.seconds - 0.6
    }

    private func itemStatusChanged(item: ObjectIdentifier, _ status: AVPlayerItem.Status) {
        guard let current = av.currentItem, ObjectIdentifier(current) == item else { return }
        switch status {
        case .readyToPlay:
            itemReady = true
            if let s = pendingSeek {
                pendingSeek = nil
                av.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        case .failed:
            itemReady = false
            let wasPlaying = isPlaying
            av.pause()
            if wasPlaying { markPaused(intentional: false) }
            needsServerCheck = true
            // The next play reloads the book from scratch (fresh session and URLs).
            av.replaceCurrentItem(with: nil)
            lastError = "Playback failed. Tap play to try again."
            Toast.show("Playback failed — tap play to try again")
        default: break
        }
    }

    // MARK: audio session & system controls

    private func configureAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let info = n.userInfo, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0) }
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began {
                    // Only a book that was playing resumes after the call/Siri/alarm.
                    self.wasPlayingBeforeInterruption = self.isPlaying
                    if self.isPlaying { self.markPaused(intentional: false) }
                } else if opts?.contains(.shouldResume) == true, self.wasPlayingBeforeInterruption {
                    self.wasPlayingBeforeInterruption = false
                    self.resume()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            // Headphones out: AVPlayer already paused; record it like a pause.
            MainActor.assumeIsolated { self?.markPaused(intentional: true) }
        }
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        c.skipForwardCommand.addTarget { [weak self] _ in self?.skip(Double(AppSettings.shared.seekForwardSec)); return .success }
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(-Double(AppSettings.shared.seekBackSec)); return .success }
        // Car and headphone next/previous buttons arrive as "track" commands: they
        // skip the configured seconds, as on Android (chapter skip stays on the
        // player's own buttons; the lock screen shows the ± seconds buttons).
        c.nextTrackCommand.addTarget { [weak self] _ in self?.skip(Double(AppSettings.shared.seekForwardSec)); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.skip(-Double(AppSettings.shared.seekBackSec)); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime, report: true)
            return .success
        }
        c.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1, 1.25, 1.5, 1.75, 2]
        c.changePlaybackRateCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            self?.setSpeed(Double(e.playbackRate)); return .success
        }
        updateSkipIntervals()
    }

    func updateSkipIntervals() {
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: AppSettings.shared.seekForwardSec)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: AppSettings.shared.seekBackSec)]
    }

    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var nowPlayingChapter: String?
    @ObservationIgnored private var nowPlayingSyncedAt: CFTimeInterval = 0

    private func updateNowPlayingInfo() {
        guard let np = nowPlaying else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        nowPlayingChapter = currentChapter()?.title
        nowPlayingSyncedAt = CACurrentMediaTime()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: np.book.title,
            MPMediaItemPropertyArtist: currentChapter()?.title ?? np.book.author ?? "",
            MPMediaItemPropertyAlbumTitle: np.book.author ?? "",
            MPMediaItemPropertyPlaybackDuration: np.totalSec,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    func loadArtwork(_ book: Book) {
        artwork = nil
        Task {
            let url = Downloads.shared.localCover(book.id) ?? book.coverURL(width: 1000)
            guard let url, let img = await ImageLoader.shared.image(url), nowPlaying?.book.id == book.id else { return }
            let crop = CoverCrops.shared.crops[book.id]
            artwork = Self.makeArtwork(crop.map { CoverCrops.apply($0, to: img) } ?? img)
            updateNowPlayingInfo()
        }
    }

    // MARK: loading

    /// Plays [book] from the newer of the local and server positions. Nil, or why it can't.
    @discardableResult
    func play(_ book: Book, startPlaying: Bool = true) async -> String? {
        if nowPlaying?.book.id == book.id, av.currentItem != nil {
            if startPlaying { resume() }
            return nil
        }
        loadGeneration += 1
        let gen = loadGeneration
        preparing = true
        lastError = nil
        defer { if gen == loadGeneration { preparing = false } }

        // Resolve the new book BEFORE stopping the current one: if it can't be
        // opened, what was playing keeps playing.
        let np: NowPlaying
        var newSession: String?
        if let saved = Downloads.shared.downloaded(book.id) {
            np = NowPlaying(book: saved.book, tracks: saved.tracks, chapters: saved.chapters, isLocal: true, serverDurationSec: saved.book.durationSec)
        } else {
            if AppSettings.shared.syncBeforePlay { await syncWithTimeout(book.id, seconds: 4) }
            await api.ensureFreshToken()
            guard let s = await api.openSession(book.id), !s.tracks.isEmpty else {
                if gen == loadGeneration { lastError = "Couldn't start this book. Check your connection — downloaded books always play offline." }
                return lastError
            }
            guard gen == loadGeneration else { if let id = s.id { await api.closeSession(id) }; return nil }
            np = NowPlaying(book: book, tracks: s.tracks, chapters: s.chapters.isEmpty ? Self.trackChapters(s.tracks) : s.chapters,
                            isLocal: false, serverDurationSec: s.durationSec)
            newSession = s.id
        }
        if nowPlaying != nil { await stop(keepLast: true) }
        guard gen == loadGeneration else { if let id = newSession { await api.closeSession(id) }; return nil }

        sessionId = newSession
        localSession = np.isLocal ? (UUID().uuidString, Format.nowMs, 0, 0) : nil
        var start = resumePosition(book.id)
        if start >= np.totalSec - 5 {
            // Finished: from the top. Merely paused near the end: a little before it
            // (starting over would report ~0 and "un-finish" it everywhere).
            let finished = library.progress[book.id]?.isFinished == true || localPosition(book.id)?.finished == true
            start = finished ? 0 : max(np.totalSec - 30, 0)
        }
        nowPlaying = np
        Store.set(book.id, Store.lastItemKey)
        listenedSec = 0
        dirty = false
        positionBeforeLastJump = nil
        pausedAt = nil
        failedSyncs = 0
        localSession?.startSec = start
        unsentId = localSession?.id ?? UUID().uuidString
        serverCheckPending = false
        speed = Store.double("playback_speed:\(book.id)") ?? Store.double("playback_speed") ?? 1
        load(trackAt: start)
        loadArtwork(book)
        startSyncLoop()
        if startPlaying {
            needsServerCheck = false
            // A downloaded book starts at once and the server is checked meanwhile
            // (a streamed one was synced just before its session opened).
            if np.isLocal && AppSettings.shared.syncBeforePlay { beginServerCheck(book.id, generation: gen) }
            startAudio()
        } else {
            // Auto-loaded (cold start): the server is checked on the first play, and
            // a streamed book's session isn't held open meanwhile.
            needsServerCheck = true
            if let sid = sessionId { sessionId = nil; await api.closeSession(sid) }
        }
        updateNowPlayingInfo()
        return nil
    }

    /// Chapters from track boundaries when the book has none.
    static func trackChapters(_ tracks: [Track]) -> [Chapter] {
        guard tracks.count > 1 else { return [] }
        var t = 0.0
        return tracks.enumerated().map { i, tr in defer { t += tr.durationSec }; return Chapter(title: "Track \(i + 1)", startSec: t) }
    }

    /// The newer of this device's saved position and the server's row.
    private func resumePosition(_ id: String) -> Double {
        let local = localPosition(id)
        let server = library.progress[id]
        switch (local, server) {
        case (nil, let s?): return s.currentTimeSec
        case (let l?, nil): return l.pending ? l.sec : 0
        case (let l?, let s?): return l.savedAt > s.lastUpdate ? l.sec : s.currentTimeSec
        default: return 0
        }
    }

    private func syncWithTimeout(_ id: String, seconds: Double) async {
        let fetch = Task { try? await self.library.syncProgressFor(id) }
        let timer = Task { try? await Task.sleep(for: .seconds(seconds)); fetch.cancel() }
        _ = await fetch.value
        timer.cancel()
    }

    /// If the server has a newer position (listened elsewhere) and nothing moved
    /// here since the load, go there.
    /// Checks whether the book moved on elsewhere (another device) since this
    /// device last saved it, and goes there if so. Until the server answers,
    /// nothing is saved or reported (see serverCheckPending). The jump is skipped
    /// only if the user moved the position during the check itself.
    private func beginServerCheck(_ id: String, generation gen: Int) {
        serverCheckPending = true
        let baseline = localPosition(id)?.savedAt ?? 0
        let seeksAtStart = seekGeneration
        Task {
            var answer: Progress?? = nil // nil = no answer (offline)
            for attempt in 0..<4 {
                do { answer = .some(try await library.syncProgressFor(id)); break } catch {}
                guard gen == loadGeneration, seekGeneration == seeksAtStart else { break }
                try? await Task.sleep(for: .seconds(Double(2 << attempt)))
            }
            guard gen == loadGeneration else { return }
            serverCheckPending = false
            if case let .some(server?) = answer, seekGeneration == seeksAtStart, !server.isFinished,
               server.lastUpdate > baseline, abs(server.currentTimeSec - position) > 3 {
                seek(to: server.currentTimeSec, report: false, isJump: false)
                Toast.show("Continued from \(Format.clock(server.currentTimeSec)) — listened elsewhere")
            }
        }
    }

    private func load(trackAt sec: Double) {
        guard let np = nowPlaying else { return }
        let (i, offset) = Self.locate(sec, np.tracks)
        setTrack(i, offset: offset)
        position = sec
    }

    private func setTrack(_ i: Int, offset: Double) {
        guard let np = nowPlaying, np.tracks.indices.contains(i) else { return }
        trackIndex = i
        let t = np.tracks[i]
        let url: URL
        if t.isLocal {
            url = Downloads.shared.fileURL(for: t)
        } else {
            guard let u = URL(string: t.url) else { return }
            url = u
        }
        let asset = AVURLAsset(url: url, options: t.isLocal ? nil : ["AVURLAssetHTTPHeaderFieldsKey": api.mediaHeaders])
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackEnded() }
        }
        itemReady = false
        pendingSeek = offset > 0.5 ? offset : nil
        itemKVO = Self.observeItem(item)
        av.replaceCurrentItem(with: item)
    }

    private func trackEnded() {
        guard let np = nowPlaying else { return }
        if trackIndex + 1 < np.tracks.count {
            setTrack(trackIndex + 1, offset: 0)
            if isPlaying { av.playImmediately(atRate: Float(speed)) }
            Task { await report() }
        } else {
            bookEnded()
        }
    }

    private func bookEnded() {
        guard let np = nowPlaying else { return }
        isPlaying = false
        accrue(stopping: true)
        position = np.totalSec
        dirty = true
        Task {
            await report(finished: true)
            // A session sync lets the server decide "finished" from its thresholds:
            // say it explicitly too.
            if !np.isLocal {
                _ = await serialWrite {
                    await self.api.saveProgress(API.Report(itemId: np.book.id, currentSec: np.totalSec, durationSec: np.totalSec,
                                                           finished: true, paused: true, listenedSec: nil))
                }
            }
            library.recordLocal(np.book.id, sec: np.totalSec, total: np.totalSec, finished: true)
            let next = PlayQueue.shared.popNext()
            if AppSettings.shared.autoDeleteOnFinish && np.isLocal {
                await stop(keepLast: next == nil)
                Downloads.shared.delete(np.book.id)
            } else if let sid = sessionId {
                sessionId = nil
                await api.closeSession(sid)
            }
            // The queue carries on with the next book.
            if let next { await play(next) }
        }
        updateNowPlayingInfo()
    }

    // MARK: transport

    func togglePlay() { isPlaying ? pause() : resume() }

    func resume(skipRewind: Bool = false) {
        guard let np = nowPlaying else {
            if let id = Store.string(Store.lastItemKey), let b = library.byId[id] { Task { await play(b) } }
            return
        }
        // A failed item, or HLS URLs that died with a closed session: load afresh.
        // The position is NOT re-saved here — the pause already saved it with its
        // real time, and a fresh stamp would beat newer progress from elsewhere.
        if av.currentItem == nil || (np.sessionScoped && sessionId == nil) {
            let b = np.book
            Task {
                if self.dirty { await self.report() }
                await self.reload(b)
            }
            return
        }
        if !skipRewind, AppSettings.shared.smartRewind, let p = pausedAt {
            let e = Date().timeIntervalSince(p)
            let r: Double = e < 10 ? 3 : (e <= 30 ? 5 : (e >= 120 ? 30 : 0))
            if r > 0 { seek(to: max(position - r, 0), report: false, isJump: false) }
        }
        pausedAt = nil
        needsServerCheck = false
        let gen = loadGeneration
        // Every resume checks the server (another device may have moved on during
        // the pause, however short).
        if AppSettings.shared.syncBeforePlay { beginServerCheck(np.book.id, generation: gen) }
        startAudio()
        guard !np.isLocal else { return }
        Task {
            // The URLs carry the token in their headers: renew it if it's about to
            // expire, and rebuild the item with the new one.
            let before = Session.shared.accessToken
            await api.ensureFreshToken()
            if gen == loadGeneration, Session.shared.accessToken != before {
                let pos = position
                load(trackAt: pos)
                if isPlaying { av.playImmediately(atRate: Float(speed)) }
            }
            // A streamed book's session was closed on pause: open a new one.
            if gen == loadGeneration, sessionId == nil, let s = await api.openSession(np.book.id), gen == loadGeneration {
                sessionId = s.id
            }
        }
    }

    private func startAudio() {
        try? AVAudioSession.sharedInstance().setActive(true)
        av.playImmediately(atRate: Float(speed))
        isPlaying = true
        dirty = true
        lastError = nil
        updateNowPlayingInfo()
    }

    /// A fresh load (new session and URLs) from the newer of the saved and the
    /// server positions, then play.
    private func reload(_ book: Book) async {
        pausedAt = nil
        await stop(keepLast: true)
        await play(book)
    }

    func pause() {
        guard isPlaying else { return }
        av.pause()
        markPaused(intentional: true)
    }

    private func markPaused(intentional: Bool) {
        refreshPosition()
        guard isPlaying else { return }
        isPlaying = false
        accrue(stopping: true)
        pausedAt = Date()
        dirty = true
        if intentional && AppSettings.shared.pauseCancelsSleep { SleepTimer.shared.cancel() }
        if let np = nowPlaying {
            PlayHistory.shared.journal(np.book.id, position: position, chapter: currentChapter()?.title)
            // On disk at once: the report below may wait behind another, and iOS can
            // suspend the app meanwhile.
            if !serverCheckPending { saveLocal(np.book.id, position, finished: false) }
        }
        persistUnsent()
        updateNowPlayingInfo()
        let gen = loadGeneration
        Task {
            await withBackgroundTime { await self.report() }
            // Closing the session on pause stops the server transcoding for a paused
            // client; it reopens on resume.
            if gen == loadGeneration, !isPlaying, let sid = sessionId {
                sessionId = nil
                await api.closeSession(sid)
            }
        }
    }

    func skip(_ delta: Double) {
        refreshPosition()
        guard let np = nowPlaying else { return }
        seek(to: min(max(position + delta, 0), np.totalSec), report: false, isJump: false)
        scheduleSeekReport()
    }

    /// Seek in BOOK coordinates (across tracks).
    func seek(to sec: Double, report: Bool = true, isJump: Bool = true) {
        guard let np = nowPlaying else { return }
        let target = min(max(sec, 0), np.totalSec)
        if isJump && abs(target - position) > 5 { positionBeforeLastJump = position }
        let (i, off) = Self.locate(target, np.tracks)
        if i != trackIndex || av.currentItem == nil {
            setTrack(i, offset: off)
            if isPlaying { av.playImmediately(atRate: Float(speed)) }
        } else if !itemReady {
            pendingSeek = off
        } else {
            av.seek(to: CMTime(seconds: off, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        position = target
        dirty = true
        seekGeneration += 1
        updateNowPlayingInfo()
        if report { scheduleSeekReport() }
    }

    /// One report 2.5 s after the last seek (scrubbing sends many).
    private func scheduleSeekReport() {
        seekReport?.cancel()
        seekReport = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await report()
        }
    }

    func nextChapter() {
        refreshPosition()
        guard let c = currentChapter(), let np = nowPlaying, c.index + 1 < np.chapters.count else { return }
        seek(to: np.chapters[c.index + 1].startSec)
    }

    func previousChapter() {
        refreshPosition()
        guard let c = currentChapter(), let np = nowPlaying else { return }
        // Within the first few seconds of a chapter, go to the previous one.
        if c.elapsedSec < 3, c.index > 0 { seek(to: np.chapters[c.index - 1].startSec) } else { seek(to: c.startSec) }
    }

    func setSpeed(_ s: Double) {
        let v = (min(max(s, 0.5), 3.5) * 20).rounded() / 20
        speed = v
        Store.set(v, "playback_speed")
        if let id = nowPlaying?.book.id { Store.set(v, "playback_speed:\(id)") }
        if isPlaying { av.rate = Float(v) }
        updateNowPlayingInfo()
    }

    /// Stops the book: final report, session closed, audio released.
    func stop(keepLast: Bool = false) async {
        guard nowPlaying != nil else { return }
        av.pause()
        if isPlaying { isPlaying = false; accrue(stopping: true) }
        seekReport?.cancel()
        await report()
        if let sid = sessionId { sessionId = nil; await api.closeSession(sid) }
        persistUnsent()
        syncLoop?.cancel()
        av.replaceCurrentItem(with: nil)
        itemKVO = nil
        nowPlaying = nil
        localSession = nil
        listenedSec = 0
        pausedAt = nil
        if !keepLast { Store.set(nil, Store.lastItemKey) }
        updateNowPlayingInfo()
        SleepTimer.shared.cancel()
        // Let other apps' audio resume.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Drops the loaded book WITHOUT reporting it (another account signed in).
    func discard() {
        loadGeneration += 1
        av.pause()
        av.replaceCurrentItem(with: nil)
        syncLoop?.cancel(); seekReport?.cancel()
        isPlaying = false
        nowPlaying = nil
        sessionId = nil
        localSession = nil
        listenedSec = 0
        audibleSince = nil
        dirty = false
        serverCheckPending = false
        updateNowPlayingInfo()
    }

    /// "Close book": stop and forget it as the last book.
    func closeBook() async { await stop(keepLast: false) }

    // MARK: position

    /// How often [position] follows the player: twice a second on screen, every
    /// 2 s in the background (nothing is drawn; readers call refreshPosition()).
    private func tickEvery(_ sec: Double) {
        if let t = timeObserver { av.removeTimeObserver(t) }
        timeObserver = av.addPeriodicTimeObserver(forInterval: CMTime(seconds: sec, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func appForegrounded() { tickEvery(0.5); refreshPosition() }

    private func tick() {
        refreshPosition()
        // The lock screen advances the elapsed time by itself (from the rate): it's
        // told again only when the chapter (shown as the artist) changes, and once a
        // minute to stay exact.
        if currentChapter()?.title != nowPlayingChapter || CACurrentMediaTime() - nowPlayingSyncedAt > 60 {
            updateNowPlayingInfo()
        }
    }

    /// Brings [position] up to date with the player, between ticks.
    func refreshPosition() {
        guard let np = nowPlaying, av.currentItem != nil, itemReady, pendingSeek == nil else { return }
        let local = av.currentTime().seconds
        guard local.isFinite else { return }
        position = np.tracks.prefix(trackIndex).reduce(0) { $0 + $1.durationSec } + local
    }

    static func locate(_ sec: Double, _ tracks: [Track]) -> (Int, Double) {
        var remaining = sec
        for (i, t) in tracks.enumerated() {
            if remaining < t.durationSec || i == tracks.count - 1 { return (i, max(remaining, 0)) }
            remaining -= t.durationSec
        }
        return (0, 0)
    }

    func currentChapter() -> ChapterInfo? { chapter(at: position) }

    func chapter(at pos: Double) -> ChapterInfo? {
        guard let np = nowPlaying, !np.chapters.isEmpty else { return nil }
        let idx = np.chapters.lastIndex { $0.startSec <= pos + 0.25 } ?? 0
        let start = np.chapters[idx].startSec
        let end = idx + 1 < np.chapters.count ? np.chapters[idx + 1].startSec : np.totalSec
        return ChapterInfo(index: idx, title: np.chapters[idx].title, startSec: start, endSec: end, elapsedSec: pos - start)
    }

    // MARK: sync

    private func startSyncLoop() {
        syncLoop?.cancel()
        syncLoop = Task {
            while !Task.isCancelled {
                // 30 s, widening up to 4 minutes while reports keep failing.
                let wait = 30.0 * Double(min(1 << min(failedSyncs, 3), 8))
                try? await Task.sleep(for: .seconds(wait))
                if isPlaying { await report() }
            }
        }
    }

    /// Audio-time listening since the last count (monotonic clock).
    private func accrue(stopping: Bool) {
        guard let since = audibleSince else { return }
        let now = CACurrentMediaTime()
        listenedSec += max(now - since, 0)
        audibleSince = (stopping || av.timeControlStatus != .playing) ? nil : now
    }

    /// Reports now (after any report already running). True when the server took it.
    @discardableResult
    func report(finished: Bool = false) async -> Bool {
        await serialWrite { await self.performReport(finished: finished) }
    }

    /// Every progress write (reports, the offline flush, mark finished/unfinished,
    /// undo) runs through here, one after another: a stale write can never land
    /// after a newer one.
    func serialWrite(_ op: @escaping () async -> Bool) async -> Bool {
        let previous = reportChain
        let task = Task { () -> Bool in
            _ = await previous?.value
            return await op()
        }
        reportChain = task
        return await task.value
    }

    private func performReport(finished: Bool) async -> Bool {
        guard let np = nowPlaying else { return false }
        guard finished || dirty || isPlaying else { return true }
        // Until the server check answers, nothing is saved or sent (dirty stays set,
        // so the next report carries it).
        if serverCheckPending && !finished { return true }
        refreshPosition()
        accrue(stopping: false)
        let gen = loadGeneration
        let id = np.book.id
        let pos = finished ? np.totalSec : position
        saveLocal(id, pos, finished: finished)
        dirty = false
        let savedAt = localPosition(id)?.savedAt
        // Snapshot the unsent listening and the session for THIS book, now.
        let listened = max(listenedSec, 0)
        let session = sessionId
        let local = localSession
        let r = API.Report(itemId: id, currentSec: pos, durationSec: np.totalSec, finished: finished,
                           paused: !isPlaying, listenedSec: listened > 0 ? listened : nil)
        var saved = false, recorded = false
        if let sid = session {
            switch await api.syncSession(sid, r) {
            case .ok: saved = true; recorded = true
            case .gone:
                // Closed by the server (restart, timeout): the position still goes
                // through, and a new session takes the listening time from here on.
                saved = await api.saveProgress(r)
                if gen == loadGeneration, sessionId == sid, let s = await api.openSession(id) { sessionId = s.id }
            case .refused:
                saved = await api.saveProgress(r)
            case .unreachable:
                saved = false
            }
        } else {
            saved = await api.saveProgress(r)
            if saved, listened > 0, let ls = local,
               await api.syncLocalSession(id: ls.id, book: np.book, startedAt: ls.startedAt, startSec: ls.startSec,
                                          report: r, totalListened: ls.total + listened) {
                recorded = true
            }
        }
        // Applied only to the book that was reported (a newer load starts clean).
        if recorded, gen == loadGeneration {
            listenedSec = max(listenedSec - listened, 0)
            if session == nil { localSession?.total += listened }
            PlayHistory.shared.record(id, listened: listened)
        }
        if saved, let at = savedAt, localPosition(id)?.savedAt == at { markConfirmed(id) }
        failedSyncs = saved ? 0 : failedSyncs + 1
        library.recordLocal(id, sec: pos, total: np.totalSec, finished: finished)
        if gen == loadGeneration { persistUnsent() }
        if !saved { BackgroundTasks.schedulePush() }
        return saved
    }

    /// Lets a report finish after the app goes to the background.
    private func withBackgroundTime(_ work: @escaping () async -> Void) async {
        let id = UIApplication.shared.beginBackgroundTask(withName: "kitzi-report")
        await work()
        if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
    }

    /// The app is going to the background: report now, with time to finish.
    func appBackgrounded() {
        refreshPosition()
        tickEvery(2)
        if let np = nowPlaying, dirty || isPlaying, !serverCheckPending { saveLocal(np.book.id, position, finished: false) }
        accrue(stopping: !isPlaying)
        persistUnsent()
        Task { await withBackgroundTime { await self.report() } }
    }

    // MARK: unsent listening time (survives the app being killed)

    /// Listening the server hasn't recorded yet, per play. Replayed through
    /// /api/session/local (cumulative total, fixed id: retries are harmless).
    struct UnsentListening: Codable {
        var id: String
        var itemId: String
        var title: String
        var author: String?
        var startedAt: Int64
        var startSec: Double
        var recorded: Double
        var unsent: Double
        var lastPos: Double
        var duration: Double?
    }

    private var unsentRecords: [String: UnsentListening] {
        get { (Store.d.data(forKey: "unsent_listening").flatMap { try? JSONDecoder().decode([String: UnsentListening].self, from: $0) }) ?? [:] }
        set { Store.set(newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue), "unsent_listening") }
    }

    /// Saves this play's unsent listening (or clears it when everything was sent).
    private func persistUnsent() {
        guard let np = nowPlaying else { return }
        var all = unsentRecords
        let unsent = max(listenedSec, 0) + (audibleSince.map { max(CACurrentMediaTime() - $0, 0) } ?? 0)
        if unsent < 1 {
            all[unsentId] = nil
        } else {
            all[unsentId] = UnsentListening(
                id: unsentId, itemId: np.book.id, title: np.book.title, author: np.book.author,
                startedAt: localSession?.startedAt ?? Format.nowMs, startSec: localSession?.startSec ?? position,
                recorded: localSession?.total ?? 0, unsent: unsent, lastPos: position, duration: np.totalSec)
        }
        unsentRecords = all
    }

    /// Sends listening left over from earlier plays (app killed offline, …).
    private func flushUnsent() async {
        for (key, r) in unsentRecords where key != unsentId || nowPlaying == nil {
            let book = library.byId[r.itemId] ?? Book(id: r.itemId, title: r.title, author: r.author)
            let report = API.Report(itemId: r.itemId, currentSec: r.lastPos, durationSec: r.duration, finished: false,
                                    paused: true, listenedSec: r.unsent)
            guard await api.syncLocalSession(id: r.id, book: book, startedAt: r.startedAt, startSec: r.startSec,
                                             report: report, totalListened: r.recorded + r.unsent) else { return }
            PlayHistory.shared.record(r.itemId, listened: r.unsent)
            var all = unsentRecords
            all[key] = nil
            unsentRecords = all
        }
    }

    /// Positions or listening not on the server yet (sign-out warns about them).
    var pendingCount: Int {
        let positions = Store.d.dictionaryRepresentation().keys.filter { $0.hasPrefix("pos:") }
            .filter { localPosition(String($0.dropFirst(4)))?.pending == true }.count
        return positions + unsentRecords.count
    }

    // Local positions: "sec|savedAt|pending|finished".
    func localPosition(_ id: String) -> LocalPosition? {
        guard let s = Store.string("pos:\(id)") else { return nil }
        let p = s.split(separator: "|")
        guard p.count == 4, let sec = Double(p[0]), let at = Int64(p[1]) else { return nil }
        return LocalPosition(sec: sec, savedAt: at, pending: p[2] == "1", finished: p[3] == "1")
    }

    private func saveLocal(_ id: String, _ sec: Double, finished: Bool, pending: Bool = true) {
        Store.set("\(sec)|\(Format.nowMs)|\(pending ? 1 : 0)|\(finished ? 1 : 0)", "pos:\(id)")
    }

    private func markConfirmed(_ id: String) {
        guard var p = localPosition(id) else { return }
        p.pending = false
        Store.set("\(p.sec)|\(p.savedAt)|0|\(p.finished ? 1 : 0)", "pos:\(id)")
    }

    /// A position the server already has (mark finished/unfinished, undo).
    func recordConfirmed(_ id: String, sec: Double, finished: Bool) { saveLocal(id, sec, finished: finished, pending: false) }

    /// Pushes positions saved while offline. A newer server position wins. Skips
    /// the book that's playing (its own reports carry it).
    func flushPending() async {
        _ = await serialWrite { await self.performFlush(); return true }
    }

    private func performFlush() async {
        await flushUnsent()
        let loaded = nowPlaying?.book.id
        let ids = Store.d.dictionaryRepresentation().keys.filter { $0.hasPrefix("pos:") }.map { String($0.dropFirst(4)) }
        for id in ids {
            guard let local = localPosition(id), local.pending else { continue }
            if id == loaded {
                // The loaded book: through its own report path (it may be paused,
                // with a failed report still pending).
                if !isPlaying && !serverCheckPending { dirty = true; _ = await performReport(finished: false) }
                continue
            }
            let server: Progress?
            do { server = try await library.syncProgressFor(id) } catch { return } // offline: later
            if let s = server, s.lastUpdate > local.savedAt {
                // Newer elsewhere: theirs stands. If this device had got further
                // (offline), keep that spot in Play history so it isn't lost.
                if local.sec > s.currentTimeSec + 30 {
                    PlayHistory.shared.journal(id, position: local.sec, chapter: "Listened offline")
                }
                markConfirmed(id)
                continue
            }
            // Re-read: a newer local save while we waited wins.
            guard let current = localPosition(id), current.pending, current.savedAt == local.savedAt else { continue }
            let duration = server?.durationSec ?? library.byId[id]?.durationSec
            switch await api.saveProgressResult(API.Report(itemId: id, currentSec: local.sec, durationSec: duration,
                                                           finished: local.finished, paused: true, listenedSec: nil)) {
            case .unreachable: return
            case .refused: markConfirmed(id) // e.g. the book was deleted: don't block the others
            case .ok:
                if localPosition(id)?.savedAt == local.savedAt { markConfirmed(id) }
                library.recordLocal(id, sec: local.sec, total: duration, finished: local.finished)
            }
        }
    }

    func clearLocalPositions() {
        Store.removeAll(prefixes: ["pos:", "playback_speed:"])
        Store.set(nil, Store.lastItemKey)
        Store.set(nil, "unsent_listening")
    }
}
