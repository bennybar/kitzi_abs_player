import CryptoKit
import SwiftUI

/// A book in Audible's catalog (not necessarily in the library).
struct AudibleBook: Identifiable, Hashable {
    let asin: String
    let title: String
    let subtitle: String?
    let authors: [String]
    let narrators: [String]
    let coverURL: URL?
    /// A smaller cover for lists.
    let thumbURL: URL?
    let stars: Double?
    let ratingCount: Int
    let performanceStars: Double?
    let storyStars: Double?
    let minutes: Int?
    let format: String?
    let kind: String?
    let releaseDate: String?
    let language: String?
    let publisher: String?
    let series: [String]
    /// The series it belongs to, with its number there ("3", "2.5").
    let seriesRefs: [SeriesRef]
    let genres: [String]
    /// The genres with their Audible ids (tappable on the book's page).
    let genreRefs: [AudibleGenre]
    let summary: String?
    var id: String { asin }

    struct SeriesRef: Hashable { let asin: String; let title: String; let sequence: String? }
    var releaseDay: Date? { releaseDate.flatMap { Self.day.date(from: $0) } }
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var author: String? { authors.isEmpty ? nil : authors.joined(separator: ", ") }
    var year: String? { releaseDate.map { String($0.prefix(4)) } }

    init?(_ p: JSON) {
        guard let asin = p.str("asin"), let title = p.str("title") else { return nil }
        self.asin = asin
        self.title = title
        subtitle = p.str("subtitle")
        authors = p.objs("authors").compactMap { $0.str("name") }
        narrators = p.objs("narrators").compactMap { $0.str("name") }
        coverURL = (p.obj("product_images")?.str("500")).flatMap(URL.init(string:))
        thumbURL = (p.obj("product_images")?.str("252")).flatMap(URL.init(string:)) ?? coverURL
        let r = p.obj("rating")
        let d = r?.obj("overall_distribution")
        stars = (d?.num("display_average_rating") ?? d?.num("average_rating")).flatMap { $0 > 0 ? $0 : nil }
        ratingCount = d?.int("num_ratings") ?? 0
        performanceStars = (r?.obj("performance_distribution")?.num("display_average_rating")).flatMap { $0 > 0 ? $0 : nil }
        storyStars = (r?.obj("story_distribution")?.num("display_average_rating")).flatMap { $0 > 0 ? $0 : nil }
        minutes = p.int("runtime_length_min").flatMap { $0 > 0 ? $0 : nil }
        format = p.str("format_type").map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
        kind = p.str("content_delivery_type").map(Self.kindLabel)
        releaseDate = p.str("release_date") ?? p.str("issue_date")
        language = p.str("language").map { $0.capitalized }
        seriesRefs = p.objs("series").compactMap { s in
            guard let a = s.str("asin"), let t = s.str("title") else { return nil }
            return SeriesRef(asin: a, title: t, sequence: s.str("sequence"))
        }
        publisher = p.str("publisher_name")
        series = p.objs("series").compactMap { s in
            guard let name = s.str("title") else { return nil }
            return s.str("sequence").map { "\(name), Book \($0)" } ?? name
        }
        var seen = Set<String>()
        genreRefs = p.objs("category_ladders").flatMap { $0.objs("ladder") }.compactMap { g -> AudibleGenre? in
            guard let id = g.str("id"), let name = g.str("name"), seen.insert(id).inserted else { return nil }
            return AudibleGenre(id: id, name: name)
        }
        genres = genreRefs.map(\.name)
        summary = (p.str("publisher_summary") ?? p.str("merchandising_summary")).map(BookDetailView.stripHTML)
    }

    private static func kindLabel(_ t: String) -> String {
        switch t {
        case "SinglePartBook", "MultiPartBook": "Audiobook"
        case "Periodical", "PodcastParent", "PodcastEpisode", "PodcastSeason": "Podcast"
        case "BookSeries": "Series"
        default: t
        }
    }
}

enum AudibleCatalog {
    /// Everything a book's page shows.
    static let groups = "rating,product_desc,product_attrs,contributors,media,series,category_ladders,product_extended_attrs"
    /// What a list row shows (about half the download): the page loads the rest.
    static let listGroups = "rating,product_attrs,contributors,media,series"
    private static let base = "https://api.audible.com/1.0/catalog"

    enum SearchSort: String, CaseIterable, Identifiable {
        case relevance = "Relevance", bestSellers = "BestSellers", newest = "-ReleaseDate", longest = "-RuntimeLength"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .relevance: "Best match"
            case .bestSellers: "Bestsellers"
            case .newest: "Newest"
            case .longest: "Longest"
            }
        }
    }

    /// A page of search results (`page` from 0: Audible counts them from 0).
    static func search(_ query: String, sort: SearchSort = .relevance, page: Int = 0) async throws -> [AudibleBook] {
        var c = URLComponents(string: "\(base)/products")!
        c.queryItems = [.init(name: "keywords", value: query), .init(name: "num_results", value: "30"),
                        .init(name: "page", value: String(page)),
                        .init(name: "products_sort_by", value: sort.rawValue), .init(name: "image_sizes", value: "252,500"),
                        .init(name: "response_groups", value: listGroups)]
        return try await get(c.url!, ttl: 600).objs("products").compactMap(AudibleBook.init)
    }

    /// One book with everything its page shows.
    static func product(_ asin: String) async throws -> AudibleBook? {
        try await get(URL(string: "\(base)/products/\(asin)?image_sizes=252,500&response_groups=\(groups)")!, ttl: 86400)
            .obj("product").flatMap(AudibleBook.init)
    }

    /// Books by an author or a narrator, bestsellers first.
    static func books(author: String? = nil, narrator: String? = nil) async throws -> [AudibleBook] {
        var c = URLComponents(string: "\(base)/products")!
        c.queryItems = [.init(name: "num_results", value: "50"), .init(name: "products_sort_by", value: "BestSellers"),
                        .init(name: "image_sizes", value: "252,500"), .init(name: "response_groups", value: listGroups)]
        if let author { c.queryItems?.append(.init(name: "author", value: author)) }
        if let narrator { c.queryItems?.append(.init(name: "narrator", value: narrator)) }
        return mainLanguage(try await get(c.url!, ttl: 6 * 3600).objs("products").compactMap(AudibleBook.init))
    }

    /// An author's or a narrator's books, newest release first (pre-orders included).
    static func newest(author: String? = nil, narrator: String? = nil) async throws -> [AudibleBook] {
        var c = URLComponents(string: "\(base)/products")!
        c.queryItems = [.init(name: "num_results", value: "20"), .init(name: "products_sort_by", value: "-ReleaseDate"),
                        .init(name: "image_sizes", value: "252,500"), .init(name: "response_groups", value: listGroups)]
        if let author { c.queryItems?.append(.init(name: "author", value: author)) }
        if let narrator { c.queryItems?.append(.init(name: "narrator", value: narrator)) }
        // Kept 20 hours: the radar asks again after 12 (or 24), and a new book
        // can wait that long.
        return mainLanguage(try await get(c.url!, ttl: 20 * 3600).objs("products").compactMap(AudibleBook.init))
    }

    /// "Listeners also enjoyed": Audible's similar books, in the book's own
    /// language (it also suggests the same book in other languages).
    static func similar(asin: String, language: String? = nil) async throws -> [AudibleBook] {
        let sims = try await get(URL(string: "\(base)/products/\(asin)/sims?similarity_type=RawSimilarities&num_results=20&image_sizes=252,500&response_groups=\(listGroups)")!, ttl: 86400)
        var language = language
        if language == nil {
            language = try? await get(URL(string: "\(base)/products/\(asin)?response_groups=product_attrs")!, ttl: 7 * 86400)
                .obj("product")?.str("language")
        }
        return sims.objs("similar_products")
            .filter { p in language == nil || p.str("language") == nil || p.str("language") == language }
            .compactMap(AudibleBook.init)
            .filter { $0.asin != asin }
    }

    /// The language most of `books` are in, and only those (lists also carry translations).
    static func mainLanguage(_ books: [AudibleBook]) -> [AudibleBook] {
        let counts = Dictionary(grouping: books.compactMap(\.language), by: { $0 }).mapValues(\.count)
        guard let main = counts.max(by: { $0.value < $1.value })?.key else { return books }
        return books.filter { $0.language == nil || $0.language == main }
    }

    // Answers are kept (memory and disk) for `ttl` seconds: a page opened again
    // costs nothing, and Audible isn't asked more than it needs to be.
    private static var memory: [String: (Date, JSON)] = [:]
    private static let cacheDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("audible")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func get(_ url: URL, ttl: Double = 0) async throws -> JSON {
        let key = url.absoluteString
        // A stable name (hashValue changes every launch).
        let file = cacheDir.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
        if ttl > 0 {
            if let (at, j) = memory[key], Date().timeIntervalSince(at) < ttl { return j }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), let at = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(at) < ttl, let d = try? Data(contentsOf: file), let j = JSONUtil.parse(d) as? JSON {
                memory[key] = (at, j)
                return j
            }
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let root = JSONUtil.parse(data) as? JSON else { throw URLError(.badServerResponse) }
        if ttl > 0 {
            memory[key] = (Date(), root)
            try? data.write(to: file, options: .atomic)
        }
        return root
    }
}

struct FindBookRoute: Hashable { var query = "" }

/// Find Book: searches Audible's catalog, shown in Kitzi's own screens.
struct FindBookView: View {
    var initialQuery = ""
    @State private var query = ""
    @State private var results: [AudibleBook]?
    @State private var searching = false
    @State private var failed = false
    @State private var sort: AudibleCatalog.SearchSort = .relevance
    /// Other languages' editions too (off: only the language most results are in).
    @State private var allLanguages = false
    @State private var page = 0
    @State private var canLoadMore = false
    @State private var loadingMore = false
    /// Not focused at first: the genres are there to browse.
    @State private var searchActive = false
    #if DEBUG
    @State private var testOpen: AudibleBook?
    @State private var testGenre: AudibleGenre?
    #endif

    /// The next page of results, added below.
    private func loadMore() async {
        guard canLoadMore, !loadingMore, let current = results else { return }
        let q = query.trimmingCharacters(in: .whitespaces)
        loadingMore = true
        defer { loadingMore = false }
        guard let more = try? await AudibleCatalog.search(q, sort: sort, page: page + 1),
              q == query.trimmingCharacters(in: .whitespaces) else { return }
        page += 1
        let have = Set(current.map(\.asin))
        results = current + more.filter { !have.contains($0.asin) }
        canLoadMore = more.count >= 30
    }

    var body: some View {
        Group {
            if searching && results == nil {
                // Rows the shape of the results while Audible answers.
                List(0..<7, id: \.self) { _ in LoadingRow().listRowBackground(Color.clear) }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
            } else if failed {
                ContentUnavailableView("Couldn't reach Audible", systemImage: "wifi.exclamationmark",
                                       description: Text("Check your connection and try again."))
            } else if let results, results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if let results {
                let shown = allLanguages ? results : AudibleCatalog.mainLanguage(results)
                List {
                    ForEach(shown) { b in
                        NavigationLink(value: b) { AudibleRow(book: b) }
                            .listRowBackground(Color.clear)
                            // Near the end: the next page.
                            .onAppear { if b.id == shown.last?.id { Task { await loadMore() } } }
                    }
                    if loadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                // Nothing typed yet: browse Audible's bestsellers by genre.
                AudibleGenresList()
            }
        }
        .kitziBackground()
        .navigationTitle("Find Book")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, isPresented: $searchActive, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Title, author, narrator")
        .task(id: "\(query)|\(sort.rawValue)") {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = nil; failed = false; return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do {
                let found = try await AudibleCatalog.search(q, sort: sort)
                guard !Task.isCancelled else { return }
                results = found
                page = 0
                canLoadMore = found.count >= 30
                failed = false
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
        .toolbar {
            if results != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) { ForEach(AudibleCatalog.SearchSort.allCases) { Text($0.label).tag($0) } }
                        Toggle(isOn: $allLanguages) { Label("Other Languages", systemImage: "globe") }
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                }
            }
        }
        .onAppear { if query.isEmpty && !initialQuery.isEmpty { query = initialQuery; searchActive = false } }
        #if DEBUG
        // Test hook (simulator screenshots): open the first result.
        .navigationDestination(item: $testOpen) { AudibleBookView(book: $0) }
        .navigationDestination(item: $testGenre) { AudibleGenreView(genre: $0) }
        .task {
            if let g = ProcessInfo.processInfo.environment["KITZI_TEST_GENRE"] { testGenre = AudibleGenre(id: g, name: "Science Fiction & Fantasy") }
        }
        .onChange(of: results) { _, r in
            if ProcessInfo.processInfo.environment["KITZI_TEST_AUDIBLE_OPEN"] != nil, testOpen == nil { testOpen = r?.first }
        }
        #endif
    }
}

struct AudibleCover: View {
    let url: URL?
    var size: CGFloat

    var body: some View {
        AudibleImage(url: url)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
    }
}

/// An Audible cover, kept in memory and on disk (so it doesn't flash when a
/// list or carousel brings it back). Its own session: Kitzi's image loader
/// signs requests for the user's server, and that mustn't go to Amazon.
struct AudibleImage: View {
    let url: URL?
    @State private var image: UIImage?

    private static let memory: NSCache<NSURL, UIImage> = { let c = NSCache<NSURL, UIImage>(); c.countLimit = 200; return c }()
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 8_000_000, diskCapacity: 150_000_000,
                              directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("audible-covers"))
        c.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: c)
    }()

    var body: some View {
        // In memory: shown in the first frame, not after the task (it flashed).
        let image = image ?? url.flatMap { Self.memory.object(forKey: $0 as NSURL) }
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "book.closed").foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            guard let url else { return }
            if let m = Self.memory.object(forKey: url as NSURL) { self.image = m; return }
            guard let (data, _) = try? await Self.session.data(from: url),
                  let img = await UIImage(data: data)?.byPreparingForDisplay() else { return }
            Self.memory.setObject(img, forKey: url as NSURL)
            if UIAccessibility.isReduceMotionEnabled { self.image = img }
            else { withAnimation(.easeOut(duration: 0.2)) { self.image = img } }
        }
    }
}

/// Stars, the average and how many ratings.
struct AudibleStars: View {
    let stars: Double
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5) { i in
                let v = stars - Double(i)
                Image(systemName: v >= 0.75 ? "star.fill" : (v >= 0.25 ? "star.leadinghalf.filled" : "star"))
            }
            .foregroundStyle(.orange)
            Text(String(format: "%.1f", stars)).fontWeight(.semibold)
            if count > 0 { Text("(\(count.formatted(.number.notation(.compactName))))").foregroundStyle(.secondary) }
        }
        .accessibilityElement()
        .accessibilityLabel("\(String(format: "%.1f", stars)) stars, \(count) ratings")
    }
}

struct AudibleRow: View {
    let book: AudibleBook
    @Environment(LibraryStore.self) private var library

    var body: some View {
        HStack(spacing: 12) {
            AudibleCover(url: book.thumbURL, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.body.weight(.semibold)).lineLimit(2)
                if let a = book.author { Text(a).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                if let s = book.stars { AudibleStars(stars: s, count: book.ratingCount).font(.caption) }
                HStack(spacing: 6) {
                    Text([book.minutes.map { Format.hm(Double($0 * 60)) }, book.format, book.year].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    if library.match(book) != nil {
                        Text("In Library").font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// An Audible book's page, laid out like Kitzi's own book page.
struct AudibleBookView: View {
    private let initial: AudibleBook
    /// The book as a list had it, then with everything (description, genres…).
    @State private var full: AudibleBook?
    private var book: AudibleBook { full ?? initial }
    init(book: AudibleBook) { initial = book }
    @Environment(LibraryStore.self) private var library
    @State private var expanded = false
    @State private var shelfarrMatches: [ShelfarrBook]?
    @State private var shelfarrBusy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                AudibleCover(url: book.coverURL, size: 220)
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                    .padding(.top, 8)
                VStack(spacing: 6) {
                    Text(book.title).font(.title2.bold()).multilineTextAlignment(.center)
                    if let s = book.subtitle { Text(s).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    if !book.authors.isEmpty {
                        people(book.authors, route: AudibleListRoute.author) {
                            Text(book.authors.joined(separator: ", ")).font(.headline).foregroundStyle(Color.accentColor)
                        }
                    }
                    if !book.narrators.isEmpty {
                        people(book.narrators, route: AudibleListRoute.narrator) {
                            (Text("Narrated by ").foregroundStyle(.secondary) + Text(book.narrators.joined(separator: ", ")).foregroundStyle(Color.accentColor))
                                .font(.subheadline)
                        }
                    }
                    if let s = book.stars { AudibleStars(stars: s, count: book.ratingCount).font(.subheadline).padding(.top, 2) }
                    chips.padding(.top, 4)
                }
                actions
                if book.performanceStars != nil || book.storyStars != nil { ratingsCard }
                if let d = book.summary, !d.isEmpty { aboutCard(d) }
                VStack(spacing: 0) {
                    AudibleReviewsCard(asin: book.asin)
                    detailsCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 80)
        }
        .kitziBackground()
        .navigationTitle("Audible")
        .navigationBarTitleDisplayMode(.inline)
        .task { if Shelfarr.shared.configured { try? await Shelfarr.shared.refresh() } }
        .task(id: initial.asin) { if full == nil, let f = try? await AudibleCatalog.product(initial.asin) { full = f } }
        .confirmationDialog("Which book should Shelfarr get?", isPresented: Binding(get: { shelfarrMatches != nil }, set: { if !$0 { shelfarrMatches = nil } }),
                            titleVisibility: .visible, presenting: shelfarrMatches) { matches in
            ForEach(matches.prefix(6)) { m in
                Button([m.title, m.author, m.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")) {
                    Task { await request(m) }
                }
            }
        } message: { _ in
            Text("Shelfarr will search for the audiobook and download it to your library.")
        }
    }

    /// An author or narrator line: one person opens their books; several, a menu.
    @ViewBuilder private func people<L: View>(_ names: [String], route: @escaping (String) -> AudibleListRoute,
                                              @ViewBuilder label: () -> L) -> some View {
        if names.count == 1 {
            NavigationLink(value: route(names[0])) { label().multilineTextAlignment(.center) }.buttonStyle(.plain)
        } else {
            Menu {
                ForEach(names, id: \.self) { n in NavigationLink(value: route(n)) { Text(n) } }
            } label: { label().multilineTextAlignment(.center) }
            .buttonStyle(.plain)
        }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            if let m = book.minutes { chip("clock", Format.hm(Double(m * 60))) }
            if let f = book.format { chip("text.book.closed", f) }
            if let y = book.year { chip("calendar", y) }
        }
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 10) {
            if let mine = library.match(book) {
                NavigationLink(value: mine) {
                    Label("Open in Your Library", systemImage: "books.vertical.fill").font(.headline)
                        .frame(maxWidth: .infinity).frame(height: 50)
                }
                .buttonStyle(.glassProminent)
            }
            // Already in the library: nothing to send.
            if Shelfarr.shared.configured && library.match(book) == nil {
                if let r = existingRequest {
                    Label("Requested on Shelfarr · \(r.status.capitalized)", systemImage: "tray.and.arrow.down")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    shelfarrButton.buttonStyle(.glassProminent)
                }
            }
        }
    }

    private var shelfarrButton: some View {
        Button { Task { await findOnShelfarr() } } label: {
            HStack(spacing: 8) {
                if shelfarrBusy { ProgressView() } else { Image(systemName: "tray.and.arrow.down.fill") }
                Text("Send to Shelfarr")
            }
            .font(.headline).frame(maxWidth: .infinity).frame(height: 50)
        }
        .disabled(shelfarrBusy)
    }

    /// A request already on Shelfarr for this title.
    private var existingRequest: ShelfarrRequest? {
        let t = AudibleRating.norm(book.title)
        return Shelfarr.shared.requests.first { AudibleRating.similar(AudibleRating.norm($0.title), t) }
    }

    private func findOnShelfarr() async {
        shelfarrBusy = true
        defer { shelfarrBusy = false }
        let title = AudibleRating.titleVariants(book.title).first ?? book.title
        let author = book.authors.first
        do {
            var found = try await Shelfarr.shared.search([title, author].compactMap { $0 }.joined(separator: " "))
            if found.isEmpty, author != nil { found = try await Shelfarr.shared.search(title) }
            if found.isEmpty {
                Toast.show("Shelfarr didn't find \(book.title)")
            } else {
                // The likeliest first: same title, then same author.
                let t = AudibleRating.norm(title), a = author.map(AudibleRating.norm)
                shelfarrMatches = found.sorted { score($0, t, a) > score($1, t, a) }
            }
        } catch {
            Toast.show(error.localizedDescription)
        }
    }

    private func score(_ m: ShelfarrBook, _ title: String, _ author: String?) -> Int {
        var s = AudibleRating.similar(AudibleRating.norm(m.title), title) ? 2 : 0
        if let author, let ma = m.author.map(AudibleRating.norm), ma.contains(author) || author.contains(ma) { s += 1 }
        return s
    }

    private func request(_ m: ShelfarrBook) async {
        do {
            try await Shelfarr.shared.request(m)
            Haptics.success()
            Toast.show("Sent \(m.title) to Shelfarr")
        } catch {
            Haptics.failure()
            Toast.show(error.localizedDescription)
        }
    }

    private var ratingsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ratings").font(.headline)
                if let s = book.stars { ratingLine("Overall", s) }
                if let s = book.performanceStars { ratingLine("Performance", s) }
                if let s = book.storyStars { ratingLine("Story", s) }
            }
        }
    }

    private func ratingLine(_ label: String, _ stars: Double) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            AudibleStars(stars: stars, count: 0)
            Spacer()
        }
        .font(.subheadline)
    }

    private func aboutCard(_ text: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("About").font(.headline)
                Text(text).font(.body).lineLimit(expanded ? nil : 6)
                if text.count > 300 {
                    Button(expanded ? "Less" : "More") { withAnimation(.kitzi) { expanded.toggle() } }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var detailsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Details").font(.headline)
                ForEach(book.seriesRefs, id: \.asin) { ref in
                    NavigationLink(value: AudibleListRoute.series(ref)) {
                        linkRow("books.vertical", "Series", ref.sequence.map { "\(ref.title), Book \($0)" } ?? ref.title)
                    }
                    .buttonStyle(.plain)
                }
                if let k = book.kind { row("headphones", "Type", [k, book.format].compactMap { $0 }.joined(separator: " · ")) }
                ForEach(Array(book.genreRefs.prefix(5).enumerated()), id: \.element.id) { i, g in
                    NavigationLink(value: g) { linkRow(i == 0 ? "tag" : "", i == 0 ? "Genres" : "", g.name) }
                        .buttonStyle(.plain)
                }
                if let d = book.releaseDate { row("calendar", "Released", d) }
                if let l = book.language { row("globe", "Language", l) }
                if let p = book.publisher { row("building.2", "Publisher", p) }
                row("number", "ASIN", book.asin)
            }
        }
    }

    private func row(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 22)
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .font(.subheadline)
    }

    /// A details row that opens something: the value in the accent colour, with a chevron.
    private func linkRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon.isEmpty ? "tag" : icon).foregroundStyle(Color.accentColor).frame(width: 22).opacity(icon.isEmpty ? 0 : 1)
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).foregroundStyle(Color.accentColor).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .contentShape(Rectangle())
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// "Listeners Also Enjoyed" on a book's page: Audible's similar books, found by
/// the book's Audible match, in the Home shelves' M3 Expressive carousel. Hidden
/// when there's no match or Audible can't be reached.
struct SimilarBooksRow: View {
    let book: Book
    @State private var similar: [AudibleBook] = []
    /// Which of them are in the library (matched once, not on every scroll frame).
    @State private var owned: Set<String> = []
    @State private var opened: AudibleBook?
    @State private var loaded = false
    @Environment(LibraryStore.self) private var library

    var body: some View {
        // A placeholder keeps the .task running when there's nothing to show yet.
        VStack(alignment: .leading, spacing: 12) {
            Color.clear.frame(height: 0)
            if !loaded {
                // Its place held while Audible answers, so the page doesn't jump.
                Text("Listeners Also Enjoyed").font(.title3.bold())
                LoadingBlock(height: CarouselSize.cover, radius: 28)
            } else if !similar.isEmpty {
                Text("Listeners Also Enjoyed").font(.title3.bold())
                KeylineCarousel(
                    items: similar,
                    height: CarouselSize.cover,
                    keylines: { w in
                        // One big cover, a medium and a small one peeking, as on Home.
                        let small: CGFloat = 40, medium = w * 0.2
                        return [w - medium - small - 16, medium, small]
                    },
                    onTap: { opened = $0 },
                    label: { $0.title }
                ) { s, fullness in
                    AudibleCarouselCover(book: s, inLibrary: owned.contains(s.asin), fullness: fullness)
                }
                .padding(.horizontal, -16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Its own gap below, only when there's something (see AudibleReviewsCard).
        .padding(.bottom, loaded && similar.isEmpty ? 0 : 18)
        .navigationDestination(item: $opened) { AudibleBookView(book: $0) }
        .task(id: book.id) {
            similar = []
            loaded = false
            defer { withAnimation(.kitzi) { loaded = true } }
            guard let asin = await AudibleRating.shared.asin(for: book),
                  let found = try? await AudibleCatalog.similar(asin: asin, language: await AudibleRating.shared.language(for: book)) else { return }
            owned = Set(found.filter { library.match($0) != nil }.map(\.asin))
            similar = found
        }
    }
}

/// A carousel item: the cover, and over it the title, stars and author.
struct AudibleCarouselCover: View {
    let book: AudibleBook
    let inLibrary: Bool
    let fullness: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // In an overlay, so the filled image can't make the item taller than the
            // carousel gives it (that pushed the title below the clipped edge).
            Color.clear
                .overlay { AudibleImage(url: book.coverURL) }
                .clipped()
            LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.6), location: 0.72),
                                   .init(color: .black.opacity(0.92), location: 1)], startPoint: .top, endPoint: .bottom)
                .opacity(Double(fullness))
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    if let st = book.stars {
                        Image(systemName: "star.fill").foregroundStyle(.orange)
                        Text(String(format: "%.1f", st)).fontWeight(.semibold)
                    }
                    if let a = book.authors.first { Text(book.stars == nil ? a : "· \(a)").lineLimit(1) }
                }
                .font(.caption).foregroundStyle(.white.opacity(0.85))
            }
            .foregroundStyle(.white)
            .padding(12)
            .opacity(Double(max(fullness * 1.6 - 0.6, 0)))
            if inLibrary {
                Image(systemName: "checkmark.circle.fill").font(.title3)
                    .symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .opacity(Double(max(fullness * 1.6 - 0.6, 0)))
            }
        }
    }
}
