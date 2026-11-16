import SwiftUI

// More from Audible's catalog: reviews, bestsellers by genre, and the books of a
// series that aren't in the library. All shown in Kitzi's own screens.

struct AudibleGenre: Hashable, Identifiable {
    let id: String
    let name: String
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
        return try await get(url).objs("customer_reviews").compactMap { r in
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
            root = try await get(URL(string: "https://api.audible.com/1.0/catalog/categories/\(parent)?categories_num_levels=1")!)
                .obj("category")?.objs("children") ?? []
        } else {
            root = try await get(URL(string: "https://api.audible.com/1.0/catalog/categories?categories_num_levels=1")!).objs("categories")
        }
        let genres = root.compactMap { c -> AudibleGenre? in
            guard let id = c.str("id"), let name = c.str("name") else { return nil }
            return AudibleGenre(id: id, name: name)
        }
        genreCache[key] = genres
        return genres
    }

    /// A genre's bestsellers, in the language most of them are in (the store
    /// also lists translations).
    static func bestsellers(_ genre: String) async throws -> [AudibleBook] {
        let url = URL(string: "https://api.audible.com/1.0/catalog/products?category_id=\(genre)&products_sort_by=BestSellers&num_results=50&image_sizes=500&response_groups=\(groups)")!
        let books = try await get(url).objs("products").compactMap(AudibleBook.init)
        let counts = Dictionary(grouping: books.compactMap(\.language), by: { $0 }).mapValues(\.count)
        guard let main = counts.max(by: { $0.value < $1.value })?.key else { return books }
        return books.filter { $0.language == nil || $0.language == main }
    }

    /// Every book of the series that `books` (the library's copies) belong to,
    /// in series order, in their language. Nil when Audible has no match.
    static func seriesBooks(name: String, books: [Book]) async throws -> [AudibleBook]? {
        // The series' Audible id, from the first library book Audible knows.
        var series: AudibleBook.SeriesRef?
        var language: String?
        for b in books.prefix(4) {
            guard let asin = await AudibleRating.shared.rating(for: b)?.asin else { continue }
            guard let p = try await get(URL(string: "https://api.audible.com/1.0/catalog/products/\(asin)?response_groups=series,product_attrs")!)
                .obj("product") else { continue }
            let refs = p.objs("series").compactMap { s -> AudibleBook.SeriesRef? in
                guard let a = s.str("asin"), let t = s.str("title") else { return nil }
                return AudibleBook.SeriesRef(asin: a, title: t, sequence: s.str("sequence"))
            }
            let want = AudibleRating.norm(name)
            series = refs.first { AudibleRating.similar(AudibleRating.norm($0.title), want) } ?? refs.first
            language = p.str("language")
            if series != nil { break }
        }
        guard let series else { return nil }
        let rels = try await get(URL(string: "https://api.audible.com/1.0/catalog/products/\(series.asin)?response_groups=relationships")!)
            .obj("product")?.objs("relationships")
            .filter { $0.str("relationship_type") == "series" && $0.str("relationship_to_product") == "child" } ?? []
        let asins = rels.compactMap { $0.str("asin") }
        var found: [AudibleBook] = []
        for start in stride(from: 0, to: asins.count, by: 40) {
            let chunk = asins[start..<min(start + 40, asins.count)].joined(separator: ",")
            let url = URL(string: "https://api.audible.com/1.0/catalog/products?asins=\(chunk)&image_sizes=500&response_groups=\(groups)")!
            found += try await get(url).objs("products").compactMap(AudibleBook.init)
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

    /// The book's number in a series (unnumbered last).
    static func sequence(_ b: AudibleBook, in series: String) -> Double {
        b.seriesRefs.first { $0.asin == series }?.sequence.flatMap(Double.init) ?? 9999
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
            if let books {
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
                HStack { Spacer(); ProgressView("Loading bestsellers…"); Spacer() }
                    .padding(.top, 40).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .kitziBackground()
        .navigationTitle(genre.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard books == nil else { return }
            async let subs = try? AudibleCatalog.genres(parent: genre.id)
            do { books = try await AudibleCatalog.bestsellers(genre.id) } catch { failed = true }
            subgenres = await subs ?? []
        }
    }
}

// MARK: reviews

/// The most helpful Audible reviews, on an Audible book's page. Hidden when
/// there are none or Audible can't be reached.
struct AudibleReviewsCard: View {
    let asin: String
    @State private var reviews: [AudibleReview] = []
    @State private var expanded: Set<String> = []

    var body: some View {
        // A placeholder keeps the .task running when there's nothing to show yet.
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if !reviews.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Reviews").font(.headline)
                    ForEach(reviews) { r in
                        if r.id != reviews.first?.id { Divider() }
                        review(r)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
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
        .onTapGesture { withAnimation(.snappy) { if open { expanded.remove(r.id) } else { expanded.insert(r.id) } } }
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
                HStack(spacing: 8) { ProgressView(); Text("Checking Audible…").foregroundStyle(.secondary) }
                    .font(.subheadline)
            }
        } header: {
            if missing != nil || !done { Text("Not in Your Library") }
        }
        .task(id: series) {
            guard missing == nil else { return }
            defer { done = true }
            guard let all = try? await AudibleCatalog.seriesBooks(name: series, books: books) else { return }
            // Not already here: by title, or by its number in the series (another
            // edition of a book that's here).
            let owned = Set(books.compactMap(\.seriesSequence))
            var seen = Set<Double>()
            missing = all.filter { b in
                guard library.match(b) == nil else { return false }
                let n = b.seriesRefs.compactMap { $0.sequence.flatMap(Double.init) }.first
                if let n {
                    if owned.contains(n) { return false }
                    // One edition per number: the most-rated (they come first).
                    return seen.insert(n).inserted
                }
                return true
            }
        }
    }

    /// "Book 4 · Coming 12 Mar 2027".
    private func line(_ b: AudibleBook) -> String? {
        let n = b.seriesRefs.compactMap(\.sequence).first.map { "Book \($0)" }
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
