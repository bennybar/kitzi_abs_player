import Foundation
import Observation
import UserNotifications

/// Watches for what's new: books just out (or coming) from the library's authors,
/// the next books of its series, and followed narrators (the "radar"); and
/// Shelfarr requests that have arrived. Checked in the background a few times a
/// day and when the app opens; each find is notified once.
@Observable
final class Radar {
    static let shared = Radar()

    /// A book on Audible that's new or coming, and why it's here.
    struct Find: Codable, Identifiable, Hashable {
        var asin: String
        var title: String
        var author: String?
        var cover: String?
        var releaseDate: String?
        /// "New from Andy Weir", "Book 4 of The Expanse", "Narrated by Ray Porter".
        var reason: String
        var foundAt: Double
        /// Notified as out (after being notified as coming).
        var announcedOut = false
        var id: String { asin }

        var releaseDay: Date? { releaseDate.flatMap { Self.day.date(from: String($0.prefix(10))) } }
        var isUpcoming: Bool { (releaseDay ?? .distantPast) > Date() }
        private static let day: DateFormatter = {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
        }()
    }

    private(set) var finds: [Find] = []
    private(set) var checking = false
    var followedNarrators: Set<String> {
        didSet { Store.set(Array(followedNarrators), "radar_narrators") }
    }

    private init() {
        followedNarrators = Set(Store.d.stringArray(forKey: "radar_narrators") ?? [])
        if let d = Store.d.data(forKey: "radar_finds"), let f = try? JSONDecoder().decode([Find].self, from: d) { finds = f }
    }

    private func save() { Store.set(try? JSONEncoder().encode(finds), "radar_finds") }

    /// Newest release first; upcoming after the recent ones.
    var sortedFinds: [Find] {
        finds.sorted { a, b in
            if a.isUpcoming != b.isUpcoming { return !a.isUpcoming }
            let (x, y) = (a.releaseDay ?? .distantPast, b.releaseDay ?? .distantPast)
            return a.isUpcoming ? x < y : x > y
        }
    }

    // MARK: checking

    /// Both checks, if they're on and due: Shelfarr at most every 3 minutes, the
    /// radar at most every 12 hours (24 from a background refresh, whose time is
    /// short), or now when `force`.
    @MainActor
    func checkAll(force: Bool = false, background: Bool = false) async {
        guard Session.shared.signedIn else { return }
        let now = Date().timeIntervalSince1970
        if AppSettings.shared.notifyShelfarr, force || now - (Store.double("shelfarr_checked_at") ?? 0) > 180 {
            Store.set(now, "shelfarr_checked_at")
            await checkShelfarr()
        }
        if AppSettings.shared.radar {
            let last = Store.double("radar_checked_at") ?? 0
            if force || now - last > (background ? 24 : 12) * 3600 { await checkReleases() }
        }
    }

    /// Books from the library's authors, its series and followed narrators that
    /// came out in the last six weeks or are coming in the next six months, and
    /// aren't in the library.
    @MainActor
    func checkReleases() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let library = LibraryStore.shared
        let now = Date()
        guard let from = Calendar.current.date(byAdding: .day, value: -42, to: now),
              let until = Calendar.current.date(byAdding: .month, value: 6, to: now) else { return }
        // The library's language (most of its Audible matches'): an author's newest
        // list is often their old books re-released in translation.
        // (Worked out once and kept: it reads every book's saved match.)
        var language = Store.string("radar_language") ?? ""
        if language.isEmpty {
            var langs: [String: Int] = [:]
            for b in library.books { if let l = AudibleRating.shared.knownLanguage(b.id) { langs[l.lowercased(), default: 0] += 1 } }
            language = langs.max { $0.value < $1.value }?.key ?? "english"
            if langs.values.reduce(0, +) >= 20 { Store.set(language, "radar_language") }
        }
        let inWindow = { (b: AudibleBook) -> Bool in
            guard let d = b.releaseDay, b.language.map({ $0.lowercased() == language }) ?? true else { return false }
            return d >= from && d <= until
        }
        var found: [String: Find] = [:]
        /// A source couldn't be asked: what it found before is kept this time.
        var incomplete = false
        func add(_ b: AudibleBook, _ reason: String) {
            guard found[b.asin] == nil, inWindow(b), library.match(b) == nil else { return }
            found[b.asin] = Find(asin: b.asin, title: b.title, author: b.author, cover: b.thumbURL?.absoluteString,
                                 releaseDate: b.releaseDate, reason: reason, foundAt: now.timeIntervalSince1970)
        }

        // Authors: those with the most books here, and of what's being listened to.
        var authorWeight: [String: Int] = [:]
        for b in library.books { if let a = b.authors.first ?? b.author { authorWeight[a, default: 0] += 1 } }
        for b in library.continueListening { if let a = b.authors.first ?? b.author { authorWeight[a, default: 0] += 100 } }
        let authors = authorWeight.sorted { $0.value > $1.value }.prefix(40).map(\.key)
        // Five at a time (one after another, 40 took most of a background refresh's time).
        for chunk in stride(from: 0, to: authors.count, by: 5).map({ Array(authors[$0..<min($0 + 5, authors.count)]) }) {
            if Task.isCancelled { return } // out of time: not marked checked, so it runs again
            let lists = await withTaskGroup(of: (String, [AudibleBook]?).self) { g in
                for a in chunk { g.addTask { (a, try? await AudibleCatalog.newest(author: a)) } }
                var out: [(String, [AudibleBook]?)] = []
                for await r in g { out.append(r) }
                return out
            }
            for (a, list) in lists {
                guard let list else {
                    incomplete = true
                    #if DEBUG
                    print("KITZITEST radar couldn't ask about \(a)")
                    #endif
                    continue
                }
                // Only the author's own books (a search also finds books "with" them),
                // and not anthologies they have one story in.
                for b in list where b.authors.count <= 3 && b.authors.contains(where: { $0.localizedCaseInsensitiveCompare(a) == .orderedSame }) {
                    add(b, "New from \(a)")
                }
            }
        }
        for n in followedNarrators.sorted() {
            guard let list = try? await AudibleCatalog.newest(narrator: n) else { incomplete = true; continue }
            for b in list where b.narrators.contains(where: { $0.localizedCaseInsensitiveCompare(n) == .orderedSame }) {
                add(b, "Narrated by \(n)")
            }
        }
        // Series being listened to or finished: the books after the last one here.
        let recent = Set(library.progress.values.filter { $0.progress > 0 }.map(\.itemId))
        let series = library.series().filter { s in s.books.contains { recent.contains($0.id) } }.prefix(25)
        for s in series {
            if Task.isCancelled { return }
            guard let found = try? await AudibleCatalog.series(named: s.name, books: s.books),
                  let all = try? await AudibleCatalog.seriesBooks(found.ref, language: found.language) else { continue }
            let owned = s.books.compactMap(\.seriesSequence).max() ?? 0
            for b in all {
                let n = AudibleCatalog.numbers(b.seriesRefs.first { $0.asin == found.ref.asin }?.sequence)
                guard n.count == 1, n[0] > owned else { continue }
                add(b, "Book \(AudibleCatalog.label(n[0])) of \(s.name)")
            }
        }

        if Task.isCancelled { return }
        // What's new since last time is notified; a coming book once more on release day.
        let known = Dictionary(uniqueKeysWithValues: finds.map { ($0.asin, $0) })
        var fresh: [Find] = []
        var nowOut: [Find] = []
        var merged: [Find] = []
        for (asin, f) in found {
            if var old = known[asin] {
                if !old.announcedOut, old.isUpcoming == false, (old.releaseDay ?? .distantPast) > Date(timeIntervalSince1970: old.foundAt) {
                    old.announcedOut = true
                    nowOut.append(old)
                }
                merged.append(old)
            } else {
                var f = f
                f.announcedOut = !f.isUpcoming
                fresh.append(f)
                merged.append(f)
            }
        }
        // Finds still in the window stay; ones now in the library or past it go.
        // After an incomplete check, the earlier finds it didn't see again stay too.
        if incomplete {
            merged += finds.filter { f in found[f.asin] == nil && (f.releaseDay.map { $0 >= from } ?? false) }
        }
        finds = merged
        save()
        Store.set(now.timeIntervalSince1970, "radar_checked_at")
        // The first run just fills the list: no flood of notifications.
        let firstRun = Store.d.object(forKey: "radar_seeded") == nil
        Store.set(true, "radar_seeded")
        guard !firstRun else { return }
        await Notifier.releases(fresh, out: nowOut)
    }

    /// Shelfarr requests that have arrived since the last check.
    @MainActor
    func checkShelfarr() async {
        let shelfarr = Shelfarr.shared
        guard shelfarr.configured, (try? await shelfarr.refresh()) != nil else { return }
        let before = (Store.d.dictionary(forKey: "shelfarr_statuses") as? [String: String]) ?? [:]
        var now: [String: String] = [:]
        var arrived: [ShelfarrRequest] = []
        for r in shelfarr.requests {
            now[String(r.id)] = r.status
            if r.isCompleted, let was = before[String(r.id)], was != r.status { arrived.append(r) }
        }
        Store.set(now, "shelfarr_statuses")
        guard !arrived.isEmpty else { return }
        // Into the library first, so the notification opens the book itself.
        await LibraryStore.shared.refreshNewest()
        for r in arrived { await Notifier.ready(r) }
    }
}

/// Local notifications, and where tapping one goes.
enum Notifier {
    static let category = "kitzi.release"

    /// Asks once; true when allowed.
    @MainActor
    static func authorize() async -> Bool {
        let c = UNUserNotificationCenter.current()
        let s = await c.notificationSettings()
        if s.authorizationStatus == .authorized || s.authorizationStatus == .provisional { return true }
        return (try? await c.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    @MainActor
    static func releases(_ fresh: [Radar.Find], out: [Radar.Find]) async {
        let c = UNUserNotificationCenter.current()
        guard await c.notificationSettings().authorizationStatus == .authorized else { return }
        // A few: one each. Many: one summary.
        if fresh.count > 3 {
            await post(id: "radar-\(Int(Date().timeIntervalSince1970))", title: "\(fresh.count) new books for you",
                       body: fresh.prefix(3).map(\.title).joined(separator: ", ") + "…", info: ["open": "releases"])
        } else {
            for f in fresh {
                let when = f.releaseDay.map { f.isUpcoming ? " · out \($0.formatted(.dateTime.month(.abbreviated).day()))" : "" } ?? ""
                await post(id: "radar-\(f.asin)", title: f.reason, body: f.title + when, info: ["open": "audible", "asin": f.asin])
            }
        }
        for f in out {
            await post(id: "radar-out-\(f.asin)", title: "Out today", body: "\(f.title) · \(f.reason)", info: ["open": "audible", "asin": f.asin])
        }
    }

    @MainActor
    static func ready(_ r: ShelfarrRequest) async {
        guard await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized else { return }
        var info = ["open": "book", "title": r.title]
        if let a = r.author { info["author"] = a }
        await post(id: "shelfarr-\(r.id)", title: "Ready to listen", body: [r.title, r.author].compactMap { $0 }.joined(separator: " · "), info: info)
    }

    private static func post(id: String, title: String, body: String, info: [String: String]) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = info
        content.threadIdentifier = category
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// Where a tapped notification asked to go; RootView opens it.
@Observable
final class NotificationRoute {
    static let shared = NotificationRoute()
    enum Target: Equatable { case audible(String), book(title: String, author: String?), releases }
    var pending: Target?

    func handle(_ info: [AnyHashable: Any]) {
        switch info["open"] as? String {
        case "audible": if let a = info["asin"] as? String { pending = .audible(a) }
        case "book": if let t = info["title"] as? String { pending = .book(title: t, author: info["author"] as? String) }
        case "releases": pending = .releases
        default: break
        }
    }
}
