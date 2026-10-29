import BackgroundTasks
import Foundation
import Observation
import SwiftUI

/// Local listening history: confirmed listening per book per day (for the
/// detailed stats), and a per-book journal of where you paused (Play history).
final class PlayHistory {
    static let shared = PlayHistory()

    struct Session: Codable { var itemId: String; var day: String; var sec: Double }
    struct Entry: Codable, Identifiable { var position: Double; var chapter: String?; var at: Int64; var id: Int64 { at } }

    private var sessions: [Session] = []
    private let file = Store.supportDir.appendingPathComponent("play_history.json")

    private init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode([Session].self, from: d) { sessions = s }
    }

    func record(_ itemId: String, listened: Double) {
        guard AppSettings.shared.detailedHistory, listened > 0 else { return }
        let day = LibraryStore.dayKey(Date())
        if let i = sessions.lastIndex(where: { $0.itemId == itemId && $0.day == day }) {
            sessions[i].sec += listened
        } else {
            sessions.append(Session(itemId: itemId, day: day, sec: listened))
        }
        try? JSONEncoder().encode(sessions).write(to: file, options: .atomic)
    }

    struct Top: Identifiable { var name: String; var sec: Double; var book: Book?; var id: String { name } }

    func top() -> (books: [Top], authors: [Top], narrators: [Top], days: Int, total: Double) {
        let lib = LibraryStore.shared
        var byBook: [String: Double] = [:]
        for s in sessions { byBook[s.itemId, default: 0] += s.sec }
        var authors: [String: Double] = [:], narrators: [String: Double] = [:]
        for (id, sec) in byBook {
            guard let b = lib.byId[id] else { continue }
            if let a = b.author { authors[a, default: 0] += sec }
            for n in b.narrators { narrators[n, default: 0] += sec }
        }
        let books = byBook.compactMap { id, sec in lib.byId[id].map { Top(name: $0.title, sec: sec, book: $0) } }
            .sorted { $0.sec > $1.sec }.prefix(10)
        func top(_ d: [String: Double]) -> [Top] { d.map { Top(name: $0.key, sec: $0.value) }.sorted { $0.sec > $1.sec }.prefix(10).map { $0 } }
        return (Array(books), top(authors), top(narrators), Set(sessions.map(\.day)).count, sessions.reduce(0) { $0 + $1.sec })
    }

    // Journal: where playback paused, newest first, at most 50 per book.
    func journal(_ itemId: String, position: Double, chapter: String?) {
        var list = entries(itemId)
        if let first = list.first, abs(first.position - position) < 5 { return }
        list.insert(Entry(position: position, chapter: chapter, at: Format.nowMs), at: 0)
        Store.set(try? JSONEncoder().encode(Array(list.prefix(50))), "journal:\(itemId)")
    }

    func entries(_ itemId: String) -> [Entry] {
        (Store.d.data(forKey: "journal:\(itemId)").flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }) ?? []
    }

    func clear() {
        sessions = []
        try? FileManager.default.removeItem(at: file)
        Store.removeAll(prefixes: ["journal:"])
    }
}

/// Up-next: books to play after the current one.
@Observable
final class PlayQueue {
    static let shared = PlayQueue()
    private(set) var items: [String] = (Store.d.stringArray(forKey: "play_queue")) ?? []

    var books: [Book] { items.compactMap { LibraryStore.shared.byId[$0] } }

    func addNext(_ id: String) { items.removeAll { $0 == id }; items.insert(id, at: 0); save() }
    func add(_ id: String) { items.removeAll { $0 == id }; items.append(id); save() }
    func remove(_ id: String) { items.removeAll { $0 == id }; save() }
    func move(from: IndexSet, to: Int) { items.move(fromOffsets: from, toOffset: to); save() }
    /// A move within [ids] (the books shown); queue entries not shown keep their slots.
    func move(visible ids: [String], from: IndexSet, to: Int) {
        var reordered = ids
        reordered.move(fromOffsets: from, toOffset: to)
        let shown = Set(ids)
        var next = reordered.makeIterator()
        items = items.map { shown.contains($0) ? (next.next() ?? $0) : $0 }
        save()
    }
    func clear() { items = []; save() }
    func popNext() -> Book? {
        guard !items.isEmpty else { return nil }
        let id = items.removeFirst(); save()
        return LibraryStore.shared.byId[id]
    }
    private func save() { Store.set(items, "play_queue") }
}

/// Pushes positions saved offline in the background, when iOS gives time.
enum BackgroundTasks {
    nonisolated static let pushId = "com.bennybar.kitzi.progress-push"
    nonisolated static let refreshId = "com.bennybar.kitzi.library-refresh"

    /// The handlers run on a background queue, so they're registered from nonisolated
    /// code; each marks its task complete on expiry too, as iOS requires.
    nonisolated static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: pushId, using: nil) { task in
            nonisolated(unsafe) let t = task
            let work = Task { @MainActor in
                await Player.shared.flushPending()
                await LibraryStore.shared.flushPendingBookmarks()
                t.setTaskCompleted(success: true)
            }
            t.expirationHandler = { work.cancel(); t.setTaskCompleted(success: false) }
        }
        // A light library + progress refresh a few times a day, so Continue
        // Listening is current when the app opens.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshId, using: nil) { task in
            nonisolated(unsafe) let t = task
            scheduleRefresh()
            let work = Task { @MainActor in
                if Session.shared.signedIn {
                    await Player.shared.flushPending()
                    await LibraryStore.shared.refreshNewest()
                    await LibraryStore.shared.syncProgress()
                }
                t.setTaskCompleted(success: true)
            }
            t.expirationHandler = { work.cancel(); t.setTaskCompleted(success: false) }
        }
    }

    nonisolated static func schedulePush() {
        let r = BGProcessingTaskRequest(identifier: pushId)
        r.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(r)
    }

    nonisolated static func scheduleRefresh() {
        let r = BGAppRefreshTaskRequest(identifier: refreshId)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        try? BGTaskScheduler.shared.submit(r)
    }
}

/// A short message at the bottom of the screen, optionally with one action.
@Observable
final class Toast {
    static let shared = Toast()
    struct Item: Identifiable { let id = UUID(); var text: String; var action: String?; var run: (() -> Void)? }
    var current: Item?
    private var hide: Task<Void, Never>?

    static func show(_ text: String, action: String? = nil, run: (() -> Void)? = nil) {
        let t = Toast.shared
        let item = Item(text: text, action: action, run: run)
        withAnimation(.spring) { t.current = item }
        t.hide?.cancel()
        t.hide = Task {
            try? await Task.sleep(for: .seconds(action == nil ? 3 : 5))
            if t.current?.id == item.id { withAnimation(.spring) { t.current = nil } }
        }
    }
}
