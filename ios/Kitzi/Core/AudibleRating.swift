import Foundation

/// Audible star ratings, looked up by the book's ASIN when the server has one,
/// else by a title/author search; cached for a week.
final class AudibleRating {
    static let shared = AudibleRating()
    struct Result: Codable { var asin: String; var stars: Double; var count: Int; var at: Double }
    private var memory: [String: Result?] = [:]

    func rating(for book: Book) async -> Result? {
        if let m = memory[book.id] { return m }
        if let d = Store.d.data(forKey: "audible2:\(book.id)"), let r = try? JSONDecoder().decode(Result.self, from: d),
           Date().timeIntervalSince1970 - r.at < 7 * 86400 {
            memory[book.id] = r.stars > 0 ? r : nil
            return memory[book.id] ?? nil
        }
        let r = await fetch(book)
        memory[book.id] = r
        let toStore = r ?? Result(asin: "", stars: 0, count: 0, at: Date().timeIntervalSince1970)
        Store.set(try? JSONEncoder().encode(toStore), "audible2:\(book.id)")
        return r
    }

    private func fetch(_ book: Book) async -> Result? {
        // The server's ASIN is the reliable match.
        if let item = try? await API.shared.item(book.id), let asin = item.obj("media")?.obj("metadata")?.str("asin"),
           let p = await product("https://api.audible.com/1.0/catalog/products/\(asin)?response_groups=rating")?.obj("product") {
            return result(p)
        }
        // Else a search, as the Android app does: title variants, with the first
        // author and then without, matched on title, author and running time.
        let author = (book.authors.first ?? book.author?.components(separatedBy: ",").first)?
            .trimmingCharacters(in: .whitespaces)
        for q in Self.titleVariants(book.title) {
            var found = await search(q, author: author)
            if found.isEmpty, author != nil { found = await search(q, author: nil) }
            if let best = pick(found, titles: Self.titleVariants(book.title).map(Self.norm), author: author, durationSec: book.durationSec) {
                return result(best)
            }
        }
        return nil
    }

    private func search(_ title: String, author: String?) async -> [JSON] {
        var c = URLComponents(string: "https://api.audible.com/1.0/catalog/products")!
        c.queryItems = [.init(name: "title", value: title), .init(name: "num_results", value: "10"),
                        .init(name: "products_sort_by", value: "Relevance"),
                        .init(name: "response_groups", value: "rating,product_attrs,product_desc,contributors")]
        if let author { c.queryItems?.append(.init(name: "author", value: author)) }
        guard let url = c.url?.absoluteString, let root = await product(url) else { return [] }
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

    private func product(_ url: String) async -> JSON? {
        guard let u = URL(string: url), let (data, resp) = try? await URLSession.shared.data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return JSONUtil.parse(data) as? JSON
    }

    private func result(_ p: JSON) -> Result? {
        guard let asin = p.str("asin"), let d = p.obj("rating")?.obj("overall_distribution"),
              let stars = d.num("display_average_rating") ?? d.num("average_rating"), stars > 0 else { return nil }
        return Result(asin: asin, stars: stars, count: d.int("num_ratings") ?? 0, at: Date().timeIntervalSince1970)
    }
}
