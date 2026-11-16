import SwiftUI

/// Home, laid out like Apple Books: today's listening, the shelves as Material 3
/// Expressive carousels under iOS "Title ›" headers, then the whole library as a
/// cover grid or a native list (sort, filter, search).
struct HomeView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var sort: BookSort = BookSort(rawValue: Store.string("library_sort") ?? "") ?? .addedDesc
    @State private var filter: BookFilter = .all
    @State private var search = ""
    @State private var serverResults: [Book] = []
    @State private var path = NavigationPath()
    @State private var loaded = false
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if search.isEmpty {
                        topCard.padding(.horizontal, 20)
                        shelves
                        if settings.becauseFinished { BecauseYouFinishedRow { path.append($0) } }
                    }
                    if search.isEmpty {
                        browseCard.id("allbooks")
                    } else {
                    // Filtered once per render (it sorts the whole library), and again
                    // as Audible ratings arrive for the "Highest rated" sort.
                    let _ = sort == .ratingDesc ? AudibleRating.shared.fillDone : 0
                    let list = library.filtered(sort: sort, filter: filter, search: search)
                    libraryHeader(count: list.count).id("allbooks")
                    if sort == .ratingDesc { RatingFillBanner() }
                    if list.isEmpty && library.books.isEmpty { emptyState }
                    if settings.gridLayout {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 16)], spacing: 20) {
                            ForEach(list) { b in
                                Button { path.append(BookFrom(book: b, source: "all-\(b.id)")) } label: {
                                    CoverTile(book: b, size: nil, progress: library.progress[b.id], zoomID: "all-\(b.id)")
                                }
                                    .buttonStyle(.plain)
                                    .bookContextMenu(b)
                            }
                        }
                        .padding(.horizontal, 20)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(list) { b in
                                Button { path.append(BookFrom(book: b, source: "all-\(b.id)")) } label: {
                                    ListBookRow(book: b, zoomID: "all-\(b.id)", showRating: sort == .ratingDesc).padding(.vertical, 8)
                                }
                                    .buttonStyle(.plain)
                                    .bookContextMenu(b)
                                Divider().padding(.leading, 64)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    }
                    // Not in the local cache yet (just added on the server): server search.
                    let extra = serverResults.filter { library.byId[$0.id] == nil }
                    if !search.isEmpty && !extra.isEmpty {
                        Text("On the Server").font(.title3.bold()).padding(.horizontal, 20)
                        ForEach(extra) { b in
                            Button { path.append(b) } label: { ListBookRow(book: b) }.buttonStyle(.plain).padding(.horizontal, 20)
                        }
                    }
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
            .navigationDestination(for: Book.self) { BookDetailView(book: $0) }
            .navigationDestination(for: BookFrom.self) { r in
                BookDetailView(book: r.book).navigationTransition(.zoom(sourceID: r.source, in: zoom))
            }
            .environment(\.coverZoom, zoom)
            .navigationDestination(for: FindBookRoute.self) { FindBookView(initialQuery: $0.query) }
            .navigationDestination(for: AllBooksRoute.self) { AllBooksView(filter: $0.filter) }
            .navigationDestination(for: BrowseRoute.self) { r in
                switch r {
                case .genres: GenresView(path: $path)
                case .authors: AuthorsView()
                case .series: SeriesView()
                }
            }
            .navigationDestination(for: ShelfRoute.self) { r in
                BookListView(title: r.title, books: r.books)
            }
            .kitziDestinations()
            .searchable(text: $search, prompt: "Title, author, series, narrator")
            .task(id: search) {
                guard search.count >= 3 else { serverResults = []; return }
                try? await Task.sleep(for: .milliseconds(400))
                serverResults = await library.searchServer(search)
            }
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
            ResumeCard(play: { b in Task { if await Player.shared.play(b) == nil { openPlayer() } } },
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
            VStack(spacing: 0) {
                ForEach(BookFilter.allCases) { f in
                    let count = library.filtered(sort: .addedDesc, filter: f, search: "").count
                    browseRow(f == .all ? "All Books" : f.label, Self.icon(f), count: count) { path.append(AllBooksRoute(filter: f)) }
                    Divider().padding(.leading, 58)
                }
                browseRow("By Genre", "tag") { path.append(BrowseRoute.genres) }
                Divider().padding(.leading, 58)
                browseRow("By Series", "books.vertical.circle") { path.append(BrowseRoute.series) }
                if !settings.showAuthorsTab {
                    Divider().padding(.leading, 58)
                    browseRow("By Author", "person.2") { path.append(BrowseRoute.authors) }
                }
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 16)
        }
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

    private func browseRow(_ title: String, _ icon: String, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
                Text(title).font(.body)
                Spacer()
                if let count { Text("\(count)").foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: shelves (M3E carousels under iOS headers)

    @ViewBuilder private var shelves: some View {
        if let server = library.serverShelves, settings.serverHomeShelves {
            ForEach(server.filter { settings.showNextInSeries || $0.id != "continue-series" }) { s in
                let listening = s.id == "continue-listening"
                let key = ["continue-listening": "continue", "recently-added": "recent", "continue-series": "series"][s.id] ?? "other"
                shelfSection(s.label, s.books, key: key, hero: listening, showProgress: listening)
            }
        } else {
            shelfSection("Continue", library.continueListening, key: "continue", hero: true, showProgress: true)
            shelfSection("Recently Added", library.recentlyAdded, key: "recent", hero: false, showProgress: false)
            if settings.showNextInSeries {
                shelfSection("Next in Series", library.continueSeries, key: "series", hero: false, showProgress: false) { $0.seriesLabel }
            }
        }
    }

    @ViewBuilder
    private func shelfSection(_ title: String, _ books: [Book], key: String, hero: Bool, showProgress: Bool,
                              caption: ((Book) -> String?)? = nil) -> some View {
        if settings.carouselOff.contains(key) {
            // Carousel turned off in Settings: a plain row of covers.
            CoverShelf(title: title, books: books, showProgress: showProgress, path: $path, big: hero)
        } else if !books.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ShelfHeader(title: title) { path.append(ShelfRoute(title: title, books: books)) }
                carousel(books, key: key, hero: hero, showProgress: showProgress, caption: caption)
            }
        }
    }

    private func carousel(_ books: [Book], key: String, hero: Bool, showProgress: Bool, caption: ((Book) -> String?)?) -> some View {
        let speed = max(Store.double("playback_speed") ?? 1, 0.1)
        return KeylineCarousel(
            items: books,
            height: hero ? 250 : 210,
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
            let left = p.flatMap { p -> String? in
                guard showProgress, !p.isFinished else { return nil }
                let d = p.durationSec > 0 ? p.durationSec : (b.durationSec ?? 0)
                let l = max(d - p.currentTimeSec, 0) / speed
                return l > 0 ? "\(Format.hm(l)) left" : nil
            }
            CarouselCover(book: b, caption: left ?? caption?(b) ?? b.author,
                          progress: showProgress ? p?.progress : nil, fullness: fullness, hero: hero)
                .coverZoomSource("\(key)-\(b.id)", zoom, radius: 28)
        }
    }

    // MARK: library

    private func libraryHeader(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(filter == .all ? "All Books" : filter.label).font(.title2.bold())
            Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Picker("Show", selection: $filter) { ForEach(BookFilter.allCases) { Text($0.label).tag($0) } }
                Picker("Sort", selection: $sort) { ForEach(BookSort.allCases) { Text($0.label).tag($0) } }
                Divider()
                Toggle(isOn: Binding(get: { settings.gridLayout }, set: { settings.gridLayout = $0 })) {
                    Label("Show as Grid", systemImage: "square.grid.2x2")
                }
            } label: {
                Label(sort.label, systemImage: "line.3.horizontal.decrease")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 20)
        .onChange(of: sort) { _, v in Store.set(v.rawValue, "library_sort") }
        .task(id: sort) { if sort == .ratingDesc { await AudibleRating.shared.fill(library.books) } }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if library.syncing { ProgressView() }
            Text(library.syncing ? "Loading your library…" : "No books yet").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
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
            ForEach(books) { b in
                ZoomBookLink(book: b, source: "list-\(b.id)") { ListBookRow(book: b, zoomID: "list-\(b.id)") }
                    .bookContextMenu(b)
            }
            if let series, settings.seriesMissing { MissingSeriesBooks(series: series, books: books) }
        }
        .listStyle(.plain)
        .environment(\.coverZoom, zoom)
        .kitziBackground()
        .navigationTitle(title)
    }
}
