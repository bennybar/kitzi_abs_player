import Foundation
import Observation

/// A library book's Audible match: its ASIN (the server's, else found by a
/// title/author search), stars and language. Saved for a week; an older one is
/// still used when Audible can't be reached.
@Observable
final class AudibleRating {
    static let shared = AudibleRating()
    /// `stars` 0: on Audible but not rated yet (new or upcoming); `asin` empty: no match.
    struct Result: Codable {
        var asin: String
        var stars: Double
        var count: Int
        var at: Double
        var language: String? = nil
    }
    @ObservationIgnored private var memory: [String: Result] = [:]
    @ObservationIgnored private var inflight: [String: Task<Result?, Never>] = [:]
    /// Filling in the library's ratings (for the "Highest rated" sort): how many
    /// are done, of how many. Total 0 when it isn't running.
    private(set) var fillDone = 0
    private(set) var fillTotal = 0
    #if DEBUG
    @ObservationIgnored private var clearedForTest = false
    #endif

    private static let maxAge: Double = 7 * 86400
    private static func key(_ id: String) -> String { "audible2:\(id)" }

    private func saved(_ id: String) -> Result? {
        if let m = memory[id] { return m }
        guard let d = Store.d.data(forKey: Self.key(id)), let r = try? JSONDecoder().decode(Result.self, from: d) else { return nil }
        memory[id] = r
        return r
    }

    private func save(_ id: String, _ r: Result) {
        memory[id] = r
        Store.set(try? JSONEncoder().encode(r), Self.key(id))
    }

    /// The rating already known (this session, or saved, however old), without asking Audible.
    func cached(_ id: String) -> Result? {
        guard let r = saved(id), r.stars > 0 else { return nil }
        return r
    }

    /// The book's Audible language as already known (no lookup).
    func knownLanguage(_ id: String) -> String? { saved(id)?.language }

    /// The book's stars (nil when Audible has no match or no ratings yet).
    func rating(for book: Book) async -> Result? {
        guard let r = await lookup(book), r.stars > 0 else { return nil }
        return r
    }

    /// The book's Audible ASIN, rated or not (nil when Audible has no match).
    func asin(for book: Book) async -> String? {
        if let a = book.asin { return a }
        guard let r = await lookup(book), !r.asin.isEmpty else { return nil }
        return r.asin
    }

    /// The book's language on Audible ("english"), when known.
    func language(for book: Book) async -> String? { await lookup(book)?.language }

    private func lookup(_ book: Book) async -> Result? {
        let old = saved(book.id)
        if let old, Date().timeIntervalSince1970 - old.at < Self.maxAge { return old }
        if let t = inflight[book.id] { return await t.value }
        let t = Task { () -> Result? in
            do {
                // A real answer (a match, or none) is saved; "no match" as an empty ASIN.
                let r = try await fetch(book) ?? Result(asin: "", stars: 0, count: 0, at: Date().timeIntervalSince1970)
                save(book.id, r)
                return r
            } catch {
                // Offline or Audible failed: keep showing what was known.
                return old
            }
        }
        inflight[book.id] = t
        let r = await t.value
        inflight[book.id] = nil
        return r
    }

    /// Looks up the ratings not known yet. Books with the server's ASIN go 50 to a
    /// request; the rest (a title search each) a few at a time.
    func fill(_ books: [Book]) async {
        guard fillTotal == 0 else { return }
        #if DEBUG
        // Test hook: start from nothing, and say how long it took.
        if ProcessInfo.processInfo.environment["KITZI_TEST_CLEAR_RATINGS"] != nil, !clearedForTest {
            clearedForTest = true
            for b in books { Store.set(nil, Self.key(b.id)); memory[b.id] = nil }
        }
        let started = Date()
        defer { print("KITZITEST fill took=\(String(format: "%.1f", Date().timeIntervalSince(started)))s rated=\(books.filter { cached($0.id) != nil }.count)/\(books.count)") }
        #endif
        let todo = books.filter { saved($0.id) == nil }
        guard !todo.isEmpty else { return }
        fillTotal = todo.count
        fillDone = 0
        defer { fillTotal = 0 }
        let withAsin = todo.filter { $0.asin != nil }, without = todo.filter { $0.asin == nil }
        for start in stride(from: 0, to: withAsin.count, by: 50) {
            if Task.isCancelled { return }
            let chunk = Array(withAsin[start..<min(start + 50, withAsin.count)])
            let asins = chunk.compactMap(\.asin).joined(separator: ",")
            guard let root = try? await product("https://api.audible.com/1.0/catalog/products?asins=\(asins)&response_groups=rating,product_attrs") else { continue }
            var found: [String: JSON] = [:]
            for p in root.objs("products") { if let a = p.str("asin") { found[a.uppercased()] = p } }
            let now = Date().timeIntervalSince1970
            for b in chunk {
                // Not in Audible's (US) catalog: no stars, but the ASIN stays known.
                let r = found[b.asin!].flatMap(result) ?? Result(asin: b.asin!, stars: 0, count: 0, at: now)
                save(b.id, r)
            }
            fillDone += chunk.count
        }
        for start in stride(from: 0, to: without.count, by: 4) {
            if Task.isCancelled { return }
            await withTaskGroup(of: Void.self) { g in
                for b in without[start..<min(start + 4, without.count)] {
                    g.addTask { _ = await self.lookup(b) }
                }
            }
            fillDone += min(4, without.count - start)
        }
    }

    /// Nil when Audible has no match; throws when it couldn't be asked.
    private func fetch(_ book: Book) async throws -> Result? {
        // The server's ASIN is the reliable match (the library list carries it;
        // an older cached copy may not, so ask the server then).
        var asin = book.asin
        if asin == nil { asin = try? await API.shared.item(book.id)?.obj("media")?.obj("metadata")?.str("asin") }
        if let asin, !asin.isEmpty {
            if let p = try await product("https://api.audible.com/1.0/catalog/products/\(asin)?response_groups=rating,product_attrs")?.obj("product") {
                return result(p)
            }
            // Not in this store's catalog: still the book's ASIN.
            return Result(asin: asin, stars: 0, count: 0, at: Date().timeIntervalSince1970)
        }
        // Else a search, as the Android app does: title variants, with the first
        // author and then without, matched on title, author and running time.
        let author = (book.authors.first ?? book.author?.components(separatedBy: ",").first)?
            .trimmingCharacters(in: .whitespaces)
        for q in Self.titleVariants(book.title) {
            var found = try await search(q, author: author)
            if found.isEmpty, author != nil { found = try await search(q, author: nil) }
            if let best = pick(found, titles: Self.titleVariants(book.title).map(Self.norm), author: author, durationSec: book.durationSec) {
                return result(best)
            }
        }
        return nil
    }

    private func search(_ title: String, author: String?) async throws -> [JSON] {
        var c = URLComponents(string: "https://api.audible.com/1.0/catalog/products")!
        c.queryItems = [.init(name: "title", value: title), .init(name: "num_results", value: "10"),
                        .init(name: "products_sort_by", value: "Relevance"),
                        .init(name: "response_groups", value: "rating,product_attrs,product_desc,contributors")]
        if let author { c.queryItems?.append(.init(name: "author", value: author)) }
        guard let url = c.url?.absoluteString, let root = try await product(url) else { return [] }
        return root.objs("products")
    }

    private func pick(_ products: [JSON], titles: [String], author: String?, durationSec: Double?) -> JSON? {
        let wantAuthor = author.map(Self.norm)
        var best: (JSON, Int)?
        for p in products {
            let t = Self.norm(p.str("title") ?? "")
            guard !t.isEmpty, titles.contains(where: { Self.similar($0, t) }) else { continue }
            var durationOk = false
            if let want = durationSec, want > 0, let mins = p.num("runtime_length_min"), mins > 0 {
                if abs(mins * 60 - want) / want > 0.08 { continue }
                durationOk = true
            }
            if let wantAuthor {
                let authors = p.objs("authors").compactMap { $0.str("name") }.map(Self.norm)
                let authorOk = authors.contains { $0.contains(wantAuthor) || wantAuthor.contains($0) }
                if !authorOk && !durationOk { continue }
            }
            let count = p.obj("rating")?.obj("overall_distribution")?.int("num_ratings") ?? 0
            if (p.obj("rating")?.obj("overall_distribution")?.num("display_average_rating") ?? 0) <= 0 { continue }
            if best == nil || count > best!.1 { best = (p, count) }
        }
        return best?.0
    }

    /// The title as searched: without "(Unabridged)", brackets, "Book 3"…, and the
    /// part before a subtitle.
    static func titleVariants(_ title: String) -> [String] {
        var t = title.replacingOccurrences(of: #"[\(\[\{].*?[\)\]\}]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)[-–—:,]?\s*\b(book|bk|vol|volume|part)\b\.?\s*\d+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        var out = [t]
        for sep in [":", " - ", " – ", " — "] {
            if let r = t.range(of: sep) {
                let head = t[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                if !head.isEmpty, !out.contains(head) { out.append(head) }
            }
        }
        return out.filter { !$0.isEmpty }
    }

    static func norm(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"\(.*?\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Same title, or one is the other plus a subtitle.
    static func similar(_ a: String, _ b: String) -> Bool {
        a == b || (a.count >= 6 && b.hasPrefix(a)) || (b.count >= 6 && a.hasPrefix(b))
    }

    /// Nil for "not found"; throws when Audible couldn't be reached or failed.
    private func product(_ url: String) async throws -> JSON? {
        guard let u = URL(string: url) else { return nil }
        let (data, resp) = try await URLSession.shared.data(from: u)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200 else { throw URLError(.badServerResponse) }
        return JSONUtil.parse(data) as? JSON
    }

    /// Stars 0 when it has none yet.
    private func result(_ p: JSON) -> Result? {
        guard let asin = p.str("asin") else { return nil }
        let d = p.obj("rating")?.obj("overall_distribution")
        let stars = d?.num("display_average_rating") ?? d?.num("average_rating") ?? 0
        return Result(asin: asin.uppercased(), stars: stars, count: d?.int("num_ratings") ?? 0,
                      at: Date().timeIntervalSince1970, language: p.str("language"))
    }
}
