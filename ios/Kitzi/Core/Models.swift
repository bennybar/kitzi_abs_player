import Foundation

struct Book: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var author: String?
    var description: String?
    var durationSec: Double?
    var sizeBytes: Int64?
    var updatedAt: Int64?
    var addedAt: Int64?
    var series: String?
    var seriesSequence: Double?
    var collection: String?
    var collectionSequence: Double?
    var authors: [String] = []
    var narrators: [String] = []
    var publisher: String?
    var publishYear: Int?
    var genres: [String] = []
    var isAudioBook: Bool = true

    /// The cover through the server; covers go through the authenticated loader.
    func coverURL(width: Int = 600) -> URL? {
        guard let base = Session.shared.baseURL else { return nil }
        var s = "\(base)/api/items/\(id)/cover?width=\(width)"
        if let updatedAt { s += "&ts=\(updatedAt)" }
        return URL(string: s)
    }

    var seriesLabel: String? {
        guard let series else { return nil }
        guard let seq = seriesSequence else { return series }
        return seq.truncatingRemainder(dividingBy: 1) == 0 ? "\(series) #\(Int(seq))" : "\(series) #\(seq)"
    }

    /// Ports the Android BookMapper: tolerant of every server's field shapes.
    static func from(_ json: JSON) -> Book? {
        guard let id = json.str("id") ?? json.str("_id") else { return nil }
        let media = json.obj("media")
        let meta = media?.obj("metadata")
        guard let title = (json.str("title") ?? meta?.str("title")), !title.isEmpty else { return nil }
        let authors = names(meta?.arr("authors") ?? [])
        var author: String? = json.str("author")
        if author == nil { author = meta?.str("authorName") }
        if author == nil { author = meta?.str("author") }
        if author == nil, !authors.isEmpty { author = authors.joined(separator: ", ") }
        let (series, seriesSeq) = grouping(meta, "series", "seriesName", "seriesSequence")
        let (collection, collectionSeq) = grouping(meta, "collection", "collectionName", "collectionSequence")
        var narrators = names(meta?.arr("narrators") ?? [])
        if narrators.isEmpty, let n = meta?.str("narratorName") {
            narrators = n.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let duration = media?.num("duration")
        var hasAudio = (duration ?? 0) > 0
        if !hasAudio, let media {
            hasAudio = !media.arr("audioFiles").isEmpty || !media.arr("tracks").isEmpty || (media.int("audioTrackCount") ?? 0) > 0
        }
        var year: Int? = meta?.int("publishedYear")
        if year == nil { year = meta?.int("publishYear") }
        if year == nil { year = meta?.int("year") }
        if year == nil, let d = meta?.str("publishedDate") { year = Int(d.prefix(4)) }
        return Book(
            id: id, title: title, author: author,
            description: meta?.str("description") ?? json.str("description"),
            durationSec: (duration ?? 0) > 0 ? duration : nil,
            sizeBytes: media?.num("size").map { Int64($0) },
            updatedAt: json.epochMs("updatedAt"),
            addedAt: json.epochMs("addedAt") ?? json.epochMs("createdAt"),
            series: series, seriesSequence: seriesSeq,
            collection: collection, collectionSequence: collectionSeq,
            authors: authors, narrators: narrators,
            publisher: meta?.str("publisher"), publishYear: year,
            genres: (meta?.arr("genres") ?? []).compactMap { $0 as? String },
            isAudioBook: hasAudio
        )
    }

    private static func names(_ a: [Any]) -> [String] {
        a.compactMap { ($0 as? JSON)?.str("name") ?? ($0 as? String) }
    }

    /// `series`/`collection` arrive as a string, an object or a list of objects.
    private static func grouping(_ meta: JSON?, _ key: String, _ nameKey: String, _ seqKey: String) -> (String?, Double?) {
        guard let meta else { return (nil, nil) }
        let raw = meta[key] ?? meta[key + "s"]
        var node: JSON?
        if let o = raw as? JSON { node = o } else if let a = raw as? [Any] { node = a.first as? JSON }
        var name = (raw as? String) ?? node?.str("name") ?? node?.str("series") ?? node?.str("title") ?? meta.str(nameKey)
        var seq = node.flatMap { $0.num("sequence") ?? $0.num("index") ?? $0.num("number") } ?? meta.num(seqKey)
        // "Series Name #3" packed into one string.
        if let n = name, seq == nil, let r = n.range(of: #"\s*#\s*([0-9.]+)\s*$"#, options: .regularExpression) {
            seq = Double(n[r].replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces))
            name = String(n[..<r.lowerBound])
        }
        name = name?.trimmingCharacters(in: .whitespaces)
        return (name?.isEmpty == false ? name : nil, seq)
    }
}

/// A book's progress, as the server keeps it (and as listened here, see recordLocal).
struct Progress: Codable, Hashable {
    var itemId: String
    var progress: Double
    var isFinished: Bool
    var currentTimeSec: Double
    var durationSec: Double
    var lastUpdate: Int64
    var hideFromContinueListening: Bool = false
    /// When the server marked it finished (ms), if it says.
    var finishedAt: Int64? = nil

    static func from(_ m: JSON) -> Progress? {
        guard let id = m.str("libraryItemId") ?? m.str("id") else { return nil }
        if m.str("episodeId") != nil { return nil }
        let duration = m.num("duration") ?? 0
        let current = m.num("currentTime") ?? 0
        let finished = m.bool("isFinished") == true
        // Derived: the server's own `progress` field is unreliable (see Android).
        var p = finished ? 1 : (duration > 0 ? current / duration : (m.num("progress") ?? 0))
        if p.isNaN { p = 0 }
        return Progress(
            itemId: id, progress: min(max(p, 0), 1), isFinished: finished,
            currentTimeSec: current, durationSec: duration,
            lastUpdate: m.epochMs("lastUpdate") ?? Int64(Date().timeIntervalSince1970 * 1000),
            hideFromContinueListening: m.bool("hideFromContinueListening") == true,
            finishedAt: finished ? m.epochMs("finishedAt") : nil
        )
    }
}

struct Chapter: Codable, Hashable {
    var title: String
    var startSec: Double
}

struct Track: Codable, Hashable {
    var index: Int
    var url: String
    var mimeType: String
    var durationSec: Double
    var isLocal: Bool
}

struct Bookmark: Codable, Hashable, Identifiable {
    var itemId: String
    var timeSec: Double
    var title: String
    var createdAt: Int64
    var id: Double { timeSec }
}

struct LibraryInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var mediaType: String
}

struct HomeShelf: Identifiable {
    var id: String
    var label: String
    var books: [Book]
}

struct Author: Hashable, Identifiable {
    var id: String?
    var name: String
    var bookCount: Int
    var imageURL: URL?
    var identity: String { name }
}

enum BookSort: String, CaseIterable, Identifiable {
    case addedDesc, addedAsc, titleAsc, titleDesc, authorAsc, updatedDesc, durationDesc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .addedDesc: "Newest first"
        case .addedAsc: "Oldest first"
        case .titleAsc: "Title A–Z"
        case .titleDesc: "Title Z–A"
        case .authorAsc: "Author A–Z"
        case .updatedDesc: "Recently updated"
        case .durationDesc: "Longest first"
        }
    }
}

enum BookFilter: String, CaseIterable, Identifiable {
    case all, inProgress, notStarted, finished, downloaded
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .inProgress: "In progress"
        case .notStarted: "Not started"
        case .finished: "Finished"
        case .downloaded: "Downloaded"
        }
    }
}

enum Format {
    static func hm(_ sec: Double) -> String {
        let s = max(0, Int(sec))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
    static func clock(_ sec: Double) -> String {
        let s = max(0, Int(sec))
        let h = s / 3600, m = (s % 3600) / 60, ss = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, ss) : String(format: "%d:%02d", m, ss)
    }
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    /// "Now" in the SERVER's clock (see API.learnServerClock): every timestamp
    /// compared with the server's lastUpdate uses this.
    static var nowMs: Int64 { phoneNowMs + Int64(Store.double("server_clock_offset_ms") ?? 0) }
    static var phoneNowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
