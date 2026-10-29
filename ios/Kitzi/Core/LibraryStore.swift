import Foundation
import Observation

/// The library: synced from the server into a local cache (JSON files per
/// library), with every list served from memory. Progress comes from the server
/// and from listening here (recordLocal), so lists update offline too.
@Observable
final class LibraryStore {
    static let shared = LibraryStore()
    private let api = API.shared

    private(set) var libraries: [LibraryInfo] = []
    private(set) var libraryId: String?
    private(set) var books: [Book] = []
    private(set) var byId: [String: Book] = [:]
    private(set) var progress: [String: Progress] = [:]
    var syncing = false
    /// Whether the last full sync reached the server.
    private(set) var lastSyncReachedServer = true
    /// The server's home shelves, when that setting is on and they loaded.
    private(set) var serverShelves: [HomeShelf]?
    /// Listening per day (yyyy-MM-dd → seconds), cached for the home tiles.
    private(set) var perDaySec: [String: Double] = [:]
    private(set) var totalListenedSec: Double = 0

    private init() {
        libraryId = Store.string(Store.libraryKey)
        if let id = libraryId { load(id) }
        perDaySec = (Store.d.dictionary(forKey: "stats_per_day") as? [String: Double]) ?? [:]
    }

    // MARK: persistence

    private func file(_ name: String, _ lib: String) -> URL { Store.supportDir.appendingPathComponent("\(name)_\(lib).json") }

    private func load(_ lib: String) {
        if let d = try? Data(contentsOf: file("books", lib)), let b = try? JSONDecoder().decode([Book].self, from: d) { setBooks(b) }
        if let d = try? Data(contentsOf: file("progress", lib)), let p = try? JSONDecoder().decode([String: Progress].self, from: d) { progress = p }
    }

    private func saveBooks() {
        guard let lib = libraryId else { return }
        try? JSONEncoder().encode(books).write(to: file("books", lib), options: .atomic)
    }

    private func saveProgress() {
        guard let lib = libraryId else { return }
        try? JSONEncoder().encode(progress).write(to: file("progress", lib), options: .atomic)
    }

    private func setBooks(_ list: [Book]) {
        books = list.filter(\.isAudioBook)
        byId = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: libraries

    /// Picks (on first run) or confirms the library. Prefers book libraries.
    func ensureLibrary() async {
        if let libs = try? await api.libraries() {
            libraries = libs.filter { $0.mediaType == "book" }
            if libraryId == nil || !libraries.contains(where: { $0.id == libraryId }) {
                if let first = libraries.first { await switchLibrary(first.id) }
            }
        }
    }

    func switchLibrary(_ id: String) async {
        libraryId = id
        Store.set(id, Store.libraryKey)
        books = []; byId = [:]; progress = [:]; serverShelves = nil
        load(id)
    }

    // MARK: sync

    /// Every page (newest first). A complete sweep can prune books deleted on the
    /// server; a partial one never does.
    func syncAll() async {
        guard let lib = libraryId else { return }
        syncing = true
        defer { syncing = false }
        let limit = 100
        var seen = Set<String>()
        var fetched: [Book] = []
        var paging: API.Paging = .page
        var complete = false
        var page = 1
        while page <= 200 {
            guard let r = try? await api.libraryItems(library: lib, page: page, limit: limit, sort: "addedAt", desc: true, paging: paging) else {
                lastSyncReachedServer = page > 1
                break
            }
            let fresh = r.items.compactMap(Book.from).filter { !seen.contains($0.id) }
            // A server that ignores `page` returns page 1 again: try the other styles.
            if page > 1 && fresh.isEmpty && !r.items.isEmpty {
                if paging == .page { paging = .offset; continue }
                if paging == .offset { paging = .skip; continue }
                break
            }
            fresh.forEach { seen.insert($0.id) }
            fetched += fresh
            if r.items.count < limit || (r.total.map { seen.count >= $0 } ?? false) { complete = true; break }
            page += 1
        }
        guard !fetched.isEmpty || complete else { return }
        lastSyncReachedServer = true
        var merged = complete ? [:] : byId
        for b in fetched { merged[b.id] = b }
        setBooks(merged.values.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) })
        saveBooks()
        Store.set(Date().timeIntervalSince1970, "last_full_sync_\(lib)")
    }

    /// A full sweep at most twice a day; otherwise just the newest page.
    func syncIfStale() async {
        guard let lib = libraryId else { return }
        let last = Store.double("last_full_sync_\(lib)") ?? 0
        if books.isEmpty || Date().timeIntervalSince1970 - last > 12 * 3600 { await syncAll() } else { await refreshNewest() }
    }

    /// The newest additions AND the most recently updated (edited metadata, a new
    /// cover) — between full sweeps, an edit to an older book would otherwise wait.
    func refreshNewest() async {
        guard let lib = libraryId else { return }
        var fetched: [JSON] = []
        for sort in ["addedAt", "updatedAt"] {
            if let r = try? await api.libraryItems(library: lib, page: 1, limit: 50, sort: sort, desc: true) { fetched += r.items }
        }
        guard !fetched.isEmpty, libraryId == lib else { return }
        var merged = byId
        for b in fetched.compactMap(Book.from) { merged[b.id] = b }
        setBooks(merged.values.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) })
        saveBooks()
    }

    /// Everything the home screen shows, refreshed: pending edits pushed first, so
    /// the pull already reflects them. [full] sweeps the whole library.
    func refreshAll(full: Bool) async {
        lastQuietRefresh = Date()
        await ensureLibrary()
        await Player.shared.flushPending()
        await flushPendingBookmarks()
        if full { await syncAll() } else { await syncIfStale() }
        await syncProgress()
        await loadListeningStats()
        await loadServerShelves()
    }

    @ObservationIgnored private var lastQuietRefresh = Date.distantPast

    /// On returning to the app and every 15 minutes while it's open: at most once
    /// every 3 minutes, so tab switches don't each cost a round of requests.
    func quietRefresh() async {
        guard Date().timeIntervalSince(lastQuietRefresh) > 180, Session.shared.signedIn else { return }
        lastQuietRefresh = Date()
        await Player.shared.flushPending()
        await flushPendingBookmarks()
        await refreshNewest()
        await syncProgress()
        await loadListeningStats()
        await loadServerShelves()
    }

    /// Progress for every book from /api/me. Rows the server no longer has are
    /// dropped (reset elsewhere), except downloaded books'.
    func syncProgress() async {
        guard let me = try? await api.me() else { return }
        let rows = me.objs("mediaProgress").compactMap(Progress.from)
        guard !rows.isEmpty else { return }
        var next: [String: Progress] = [:]
        for r in rows { next[r.itemId] = r }
        // Kept only while this device has a position the server hasn't got yet:
        // otherwise the server's reset (elsewhere) stands.
        for (id, p) in progress where next[id] == nil && Downloads.shared.isDownloaded(id)
            && Player.shared.localPosition(id)?.pending == true { next[id] = p }
        progress = next
        saveProgress()
        cacheBookmarks(me)
    }

    /// One book's progress (before playing it). nil = none on the server.
    @discardableResult
    func syncProgressFor(_ id: String) async throws -> Progress? {
        let m = try await api.mediaProgress(id)
        guard let m, let row = Progress.from(m) else {
            if progress[id] != nil { progress[id] = nil; saveProgress() }
            return nil
        }
        if progress[id] != row { progress[id] = row; saveProgress() }
        return row
    }

    /// What was just listened here, into the table the lists read.
    func recordLocal(_ id: String, sec: Double, total: Double?, finished: Bool) {
        let duration = total ?? progress[id]?.durationSec ?? byId[id]?.durationSec ?? 0
        let p = finished ? 1 : (duration > 0 ? min(max(sec / duration, 0), 1) : 0)
        progress[id] = Progress(itemId: id, progress: p, isFinished: finished, currentTimeSec: sec,
                                durationSec: duration, lastUpdate: Format.nowMs)
        saveProgress()
    }

    // MARK: lists

    var continueListening: [Book] {
        progress.values
            .filter { !$0.isFinished && $0.progress > 0 && !$0.hideFromContinueListening && byId[$0.itemId] != nil }
            .sorted { $0.lastUpdate > $1.lastUpdate }
            .prefix(20).compactMap { byId[$0.itemId] }
    }

    var recentlyAdded: [Book] { Array(books.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }.prefix(20)) }

    /// The next book in each series you've finished one of (not one you've started).
    var continueSeries: [Book] {
        let groups = Dictionary(grouping: books.filter { $0.series != nil }) { $0.series!.lowercased().trimmingCharacters(in: .whitespaces) }
        var picks: [(Int64, Book)] = []
        for (_, members) in groups {
            let ordered = members.sorted { a, b in
                switch (a.seriesSequence, b.seriesSequence) {
                case let (x?, y?): return x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.title.lowercased() < b.title.lowercased()
                }
            }
            guard let lastDone = ordered.lastIndex(where: { progress[$0.id]?.isFinished == true }) else { continue }
            guard let next = ordered.dropFirst(lastDone + 1).first(where: { progress[$0.id]?.isFinished != true }) else { continue }
            if (progress[next.id]?.progress ?? 0) > 0 { continue }
            picks.append((progress[ordered[lastDone].id]?.lastUpdate ?? 0, next))
        }
        return picks.sorted { $0.0 > $1.0 }.prefix(20).map(\.1)
    }

    func filtered(sort: BookSort, filter: BookFilter, search: String) -> [Book] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = books.filter { b in
            if !q.isEmpty {
                let hay = [b.title, b.author ?? "", b.series ?? "", b.narrators.joined(separator: " ")].joined(separator: " ").lowercased()
                if !hay.contains(q) { return false }
            }
            let p = progress[b.id]
            switch filter {
            case .all: return true
            case .inProgress: return p.map { !$0.isFinished && $0.progress > 0 } ?? false
            case .notStarted: return p.map { !$0.isFinished && $0.progress <= 0 } ?? true
            case .finished: return p?.isFinished == true
            case .downloaded: return Downloads.shared.isDownloaded(b.id)
            }
        }
        switch sort {
        case .addedDesc: return list.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        case .addedAsc: return list.sorted { ($0.addedAt ?? 0) < ($1.addedAt ?? 0) }
        case .titleAsc: return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .titleDesc: return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .authorAsc: return list.sorted { ($0.author ?? "~").localizedCaseInsensitiveCompare($1.author ?? "~") == .orderedAscending }
        case .updatedDesc: return list.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        case .durationDesc: return list.sorted { ($0.durationSec ?? 0) > ($1.durationSec ?? 0) }
        }
    }

    /// Books on the server matching a search (for books not cached yet).
    func searchServer(_ q: String) async -> [Book] {
        guard let lib = libraryId, let r = try? await api.search(library: lib, query: q) else { return [] }
        return r.compactMap(Book.from).filter(\.isAudioBook)
    }

    struct SeriesRow: Identifiable { var name: String; var books: [Book]; var id: String { name } }

    func series(minBooks: Int = 1) -> [SeriesRow] {
        Dictionary(grouping: books.filter { $0.series != nil }) { $0.series!.trimmingCharacters(in: .whitespaces) }
            .map { SeriesRow(name: $0.key, books: $0.value.sorted { ($0.seriesSequence ?? .infinity) < ($1.seriesSequence ?? .infinity) }) }
            .filter { $0.books.count >= minBooks }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func booksByAuthor(_ name: String) -> [Book] {
        books.filter { b in b.authors.contains(name) || (b.author ?? "").split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == name } }
            .sorted { ($0.series ?? $0.title) < ($1.series ?? $1.title) || (($0.series ?? "") == ($1.series ?? "") && ($0.seriesSequence ?? 0) < ($1.seriesSequence ?? 0)) }
    }

    /// Authors with their photos from the server; falls back to the local library.
    func authors() async -> [Author] {
        var counts: [String: Int] = [:]
        for b in books {
            let names = b.authors.isEmpty ? (b.author ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : b.authors
            for n in names where !n.isEmpty { counts[n, default: 0] += 1 }
        }
        var images: [String: (String, URL?)] = [:]
        if let lib = libraryId, let base = api.base, let list = try? await api.authors(library: lib) {
            for a in list {
                guard let n = a.str("name"), let id = a.str("id") else { continue }
                let url = a.str("imagePath") != nil ? URL(string: "\(base)/api/authors/\(id)/image?width=300") : nil
                images[n] = (id, url)
                authorIds[n] = id
            }
        }
        return counts.map { Author(id: images[$0.key]?.0, name: $0.key, bookCount: $0.value, imageURL: images[$0.key]?.1) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Author name → server id (filled by [authors]).
    @ObservationIgnored private var authorIds: [String: String] = [:]

    struct AuthorInfo { var name: String; var description: String?; var imageURL: URL? }

    /// An author's photo and bio from the server, or nil (offline, unknown author).
    func authorInfo(_ name: String) async -> AuthorInfo? {
        if authorIds[name] == nil { _ = await authors() }
        guard let id = authorIds[name], let base = api.base,
              let a = try? await api.getJSON("/api/authors/\(id)?include=items") as? JSON else { return nil }
        let image = a.str("imagePath") != nil ? URL(string: "\(base)/api/authors/\(id)/image?width=400") : nil
        return AuthorInfo(name: a.str("name") ?? name, description: a.str("description"), imageURL: image)
    }

    /// Books finished, from progress.
    var finishedCount: Int { progress.values.filter(\.isFinished).count }

    /// Server collections, then any `collection` metadata grouping not among them.
    func collections() async -> [SeriesRow] {
        var rows: [SeriesRow] = []
        if let lib = libraryId, let list = try? await api.collections(library: lib) {
            for c in list {
                guard let name = c.str("name") else { continue }
                let bs = c.objs("books").compactMap { byId[$0.str("id") ?? ""] ?? Book.from($0) }
                if !bs.isEmpty { rows.append(SeriesRow(name: name, books: bs)) }
            }
        }
        let have = Set(rows.map(\.name))
        let meta = Dictionary(grouping: books.filter { $0.collection != nil }) { $0.collection! }
            .filter { !have.contains($0.key) }
            .map { SeriesRow(name: $0.key, books: $0.value.sorted { ($0.collectionSequence ?? .infinity) < ($1.collectionSequence ?? .infinity) }) }
        return (rows + meta).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func playlists() async -> [SeriesRow] {
        guard let list = try? await api.playlists() else { return [] }
        return list.filter { $0.str("libraryId") == nil || $0.str("libraryId") == libraryId }.compactMap { p in
            guard let name = p.str("name") else { return nil }
            let bs = p.objs("items").filter { $0.str("episodeId") == nil }.compactMap { i -> Book? in
                guard let li = i.obj("libraryItem") else { return byId[i.str("libraryItemId") ?? ""] }
                return byId[li.str("id") ?? ""] ?? Book.from(li)
            }
            return bs.isEmpty ? nil : SeriesRow(name: name, books: bs)
        }
    }

    func loadServerShelves() async {
        guard AppSettings.shared.serverHomeShelves else { serverShelves = nil; return }
        guard let lib = libraryId, let list = try? await api.personalized(library: lib) else { return }
        serverShelves = list.filter { $0.str("type") == "book" }.compactMap { s in
            guard let label = s.str("label") else { return nil }
            let bs = s.objs("entities").compactMap { byId[$0.str("id") ?? ""] ?? Book.from($0) }
            return bs.isEmpty ? nil : HomeShelf(id: s.str("id") ?? label, label: label, books: bs)
        }
    }

    // MARK: stats

    func loadListeningStats() async {
        guard let s = try? await api.listeningStats() else { return }
        var days: [String: Double] = [:]
        for (k, v) in s.obj("days") ?? [:] { days[k] = (v as? NSNumber)?.doubleValue ?? 0 }
        perDaySec = days
        totalListenedSec = s.num("totalTime") ?? 0
        Store.set(days, "stats_per_day")
    }

    static func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    var todaySec: Double { perDaySec[Self.dayKey(Date())] ?? 0 }

    var streakDays: Int {
        // Not broken yet if today hasn't been listened to: count from yesterday.
        var day = Date(), n = 0
        if (perDaySec[Self.dayKey(day)] ?? 0) <= 0 { day = Calendar.current.date(byAdding: .day, value: -1, to: day)! }
        while (perDaySec[Self.dayKey(day)] ?? 0) > 0 { n += 1; day = Calendar.current.date(byAdding: .day, value: -1, to: day)! }
        return n
    }

    var bestStreak: Int {
        let days = perDaySec.filter { $0.value > 0 }.keys.sorted()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        var best = 0, run = 0
        var prev: Date?
        for k in days {
            guard let d = f.date(from: k) else { continue }
            if let p = prev, Calendar.current.date(byAdding: .day, value: 1, to: p) == d { run += 1 } else { run = 1 }
            best = max(best, run); prev = d
        }
        return best
    }

    var weekSec: Double {
        (0..<7).reduce(0) { $0 + (perDaySec[Self.dayKey(Calendar.current.date(byAdding: .day, value: -$1, to: Date())!)] ?? 0) }
    }

    /// Time left in the books in progress, at the current speed.
    var leftInProgressSec: Double {
        let speed = max(Store.double("playback_speed") ?? 1, 0.1)
        return continueListening.reduce(0) { sum, b in
            let p = progress[b.id]
            let d = (p?.durationSec ?? 0) > 0 ? p!.durationSec : (b.durationSec ?? 0)
            return sum + max(d - (p?.currentTimeSec ?? 0), 0)
        } / speed
    }

    // MARK: finished

    /// Mark (un)finished on the server, then here. Stops the book first if playing.
    func setFinished(_ id: String, _ finished: Bool) async -> Bool {
        if Player.shared.nowPlaying?.book.id == id { await Player.shared.stop() }
        let existing = progress[id]
        let duration = (existing?.durationSec ?? 0) > 0 ? existing!.durationSec : (byId[id]?.durationSec ?? 0)
        // Through the player's serial write queue: no older report can land after it.
        let api = self.api
        guard await Player.shared.serialWrite({ await api.setFinished(id, finished: finished, durationSec: duration > 0 ? duration : nil) })
        else { return false }
        let pos = finished ? duration : 0
        progress[id] = Progress(itemId: id, progress: finished ? 1 : 0, isFinished: finished, currentTimeSec: pos,
                                durationSec: duration, lastUpdate: Format.nowMs)
        saveProgress()
        Player.shared.recordConfirmed(id, sec: pos, finished: finished)
        if finished && AppSettings.shared.autoDeleteOnFinish { Downloads.shared.delete(id) }
        return true
    }

    /// Puts progress back exactly (the Undo for marking finished).
    func restoreProgress(_ previous: Progress?, _ id: String) async -> Bool {
        let prev = previous ?? Progress(itemId: id, progress: 0, isFinished: false, currentTimeSec: 0,
                                        durationSec: byId[id]?.durationSec ?? 0, lastUpdate: Format.nowMs)
        let api = self.api
        let report = API.Report(itemId: id, currentSec: prev.currentTimeSec, durationSec: prev.durationSec > 0 ? prev.durationSec : nil,
                                finished: prev.isFinished, paused: true, listenedSec: nil)
        let ok = await Player.shared.serialWrite { await api.saveProgress(report) }
        if ok {
            var p = prev; p.lastUpdate = Format.nowMs
            progress[id] = p
            saveProgress()
            Player.shared.recordConfirmed(id, sec: prev.currentTimeSec, finished: prev.isFinished)
        }
        return ok
    }

    // MARK: bookmarks (offline edits queued and replayed later)

    struct BookmarkOp: Codable { var kind: String; var itemId: String; var timeSec: Double; var title: String }

    private var pendingOps: [BookmarkOp] {
        get { (Store.d.data(forKey: "pending_bookmark_ops").flatMap { try? JSONDecoder().decode([BookmarkOp].self, from: $0) }) ?? [] }
        set { Store.set(newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue), "pending_bookmark_ops") }
    }

    private func cacheBookmarks(_ me: JSON) {
        let all = me.objs("bookmarks").compactMap { b -> Bookmark? in
            guard let id = b.str("libraryItemId"), let t = b.num("time") else { return nil }
            return Bookmark(itemId: id, timeSec: t, title: b.str("title") ?? "Bookmark", createdAt: b.epochMs("createdAt") ?? 0)
        }
        for (id, list) in Dictionary(grouping: all, by: \.itemId) { saveCached(id, list) }
    }

    private func cached(_ id: String) -> [Bookmark] {
        (Store.d.data(forKey: "bookmarks_cache:\(id)").flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) }) ?? []
    }
    private func saveCached(_ id: String, _ list: [Bookmark]) { Store.set(try? JSONEncoder().encode(list), "bookmarks_cache:\(id)") }

    private func apply(_ list: [Bookmark], _ op: BookmarkOp) -> [Bookmark] {
        switch op.kind {
        case "add": return list.filter { $0.timeSec != op.timeSec } + [Bookmark(itemId: op.itemId, timeSec: op.timeSec, title: op.title, createdAt: Format.nowMs)]
        case "rename": return list.map { $0.timeSec == op.timeSec ? Bookmark(itemId: $0.itemId, timeSec: $0.timeSec, title: op.title, createdAt: $0.createdAt) : $0 }
        default: return list.filter { $0.timeSec != op.timeSec }
        }
    }

    func bookmarks(_ id: String) async -> [Bookmark] {
        if let me = try? await api.me() {
            cacheBookmarks(me)
            if !me.objs("bookmarks").contains(where: { $0.str("libraryItemId") == id }) { saveCached(id, []) }
        }
        return pendingOps.filter { $0.itemId == id }.reduce(cached(id)) { apply($0, $1) }.sorted { $0.timeSec < $1.timeSec }
    }

    /// True when the server has it already; false = saved here and queued.
    @discardableResult
    func bookmarkOp(_ op: BookmarkOp) async -> Bool {
        let sent = pendingOps.isEmpty ? await send(op) : false
        if sent { saveCached(op.itemId, apply(cached(op.itemId), op)) } else { pendingOps.append(op) }
        return sent
    }

    private func send(_ op: BookmarkOp) async -> Bool {
        switch op.kind {
        case "add": await api.addBookmark(op.itemId, time: op.timeSec, title: op.title)
        case "rename": await api.renameBookmark(op.itemId, time: op.timeSec, title: op.title)
        default: await api.deleteBookmark(op.itemId, time: op.timeSec)
        }
    }

    /// Sends queued edits, oldest first. Offline: stop and try later. Online but
    /// refused (a rename of a bookmark deleted elsewhere): drop that edit — kept,
    /// it would block every later one forever.
    func flushPendingBookmarks() async {
        var ops = pendingOps
        while let op = ops.first {
            if await send(op) {
                saveCached(op.itemId, apply(cached(op.itemId), op))
            } else if !Player.shared.online {
                return
            }
            ops.removeFirst()
            pendingOps = ops
        }
    }

    // MARK: sign out

    /// Everything that belonged to the account: every library's cached books and
    /// progress, the stats, queued bookmark edits, the covers. Downloads stay.
    func clearForSignOut() {
        let dir = Store.supportDir
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where (name.hasPrefix("progress_") || name.hasPrefix("books_")) && name.hasSuffix(".json") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        libraries = []
        libraryId = nil
        books = []
        byId = [:]
        progress = [:]
        serverShelves = nil
        perDaySec = [:]
        totalListenedSec = 0
        authorIds = [:]
        Store.set(nil, Store.libraryKey)
        Store.set(nil, "stats_per_day")
        Store.set(nil, "pending_bookmark_ops")
        Store.removeAll(prefixes: ["bookmarks_cache:", "last_full_sync_"])
        ImageLoader.shared.clearDisk()
    }

    /// Queued edits only (a different account signed in on this device).
    func clearPendingEdits() {
        Store.set(nil, "pending_bookmark_ops")
    }
}
