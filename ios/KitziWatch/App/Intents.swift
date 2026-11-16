import AppIntents

/// "Resume Kitzi" from Siri, Shortcuts or the Action button: carries on with the
/// loaded book, else the latest one on the shelf.
struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Listening"
    static let description = IntentDescription("Plays the audiobook you were listening to.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = WatchPlayer.shared
        var why: String?
        if player.nowPlaying != nil {
            why = await player.resume()
        } else if let s = WatchModel.shared.shelf.first {
            why = await player.play(s.book, fallbackSec: s.currentTimeSec, fallbackAt: s.lastUpdate)
        } else {
            why = "There's nothing to resume."
        }
        if let why { throw PlaybackFailed(reason: why) }
        return .result()
    }
}

struct PauseListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause Listening"

    @MainActor
    func perform() async throws -> some IntentResult {
        WatchPlayer.shared.pause()
        return .result()
    }
}

// MARK: a particular book

/// A book Siri and Shortcuts can name: one on the shelf or on the watch.
struct BookEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Audiobook"
    static let defaultQuery = BookQuery()
    var id: String
    var title: String
    var author: String?
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: author.map { "\($0)" })
    }
}

struct BookQuery: EntityStringQuery {
    /// The shelf (most recent first), then the other books on the watch.
    @MainActor private func all() -> [(BookEntity, Book)] {
        var seen = Set<String>()
        var out: [(BookEntity, Book)] = []
        for s in WatchModel.shared.shelf where seen.insert(s.id).inserted {
            out.append((BookEntity(id: s.id, title: s.book.title, author: s.book.author), s.book))
        }
        for id in WatchDownloads.shared.downloadedIds where seen.insert(id).inserted {
            if let m = WatchDownloads.shared.downloaded(id) {
                out.append((BookEntity(id: id, title: m.book.title, author: m.book.author), m.book))
            }
        }
        return out
    }

    @MainActor func entities(for identifiers: [String]) async throws -> [BookEntity] {
        all().map(\.0).filter { identifiers.contains($0.id) }
    }

    @MainActor func suggestedEntities() async throws -> [BookEntity] { all().map(\.0) }

    @MainActor func entities(matching string: String) async throws -> [BookEntity] {
        let q = string.lowercased()
        return all().map(\.0).filter { $0.title.lowercased().contains(q) || ($0.author?.lowercased().contains(q) ?? false) }
    }

    @MainActor static func book(_ id: String) -> Book? {
        WatchModel.shared.shelf.first { $0.id == id }?.book ?? WatchDownloads.shared.downloaded(id)?.book
    }
}

/// "Play The Martian in Kitzi".
struct PlayBookIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Audiobook"
    static let description = IntentDescription("Plays a book from where you got to.")

    @Parameter(title: "Book") var book: BookEntity

    init() {}
    init(book: BookEntity) { self.book = book }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let b = BookQuery.book(book.id) else { throw PlaybackFailed(reason: "That book isn't on your shelf or your watch.") }
        let shelf = WatchModel.shared.shelf.first { $0.id == b.id }
        if let why = await WatchPlayer.shared.play(b, fallbackSec: shelf?.currentTimeSec ?? 0, fallbackAt: shelf?.lastUpdate ?? 0) {
            throw PlaybackFailed(reason: why)
        }
        return .result()
    }
}

// MARK: while playing

struct SkipBackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Back 30 Seconds"

    @MainActor
    func perform() async throws -> some IntentResult {
        guard WatchPlayer.shared.nowPlaying != nil else { throw PlaybackFailed(reason: "Nothing is playing.") }
        WatchPlayer.shared.skip(-30)
        return .result()
    }
}

struct SkipForwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Forward 30 Seconds"

    @MainActor
    func perform() async throws -> some IntentResult {
        guard WatchPlayer.shared.nowPlaying != nil else { throw PlaybackFailed(reason: "Nothing is playing.") }
        WatchPlayer.shared.skip(30)
        return .result()
    }
}

struct AddBookmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Bookmark"
    static let description = IntentDescription("Bookmarks where you are in the book.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard WatchPlayer.shared.nowPlaying != nil else { throw PlaybackFailed(reason: "Nothing is playing.") }
        guard await WatchPlayer.shared.addBookmark() else { throw PlaybackFailed(reason: "Couldn't add the bookmark. Check the connection.") }
        return .result(dialog: "Bookmark added.")
    }
}

struct SleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    static let description = IntentDescription("Pauses your audiobook after a while.")

    @Parameter(title: "Minutes", default: 15, inclusiveRange: (1, 180)) var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard WatchPlayer.shared.nowPlaying != nil else { throw PlaybackFailed(reason: "Nothing is playing.") }
        WatchPlayer.shared.sleep(minutes: minutes)
        return .result(dialog: "Pausing in \(minutes) minutes.")
    }
}

struct KitziShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumeListeningIntent(),
                    phrases: ["Resume \(.applicationName)", "Continue my audiobook in \(.applicationName)"],
                    shortTitle: "Resume Listening", systemImageName: "play.fill")
        AppShortcut(intent: PauseListeningIntent(),
                    phrases: ["Pause \(.applicationName)"],
                    shortTitle: "Pause Listening", systemImageName: "pause.fill")
        AppShortcut(intent: PlayBookIntent(),
                    phrases: ["Play \(\.$book) in \(.applicationName)", "Listen to \(\.$book) in \(.applicationName)"],
                    shortTitle: "Play Audiobook", systemImageName: "book.fill")
        AppShortcut(intent: SkipBackIntent(),
                    phrases: ["Skip back in \(.applicationName)", "Go back in \(.applicationName)"],
                    shortTitle: "Skip Back", systemImageName: "gobackward.30")
        AppShortcut(intent: SkipForwardIntent(),
                    phrases: ["Skip forward in \(.applicationName)"],
                    shortTitle: "Skip Forward", systemImageName: "goforward.30")
        AppShortcut(intent: AddBookmarkIntent(),
                    phrases: ["Add a bookmark in \(.applicationName)", "Bookmark this in \(.applicationName)"],
                    shortTitle: "Add Bookmark", systemImageName: "bookmark.fill")
        AppShortcut(intent: SleepTimerIntent(),
                    phrases: ["Set a sleep timer in \(.applicationName)"],
                    shortTitle: "Sleep Timer", systemImageName: "moon.zzz.fill")
    }
}
