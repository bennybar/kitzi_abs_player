import SwiftUI

/// What the library's books are missing (a cover, a description, the narrator,
/// Audible's id, chapters), each with a fix from Audible: the server's Quick
/// Match (fills only what's missing), Audible's id, or Audible's chapters.
struct LibraryHealthView: View {
    enum Issue: String, CaseIterable, Identifiable {
        case cover = "No Cover", description = "No Description", narrator = "No Narrator",
             asin = "Not Matched to Audible", chapters = "No Chapters",
             noSeries = "No Series", series = "Series Differs from Audible"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .cover: "photo"
            case .description: "text.alignleft"
            case .narrator: "mic"
            case .asin: "link"
            case .chapters: "list.bullet"
            case .noSeries: "books.vertical"
            case .series: "arrow.triangle.swap"
            }
        }
        var fix: String {
            switch self {
            case .asin: "Match"
            case .chapters: "Chapters"
            case .series, .noSeries: "Sync"
            default: "Quick Match"
            }
        }
        var explain: String {
            switch self {
            case .cover, .description, .narrator:
                "Quick Match asks your server to fill in what's missing from Audible. What the book already has is kept."
            case .asin: "Finds the book on Audible and saves its id to your server, so ratings, reviews and series work directly."
            case .chapters: "Long books with one chapter or none. Shows Audible's chapters to compare before you apply them."
            case .noSeries: "Audible puts these in a series your server doesn't have for them. Sync saves Audible's series and book number to your server."
            case .series: "Your server and Audible disagree on these (before → after). Sync changes them to Audible's. Check them: Audible sometimes numbers by publication rather than reading order. Series Audible doesn't list are kept."
            }
        }

        @MainActor func applies(_ b: Book) -> Bool {
            switch self {
            case .cover: b.hasCover == false
            case .description: (b.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .narrator: b.narrators.isEmpty
            case .asin: b.asin == nil
            case .chapters: (b.chapterCount ?? 2) <= 1 && (b.durationSec ?? 0) > 2 * 3600
            case .series, .noSeries: false // from Audible, see seriesChanges
            }
        }
    }

    @Environment(LibraryStore.self) private var library
    @State private var working: Set<String> = []
    @State private var done: Set<String> = []
    @State private var chaptersFor: Book?
    @State private var confirmAll: Issue?

    /// The books with each issue: worked out when the library changes, not on
    /// every redraw (a Fix All redraws twice per book).
    @State private var found: [(Issue, [Book])] = []
    /// Books whose series differ from Audible's (nil while checking).
    @State private var seriesChanges: [String: SeriesSync.Change]?

    var body: some View {
        let groups = found.map { i, books in (i, books.filter { !done.contains(key($0, i)) }) }
        List {
            if seriesChanges == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Comparing series with Audible…").font(.subheadline).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            if groups.allSatisfy({ $0.1.isEmpty }), seriesChanges != nil {
                ContentUnavailableView("All in order", systemImage: "checkmark.seal",
                                       description: Text("Every book has a cover, a description, its narrator, Audible's id and chapters."))
                    .listRowBackground(Color.clear)
            }
            ForEach(groups.filter { !$0.1.isEmpty }, id: \.0) { issue, books in
                Section {
                    ForEach(books.prefix(50)) { b in row(b, issue) }
                    if books.count > 50 {
                        Text("and \(books.count - 50) more").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Label("\(issue.rawValue) · \(books.count)", systemImage: issue.icon)
                        Spacer()
                        if issue != .chapters, books.count > 1 {
                            Button("Fix All") { confirmAll = issue }.font(.caption.weight(.semibold)).textCase(nil)
                        }
                    }
                } footer: {
                    Text(issue.explain)
                }
            }
        }
        .kitziBackground(grouped: true)
        .navigationTitle("Library Health")
        .animation(.kitzi, value: done)
        .onChange(of: library.booksVersion, initial: true) { _, _ in regroup() }
        .onChange(of: seriesChanges) { _, _ in regroup() }
        .task(id: library.booksVersion) {
            let changes = await SeriesSync.check(library.books)
            withAnimation(.kitzi) { seriesChanges = changes }
        }
        .refreshable { await library.syncAll() }
        .sheet(item: $chaptersFor) { b in
            AudibleChaptersSheet(book: b, current: []) { _ in done.insert(key(b, .chapters)) }
        }
        .confirmationDialog("Fix all of them?", isPresented: Binding(get: { confirmAll != nil }, set: { if !$0 { confirmAll = nil } }),
                            titleVisibility: .visible, presenting: confirmAll) { issue in
            Button("Fix \(books(issue).count) Books") { Task { await fixAll(issue) } }
        } message: { issue in
            switch issue {
            case .asin: Text("Each book is looked up on Audible, and the id is saved to your server when it's found.")
            case .noSeries: Text("Audible's series and book numbers are added to these books on your server.")
            case .series: Text("These books' series and numbers on your server are changed to Audible's. It can't be undone from Kitzi.")
            default: Text("Your server fills in what each book is missing from Audible. What they already have is kept.")
            }
        }
    }

    private func regroup() {
        found = Issue.allCases.map { i in
            switch i {
            case .noSeries: (i, library.books.filter { seriesChanges?[$0.id]?.before.isEmpty == true })
            case .series: (i, library.books.filter { seriesChanges?[$0.id].map { !$0.before.isEmpty } == true })
            default: (i, library.books.filter { i.applies($0) })
            }
        }
    }

    /// The books with an issue, not fixed yet.
    private func books(_ issue: Issue) -> [Book] {
        (found.first { $0.0 == issue }?.1 ?? []).filter { !done.contains(key($0, issue)) }
    }

    private func key(_ b: Book, _ i: Issue) -> String { "\(i.rawValue)|\(b.id)" }

    private func row(_ b: Book, _ issue: Issue) -> some View {
        HStack(spacing: 12) {
            NavigationLink(value: b) {
                HStack(spacing: 12) {
                    CoverImage(book: b).frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        if issue == .series || issue == .noSeries, let c = seriesChanges?[b.id] {
                            Text(c.summary).font(.caption).foregroundStyle(Color.accentColor).lineLimit(2)
                        } else if let a = b.author {
                            Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 6)
            if working.contains(key(b, issue)) {
                ProgressView().transition(.opacity)
            } else {
                Button(issue.fix) { Task { await fix(b, issue) } }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glass)
            }
        }
    }

    /// Nil, or why it couldn't.
    @discardableResult
    private func fix(_ b: Book, _ issue: Issue, quiet: Bool = false) async -> String? {
        let k = key(b, issue)
        if issue == .chapters { chaptersFor = b; return nil }
        working.insert(k)
        defer { working.remove(k) }
        var why: String?
        switch issue {
        case .series, .noSeries:
            why = await SeriesSync.apply(b)
        case .asin:
            if let asin = await AudibleRating.shared.asin(for: b) {
                why = await API.shared.saveAsinIfMissing(b.id, asin) ? nil : "Couldn't save Audible's id for \(b.title)."
            } else {
                why = "Audible doesn't have \(b.title)."
            }
        default:
            why = await API.shared.quickMatch(b.id, title: b.title, author: b.authors.first ?? b.author, asin: b.asin)
        }
        if let why {
            if !quiet { Haptics.failure(); Toast.show(why) }
        } else {
            done.insert(k)
            if !quiet { Haptics.success() }
        }
        return why
    }

    private func fixAll(_ issue: Issue) async {
        let books = books(issue)
        var failed = 0
        for b in books { if await fix(b, issue, quiet: true) != nil { failed += 1 } }
        Haptics.success()
        Toast.show(failed == 0 ? "Fixed \(books.count) books" : "Fixed \(books.count - failed) of \(books.count)")
        // The server's changes, into the library.
        await library.syncAll()
        done = []
    }
}
