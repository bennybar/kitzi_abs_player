import SwiftUI

/// Home, laid out like Apple Books: today's listening, the shelves as Material 3
/// Expressive carousels under iOS "Title ›" headers, then the whole library as a
/// Browse card (All Books and Search have their own screens).
struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var path = NavigationPath()
    @State private var loaded = false
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    topCard.padding(.horizontal, 20)
                    // The first sync: shelves' shapes instead of an empty page.
                    if library.books.isEmpty && library.syncing {
                        ForEach(0..<2, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 12) {
                                Capsule().fill(.quaternary).frame(width: 150, height: 20)
                                LoadingBlock(height: CarouselSize.cover, radius: 28)
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    shelves
                    VStack(alignment: .leading, spacing: 0) {
                        if settings.becauseFinished { BecauseYouFinishedRow { path.append($0) } }
                        browseCard
                    }
                    .id("allbooks")
                }
                .padding(.vertical, 8)
                .padding(.bottom, 90)
            }
            #if DEBUG
            .task {
                // Test hook (simulator screenshots): scroll to the All Books part.
                guard ProcessInfo.processInfo.environment["KITZI_SCROLL_ALL"] != nil else { return }
                try? await Task.sleep(for: .seconds(8))
                proxy.scrollTo("allbooks", anchor: .top)
            }
            #endif
            }
            .kitziBackground()
            .navigationTitle("Library")
            .navigationDestination(for: BookFrom.self) { r in
                BookDetailView(book: r.book).navigationTransition(.zoom(sourceID: r.source, in: zoom))
            }
            .environment(\.coverZoom, zoom)
            .navigationDestination(for: FindBookRoute.self) { FindBookView(initialQuery: $0.query) }
            .navigationDestination(for: AllBooksRoute.self) { AllBooksView(filter: $0.filter) }
            .navigationDestination(for: BrowseRoute.self) { r in
                switch r {
                // (The stack's environment doesn't reach its destinations: without
                // this, covers there have no source to zoom from.)
                case .genres: GenresView(path: $path).environment(\.coverZoom, zoom)
                case .authors: AuthorsView()
                case .series: SeriesView()
                case .narrators: NarratorsView()
                }
            }
            #if DEBUG
            .navigationDestination(for: DebugScreen.self) { s in
                switch s {
                case .yearReview: YearInReviewView()
                case .health: LibraryHealthView()
                }
            }
            #endif
            .navigationDestination(for: ShelfRoute.self) { r in
                BookListView(title: r.title, books: r.books)
            }
            .kitziDestinations()
            .refreshable { await refresh(full: true) }
            .task {
                guard !loaded else { return }
                loaded = true
                await refresh(full: false)
                #if DEBUG
                // Test hook (simulator screenshots): open a book's page.
                if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "detail",
                   let w = ProcessInfo.processInfo.environment["KITZI_TEST_BOOK"],
                   let b = library.books.first(where: { $0.title.localizedCaseInsensitiveContains(w) }) {
                    path.append(b)
                }
                if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "allbooks" {
                    path.append(AllBooksRoute(filter: .all))
                }
                if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "series",
                   let name = ProcessInfo.processInfo.environment["KITZI_TEST_SERIES"] {
                    path.append(SeriesRoute(name: name))
                }
                if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "findbook" {
                    path.append(FindBookRoute(query: ProcessInfo.processInfo.environment["KITZI_TEST_QUERY"] ?? ""))
                }
                if ProcessInfo.processInfo.environment["KITZI_TEST_MATCH"] != nil {
                    // Matching an Audible book to the library: ASIN first, then the exact title.
                    @MainActor func fake(_ asin: String, _ title: String, _ author: String) -> AudibleBook? {
                        AudibleBook(["asin": asin, "title": title, "authors": [["name": author]]])
                    }
                    let martian = library.books.first { $0.title == "The Martian" }
                    let cases: [(String, AudibleBook?)] = [
                        ("same title", fake("X1", "The Martian", "Andy Weir")),
                        ("longer title (sequel-like)", fake("X2", "The Martian Chronicles", "Andy Weir")),
                        ("title with subtitle", fake("X3", "The Martian: A Novel", "Andy Weir")),
                        ("other author", fake("X4", "The Martian", "Ray Bradbury")),
                        ("server ASIN, other title", fake(martian?.asin ?? "none", "Totally Different", "Nobody")),
                    ]
                    print("KITZITEST match martianAsin=\(martian?.asin ?? "-") booksWithAsin=\(library.books.filter { $0.asin != nil }.count)/\(library.books.count)")
                    for (name, b) in cases { print("KITZITEST match \(name): \(b.flatMap { library.match($0)?.title } ?? "no match")") }
                }
                if ProcessInfo.processInfo.environment["KITZI_TEST_STATE"] != nil {
                    // A lived-in app for screenshots: two short books downloaded (one in
                    // progress), three in the queue.
                    let started = library.books.filter { (library.progress[$0.id]?.progress ?? 0) > 0 }
                        .sorted { ($0.durationSec ?? 0) < ($1.durationSec ?? 0) }
                    for b in started.prefix(2) { _ = await Downloads.shared.start(b.id) }
                    for b in library.books.prefix(3) { PlayQueue.shared.add(b.id) }
                }
                if let a = ProcessInfo.processInfo.environment["KITZI_TEST_AUTHOR"] { path.append(a) }
                if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "byauthor" {
                    path.append(BrowseRoute.authors)
                }
                if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "byseries" {
                    path.append(BrowseRoute.series)
                }
                if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "yearreview" { path.append(DebugScreen.yearReview) }
                if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "health" { path.append(DebugScreen.health) }
                if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "narrators" {
                    path.append(BrowseRoute.narrators)
                }
                if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "whatnext" { path.append(WhatNextRoute()) }
                if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "smart" {
                    for s in SmartShelf.presets {
                        let found = library.books(s)
                        print("KITZITEST smart \(s.name) count=\(found.count) first=\(found.prefix(3).map(\.title).joined(separator: " | "))")
                    }
                    if settings.smartShelves.isEmpty { settings.smartShelves = [SmartShelf.presets[0], SmartShelf.presets[2]] }
                }
                if ProcessInfo.processInfo.environment["KITZI_TEST_OPEN"] == "genres" {
                    path.append(BrowseRoute.genres)
                }
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: FindBookRoute()) {
                        HStack(spacing: 6) { Image(systemName: "text.magnifyingglass"); Text("Find Book") }.fixedSize()
                    }
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { StatsView() } label: { Image(systemName: "chart.bar") }
                }
            }
        }
    }

    private func refresh(full: Bool) async {
        await library.refreshAll(full: full)
        if full && !library.lastSyncReachedServer { Toast.show("Couldn't reach the server — showing your offline library") }
    }

    // MARK: top card (Settings → Home Shelves → Top of Library)

    @Environment(\.openPlayer) private var openPlayer

    @ViewBuilder private var topCard: some View {
        switch settings.homeTop {
        case "resume":
            ResumeCard(play: { b in Task { if let why = await Player.shared.play(b) { Haptics.failure(); Toast.show(why) } else { openPlayer() } } },
                       open: { b in path.append(BookFrom(book: b, source: "resume-\(b.id)")) })
        case "stats": StatsStrip()
        default: GoalCard()
        }
    }

    // MARK: browse

    /// The end of Home: All Books and its filters, by genre, and by author when
    /// there's no Authors tab — each its own screen (the whole library was one
    /// long list here).
    private var browseCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse").font(.title2.bold()).padding(.horizontal, 20)
            // Two columns of tiles (it was eight full-width rows, a whole screen). A
            // plain grid, not a lazy one: inside Home's lazy stack a lazy grid left
            // its first row blank after scrolling.
            let tiles = browseTiles
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { i in
                        HStack(spacing: 10) {
                            browseTile(tiles[i])
                            if i + 1 < tiles.count { browseTile(tiles[i + 1]) } else { Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private struct BrowseTile { var title: String; var icon: String; var count: Int?; var go: () -> Void }

    /// All Books and the filters that have books (counted without sorting the
    /// library), then genre, series and (without its tab) author.
    private var browseTiles: [BrowseTile] {
        var out: [BrowseTile] = []
        for f in BookFilter.allCases {
            let count = library.count(f)
            if f == .all || count > 0 {
                out.append(BrowseTile(title: f == .all ? "All Books" : f.label, icon: Self.icon(f), count: count) { path.append(AllBooksRoute(filter: f)) })
            }
        }
        out.append(BrowseTile(title: "What Next?", icon: "sparkles", count: nil) { path.append(WhatNextRoute()) })
        if settings.radar {
            let n = Radar.shared.finds.count
            out.append(BrowseTile(title: "New Releases", icon: "dot.radiowaves.left.and.right", count: n > 0 ? n : nil) { path.append(ReleasesRoute()) })
        }
        out.append(BrowseTile(title: "By Genre", icon: "tag", count: nil) { path.append(BrowseRoute.genres) })
        out.append(BrowseTile(title: "By Series", icon: "books.vertical.circle", count: nil) { path.append(BrowseRoute.series) })
        out.append(BrowseTile(title: "By Narrator", icon: "mic", count: nil) { path.append(BrowseRoute.narrators) })
        if !settings.showAuthorsTab {
            out.append(BrowseTile(title: "By Author", icon: "person.2", count: nil) { path.append(BrowseRoute.authors) })
        }
        return out
    }

    private func browseTile(_ t: BrowseTile) -> some View {
        Button(action: t.go) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: t.icon).font(.title3).foregroundStyle(Color.accentColor).frame(height: 24)
                    Spacer()
                    if let count = t.count { Text("\(count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t.count.map { "\(t.title), \($0) books" } ?? t.title)
    }

    private static func icon(_ f: BookFilter) -> String {
        switch f {
        case .all: "books.vertical"
        case .inProgress: "play.circle"
        case .notStarted: "circle.dashed"
        case .finished: "checkmark.circle"
        case .downloaded: "arrow.down.circle"
        }
    }

    // MARK: shelves (M3E carousels under iOS headers)

    @ViewBuilder private var shelves: some View {
        if let server = library.serverShelves, settings.serverHomeShelves {
            ForEach(server.filter { settings.showNextInSeries || $0.id != "continue-series" }) { s in
                let listening = s.id == "continue-listening"
                let key = ["continue-listening": "continue", "recently-added": "recent", "continue-series": "series"][s.id] ?? "other"
                shelfSection(s.label, listening ? continueBooks(s.books) : s.books, key: key, hero: listening, showProgress: listening, zoomKey: s.id)
            }
        } else {
            shelfSection("Continue", continueBooks(library.continueListening), key: "continue", hero: true, showProgress: true)
            shelfSection("Recently Added", library.recentlyAdded, key: "recent", hero: false, showProgress: false)
            if settings.showNextInSeries {
                shelfSection("Next in Series", library.continueSeries, key: "series", hero: false, showProgress: false) { $0.seriesLabel }
            }
        }
        // Your own: saved filters (Settings › Home Shelves › Smart Shelves).
        ForEach(settings.smartShelves) { s in
            shelfSection(s.name, library.books(s), key: "smart", hero: false, showProgress: s.status == "inProgress", zoomKey: "smart-\(s.id)")
        }
    }

    /// With the Resume card on top, Continue doesn't repeat the card's book.
    private func continueBooks(_ books: [Book]) -> [Book] {
        guard settings.homeTop == "resume", let shown = Player.shared.nowPlaying?.book.id ?? library.continueListening.first?.id else { return books }
        return books.filter { $0.id != shown }
    }

    @ViewBuilder
    private func shelfSection(_ title: String, _ books: [Book], key: String, hero: Bool, showProgress: Bool,
                              zoomKey: String? = nil, caption: ((Book) -> String?)? = nil) -> some View {
        if settings.carouselOff.contains(key) {
            // Carousel turned off in Settings: a plain row of covers.
            CoverShelf(title: title, books: books, showProgress: showProgress, path: $path, big: hero)
        } else if !books.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ShelfHeader(title: title) { path.append(ShelfRoute(title: title, books: books)) }
                // The server's other shelves share a key ("other"): each zooms under its own id.
                carousel(books, key: zoomKey ?? key, hero: hero, showProgress: showProgress, caption: caption)
            }
        }
    }

    private func carousel(_ books: [Book], key: String, hero: Bool, showProgress: Bool, caption: ((Book) -> String?)?) -> some View {
        KeylineCarousel(
            items: books,
            height: CarouselSize.cover,
            keylines: { w in
                // One big cover, a medium and a small one peeking.
                let small: CGFloat = 40, medium = w * 0.2
                return [w - medium - small - 16, medium, small]
            },
            onTap: { path.append(BookFrom(book: $0, source: "\(key)-\($0.id)")) },
            label: { $0.title },
            menuBook: { $0 }
        ) { b, fullness in
            let p = library.progress[b.id]
            let left = showProgress ? library.timeLeft(b).map { "\(Format.hm($0)) left" } : nil
            CarouselCover(book: b, caption: left ?? caption?(b) ?? b.author,
                          progress: showProgress ? p?.progress : nil, fullness: fullness, hero: hero)
                .coverZoomSource("\(key)-\(b.id)", zoom, radius: 28)
        }
    }

}

/// A plain list of books (an author's, a series', a shelf's "See All").
struct BookListView: View {
    let title: String
    let books: [Book]
    /// A series' page: also lists its books on Audible that aren't here.
    var series: String? = nil
    @Environment(AppSettings.self) private var settings
    @Namespace private var zoom
    var body: some View {
        List {
            if let series, settings.seriesMissing {
                // The whole series in order: yours and the ones that aren't here.
                SeriesLadder(series: series, books: books)
            } else {
                ForEach(books) { b in
                    ZoomBookLink(book: b, source: "list-\(b.id)") { ListBookRow(book: b, zoomID: "list-\(b.id)") }
                        .bookContextMenu(b)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.coverZoom, zoom)
        .kitziBackground()
        .navigationTitle(title)
    }
}

#if DEBUG
/// Test hook screens (simulator screenshots).
enum DebugScreen: Hashable { case yearReview, health }
#endif
