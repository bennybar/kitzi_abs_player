import Charts
import SwiftUI

/// A year of listening, from the server's listening sessions (every device, not
/// only this one): hours, days, streak, the books, authors and narrators, the
/// busiest month and weekday, and a card to share.
struct YearReview {
    struct Entry: Identifiable { var id: String; var name: String; var sec: Double; var book: Book? }
    var year: Int
    var totalSec: Double = 0
    var days = 0
    var longestStreak = 0
    var books: [Entry] = []
    var authors: [Entry] = []
    var narrators: [Entry] = []
    var finished: [Book] = []
    /// The finished book read quickest: (book, days from its first session to finishing).
    var fastest: (book: Book, days: Int)?
    var perMonthSec: [Double] = Array(repeating: 0, count: 12)
    var busiestWeekday: String?
    var busiestDay: (date: Date, sec: Double)?

    /// Built from the sessions (newest first, paged) and the library.
    @MainActor
    static func load(year: Int, library: LibraryStore) async -> YearReview? {
        var r = YearReview(year: year)
        let cal = Calendar.current
        guard let from = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let to = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return nil }
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"

        var perBook: [String: Double] = [:], titles: [String: String] = [:], authorsOf: [String: String] = [:]
        var perDay: [String: Double] = [:], firstSession: [String: Date] = [:]
        var page = 0
        pages: while page < 200 {
            guard let root = try? await API.shared.getJSON("/api/me/listening-sessions?itemsPerPage=100&page=\(page)") as? JSON else {
                if page == 0 { return nil } else { break }
            }
            let sessions = root.objs("sessions")
            if sessions.isEmpty { break }
            for s in sessions {
                let day = s.str("date").flatMap { dayFormat.date(from: $0) }
                    ?? (s.num("startedAt").map { Date(timeIntervalSince1970: $0 / 1000) })
                guard let day else { continue }
                // Newest first: past the year's start, done.
                if day < from { break pages }
                guard day < to, let id = s.str("libraryItemId") else { continue }
                let sec = s.num("timeListening") ?? 0
                guard sec > 0 else { continue }
                perBook[id, default: 0] += sec
                perDay[dayFormat.string(from: day), default: 0] += sec
                r.perMonthSec[cal.component(.month, from: day) - 1] += sec
                if titles[id] == nil { titles[id] = s.str("displayTitle") }
                if authorsOf[id] == nil { authorsOf[id] = s.str("displayAuthor") }
                if (firstSession[id] ?? .distantFuture) > day { firstSession[id] = day }
            }
            let pages = Int(root.num("numPages") ?? 1)
            page += 1
            if page >= pages { break }
        }

        r.totalSec = perBook.values.reduce(0, +)
        r.days = perDay.values.filter { $0 > 0 }.count
        // The longest run of consecutive days.
        var best = 0, run = 0
        var prev: Date?
        for d in perDay.keys.compactMap({ dayFormat.date(from: $0) }).sorted() {
            run = prev.map { cal.dateComponents([.day], from: $0, to: d).day == 1 } == true ? run + 1 : 1
            best = max(best, run); prev = d
        }
        r.longestStreak = best
        if let top = perDay.max(by: { $0.value < $1.value }), let d = dayFormat.date(from: top.key) { r.busiestDay = (d, top.value) }
        var weekdays = Array(repeating: 0.0, count: 7)
        for (k, v) in perDay { if let d = dayFormat.date(from: k) { weekdays[cal.component(.weekday, from: d) - 1] += v } }
        if let i = weekdays.indices.max(by: { weekdays[$0] < weekdays[$1] }), weekdays[i] > 0 {
            r.busiestWeekday = cal.weekdaySymbols[i]
        }

        r.books = perBook.map { Entry(id: $0.key, name: library.byId[$0.key]?.title ?? titles[$0.key] ?? "Book", sec: $0.value, book: library.byId[$0.key]) }
            .sorted { $0.sec > $1.sec }
        var byAuthor: [String: Double] = [:], byNarrator: [String: Double] = [:]
        for (id, sec) in perBook {
            let b = library.byId[id]
            if let a = b?.authors.first ?? b?.author ?? authorsOf[id] { byAuthor[a, default: 0] += sec }
            for n in b?.narrators ?? [] { byNarrator[n, default: 0] += sec }
        }
        r.authors = byAuthor.map { Entry(id: $0.key, name: $0.key, sec: $0.value) }.sorted { $0.sec > $1.sec }
        r.narrators = byNarrator.map { Entry(id: $0.key, name: $0.key, sec: $0.value) }.sorted { $0.sec > $1.sec }

        // Finished this year, newest first; and the quickest from first listen to the end.
        let finished = library.progress.values.filter { p in
            guard p.isFinished else { return false }
            let at = Date(timeIntervalSince1970: Double(p.finishedAt ?? p.lastUpdate) / 1000)
            return at >= from && at < to
        }.sorted { ($0.finishedAt ?? $0.lastUpdate) > ($1.finishedAt ?? $1.lastUpdate) }
        r.finished = finished.compactMap { library.byId[$0.itemId] }
        r.fastest = finished.compactMap { p -> (Book, Int)? in
            guard let b = library.byId[p.itemId], let first = firstSession[p.itemId], (b.durationSec ?? 0) > 3600 else { return nil }
            let at = Date(timeIntervalSince1970: Double(p.finishedAt ?? p.lastUpdate) / 1000)
            return (b, max((cal.dateComponents([.day], from: cal.startOfDay(for: first), to: cal.startOfDay(for: at)).day ?? 0) + 1, 1))
        }.min { $0.1 < $1.1 }.map { (book: $0.0, days: $0.1) }
        return r
    }
}

struct YearInReviewView: View {
    @Environment(LibraryStore.self) private var library
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var review: YearReview?
    @State private var failed = false
    @State private var card: Image?

    var body: some View {
        ScrollView {
            if let r = review {
                VStack(alignment: .leading, spacing: 18) {
                    YearCard(review: r).padding(.top, 4)
                    if r.totalSec > 0 {
                        months(r)
                        moments(r)
                        list("Most Listened", r.books.prefix(5).map { ($0.name, $0.sec, $0.book) })
                        list("Top Authors", r.authors.prefix(5).map { ($0.name, $0.sec, nil) })
                        list("Top Narrators", r.narrators.prefix(5).map { ($0.name, $0.sec, nil) })
                        if !r.finished.isEmpty { finished(r) }
                    }
                }
                .padding(16)
                .padding(.bottom, 80)
            } else if failed {
                ContentUnavailableView("Couldn't load \(String(year))", systemImage: "wifi.exclamationmark",
                                       description: Text("Your listening history comes from the server. Check your connection."))
            } else {
                ProgressView("Adding up \(String(year))…").padding(.top, 80).frame(maxWidth: .infinity)
            }
        }
        .kitziBackground()
        .navigationTitle("\(String(year)) in Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    let now = Calendar.current.component(.year, from: Date())
                    ForEach((now - 4...now).reversed(), id: \.self) { y in
                        Button(String(y)) { year = y }
                    }
                } label: { Image(systemName: "calendar") }
            }
            if let card, let r = review {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: card, preview: SharePreview("My \(String(r.year)) in audiobooks", image: card))
                }
            }
        }
        .task(id: year) {
            review = nil
            failed = false
            card = nil
            guard let r = await YearReview.load(year: year, library: library) else { failed = true; return }
            review = r
            // The card as an image, to share.
            let renderer = ImageRenderer(content: YearCard(review: r).frame(width: 360).padding(12).background(Color(.systemBackground)))
            renderer.scale = 3
            if let ui = renderer.uiImage { card = Image(uiImage: ui) }
        }
    }

    private func months(_ r: YearReview) -> some View {
        let symbols = Calendar.current.shortMonthSymbols
        return VStack(alignment: .leading, spacing: 10) {
            Text("By Month").font(.headline)
            Chart(Array(r.perMonthSec.enumerated()), id: \.offset) { i, sec in
                BarMark(x: .value("Month", symbols[i]), y: .value("Hours", sec / 3600))
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(4)
            }
            .chartYAxisLabel("hours")
            .frame(height: 170)
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func moments(_ r: YearReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let d = r.busiestDay {
                row("sun.max.fill", "Biggest day", "\(d.date.formatted(.dateTime.month(.wide).day())) · \(Format.hm(d.sec))")
            }
            if let w = r.busiestWeekday { row("calendar", "Favourite day", w) }
            if r.days > 0 { row("clock", "On a listening day", Format.hm(r.totalSec / Double(r.days))) }
            if let f = r.fastest {
                row("hare.fill", "Fastest finish", "\(f.book.title) · \(f.days) day\(f.days == 1 ? "" : "s")")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func row(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 22)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).lineLimit(2)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private func list(_ title: String, _ items: [(String, Double, Book?)]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(spacing: 12) {
                        if let b = item.2 {
                            CoverImage(book: b).frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Text("\(i + 1)").font(.headline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40)
                        }
                        Text(item.0).lineLimit(1)
                        Spacer()
                        Text(Format.hm(item.1)).foregroundStyle(.secondary).font(.subheadline)
                    }
                }
            }
            .padding(16)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private func finished(_ r: YearReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Finished in \(String(r.year))").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(r.finished) { b in
                        NavigationLink(value: b) {
                            CoverImage(book: b).frame(width: 84, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// The year on one card (shown at the top, and shared as an image).
struct YearCard: View {
    let review: YearReview

    var body: some View {
        let r = review
        VStack(alignment: .leading, spacing: 14) {
            Text("My \(String(r.year)) in audiobooks").font(.headline).foregroundStyle(.white.opacity(0.85))
            if r.totalSec <= 0 {
                Text("Nothing listened yet").font(.title.bold()).foregroundStyle(.white)
            } else {
                Text("\(Int((r.totalSec / 3600).rounded())) hours").font(.system(size: 44, weight: .heavy)).foregroundStyle(.white)
                HStack(spacing: 18) {
                    stat("\(r.finished.count)", "finished")
                    stat("\(r.days)", "days")
                    stat("\(r.longestStreak)", "day streak")
                }
                if let top = r.books.first {
                    HStack(spacing: 12) {
                        if let b = top.book {
                            CoverImage(book: b).frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Most listened").font(.caption).foregroundStyle(.white.opacity(0.75))
                            Text(top.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                        }
                    }
                }
                if let a = r.authors.first {
                    Text("Top author: \(a.name)").font(.subheadline).foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.65), .purple.opacity(0.8)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title2.weight(.bold)).foregroundStyle(.white)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.8))
        }
    }
}
