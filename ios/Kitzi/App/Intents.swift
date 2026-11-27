import AppIntents

// Siri, Shortcuts, Spotlight and the Action button: "Resume Kitzi", "Play The
// Martian in Kitzi", skip, bookmark, sleep timer, speed. They run in the app
// without opening it (audio intents start playback in the background).

struct PlaybackFailed: Error, CustomLocalizedStringResourceConvertible {
    let reason: String
    var localizedStringResource: LocalizedStringResource { "\(reason)" }
}

/// Plays a book (nil: the one loaded, else the last one, else the latest in progress).
@MainActor
private func resumeOrPlay(_ book: Book? = nil) async throws {
    let player = Player.shared
    if let book {
        if let why = await player.play(book) { throw PlaybackFailed(reason: why) }
        return
    }
    if player.nowPlaying != nil { player.resume(); return }
    let library = LibraryStore.shared
    let last = Store.string(Store.lastItemKey).flatMap { library.byId[$0] }
    guard let b = last ?? library.continueListening.first else { throw PlaybackFailed(reason: "There's nothing to resume.") }
    if let why = await player.play(b) { throw PlaybackFailed(reason: why) }
}

struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Listening"
    static let description = IntentDescription("Plays the audiobook you were listening to.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await resumeOrPlay()
        return .result()
    }
}

struct PauseListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause Listening"

    @MainActor
    func perform() async throws -> some IntentResult {
        Player.shared.pause()
        return .result()
    }
}

// MARK: a particular book

/// A book Siri and Shortcuts can name: any book in the library.
struct BookEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Audiobook"
    static let defaultQuery = BookQuery()
    var id: String
    var title: String
    var author: String?
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: author.map { "\($0)" })
    }

    init(_ b: Book) { id = b.id; title = b.title; author = b.author }
}

struct BookQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [BookEntity] {
        identifiers.compactMap { LibraryStore.shared.byId[$0] }.map(BookEntity.init)
    }

    /// In progress first (what people ask for), then recently added.
    @MainActor func suggestedEntities() async throws -> [BookEntity] {
        let l = LibraryStore.shared
        var seen = Set<String>()
        return (l.continueListening + l.recentlyAdded).filter { seen.insert($0.id).inserted }.prefix(30).map(BookEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [BookEntity] {
        LibraryStore.shared.filtered(sort: .titleAsc, filter: .all, search: string).prefix(20).map(BookEntity.init)
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
        guard let b = LibraryStore.shared.byId[book.id] else { throw PlaybackFailed(reason: "That book isn't in your library.") }
        try await resumeOrPlay(b)
        return .result()
    }
}

// MARK: while playing

@MainActor
private func requirePlaying() throws {
    guard Player.shared.nowPlaying != nil else { throw PlaybackFailed(reason: "Nothing is playing.") }
}

struct SkipBackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Back"

    @MainActor
    func perform() async throws -> some IntentResult {
        try requirePlaying()
        Player.shared.skip(-Double(AppSettings.shared.seekBackSec))
        return .result()
    }
}

struct SkipForwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Forward"

    @MainActor
    func perform() async throws -> some IntentResult {
        try requirePlaying()
        Player.shared.skip(Double(AppSettings.shared.seekForwardSec))
        return .result()
    }
}

struct NextChapterIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Chapter"

    @MainActor
    func perform() async throws -> some IntentResult {
        try requirePlaying()
        Player.shared.nextChapter()
        return .result()
    }
}

struct AddBookmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Bookmark"
    static let description = IntentDescription("Bookmarks where you are in the book.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try requirePlaying()
        let p = Player.shared
        guard let np = p.nowPlaying else { throw PlaybackFailed(reason: "Nothing is playing.") }
        p.refreshPosition()
        let pos = p.position
        let title = p.currentChapter()?.title ?? "Bookmark"
        let sent = await LibraryStore.shared.bookmarkOp(.init(kind: "add", itemId: np.book.id, timeSec: (pos * 1000).rounded() / 1000, title: title))
        return .result(dialog: sent ? "Bookmark added at \(Format.clock(pos))." : "Bookmark saved. It syncs when the server can be reached.")
    }
}

struct SleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    static let description = IntentDescription("Pauses your audiobook after a while, or at the end of the chapter (0 minutes).")

    @Parameter(title: "Minutes", default: 30, inclusiveRange: (0, 180)) var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try requirePlaying()
        if minutes == 0 {
            guard SleepTimer.shared.startEndOfChapter() else { throw PlaybackFailed(reason: "This book has no chapters.") }
            return .result(dialog: "Pausing at the end of the chapter.")
        }
        SleepTimer.shared.start(minutes: minutes)
        return .result(dialog: "Pausing in \(minutes) minutes.")
    }
}

struct SetSpeedIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Playback Speed"

    @Parameter(title: "Speed", default: 1.0, inclusiveRange: (0.5, 3.5)) var speed: Double

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try requirePlaying()
        Player.shared.setSpeed(speed)
        return .result(dialog: "Playing at \(SpeedLabel.text(Player.shared.speed)).")
    }
}

/// "What am I listening to?"
struct NowListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "What Am I Listening To"

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let p = Player.shared
        guard let np = p.nowPlaying else { throw PlaybackFailed(reason: "Nothing is loaded.") }
        p.refreshPosition()
        let left = max(np.totalSec - p.position, 0) / max(p.speed, 0.1)
        var line = "\(np.book.title)"
        if let a = np.book.author { line += " by \(a)" }
        if let c = p.currentChapter() { line += ", \(c.title)" }
        line += ". \(Format.hm(left)) left."
        return .result(dialog: "\(line)")
    }
}

struct KitziShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResumeListeningIntent(),
                    phrases: ["Resume \(.applicationName)", "Continue my audiobook in \(.applicationName)", "Play my book in \(.applicationName)"],
                    shortTitle: "Resume Listening", systemImageName: "play.fill")
        AppShortcut(intent: PauseListeningIntent(),
                    phrases: ["Pause \(.applicationName)"],
                    shortTitle: "Pause Listening", systemImageName: "pause.fill")
        AppShortcut(intent: PlayBookIntent(),
                    phrases: ["Play \(\.$book) in \(.applicationName)", "Listen to \(\.$book) in \(.applicationName)"],
                    shortTitle: "Play Audiobook", systemImageName: "book.fill")
        AppShortcut(intent: SkipBackIntent(),
                    phrases: ["Skip back in \(.applicationName)", "Go back in \(.applicationName)"],
                    shortTitle: "Skip Back", systemImageName: "gobackward")
        AppShortcut(intent: AddBookmarkIntent(),
                    phrases: ["Add a bookmark in \(.applicationName)", "Bookmark this in \(.applicationName)"],
                    shortTitle: "Add Bookmark", systemImageName: "bookmark.fill")
        AppShortcut(intent: SleepTimerIntent(),
                    phrases: ["Set a sleep timer in \(.applicationName)"],
                    shortTitle: "Sleep Timer", systemImageName: "moon.zzz.fill")
        AppShortcut(intent: NowListeningIntent(),
                    phrases: ["What am I listening to in \(.applicationName)"],
                    shortTitle: "Now Listening", systemImageName: "headphones")
    }
}
