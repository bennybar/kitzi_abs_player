import ActivityKit
import Foundation
import Network
import Observation
import UIKit

/// A book saved on the device: what's needed to play it with no network.
struct DownloadedBook: Codable {
    var book: Book
    var tracks: [Track]   // url = path relative to the books folder
    var chapters: [Chapter]
}

/// Downloads books with a BACKGROUND URLSession, so they continue (and finish)
/// while Kitzi is suspended or closed. Progress shows in a Live Activity — the
/// Dynamic Island and Lock Screen — which ends as soon as the downloads do.
@Observable
final class Downloads {
    static let shared = Downloads()

    /// `.waiting`: Wi-Fi only is on and there's no Wi-Fi right now.
    enum State: Equatable { case none, queued, running(Double), waiting(Double), failed, done }
    private(set) var states: [String: State] = [:]

    /// A book being downloaded: its tracks, and bytes per task for the progress.
    struct Plan: Codable {
        var book: Book
        var chapters: [Chapter]
        var tracks: [Track]          // url = relative path once done
        var remote: [String]         // absolute URL per track
        var totalBytes: Int64
        var doneTracks: Set<Int> = []
    }
    private var plans: [String: Plan] = [:] { didSet { savePlans() } }
    private var written: [String: [Int: Int64]] = [:]
    /// Failed attempts per track ("id|index"), for the retry backoff.
    private var attempts: [String: Int] = [:]
    /// Cover fetches still running (awaited before telling iOS we're done).
    private var coverTasks: [String: Task<Void, Never>] = [:]
    /// What the last download that ended did, for the Live Activity's final line.
    private(set) var lastOutcome: (text: String, failed: Bool)?
    /// Whether the device is on Wi-Fi (or wired) right now.
    private(set) var onWiFi = true
    private let pathMonitor = NWPathMonitor()

    nonisolated static let sessionId = "com.bennybar.kitzi.downloads"
    @ObservationIgnored private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.allowsCellularAccess = true
        return URLSession(configuration: c, delegate: DownloadDelegate(), delegateQueue: nil)
    }()
    /// iOS's completion handler when it relaunched us for finished downloads.
    var backgroundCompletion: (() -> Void)?

    private static let maxAttempts = 4

    private init() {
        // Re-downloadable audio must not fill the user's iCloud backup.
        var dir = Self.booksDir
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)

        for id in (try? FileManager.default.contentsOfDirectory(atPath: Self.booksDir.path)) ?? []
        where FileManager.default.fileExists(atPath: Self.booksDir.appendingPathComponent("\(id)/book.json").path) {
            states[id] = .done
        }
        if let d = Store.d.data(forKey: "download_plans"), let p = try? JSONDecoder().decode([String: Plan].self, from: d) {
            plans = p
            for id in p.keys { states[id] = .queued }
        }
        Self.watchNetwork(pathMonitor)
        _ = session // reconnect to the background session's tasks
        Task { await reconcile() }
    }

    nonisolated static var booksDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("books")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// The monitor calls back on its own queue: the handler mustn't be main-actor code.
    nonisolated private static func watchNetwork(_ monitor: NWPathMonitor) {
        monitor.pathUpdateHandler = { path in
            let wifi = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in Downloads.shared.networkChanged(wifi: wifi) }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    private func networkChanged(wifi: Bool) {
        guard wifi != onWiFi else { return }
        onWiFi = wifi
        for id in plans.keys { setActive(id) }
        LiveActivity.shared.refresh()
    }

    private func savePlans() { Store.set(plans.isEmpty ? nil : try? JSONEncoder().encode(plans), "download_plans") }

    /// Running, or waiting for Wi-Fi when that's what's holding it up.
    private func setActive(_ id: String) {
        let f = fraction(id)
        states[id] = (AppSettings.shared.wifiOnlyDownloads && !onWiFi) ? .waiting(f) : .running(f)
    }

    private var waitingForWiFi: Bool { AppSettings.shared.wifiOnlyDownloads && !onWiFi }

    // MARK: queries

    func state(_ id: String) -> State { states[id] ?? .none }
    func isDownloaded(_ id: String) -> Bool { states[id] == .done }

    func downloaded(_ id: String) -> DownloadedBook? {
        guard let d = try? Data(contentsOf: Self.booksDir.appendingPathComponent("\(id)/book.json")) else { return nil }
        return try? JSONDecoder().decode(DownloadedBook.self, from: d)
    }

    func fileURL(for t: Track) -> URL { Self.booksDir.appendingPathComponent(t.url) }

    func localCover(_ id: String) -> URL? {
        let u = Self.booksDir.appendingPathComponent("\(id)/cover.jpg")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    var downloadedIds: [String] { states.filter { $0.value == .done }.map(\.key) }

    func bytes(_ id: String) -> Int64 {
        let dir = Self.booksDir.appendingPathComponent(id)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    var totalBytes: Int64 { downloadedIds.reduce(0) { $0 + bytes($1) } }

    // MARK: actions

    /// Plans and starts a book's download. False if the server lists no audio.
    /// Starting a failed book again keeps the tracks it already has.
    @discardableResult
    func start(_ id: String) async -> Bool {
        guard plans[id] == nil, states[id] != .done else { return true }
        states[id] = .queued
        guard let item = try? await API.shared.item(id, expanded: true), let base = API.shared.base,
              let media = item.obj("media") else { states[id] = .failed; return false }
        var book = Book.from(item) ?? LibraryStore.shared.byId[id]
        book?.isAudioBook = true
        let trackJson = media.objs("tracks").sorted { ($0.int("index") ?? 0) < ($1.int("index") ?? 0) }
        guard let book, !trackJson.isEmpty else { states[id] = Optional.none; return false }
        var sizes: [Int: Int64] = [:]
        for f in media.objs("audioFiles") { sizes[f.int("index") ?? -1] = Int64(f.obj("metadata")?.num("size") ?? 0) }
        var tracks: [Track] = [], remote: [String] = []
        for (i, t) in trackJson.enumerated() {
            let ext = (t.obj("metadata")?.str("ext") ?? "mp3").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard let content = t.str("contentUrl") else { continue }
            tracks.append(Track(index: i, url: "\(id)/track\(i).\(ext)", mimeType: t.str("mimeType") ?? "audio/mpeg",
                                durationSec: t.num("duration") ?? 0, isLocal: true))
            remote.append(content.hasPrefix("http") ? content : base + content)
        }
        let total = max(sizes.values.reduce(0, +), 1)
        var chapters = API.chapters(media.arr("chapters"))
        if chapters.isEmpty { chapters = Player.trackChapters(tracks) }
        plans[id] = Plan(book: book, chapters: chapters, tracks: tracks, remote: remote, totalBytes: total)
        try? FileManager.default.createDirectory(at: Self.booksDir.appendingPathComponent(id), withIntermediateDirectories: true)
        enqueueTasks(id)
        LiveActivity.shared.refresh()
        return true
    }

    /// Queues every track not on disk yet. Tracks already downloaded (a retry, a
    /// relaunch) are counted as done instead of being fetched again.
    private func enqueueTasks(_ id: String) {
        guard var plan = plans[id] else { return }
        for (i, t) in plan.tracks.enumerated() where !plan.doneTracks.contains(i) {
            if FileManager.default.fileExists(atPath: fileURL(for: t).path) { plan.doneTracks.insert(i) }
        }
        plans[id] = plan
        if plan.doneTracks.count == plan.tracks.count { complete(id); return }
        for i in plan.remote.indices where !plan.doneTracks.contains(i) { queueTrack(id, i, resumeData: nil) }
        setActive(id)
    }

    /// One track, with a token fetched NOW (never one baked in long ago).
    private func queueTrack(_ id: String, _ i: Int, resumeData: Data?) {
        guard let plan = plans[id], plan.remote.indices.contains(i), !plan.doneTracks.contains(i),
              let u = URL(string: plan.remote[i]) else { return }
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var req = API.shared.authorized(u)
            req.allowsCellularAccess = !AppSettings.shared.wifiOnlyDownloads
            task = session.downloadTask(with: req)
        }
        task.taskDescription = "\(id)|\(i)|\(plan.tracks[i].url)"
        task.resume()
    }

    /// The Wi-Fi only setting changed: re-queue unfinished tracks with the new rule
    /// (a queued request keeps the rule it was created with).
    func wifiOnlyChanged() {
        let ids = Array(plans.keys)
        guard !ids.isEmpty else { return }
        let s = session
        Task {
            for t in await s.allTasks {
                if let id = t.taskDescription?.split(separator: "|").first.map(String.init), ids.contains(id) { t.cancel() }
            }
            for id in ids { enqueueTasks(id) }
            LiveActivity.shared.refresh()
        }
    }

    func cancel(_ id: String) {
        // A downloaded book that's playing from these files: stop it first.
        if let np = Player.shared.nowPlaying, np.book.id == id, np.isLocal {
            states[id] = Optional.none
            Task {
                await Player.shared.stop(keepLast: true)
                removeNow(id)
            }
        } else {
            removeNow(id)
        }
    }

    private func removeNow(_ id: String) {
        let wasActive = plans[id] != nil
        cancelTasks(id)
        plans[id] = nil
        written[id] = nil
        clearAttempts(id)
        try? FileManager.default.removeItem(at: Self.booksDir.appendingPathComponent(id))
        states[id] = Optional.none
        if wasActive { lastOutcome = ("Download cancelled", true) }
        LiveActivity.shared.refresh()
    }

    private func cancelTasks(_ id: String) {
        let s = session
        Task {
            for t in await s.allTasks where t.taskDescription?.hasPrefix(id + "|") == true { t.cancel() }
        }
    }

    private func clearAttempts(_ id: String) {
        for k in attempts.keys where k.hasPrefix(id + "|") { attempts[k] = nil }
    }

    func delete(_ id: String) { cancel(id) }

    func deleteAll() { for id in Array(states.keys) { delete(id) } }

    /// Tasks iOS still has, matched to plans (after a relaunch).
    private func reconcile() async {
        let tasks = await session.allTasks
        var live: [String: Set<Int>] = [:]
        for t in tasks {
            guard let p = t.taskDescription?.split(separator: "|"), p.count >= 2, let i = Int(p[1]) else { continue }
            live[String(p[0]), default: []].insert(i)
        }
        for id in Array(plans.keys) {
            guard var plan = plans[id] else { continue }
            // Tracks whose file arrived while we weren't running count as done.
            for (i, t) in plan.tracks.enumerated() where FileManager.default.fileExists(atPath: fileURL(for: t).path) {
                plan.doneTracks.insert(i)
            }
            plans[id] = plan
            if plan.doneTracks.count == plan.tracks.count { complete(id); continue }
            for i in plan.remote.indices where !plan.doneTracks.contains(i) && !(live[id]?.contains(i) ?? false) {
                queueTrack(id, i, resumeData: nil)
            }
            setActive(id)
        }
        LiveActivity.shared.refresh()
    }

    // MARK: delegate callbacks (on the main actor)

    func progress(_ id: String, track: Int, written w: Int64) {
        guard plans[id] != nil else { return }
        written[id, default: [:]][track] = w
        setActive(id)
        LiveActivity.shared.refresh()
    }

    private func fraction(_ id: String) -> Double {
        guard let p = plans[id] else { return 0 }
        let bytes = (written[id] ?? [:]).values.reduce(0, +)
        let byTracks = Double(p.doneTracks.count) / Double(max(p.tracks.count, 1))
        return min(max(Double(bytes) / Double(p.totalBytes), byTracks), 1)
    }

    func finished(_ id: String, track: Int) {
        guard var p = plans[id] else { return }
        p.doneTracks.insert(track)
        plans[id] = p
        attempts["\(id)|\(track)"] = nil
        if p.doneTracks.count == p.tracks.count { complete(id) } else { setActive(id) }
        LiveActivity.shared.refresh()
    }

    /// One track failed. Network trouble and server errors retry the TRACK (with
    /// backoff, from where it stopped when iOS kept resume data); an expired token
    /// is renewed first. Only a real refusal, or too many tries, fails the book.
    func trackFailed(_ id: String, track: Int, httpCode: Int?, resumeData: Data?) {
        guard plans[id] != nil else { return }
        let key = "\(id)|\(track)"
        let n = (attempts[key] ?? 0) + 1
        attempts[key] = n
        if let code = httpCode, (400..<500).contains(code), code != 401, code != 408, code != 429 {
            failed(id); return
        }
        guard n <= Self.maxAttempts else { failed(id); return }
        if httpCode == 401 {
            Task {
                _ = await API.shared.refresh()
                queueTrack(id, track, resumeData: nil)
            }
            return
        }
        let delay = Double(1 << n) * 5 // 10 s, 20 s, 40 s, 80 s
        Task {
            try? await Task.sleep(for: .seconds(delay))
            queueTrack(id, track, resumeData: resumeData)
        }
    }

    /// The book can't be downloaded: its other tracks stop too. Tracks already on
    /// disk stay, so a retry only fetches the rest.
    func failed(_ id: String) {
        guard let p = plans[id] else { return }
        cancelTasks(id)
        plans[id] = nil
        written[id] = nil
        clearAttempts(id)
        states[id] = .failed
        lastOutcome = ("Download failed: \(p.book.title)", true)
        LiveActivity.shared.refresh()
    }

    private func complete(_ id: String) {
        guard let p = plans[id] else { return }
        let manifest = DownloadedBook(book: p.book, tracks: p.tracks, chapters: p.chapters)
        try? JSONEncoder().encode(manifest).write(to: Self.booksDir.appendingPathComponent("\(id)/book.json"), options: .atomic)
        plans[id] = nil
        written[id] = nil
        clearAttempts(id)
        states[id] = .done
        lastOutcome = ("Downloaded \(p.book.title)", false)
        // The cover, for offline lists and the lock screen.
        if let u = p.book.coverURL(width: 1000) {
            let dest = Self.booksDir.appendingPathComponent("\(id)/cover.jpg")
            coverTasks[id] = Task {
                let req = API.shared.authorized(u)
                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200 {
                    try? data.write(to: dest)
                }
                coverTasks[id] = nil
            }
        }
    }

    /// Live Activity input: the book downloading now and how many wait behind it.
    var activeSummary: (title: String, fraction: Double, queued: Int, waiting: Bool)? {
        let active = plans.keys.sorted()
        guard let first = active.first, let p = plans[first] else { return nil }
        return (p.book.title, fraction(first), active.count - 1, waitingForWiFi)
    }

    /// iOS relaunched us for finished downloads and delivered every event. Finish the
    /// covers and END the Live Activity (awaited, inside a background task) before
    /// handing control back — after that the app may be suspended at once.
    func backgroundEventsFinished() {
        let app = UIApplication.shared
        let bg = BackgroundTaskBox()
        bg.id = app.beginBackgroundTask(withName: "kitzi.downloads.finish") { bg.end() }
        Task {
            for t in Array(coverTasks.values) { await t.value }
            await LiveActivity.shared.sync()
            backgroundCompletion?()
            backgroundCompletion = nil
            bg.end()
        }
    }
}

/// A background-task id that ends exactly once (from expiry or completion).
final class BackgroundTaskBox {
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// URLSession's delegate runs off the main actor (on the session's serial queue):
/// the downloaded file must be moved before the callback returns, then the rest
/// happens on the main actor.
nonisolated final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Last progress sent per task — progress is throttled so a fast download
    /// doesn't flood the main actor with one hop per network packet.
    private var lastSent: [Int: (at: Date, bytes: Int64)] = [:]

    private func parse(_ t: URLSessionTask) -> (String, Int, String)? {
        guard let p = t.taskDescription?.split(separator: "|", maxSplits: 2), p.count == 3, let i = Int(p[1]) else { return nil }
        return (String(p[0]), i, String(p[2]))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (id, i, rel) = parse(downloadTask) else { return }
        lastSent[downloadTask.taskIdentifier] = nil
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            Task { @MainActor in Downloads.shared.trackFailed(id, track: i, httpCode: code, resumeData: nil) }
            return
        }
        let dest = Downloads.booksDir.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor in Downloads.shared.finished(id, track: i) }
        } catch {
            Task { @MainActor in Downloads.shared.trackFailed(id, track: i, httpCode: nil, resumeData: nil) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (id, i, _) = parse(downloadTask) else { return }
        let now = Date()
        let step = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite / 100 : 1_000_000
        if let last = lastSent[downloadTask.taskIdentifier],
           now.timeIntervalSince(last.at) < 0.5, totalBytesWritten - last.bytes < step { return }
        lastSent[downloadTask.taskIdentifier] = (now, totalBytesWritten)
        Task { @MainActor in Downloads.shared.progress(id, track: i, written: totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lastSent[task.taskIdentifier] = nil
        guard let error, let (id, i, _) = parse(task) else { return }
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in Downloads.shared.trackFailed(id, track: i, httpCode: nil, resumeData: resume) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in Downloads.shared.backgroundEventsFinished() }
    }
}

/// The downloads Live Activity: started with the first download, updated as they
/// progress, and ended (after a brief final line) when nothing is left — so it
/// never lingers in the Dynamic Island.
final class LiveActivity {
    static let shared = LiveActivity()
    private var activityId: String?
    private var lastUpdate = Date.distantPast
    private var endTask: Task<Void, Never>?

    private init() {
        // Leftovers from a previous run (the app was killed mid-download): adopted if
        // downloads are still planned, else ended by the first refresh.
        activityId = Activity<DownloadActivityAttributes>.activities.first?.id
    }

    /// Updates are marked stale after two minutes: while iOS keeps the app
    /// suspended no progress arrives, and a stale activity says so.
    private var staleDate: Date { .now + 120 }

    func refresh() {
        guard let s = Downloads.shared.activeSummary else {
            if activityId != nil || !Activity<DownloadActivityAttributes>.activities.isEmpty {
                endTask = Task { await end() }
            }
            return
        }
        let state = DownloadActivityAttributes.ContentState(
            title: s.waiting ? "\(s.title) · waiting for Wi-Fi" : s.title,
            fraction: s.fraction, queued: s.queued, done: false, failed: false)
        if let id = activityId, Activity<DownloadActivityAttributes>.activities.contains(where: { $0.id == id }) {
            // At most once a second: Live Activity updates are budgeted.
            guard Date().timeIntervalSince(lastUpdate) > 1 else { return }
            lastUpdate = Date()
            let stale = staleDate
            Task {
                for act in Activity<DownloadActivityAttributes>.activities where act.id == id {
                    await act.update(ActivityContent(state: state, staleDate: stale))
                }
            }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            activityId = (try? Activity.request(attributes: DownloadActivityAttributes(),
                                                content: ActivityContent(state: state, staleDate: staleDate)))?.id
            lastUpdate = Date()
        }
    }

    /// Brings the activity in line with the downloads and waits until it's done
    /// (used before handing a background relaunch back to iOS).
    func sync() async {
        refresh()
        await endTask?.value
    }

    /// Shows the outcome for a few seconds, then removes every Kitzi activity.
    private func end() async {
        let id = activityId
        activityId = nil
        let outcome = Downloads.shared.lastOutcome ?? ("Downloads finished", false)
        let final = DownloadActivityAttributes.ContentState(title: outcome.text, fraction: outcome.failed ? 0 : 1,
                                                            queued: 0, done: true, failed: outcome.failed)
        for act in Activity<DownloadActivityAttributes>.activities {
            if act.id == id {
                await act.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .after(.now + 4))
            } else {
                await act.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
