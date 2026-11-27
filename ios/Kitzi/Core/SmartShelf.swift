import Foundation

/// A saved filter shown as a row on Home ("Under 6 Hours", "Highly Rated, Not
/// Started"): every rule that's set must hold.
struct SmartShelf: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    /// "any", "notStarted", "inProgress" or "finished".
    var status = "notStarted"
    var maxHours: Double? = nil
    /// Audible's stars at least this (books whose rating isn't known yet are left out).
    var minRating: Double? = nil
    /// Added to the library in the last so many days.
    var addedDays: Int? = nil
    var genre: String? = nil
    /// Only books of a series you've started or finished a book of.
    var mySeries = false
    var downloaded = false
    /// "added" (newest), "shortest", "rating" or "title".
    var sort = "added"

    static let presets: [SmartShelf] = [
        SmartShelf(name: "Under 6 Hours", maxHours: 6, sort: "shortest"),
        SmartShelf(name: "Unstarted in My Series", mySeries: true, sort: "title"),
        SmartShelf(name: "Highly Rated, Not Started", minRating: 4.5, sort: "rating"),
        SmartShelf(name: "Added This Month", status: "any", addedDays: 30),
    ]

    /// What it asks for, in a line ("Not started · under 6 h · shortest first").
    var summary: String {
        var parts: [String] = []
        switch status {
        case "notStarted": parts.append("Not started")
        case "inProgress": parts.append("In progress")
        case "finished": parts.append("Finished")
        default: break
        }
        if let h = maxHours { parts.append("under \(Int(h)) h") }
        if let r = minRating { parts.append("\(String(format: "%.1f", r))★ or more") }
        if let d = addedDays { parts.append("added in the last \(d) days") }
        if let g = genre { parts.append(g) }
        if mySeries { parts.append("series I'm in") }
        if downloaded { parts.append("downloaded") }
        parts.append(["added": "newest first", "shortest": "shortest first", "rating": "best rated first", "title": "by title"][sort] ?? "")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

extension LibraryStore {
    /// The books a smart shelf shows, in its order.
    func books(_ shelf: SmartShelf) -> [Book] {
        var started: Set<String> = []
        if shelf.mySeries {
            for b in books where b.series != nil { if let p = progress[b.id], p.isFinished || p.progress > 0 { started.insert(b.series!) } }
        }
        let cutoff = shelf.addedDays.map { Format.nowMs - Int64($0) * 86_400_000 }
        let rating = { (b: Book) in AudibleRating.shared.cached(b.id)?.stars }
        let list = books.filter { b in
            let p = progress[b.id]
            switch shelf.status {
            case "notStarted": if !(p.map { !$0.isFinished && $0.progress <= 0 } ?? true) { return false }
            case "inProgress": if !(p.map { !$0.isFinished && $0.progress > 0 } ?? false) { return false }
            case "finished": if p?.isFinished != true { return false }
            default: break
            }
            if let h = shelf.maxHours, !((b.durationSec ?? .infinity) <= h * 3600) { return false }
            if let r = shelf.minRating, !((rating(b) ?? 0) >= r) { return false }
            if let cutoff, !((b.addedAt ?? 0) >= cutoff) { return false }
            if let g = shelf.genre, !b.genres.contains(g) { return false }
            if shelf.mySeries, !(b.series.map(started.contains) ?? false) { return false }
            if shelf.downloaded, !Downloads.shared.isDownloaded(b.id) { return false }
            return true
        }
        switch shelf.sort {
        case "shortest": return list.sorted { ($0.durationSec ?? .infinity) < ($1.durationSec ?? .infinity) }
        case "rating": return list.sorted { (rating($0) ?? 0) > (rating($1) ?? 0) }
        case "title":
            // A series' books together and in order.
            return list.sorted {
                let (a, b) = ($0.series ?? $0.title, $1.series ?? $1.title)
                if a != b { return a.localizedCaseInsensitiveCompare(b) == .orderedAscending }
                return ($0.seriesSequence ?? 0) < ($1.seriesSequence ?? 0)
            }
        default: return list.sorted { ($0.addedAt ?? 0) > ($1.addedAt ?? 0) }
        }
    }
}
