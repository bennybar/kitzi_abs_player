import SwiftUI

// More from Audible's catalog: reviews, bestsellers by genre, and the books of a
// series that aren't in the library. All shown in Kitzi's own screens.

struct AudibleGenre: Hashable, Identifiable {
    let id: String
    let name: String
}

/// A list of Audible books from a book's page: an author's, a narrator's, a series'.
enum AudibleListRoute: Hashable {
    case author(String), narrator(String), series(AudibleBook.SeriesRef)
}

struct AudibleReview: Identifiable {
    let id: String
    let title: String?
    let body: String
    let author: String?
    let stars: Double?
    let date: Date?
    let helpful: Int
}

extension AudibleCatalog {
    /// The most helpful reviews.
    static func reviews(asin: String, count: Int = 5) async throws -> [AudibleReview] {
        let url = URL(string: "https://api.audible.com/1.0/catalog/products/\(asin)/reviews?num_results=\(count)&sort_by=MostHelpful")!
        return try await get(url, ttl: 86400).objs("customer_reviews").compactMap { r in
            // Reviews carry bits of HTML ("<br />").
            guard let id = r.str("id"), let body = r.str("body").map(BookDetailView.stripHTML), !body.isEmpty else { return nil }
            return AudibleReview(id: id, title: r.str("title").map(BookDetailView.stripHTML),
                                 body: body, author: r.str("author_name"),
                                 stars: r.obj("ratings")?.num("overall_rating").flatMap { $0 > 0 ? $0 : nil },
                                 date: r.str("submission_date").flatMap { ISO8601DateFormatter().date(from: $0) },
                                 helpful: r.obj("review_content_scores")?.int("num_helpful_votes") ?? 0)
        }
    }

    private static var genreCache: [String: [AudibleGenre]] = [:]

    /// The top-level genres (`parent` nil), or a genre's subgenres.
    static func genres(parent: String? = nil) async throws -> [AudibleGenre] {
        let key = parent ?? ""
        if let c = genreCache[key] { return c }
        let root: [JSON]
        if let parent {
            root = try await get(URL(string: "https://api.audible.com/1.0/catalog/categories/\(parent)?categories_num_levels=1")!, ttl: 7 * 86400)
                .obj("category")?.objs("children") ?? []
        } else {
            root = try await get(URL(string: "https://api.audible.com/1.0/catalog/categories?categories_num_levels=1")!, ttl: 7 * 86400).objs("categories")
        }
        let genres = root.compactMap { c -> AudibleGenre? in
            guard let id = c.str("id"), let name = c.str("name") else { return nil }
            return AudibleGenre(id: id, name: name)
        }
        genreCache[key] = genres
        return genres
    }

    enum GenreList: String, CaseIterable, Identifiable {
        case bestsellers = "Bestsellers", topRated = "Top Rated", newReleases = "New Releases"
        var id: String { rawValue }
    }

    /// A genre's bestsellers (top 100), in the language most of them are in.
    static func bestsellers(_ genre: String) async throws -> [AudibleBook] {
        var books: [AudibleBook] = []
        for page in 0...1 { // Audible counts pages from 0
            let url = URL(string: "https://api.audible.com/1.0/catalog/products?category_id=\(genre)&products_sort_by=BestSellers&num_results=50&page=\(page)&image_sizes=252,500&response_groups=\(listGroups)")!
            books += try await get(url, ttl: 6 * 3600).objs("products").compactMap(AudibleBook.init)
        }
        var seen = Set<String>()
        return mainLanguage(books.filter { seen.insert($0.asin).inserted })
    }

    /// A genre's list. Top rated: its bestsellers by stars weighted by how many
    /// rated them (Audible's own rating sort puts a 4.9 from 200 people first).
    /// New releases: its bestsellers out in the last four months, newest first
    /// (Audible's newest-first list is pages of pre-orders).
    static func genreBooks(_ genre: String, _ list: GenreList) async throws -> [AudibleBook] {
        let books = try await bestsellers(genre)
        switch list {
        case .bestsellers:
            return books
        case .topRated:
            return books.filter { ($0.stars ?? 0) > 0 }.sorted { weighted($0) > weighted($1) }
        case .newReleases:
            let now = Date(), from = now.addingTimeInterval(-120 * 86400)
            return books.filter { ($0.releaseDay.map { $0 >= from && $0 <= now }) ?? false }
                .sorted { ($0.releaseDay ?? .distantPast) > ($1.releaseDay ?? .distantPast) }
        }
    }

    /// Stars pulled towards a typical 4.3 by the weight of 100 ratings.
    static func weighted(_ b: AudibleBook) -> Double {
        let n = Double(b.ratingCount)
        return ((b.stars ?? 0) * n + 4.3 * 100) / (n + 100)
    }

    /// The Audible series a library series is, from the first of its books Audible
    /// knows: the one whose name matches (or the book's only series). Nil rather
    /// than a guess when the book is in several and none matches (a bigger
    /// "universe" isn't this series).
    static func series(named name: String, books: [Book]) async throws -> (ref: AudibleBook.SeriesRef, language: String?)? {
        let want = AudibleRating.norm(name)
        for b in books.prefix(4) {
            guard let asin = await AudibleRating.shared.asin(for: b) else { continue }
            guard let p = try await get(URL(string: "https://api.audible.com/1.0/catalog/products/\(asin)?response_groups=series,product_attrs")!, ttl: 86400)
                .obj("product") else { continue }
            let refs = p.objs("series").compactMap { s -> AudibleBook.SeriesRef? in
                guard let a = s.str("asin"), let t = s.str("title") else { return nil }
                return AudibleBook.SeriesRef(asin: a, title: t, sequence: s.str("sequence"))
            }
            let named = refs.first { AudibleRating.norm($0.title) == want }
                ?? refs.first { AudibleRating.similar(AudibleRating.norm($0.title), want) }
            if let ref = named ?? (refs.count == 1 ? refs[0] : nil) { return (ref, p.str("language")) }
        }
        return nil
    }

    /// Every book of an Audible series, in series order, in `language` if given.
    static func seriesBooks(_ series: AudibleBook.SeriesRef, language: String?) async throws -> [AudibleBook] {
        let rels = try await get(URL(string: "https://api.audible.com/1.0/catalog/products/\(series.asin)?response_groups=relationships")!, ttl: 86400)
            .obj("product")?.objs("relationships")
            .filter { $0.str("relationship_type") == "series" && $0.str("relationship_to_product") == "child" } ?? []
        let asins = rels.compactMap { $0.str("asin") }
        var found: [AudibleBook] = []
        for start in stride(from: 0, to: asins.count, by: 40) {
            let chunk = asins[start..<min(start + 40, asins.count)].joined(separator: ",")
            let url = URL(string: "https://api.audible.com/1.0/catalog/products?asins=\(chunk)&image_sizes=252,500&response_groups=\(listGroups)")!
            found += try await get(url, ttl: 86400).objs("products").compactMap(AudibleBook.init)
        }
        let lang = language.map { $0.capitalized }
        return found
            .filter { lang == nil || $0.language == nil || $0.language == lang }
            .sorted {
                let (a, b) = (sequence($0, in: series.asin), sequence($1, in: series.asin))
                // Editions of the same number: the most-rated first.
                return a != b ? a < b : $0.ratingCount > $1.ratingCount
            }
    }

    /// The numbers a series entry covers: "3" is [3], "1-3" (a box set) is
    /// [1, 2, 3], "2.5" is [2.5]; empty when it has none.
    static func numbers(_ sequence: String?) -> [Double] {
        guard let s = sequence?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return [] }
        if let n = Double(s) { return [n] }
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == "–" }).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), a <= b, b - a < 50 { return (a...b).map(Double.init) }
        return []
    }

    /// "4", or "2.5".
    static func label(_ n: Double) -> String {
        n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
    }

    /// The book's number in a series (unnumbered last).
    static func sequence(_ b: AudibleBook, in series: String) -> Double {
        numbers(b.seriesRefs.first { $0.asin == series }?.sequence).first ?? 9999
    }
}

// MARK: genres

/// Find Book before anything is typed: Audible's genres.
struct AudibleGenresList: View {
    @State private var genres: [AudibleGenre]?
    @State private var failed = false

    var body: some View {
        List {
            Section {
                if let genres {
                    ForEach(genres) { g in
                        NavigationLink(value: g) { Text(g.name) }
                            .listRowBackground(Color.clear)
                    }
                } else if failed {
                    Text("Couldn't reach Audible.").foregroundStyle(.secondary).listRowBackground(Color.clear)
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
            } header: {
                Text("Bestsellers by Genre")
            } footer: {
                Text("Or search Audible by title, author or narrator.")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .task {
            guard genres == nil else { return }
            do { genres = try await AudibleCatalog.genres() } catch { failed = true }
        }
    }
}

/// A genre's bestsellers, with its subgenres along the top.
struct AudibleGenreView: View {
    let genre: AudibleGenre
    @State private var list: AudibleCatalog.GenreList = .bestsellers
    @State private var books: [AudibleBook]?
    @State private var subgenres: [AudibleGenre] = []
    @State private var failed = false

    var body: some View {
        List {
            if !subgenres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(subgenres) { g in
                            NavigationLink(value: g) {
                                Text(g.name).font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .glassEffect(.regular.interactive(), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Picker("List", selection: $list) {
                ForEach(AudibleCatalog.GenreList.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            if let books, books.isEmpty {
                Text(list == .newReleases ? "No bestsellers came out here in the last four months." : "Nothing here yet.")
                    .font(.subheadline).foregroundStyle(.secondary).listRowBackground(Color.clear)
            } else if let books {
                ForEach(Array(books.enumerated()), id: \.element.id) { i, b in
                    NavigationLink(value: b) {
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(i + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(minWidth: 26, alignment: .trailing).padding(.top, 4)
                            AudibleRow(book: b)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } else if failed {
                ContentUnavailableView("Couldn't reach Audible", systemImage: "wifi.exclamationmark",
                                       description: Text("Check your connection and try again."))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(0..<7, id: \.self) { _ in LoadingRow().listRowBackground(Color.clear) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .kitziBackground()
        .navigationTitle(genre.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: list) {
            books = nil
            failed = false
            do { books = try await AudibleCatalog.genreBooks(genre.id, list) } catch { failed = true }
        }
        .task { subgenres = (try? await AudibleCatalog.genres(parent: genre.id)) ?? [] }
    }
}

// MARK: reviews

/// The most helpful Audible reviews, on an Audible book's page. Hidden when
/// there are none or Audible can't be reached.
struct AudibleReviewsCard: View {
    let asin: String
    /// Nil while loading (a placeholder holds its place).
    @State private var reviews: [AudibleReview]?
    @State private var expanded: Set<String> = []
    /// Two to start with (five long reviews ran two screens); the rest on demand.
    @State private var showAll = false

    var body: some View {
        // A placeholder keeps the .task running when there's nothing to show yet.
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if reviews == nil {
                LoadingBlock(height: 220)
            } else if let reviews, !reviews.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Reviews").font(.headline)
                    ForEach(showAll ? reviews : Array(reviews.prefix(2))) { r in
                        if r.id != reviews.first?.id { Divider() }
                        review(r)
                    }
                    if !showAll, reviews.count > 2 {
                        Divider()
                        Button("Show \(reviews.count - 2) More Reviews") { withAnimation(.kitzi) { showAll = true } }
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        // Its own gap below, only when there's something (pages stack it with no
        // spacing, so an empty one leaves no double gap).
        .padding(.bottom, reviews?.isEmpty == true ? 0 : 18)
        .animation(.kitzi, value: reviews == nil)
        .task(id: asin) {
            reviews = (try? await AudibleCatalog.reviews(asin: asin)) ?? []
        }
    }

    private func review(_ r: AudibleReview) -> some View {
        let open = expanded.contains(r.id)
        return VStack(alignment: .leading, spacing: 6) {
            if let s = r.stars { AudibleStars(stars: s, count: 0).font(.caption) }
            if let t = r.title, !t.isEmpty { Text(t).font(.subheadline.weight(.semibold)) }
            Text(r.body).font(.subheadline).lineLimit(open ? nil : 5)
            HStack(spacing: 6) {
                Text([r.author, r.date?.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · "))
                if r.helpful > 0 { Text("· \(r.helpful.formatted()) found helpful") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.kitzi) { if open { expanded.remove(r.id) } else { expanded.insert(r.id) } } }
    }
}

// MARK: series

/// On a series' page: its books on Audible that aren't in the library (or
/// coming soon), each opening its Audible page (Send to Shelfarr is there).
struct MissingSeriesBooks: View {
    let series: String
    let books: [Book]
    @Environment(LibraryStore.self) private var library
    @State private var missing: [AudibleBook]?
    @State private var done = false

    var body: some View {
        Section {
            if let missing {
                if missing.isEmpty {
                    Label("You have every book in this series", systemImage: "checkmark.seal")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(missing) { b in
                        NavigationLink(value: b) {
                            VStack(alignment: .leading, spacing: 4) {
                                AudibleRow(book: b)
                                if let line = line(b) {
                                    Text(line).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                                        .padding(.leading, 76)
                                }
                            }
                        }
                    }
                }
            } else if !done {
                LoadingRow()
                LoadingRow()
            }
        } header: {
            if missing != nil || !done { Text("Not in Your Library") }
        }
        .task(id: series) {
            guard missing == nil else { return }
            defer { done = true }
            guard let found = try? await AudibleCatalog.series(named: series, books: books),
                  let all = try? await AudibleCatalog.seriesBooks(found.ref, language: found.language) else { return }
            // Not already here: by ASIN or title, or by its number in the series
            // (another edition of a book that's here; a box set of books that are).
            let owned = Set(books.compactMap(\.seriesSequence))
            var seen = Set<Double>()
            missing = all.filter { b in
                guard library.match(b) == nil else { return false }
                let ns = AudibleCatalog.numbers(b.seriesRefs.first { $0.asin == found.ref.asin }?.sequence)
                guard !ns.isEmpty else { return true }
                if ns.allSatisfy(owned.contains) { return false }
                // One edition per number: the most-rated (they come first).
                if ns.count == 1 { return seen.insert(ns[0]).inserted }
                return true
            }
        }
    }

    /// "Book 4 · Coming 12 Mar 2027".
    private func line(_ b: AudibleBook) -> String? {
        let n = b.seriesRefs.compactMap(\.sequence).first.map { $0.contains("-") ? "Books \($0)" : "Book \($0)" }
        var coming: String?
        if let d = b.releaseDay, d > Date() { coming = "Coming \(d.formatted(date: .abbreviated, time: .omitted))" }
        let parts = [n, coming].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: rating sort

/// "Getting Audible ratings… 120 of 800" while the "Highest rated" sort fills
/// in the ratings it doesn't have yet.
struct RatingFillBanner: View {
    var body: some View {
        let r = AudibleRating.shared
        if r.fillTotal > 0 {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Getting Audible ratings… \(r.fillDone) of \(r.fillTotal)")
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }
}

/// Reviews on a library book's page: its Audible match's (none when Audible
/// has no match).
struct LibraryBookReviews: View {
    let book: Book
    @State private var asin: String?
    @State private var matched = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if let asin {
                AudibleReviewsCard(asin: asin)
            } else if !matched {
                LoadingBlock(height: 220)
            }
        }
        .padding(.bottom, matched ? 0 : 18) // the card inside brings its own
        .animation(.kitzi, value: matched)
        .task(id: book.id) {
            asin = nil
            matched = false
            asin = await AudibleRating.shared.asin(for: book)
            matched = true
        }
    }
}

// MARK: author, narrator, series

/// An author's or narrator's books on Audible (bestsellers first), or a series'
/// books in order. Each opens its Audible page.
struct AudibleListView: View {
    let route: AudibleListRoute
    @State private var books: [AudibleBook]?
    @State private var failed = false

    private var title: String {
        switch route {
        case .author(let n), .narrator(let n): n
        case .series(let ref): ref.title
        }
    }

    var body: some View {
        List {
            if case .narrator = route {
                Text("Narrated by \(title)").font(.subheadline).foregroundStyle(.secondary).listRowBackground(Color.clear)
            }
            if let books {
                if books.isEmpty {
                    Text("Audible has nothing here.").foregroundStyle(.secondary).listRowBackground(Color.clear)
                }
                ForEach(books) { b in
                    NavigationLink(value: b) {
                        VStack(alignment: .leading, spacing: 4) {
                            AudibleRow(book: b)
                            if case .series(let ref) = route, let seq = b.seriesRefs.first(where: { $0.asin == ref.asin })?.sequence {
                                Text(seq.contains("-") ? "Books \(seq)" : "Book \(seq)")
                                    .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor).padding(.leading, 76)
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } else if failed {
                ContentUnavailableView("Couldn't reach Audible", systemImage: "wifi.exclamationmark",
                                       description: Text("Check your connection and try again."))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(0..<7, id: \.self) { _ in LoadingRow().listRowBackground(Color.clear) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .kitziBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard books == nil else { return }
            do {
                switch route {
                case .author(let n): books = try await AudibleCatalog.books(author: n)
                case .narrator(let n): books = try await AudibleCatalog.books(narrator: n)
                case .series(let ref):
                    let all = try await AudibleCatalog.seriesBooks(ref, language: nil)
                    books = AudibleCatalog.mainLanguage(all)
                }
            } catch { failed = true }
        }
    }
}

// MARK: next in series

/// On a library book's page: the next book of its series on Audible, opening the
/// library's copy when it's here, else its Audible page (with Send to Shelfarr).
struct NextInSeriesCard: View {
    let book: Book
    @Environment(LibraryStore.self) private var library
    @State private var next: AudibleBook?
    @State private var number: String?
    @State private var looked = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if !looked {
                LoadingBlock(height: 92)
            } else if let next {
                let mine = library.match(next) ?? ownedByNumber
                Group {
                    if let mine {
                        NavigationLink(value: mine) { card(next, status: "In your library") }
                    } else {
                        NavigationLink(value: next) { card(next, status: coming(next) ?? "Not in your library") }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, looked && next == nil ? 0 : 18)
        .animation(.kitzi, value: looked)
        .task(id: book.id) {
            next = nil
            looked = false
            defer { looked = true }
            guard let name = book.series, let current = book.seriesSequence else { return }
            let inSeries = library.books.filter { $0.series == name }.sorted { ($0.seriesSequence ?? 0) < ($1.seriesSequence ?? 0) }
            guard let found = try? await AudibleCatalog.series(named: name, books: [book] + inSeries.filter { $0.id != book.id }),
                  let all = try? await AudibleCatalog.seriesBooks(found.ref, language: found.language) else { return }
            // The first single book numbered after this one (not a box set).
            let candidate = all.first { b in
                let ns = AudibleCatalog.numbers(b.seriesRefs.first { $0.asin == found.ref.asin }?.sequence)
                return ns.count == 1 && ns[0] > current
            }
            number = candidate?.seriesRefs.first { $0.asin == found.ref.asin }?.sequence
            #if DEBUG
            print("KITZITEST next series=\(found.ref.title) current=\(current) next=\(candidate?.title ?? "-") #\(number ?? "-") owned=\(candidate.flatMap { library.match($0)?.title } ?? "no")")
            #endif
            withAnimation(.kitzi) { next = candidate }
        }
    }

    /// The library's book with that number in this series (another edition).
    private var ownedByNumber: Book? {
        guard let n = number.flatMap(Double.init), let name = book.series else { return nil }
        return library.books.first { $0.series == name && $0.seriesSequence == n }
    }

    private func coming(_ b: AudibleBook) -> String? {
        guard let d = b.releaseDay, d > Date() else { return nil }
        return "Coming \(d.formatted(date: .abbreviated, time: .omitted))"
    }

    private func card(_ b: AudibleBook, status: String) -> some View {
        HStack(spacing: 14) {
            AudibleCover(url: b.thumbURL, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("Next in \(book.series ?? "Series")").font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Text(b.title).font(.headline).lineLimit(2)
                Text([number.map { "Book \($0)" }, status].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: because you finished

/// On Home: Audible's books like the one finished last, not in the library.
struct BecauseYouFinishedRow: View {
    /// Opens a book's Audible page (on Home's own path: Home is a lazy stack,
    /// where a destination of the row's own wouldn't be reliable).
    let open: (AudibleBook) -> Void
    @Environment(LibraryStore.self) private var library
    @State private var finished: Book?
    @State private var similar: [AudibleBook] = []

    /// The book finished most recently.
    private var lastFinished: Book? {
        #if DEBUG
        // Test hook (simulator screenshots): pretend this book was finished last.
        if let t = ProcessInfo.processInfo.environment["KITZI_TEST_FINISHED"] {
            return library.books.first { $0.title.localizedCaseInsensitiveContains(t) }
        }
        #endif
        return library.progress.values.filter(\.isFinished)
            .max { ($0.finishedAt ?? $0.lastUpdate) < ($1.finishedAt ?? $1.lastUpdate) }
            .flatMap { library.byId[$0.itemId] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Color.clear.frame(height: 0)
            if let finished, !similar.isEmpty {
                Text("Because You Finished \(finished.title)").font(.title2.weight(.bold)).lineLimit(2)
                    .padding(.horizontal, 16)
                KeylineCarousel(
                    items: similar,
                    height: CarouselSize.cover,
                    keylines: { w in
                        let small: CGFloat = 40, medium = w * 0.2
                        return [w - medium - small - 16, medium, small]
                    },
                    onTap: { open($0) },
                    label: { $0.title }
                ) { s, fullness in
                    AudibleCarouselCover(book: s, inLibrary: false, fullness: fullness)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Its own gap below, only when there's something (Home stacks it with
        // the next section with no spacing, so an empty one leaves no double gap).
        .padding(.bottom, finished != nil && !similar.isEmpty ? 26 : 0)
        .task(id: lastFinished?.id) {
            guard let b = lastFinished else { similar = []; finished = nil; return }
            guard let asin = await AudibleRating.shared.asin(for: b),
                  let found = try? await AudibleCatalog.similar(asin: asin, language: await AudibleRating.shared.language(for: b)) else { return }
            let fresh = found.filter { library.match($0) == nil }
            #if DEBUG
            print("KITZITEST because finished=\(b.title) similar=\(found.count) notOwned=\(fresh.count) first=\(fresh.first?.title ?? "-")")
            #endif
            // Not animated: a whole row arriving in Home's lazy stack would slide
            // everything under it.
            finished = b
            similar = fresh
        }
    }
}

// MARK: chapters from Audible

/// Audible's chapters for a library book (through the server, from Audnexus),
/// compared with the book's, and saved to the server on Apply.
struct AudibleChaptersSheet: View {
    let book: Book
    let current: [Chapter]
    let onApplied: ([Chapter]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var found: (chapters: [Chapter], runtimeSec: Double?)?
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    /// The Audible book the chapters came from.
    @State private var asin: String?
    /// The server has no ASIN for the book (Kitzi matched it by title): Apply saves this one too.
    @State private var savesAsin = false

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Asking Audible…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let found {
                    List {
                        Section {
                            if let warning = mismatch(found.runtimeSec) {
                                Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.subheadline)
                            }
                            Text("\(found.chapters.count) chapters on Audible · \(current.count) now").font(.subheadline).foregroundStyle(.secondary)
                            if savesAsin, let asin {
                                Text("Also saves Audible's ID (\(asin)) for this book to your server, so it's matched directly from now on.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Section("Audible's Chapters") {
                            ForEach(Array(found.chapters.enumerated()), id: \.offset) { i, c in
                                HStack {
                                    Text(c.title.isEmpty ? "Chapter \(i + 1)" : c.title).lineLimit(2)
                                    Spacer()
                                    Text(Format.clock(c.startSec)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.subheadline)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No chapters from Audible", systemImage: "list.bullet",
                                           description: Text(error ?? "Audible has no chapters for this book, or it couldn't be matched."))
                }
            }
            .navigationTitle("Chapters from Audible")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if let found {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") { Task { await apply(found.chapters) } }.disabled(saving)
                    }
                }
            }
            .alert("Couldn't save", isPresented: Binding(get: { error != nil && found != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .task {
            defer { loading = false }
            guard let asin = await AudibleRating.shared.asin(for: book) else {
                error = "Audible doesn't have this book."
                return
            }
            self.asin = asin
            // Matched by title (the server has no ASIN): Apply confirms the match.
            let onServer = try? await API.shared.item(book.id)?.obj("media")?.obj("metadata")?.str("asin")
            savesAsin = (onServer ?? nil)?.isEmpty ?? true
            found = await API.shared.audibleChapters(asin: asin)
        }
    }

    /// Audible's edition being a different length means its chapter times may not fit.
    private func mismatch(_ runtime: Double?) -> String? {
        guard let runtime, let d = book.durationSec, d > 0 else { return nil }
        let diff = runtime - d
        guard abs(diff) > max(30, d * 0.01) else { return nil }
        let mins = Int((abs(diff) / 60).rounded())
        return "Audible's edition is \(mins) min \(diff > 0 ? "longer" : "shorter") than yours, so its chapters may not line up."
    }

    private func apply(_ chapters: [Chapter]) async {
        saving = true
        defer { saving = false }
        let d = book.durationSec ?? (chapters.last?.startSec ?? 0)
        // Chapters past the end of this edition are dropped.
        let fitting = chapters.filter { $0.startSec < d }
        if let why = await API.shared.saveChapters(book.id, fitting, durationSec: d) {
            Haptics.failure()
            error = why
            return
        }
        Haptics.success()
        // The chapters fit, so the match is right: the server keeps the ASIN too
        // (only if it still has none).
        var savedAsin = false
        if savesAsin, let asin { savedAsin = await API.shared.saveAsinIfMissing(book.id, asin) }
        onApplied(fitting)
        Toast.show(savedAsin ? "Chapters and Audible ID saved" : "Chapters updated from Audible")
        dismiss()
    }
}
