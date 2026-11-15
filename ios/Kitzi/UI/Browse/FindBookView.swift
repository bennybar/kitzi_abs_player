import SwiftUI

/// A book in Audible's catalog (not necessarily in the library).
struct AudibleBook: Identifiable, Hashable {
    let asin: String
    let title: String
    let subtitle: String?
    let authors: [String]
    let narrators: [String]
    let coverURL: URL?
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
    let genres: [String]
    let summary: String?
    var id: String { asin }

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
        publisher = p.str("publisher_name")
        series = p.objs("series").compactMap { s in
            guard let name = s.str("title") else { return nil }
            return s.str("sequence").map { "\(name), Book \($0)" } ?? name
        }
        var seen = Set<String>()
        genres = p.objs("category_ladders").flatMap { $0.objs("ladder").compactMap { $0.str("name") } }
            .filter { seen.insert($0).inserted }
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
    static func search(_ query: String) async throws -> [AudibleBook] {
        var c = URLComponents(string: "https://api.audible.com/1.0/catalog/products")!
        c.queryItems = [.init(name: "keywords", value: query), .init(name: "num_results", value: "30"),
                        .init(name: "products_sort_by", value: "Relevance"), .init(name: "image_sizes", value: "500"),
                        .init(name: "response_groups", value: groups)]
        return try await get(c.url!).objs("products").compactMap(AudibleBook.init)
    }

    private static let groups = "rating,product_desc,product_attrs,contributors,media,series,category_ladders,product_extended_attrs"
    private static var similarCache: [String: [AudibleBook]] = [:]

    /// "Listeners also enjoyed": Audible's similar books, in the book's own
    /// language (it also suggests the same book in other languages).
    static func similar(asin: String) async throws -> [AudibleBook] {
        if let c = similarCache[asin] { return c }
        let sims = try await get(URL(string: "https://api.audible.com/1.0/catalog/products/\(asin)/sims?similarity_type=RawSimilarities&num_results=20&image_sizes=500&response_groups=\(groups)")!)
        let own = try? await get(URL(string: "https://api.audible.com/1.0/catalog/products/\(asin)?response_groups=product_attrs")!)
        let language = own?.obj("product")?.str("language")
        let books = sims.objs("similar_products")
            .filter { p in language == nil || p.str("language") == nil || p.str("language") == language }
            .compactMap(AudibleBook.init)
            .filter { $0.asin != asin }
        similarCache[asin] = books
        return books
    }

    private static func get(_ url: URL) async throws -> JSON {
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let root = JSONUtil.parse(data) as? JSON else { throw URLError(.badServerResponse) }
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
    @State private var searchActive = true
    #if DEBUG
    @State private var testOpen: AudibleBook?
    #endif

    var body: some View {
        Group {
            if searching && results == nil {
                ProgressView("Searching Audible…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                ContentUnavailableView("Couldn't reach Audible", systemImage: "wifi.exclamationmark",
                                       description: Text("Check your connection and try again."))
            } else if let results, results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if let results {
                List(results) { b in
                    NavigationLink(value: b) { AudibleRow(book: b) }
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView("Find a Book", systemImage: "text.magnifyingglass",
                                       description: Text("Search Audible by title, author or narrator to see ratings, length and what it's about."))
            }
        }
        .kitziBackground()
        .navigationTitle("Find Book")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, isPresented: $searchActive, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Title, author, narrator")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { results = nil; failed = false; return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do {
                let found = try await AudibleCatalog.search(q)
                guard !Task.isCancelled else { return }
                results = found
                failed = false
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
        .onAppear { if query.isEmpty && !initialQuery.isEmpty { query = initialQuery; searchActive = false } }
        #if DEBUG
        // Test hook (simulator screenshots): open the first result.
        .navigationDestination(item: $testOpen) { AudibleBookView(book: $0) }
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
        AsyncImage(url: url) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "book.closed").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
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

private struct AudibleRow: View {
    let book: AudibleBook
    @Environment(LibraryStore.self) private var library

    var body: some View {
        HStack(spacing: 12) {
            AudibleCover(url: book.coverURL, size: 64)
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
    let book: AudibleBook
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
                    if let a = book.author { Text(a).font(.headline).foregroundStyle(Color.accentColor).multilineTextAlignment(.center) }
                    if !book.narrators.isEmpty {
                        Text("Narrated by \(book.narrators.joined(separator: ", "))").font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if let s = book.stars { AudibleStars(stars: s, count: book.ratingCount).font(.subheadline).padding(.top, 2) }
                    chips.padding(.top, 4)
                }
                actions
                if book.performanceStars != nil || book.storyStars != nil { ratingsCard }
                if let d = book.summary, !d.isEmpty { aboutCard(d) }
                detailsCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 80)
        }
        .kitziBackground()
        .navigationTitle("Audible")
        .navigationBarTitleDisplayMode(.inline)
        .task { if Shelfarr.shared.configured { try? await Shelfarr.shared.refresh() } }
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
            if Shelfarr.shared.configured {
                if let r = existingRequest {
                    Label("Requested on Shelfarr · \(r.status.capitalized)", systemImage: "tray.and.arrow.down")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    if library.match(book) == nil {
                        shelfarrButton.buttonStyle(.glassProminent)
                    } else {
                        shelfarrButton.buttonStyle(.glass)
                    }
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
            Toast.show("Sent \(m.title) to Shelfarr")
        } catch {
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
                    Button(expanded ? "Less" : "More") { withAnimation(.snappy) { expanded.toggle() } }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var detailsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Details").font(.headline)
                if !book.series.isEmpty { row("books.vertical", "Series", book.series.joined(separator: "\n")) }
                if let k = book.kind { row("headphones", "Type", [k, book.format].compactMap { $0 }.joined(separator: " · ")) }
                if !book.genres.isEmpty { row("tag", "Genres", book.genres.prefix(5).joined(separator: ", ")) }
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

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

extension LibraryStore {
    /// The library's copy of an Audible book: same title (or title plus subtitle) and author.
    func match(_ a: AudibleBook) -> Book? {
        let titles = AudibleRating.titleVariants(a.title).map(AudibleRating.norm)
        let authors = a.authors.map(AudibleRating.norm)
        return books.first { b in
            let t = AudibleRating.norm(b.title)
            guard titles.contains(where: { AudibleRating.similar($0, t) }) else { return false }
            let mine = (b.authors.isEmpty ? [b.author ?? ""] : b.authors).map(AudibleRating.norm)
            return authors.isEmpty || mine.contains { m in authors.contains { !m.isEmpty && ($0.contains(m) || m.contains($0)) } }
        }
    }
}

/// "Listeners Also Enjoyed" on a book's page: Audible's similar books, found by
/// the book's Audible match, in the Home shelves' M3 Expressive carousel. Hidden
/// when there's no match or Audible can't be reached.
struct SimilarBooksRow: View {
    let book: Book
    @State private var similar: [AudibleBook] = []
    @State private var opened: AudibleBook?
    @Environment(LibraryStore.self) private var library

    var body: some View {
        // A placeholder keeps the .task running when there's nothing to show yet.
        VStack(alignment: .leading, spacing: 12) {
            Color.clear.frame(height: 0)
            if !similar.isEmpty {
                Text("Listeners Also Enjoyed").font(.title3.bold())
                KeylineCarousel(
                    items: similar,
                    height: 210,
                    keylines: { w in
                        // One big cover, a medium and a small one peeking, as on Home.
                        let small: CGFloat = 40, medium = w * 0.2
                        return [w - medium - small - 16, medium, small]
                    },
                    onTap: { opened = $0 },
                    label: { $0.title }
                ) { s, fullness in
                    AudibleCarouselCover(book: s, inLibrary: library.match(s) != nil, fullness: fullness)
                }
                .padding(.horizontal, -16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationDestination(item: $opened) { AudibleBookView(book: $0) }
        .task(id: book.id) {
            similar = []
            guard let asin = await AudibleRating.shared.rating(for: book)?.asin,
                  let found = try? await AudibleCatalog.similar(asin: asin) else { return }
            withAnimation(.snappy) { similar = found }
        }
    }
}

/// A carousel item: the cover, and over it the title, stars and author.
private struct AudibleCarouselCover: View {
    let book: AudibleBook
    let inLibrary: Bool
    let fullness: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // In an overlay, so the filled image can't make the item taller than the
            // carousel gives it (that pushed the title below the clipped edge).
            Color.clear
                .overlay {
                    AsyncImage(url: book.coverURL) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(.quaternary)
                    }
                }
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
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
