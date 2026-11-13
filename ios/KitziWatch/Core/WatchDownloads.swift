import Foundation
import Observation
import UIKit
import WatchKit

/// Books saved on the watch: downloaded from the server with a background
/// URLSession, or sent from the iPhone (see WatchLink). watchOS picks the
/// connection itself — Wi-Fi, cellular if allowed, or the phone's Bluetooth link —
/// and may hold big transfers until the watch is charging.
@Observable
final class WatchDownloads {
    static let shared = WatchDownloads()

    enum State: Equatable { case none, queued, running(Double), failed, done }
    private(set) var states: [String: State] = [:]

    /// A book on its way: from the server (`remote` set) or from the phone.
    struct Plan: Codable {
        var manifest: WatchBookManifest
        var remote: [String]?
        var totalBytes: Int64
        var doneTracks: Set<Int> = []
    }
    private var plans: [String: Plan] = [:] { didSet { Store.set(try? JSONEncoder().encode(plans), "download_plans") } }
    private var written: [String: [Int: Int64]] = [:]
    private var attempts: [String: Int] = [:]

    nonisolated static let sessionId = "com.bennybar.kitzi.watch.downloads"
    /// Per track. Generous: big books over a watch's connection drop often, and
    /// each try resumes where the last one stopped.
    private static let maxAttempts = 8
    @ObservationIgnored private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionId)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        return URLSession(configuration: c, delegate: WatchDownloadDelegate(), delegateQueue: nil)
    }()
    /// watchOS woke the app for finished downloads: completed once they're handled.
    private var backgroundTasks: [WKURLSessionRefreshBackgroundTask] = []

    private init() {
        for id in (try? FileManager.default.contentsOfDirectory(atPath: Self.booksDir.path)) ?? []
        where FileManager.default.fileExists(atPath: Self.booksDir.appendingPathComponent("\(id)/book.json").path) {
            states[id] = .done
        }
        if let d = Store.d.data(forKey: "download_plans"), let p = try? JSONDecoder().decode([String: Plan].self, from: d) {
            plans = p
            for id in p.keys { states[id] = .queued }
        }
        _ = session // reconnect to the background session's tasks
        Task { await reconcile() }
    }

    /// After a relaunch: tracks that arrived while the app wasn't running count
    /// as done, and any the system no longer has are queued again.
    private func reconcile() async {
        let tasks = await session.allTasks
        var live: [String: Set<Int>] = [:]
        for t in tasks {
            guard let p = t.taskDescription?.split(separator: "|"), p.count >= 2, let i = Int(p[1]) else { continue }
            live[String(p[0]), default: []].insert(i)
        }
        for id in Array(plans.keys) {
            guard var plan = plans[id] else { continue }
            for (i, t) in plan.manifest.tracks.enumerated() where FileManager.default.fileExists(atPath: fileURL(for: t).path) {
                plan.doneTracks.insert(i)
            }
            plans[id] = plan
            if plan.doneTracks.count == plan.manifest.tracks.count { complete(id); continue }
            states[id] = .running(Double(plan.doneTracks.count) / Double(plan.manifest.tracks.count))
            // A book from the iPhone: the rest is still on its way from there.
            guard let remote = plan.remote else { continue }
            await API.shared.ensureFreshToken()
            for i in remote.indices where !plan.doneTracks.contains(i) && !(live[id]?.contains(i) ?? false) {
                queueTrack(id, i, resumeData: nil)
            }
        }
    }

    nonisolated static var booksDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("books")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: queries

    func state(_ id: String) -> State { states[id] ?? .none }
    func isDownloaded(_ id: String) -> Bool { states[id] == .done }
    var downloadedIds: [String] { states.filter { $0.value == .done }.map(\.key) }

    func downloaded(_ id: String) -> WatchBookManifest? {
        guard let d = try? Data(contentsOf: Self.booksDir.appendingPathComponent("\(id)/book.json")) else { return nil }
        return try? JSONDecoder().decode(WatchBookManifest.self, from: d)
    }

    func fileURL(for t: Track) -> URL { Self.booksDir.appendingPathComponent(t.url) }

    func coverFile(_ id: String) -> URL? {
        let u = Self.booksDir.appendingPathComponent("\(id)/cover.jpg")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    var totalBytes: Int64 {
        let files = FileManager.default.enumerator(at: Self.booksDir, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL] ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: from the server

    /// Plans and starts a book's download. Nil, or why it can't.
    @discardableResult
    func start(_ id: String) async -> String? {
        guard plans[id] == nil, states[id] != .done else { return nil }
        states[id] = .queued
        guard let item = try? await API.shared.item(id, expanded: true), let base = API.shared.base,
              let media = item.obj("media"), let book = Book.from(item) else {
            states[id] = .failed
            return "Couldn't reach the server. Check the connection."
        }
        let trackJson = media.objs("tracks").sorted { ($0.int("index") ?? 0) < ($1.int("index") ?? 0) }
        var sizes: [Int: Int64] = [:]
        for f in media.objs("audioFiles") { sizes[f.int("index") ?? -1] = Int64(f.obj("metadata")?.num("size") ?? 0) }
        var tracks: [Track] = [], remote: [String] = []
        for (i, t) in trackJson.enumerated() {
            guard let content = t.str("contentUrl") else { continue }
            let ext = (t.obj("metadata")?.str("ext") ?? "mp3").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            tracks.append(Track(index: i, url: "\(id)/track\(i).\(ext)", mimeType: t.str("mimeType") ?? "audio/mpeg",
                                durationSec: t.num("duration") ?? 0, isLocal: true))
            remote.append(content.hasPrefix("http") ? content : base + content)
        }
        guard !tracks.isEmpty else { states[id] = State.none; return "The server lists no audio for this book." }
        // Room for it, with some to spare for the system.
        let total = sizes.values.reduce(0, +)
        if let free = Self.freeBytes, total > 0, total + 300_000_000 > free {
            states[id] = State.none
            return "Not enough space on the watch: the book needs \(Format.size(total)) and \(Format.size(max(free - 300_000_000, 0))) is free."
        }
        var chapters = API.chapters(media.arr("chapters"))
        if chapters.isEmpty, tracks.count > 1 {
            var t = 0.0
            chapters = tracks.enumerated().map { i, tr in defer { t += tr.durationSec }; return Chapter(title: "Track \(i + 1)", startSec: t) }
        }
        try? FileManager.default.createDirectory(at: Self.booksDir.appendingPathComponent(id), withIntermediateDirectories: true)
        plans[id] = Plan(manifest: WatchBookManifest(book: book, tracks: tracks, chapters: chapters), remote: remote,
                         totalBytes: max(total, 1))
        await API.shared.ensureFreshToken()
        for i in remote.indices { queueTrack(id, i, resumeData: nil) }
        states[id] = .running(0)
        // The cover now, while there's a connection.
        Task { await fetchCover(id) }
        return nil
    }

    /// Space the watch can give the app for big files.
    static var freeBytes: Int64? {
        ((try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()))?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// JPEG: watchOS can't decode the WebP the server sends by default.
    private func fetchCover(_ id: String) async {
        guard let base = API.shared.base, let u = URL(string: "\(base)/api/items/\(id)/cover?width=400&format=jpeg"),
              let (data, resp) = try? await URLSession.shared.data(for: API.shared.authorized(u)),
              (resp as? HTTPURLResponse)?.statusCode == 200, UIImage(data: data) != nil else { return }
        let dir = Self.booksDir.appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try? data.write(to: dir.appendingPathComponent("cover.jpg"))
    }

    /// `after`: the retry backoff, kept by the system (it holds while the app is
    /// suspended or closed, where a timer in the app wouldn't run).
    private func queueTrack(_ id: String, _ i: Int, resumeData: Data?, after delay: Double = 0) {
        guard let plan = plans[id], let remote = plan.remote, remote.indices.contains(i), let u = URL(string: remote[i]) else { return }
        var req = API.shared.authorized(u)
        req.allowsCellularAccess = Store.downloadsUseCellular
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: req)
        task.taskDescription = "\(id)|\(i)|\(plan.manifest.tracks[i].url)"
        if delay > 0 { task.earliestBeginDate = Date().addingTimeInterval(delay) }
        task.resume()
    }

    /// The cellular setting changed: a queued request keeps the rule it was made
    /// with, so unfinished tracks start again with the new one.
    func cellularChanged() {
        let ids = plans.filter { $0.value.remote != nil }.map(\.key)
        guard !ids.isEmpty else { return }
        let s = session
        Task {
            for t in await s.allTasks { t.cancel() }
            for id in ids {
                guard let plan = plans[id], let remote = plan.remote else { continue }
                for i in remote.indices where !plan.doneTracks.contains(i) { queueTrack(id, i, resumeData: nil) }
            }
        }
    }

    func progress(_ id: String, track: Int, written w: Int64) {
        guard let plan = plans[id] else { return }
        written[id, default: [:]][track] = w
        let bytes = (written[id] ?? [:]).values.reduce(0, +)
        let byTracks = Double(plan.doneTracks.count) / Double(max(plan.manifest.tracks.count, 1))
        states[id] = .running(min(max(Double(bytes) / Double(plan.totalBytes), byTracks), 1))
    }

    func trackFinished(_ id: String, track: Int) {
        guard var plan = plans[id] else { return }
        plan.doneTracks.insert(track)
        plans[id] = plan
        if plan.doneTracks.count == plan.manifest.tracks.count {
            complete(id)
        } else {
            states[id] = .running(Double(plan.doneTracks.count) / Double(plan.manifest.tracks.count))
        }
    }

    /// Network trouble retries the track a few times; a refusal fails the book.
    func trackFailed(_ id: String, track: Int, httpCode: Int?, resumeData: Data?) {
        guard plans[id] != nil else { return }
        let key = "\(id)|\(track)"
        let n = (attempts[key] ?? 0) + 1
        attempts[key] = n
        guard n <= Self.maxAttempts else { failed(id); return }
        if httpCode == 401 {
            // An expired sign-in (the watch's own session): renew it, then again.
            Task {
                _ = await API.shared.refresh()
                queueTrack(id, track, resumeData: nil)
            }
            return
        }
        if let code = httpCode, (400..<500).contains(code), code != 408, code != 429 { failed(id); return }
        // A dropped connection carries on from where it stopped (resume data).
        queueTrack(id, track, resumeData: resumeData, after: min(Double(1 << n) * 5, 300))
    }

    private func failed(_ id: String) {
        cancelTasks(id)
        plans[id] = nil
        written[id] = nil
        states[id] = .failed
    }

    private func complete(_ id: String) {
        guard let plan = plans[id] else { return }
        try? JSONEncoder().encode(plan.manifest).write(to: Self.booksDir.appendingPathComponent("\(id)/book.json"), options: .atomic)
        plans[id] = nil
        written[id] = nil
        for k in attempts.keys where k.hasPrefix(id + "|") { attempts[k] = nil }
        states[id] = .done
    }

    // MARK: from the phone

    /// A track (or the cover) the iPhone sent, already moved to `file`.
    func received(_ id: String, index: Int?, manifest: WatchBookManifest?, file: URL) {
        let dir = Self.booksDir.appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let index, let manifest, manifest.tracks.indices.contains(index) else {
            // The cover.
            let dest = dir.appendingPathComponent("cover.jpg")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: file, to: dest)
            // The iPhone's copy is usually WebP, which watchOS can't decode: get a JPEG.
            if UIImage(contentsOfFile: dest.path) == nil {
                try? FileManager.default.removeItem(at: dest)
                Task { await fetchCover(id) }
            }
            return
        }
        guard states[id] != .done else { try? FileManager.default.removeItem(at: file); return }
        let dest = fileURL(for: manifest.tracks[index])
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.moveItem(at: file, to: dest)) != nil else { return }
        if plans[id] == nil {
            plans[id] = Plan(manifest: manifest, remote: nil, totalBytes: 1)
        }
        trackFinished(id, track: index)
    }

    // MARK: remove

    func cancel(_ id: String) { delete(id) }

    func delete(_ id: String) {
        if WatchPlayer.shared.nowPlaying?.book.id == id, WatchPlayer.shared.nowPlaying?.isLocal == true {
            Task { await WatchPlayer.shared.stop() ; removeNow(id) }
        } else {
            removeNow(id)
        }
    }

    private func removeNow(_ id: String) {
        cancelTasks(id)
        plans[id] = nil
        written[id] = nil
        try? FileManager.default.removeItem(at: Self.booksDir.appendingPathComponent(id))
        states[id] = State.none
    }

    private func cancelTasks(_ id: String) {
        let s = session
        Task {
            for t in await s.allTasks where t.taskDescription?.hasPrefix(id + "|") == true { t.cancel() }
        }
    }

    // MARK: background

    func hold(_ task: WKURLSessionRefreshBackgroundTask) {
        backgroundTasks.append(task)
        _ = session
    }

    func backgroundEventsFinished() {
        for t in backgroundTasks { t.setTaskCompletedWithSnapshot(false) }
        backgroundTasks = []
    }
}

/// URLSession's delegate runs off the main actor: the downloaded file must be
/// moved before the callback returns, then the rest happens on the main actor.
nonisolated final class WatchDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var lastSent: [Int: Date] = [:]

    private func parse(_ t: URLSessionTask) -> (String, Int, String)? {
        guard let p = t.taskDescription?.split(separator: "|", maxSplits: 2), p.count == 3, let i = Int(p[1]) else { return nil }
        return (String(p[0]), i, String(p[2]))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (id, i, rel) = parse(downloadTask) else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            Task { @MainActor in WatchDownloads.shared.trackFailed(id, track: i, httpCode: code, resumeData: nil) }
            return
        }
        let dest = WatchDownloads.booksDir.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            Task { @MainActor in WatchDownloads.shared.trackFinished(id, track: i) }
        } catch {
            Task { @MainActor in WatchDownloads.shared.trackFailed(id, track: i, httpCode: nil, resumeData: nil) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (id, i, _) = parse(downloadTask) else { return }
        let now = Date()
        if let last = lastSent[downloadTask.taskIdentifier], now.timeIntervalSince(last) < 1 { return }
        lastSent[downloadTask.taskIdentifier] = now
        Task { @MainActor in WatchDownloads.shared.progress(id, track: i, written: totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lastSent[task.taskIdentifier] = nil
        guard let error, let (id, i, _) = parse(task) else { return }
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled else { return }
        let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in WatchDownloads.shared.trackFailed(id, track: i, httpCode: nil, resumeData: resume) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in WatchDownloads.shared.backgroundEventsFinished() }
    }
}
