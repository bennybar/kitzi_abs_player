import Foundation

/// A book's series as Audible has them, saved to the server: missing ones are
/// added, and a series whose name or number differs from Audible's is made to
/// match. Series the server has that Audible doesn't list (a collection of
/// your own) are kept.
enum SeriesSync {
    struct Entry: Hashable { var name: String; var sequence: String? }

    /// What would change for a book: the server's series now, and after.
    struct Change: Hashable {
        var before: [Entry]
        var after: [Entry]
        /// "The Titan Trilogy #1", or "Expanse #3 → The Expanse #3".
        var summary: String {
            let label = { (e: Entry) in e.sequence.map { "\(e.name) #\($0)" } ?? e.name }
            let gone = before.filter { !after.contains($0) }, new = after.filter { !before.contains($0) }
            if gone.isEmpty { return new.map(label).joined(separator: ", ") }
            return gone.map(label).joined(separator: ", ") + " → " + new.map(label).joined(separator: ", ")
        }
    }

    /// The server's series made to match Audible's: each of Audible's replaces
    /// the server's one with a similar name (its name and number from Audible),
    /// or, when both have just one, the server's one; else it's added.
    static func merge(server: [Entry], audible: [Entry]) -> [Entry] {
        var out = server
        var used = Set<Int>()
        for a in audible {
            let want = AudibleRating.norm(a.name)
            let i = out.indices.first { !used.contains($0) && AudibleRating.norm(out[$0].name) == want }
                ?? out.indices.first { !used.contains($0) && AudibleRating.similar(AudibleRating.norm(out[$0].name), want) }
                ?? (server.count == 1 && audible.count == 1 ? 0 : nil)
            if let i {
                out[i] = Entry(name: a.name, sequence: a.sequence ?? out[i].sequence)
                used.insert(i)
            } else {
                out.append(a)
                used.insert(out.count - 1)
            }
        }
        return out
    }

    /// The library's main language on Audible (most of its matches').
    @MainActor static var libraryLanguage: String {
        if let l = Store.string("radar_language"), !l.isEmpty { return l }
        var langs: [String: Int] = [:]
        for b in LibraryStore.shared.books { if let l = AudibleRating.shared.knownLanguage(b.id) { langs[l.lowercased(), default: 0] += 1 } }
        return langs.max { $0.value < $1.value }?.key ?? "english"
    }

    /// Audible's series for each of these ASINs (50 to a request). Books Audible
    /// doesn't put in a series map to []. An edition in another language than the
    /// library's is left out: its series is the translation's ("La Torre Oscura"),
    /// numbered its own way.
    static func audibleSeries(_ asins: [String]) async -> [String: [Entry]] {
        let language = libraryLanguage
        var out: [String: [Entry]] = [:]
        for start in stride(from: 0, to: asins.count, by: 50) {
            if Task.isCancelled { break }
            let chunk = asins[start..<min(start + 50, asins.count)].joined(separator: ",")
            guard let url = URL(string: "https://api.audible.com/1.0/catalog/products?asins=\(chunk)&response_groups=series,product_attrs"),
                  let root = try? await AudibleCatalog.get(url, ttl: 86400) else { continue }
            for p in root.objs("products") {
                guard let a = p.str("asin") else { continue }
                if let l = p.str("language"), l.lowercased() != language { continue }
                out[a.uppercased()] = p.objs("series").compactMap { s in
                    s.str("title").map { Entry(name: $0, sequence: s.str("sequence")?.trimmingCharacters(in: .whitespaces)) }
                }
            }
        }
        return out
    }

    /// The library's books whose series differ from Audible's (only books whose
    /// Audible id is known: the server's, or one matched before). From the books
    /// as listed (their first series); the full list is read again before saving.
    static func check(_ books: [Book]) async -> [String: Change] {
        var asinOf: [String: String] = [:]
        for b in books {
            if let a = b.asin ?? AudibleRating.shared.knownAsin(b.id) { asinOf[b.id] = a.uppercased() }
        }
        let series = await audibleSeries(Array(Set(asinOf.values)))
        var out: [String: Change] = [:]
        for b in books {
            guard let asin = asinOf[b.id], let audible = series[asin], !audible.isEmpty else { continue }
            let server = entries(b)
            let after = merge(server: server, audible: audible)
            if !same(server, after) { out[b.id] = Change(before: server, after: after) }
        }
        return out
    }

    /// The book's series as the library list gives them: one, or several packed
    /// into one string ("The Dune Sequence #1, DUNE: Legends of Dune #1").
    static func entries(_ b: Book) -> [Entry] {
        guard let s = b.series else { return [] }
        let full = s + (b.seriesSequence.map { " #\(AudibleCatalog.label($0))" } ?? "")
        let parts = full.components(separatedBy: ", ")
        let numbered = #"^(.*?)\s*#\s*([0-9][0-9.\-–]*)$"#
        // Several only when each (but the last) ends in its number: a comma may
        // also be part of a name.
        let several = parts.count > 1 && parts.dropLast().allSatisfy { $0.range(of: numbered, options: .regularExpression) != nil }
        return (several ? parts : [full]).map { p in
            guard let r = p.range(of: #"\s*#\s*([0-9][0-9.\-–]*)$"#, options: .regularExpression) else { return Entry(name: p, sequence: nil) }
            return Entry(name: String(p[..<r.lowerBound]).trimmingCharacters(in: .whitespaces),
                         sequence: p[r].replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces))
        }
    }

    /// One book, looked up now (its Audible match found if need be). Nil: nothing
    /// to change, or Audible has no series for it.
    static func check(_ book: Book) async -> Change? {
        guard let asin = await AudibleRating.shared.asin(for: book),
              let audible = await audibleSeries([asin.uppercased()])[asin.uppercased()], !audible.isEmpty,
              let server = await serverSeries(book.id) else { return nil }
        let after = merge(server: server.map(\.entry), audible: audible)
        return same(server.map(\.entry), after) ? nil : Change(before: server.map(\.entry), after: after)
    }

    /// Saves Audible's series for the book to the server. Nil, or why it couldn't.
    static func apply(_ book: Book) async -> String? {
        guard let asin = await AudibleRating.shared.asin(for: book) else { return "Audible doesn't have \(book.title)." }
        guard let audible = await audibleSeries([asin.uppercased()])[asin.uppercased()], !audible.isEmpty else {
            return "Audible doesn't list \(book.title) in a series (in your library's language)."
        }
        guard let server = await serverSeries(book.id) else { return "Couldn't reach the server." }
        let after = merge(server: server.map(\.entry), audible: audible)
        if same(server.map(\.entry), after) { return nil }
        // A series the server has under the same name keeps its id; a new or
        // renamed one goes by name (the server finds it, or makes it). Renaming
        // by id would rename the series for every book in it.
        let payload: [JSON] = after.map { e in
            var o: JSON = ["name": e.name, "sequence": e.sequence ?? ""]
            if let id = server.first(where: { $0.entry.name == e.name })?.id { o["id"] = id }
            return o
        }
        guard let (code, _) = try? await API.shared.send("/api/items/\(book.id)/media", method: "PATCH",
                                                          body: ["metadata": ["series": payload]]) else {
            return "Couldn't reach the server."
        }
        switch code {
        case 200..<300: return nil
        case 403: return "Your account isn't allowed to edit books on this server."
        default: return "The server didn't take it (\(code))."
        }
    }

    /// The book's series on the server now, with their ids.
    private static func serverSeries(_ id: String) async -> [(id: String?, entry: Entry)]? {
        guard let item = try? await API.shared.item(id), let meta = item.obj("media")?.obj("metadata") else { return nil }
        return meta.objs("series").compactMap { s in
            s.str("name").map { (s.str("id"), Entry(name: $0, sequence: s.str("sequence").flatMap { $0.isEmpty ? nil : $0 })) }
        }
    }

    /// The same series and numbers ("3" and "3.0" are the same number).
    private static func same(_ a: [Entry], _ b: [Entry]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { x, y in
            x.name == y.name && (x.sequence.flatMap(Double.init) == y.sequence.flatMap(Double.init) || x.sequence == y.sequence)
        }
    }
}
