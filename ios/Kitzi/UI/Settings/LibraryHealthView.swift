import SwiftUI

/// What the library's books are missing (a cover, a description, the narrator,
/// Audible's id, chapters), each with a fix from Audible: the server's Quick
/// Match (fills only what's missing), Audible's id, or Audible's chapters.
struct LibraryHealthView: View {
    enum Issue: String, CaseIterable, Identifiable {
        case cover = "No Cover", description = "No Description", narrator = "No Narrator",
             asin = "Not Matched to Audible", chapters = "No Chapters"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .cover: "photo"
            case .description: "text.alignleft"
            case .narrator: "mic"
            case .asin: "link"
            case .chapters: "list.bullet"
            }
        }
        var fix: String {
            switch self {
            case .asin: "Match"
            case .chapters: "Chapters"
            default: "Quick Match"
            }
        }
        var explain: String {
            switch self {
            case .cover, .description, .narrator:
                "Quick Match asks your server to fill in what's missing from Audible. What the book already has is kept."
            case .asin: "Finds the book on Audible and saves its id to your server, so ratings, reviews and series work directly."
            case .chapters: "Long books with one chapter or none. Shows Audible's chapters to compare before you apply them."
            }
        }

        @MainActor func applies(_ b: Book) -> Bool {
            switch self {
            case .cover: b.hasCover == false
            case .description: (b.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .narrator: b.narrators.isEmpty
            case .asin: b.asin == nil
            case .chapters: (b.chapterCount ?? 2) <= 1 && (b.durationSec ?? 0) > 2 * 3600
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

    var body: some View {
        let groups = found.map { i, books in (i, books.filter { !done.contains(key($0, i)) }) }
        List {
            if groups.allSatisfy({ $0.1.isEmpty }) {
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
        .onChange(of: library.booksVersion, initial: true) { _, _ in
            found = Issue.allCases.map { i in (i, library.books.filter { i.applies($0) }) }
        }
        .refreshable { await library.syncAll() }
        .sheet(item: $chaptersFor) { b in
            AudibleChaptersSheet(book: b, current: []) { _ in done.insert(key(b, .chapters)) }
        }
        .confirmationDialog("Fix all of them?", isPresented: Binding(get: { confirmAll != nil }, set: { if !$0 { confirmAll = nil } }),
                            titleVisibility: .visible, presenting: confirmAll) { issue in
            Button("Fix \(library.books.filter { issue.applies($0) }.count) Books") { Task { await fixAll(issue) } }
        } message: { issue in
            Text(issue == .asin ? "Each book is looked up on Audible, and the id is saved to your server when it's found."
                 : "Your server fills in what each book is missing from Audible. What they already have is kept.")
        }
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
                        if let a = b.author { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
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
        let books = library.books.filter { issue.applies($0) && !done.contains(key($0, issue)) }
        var failed = 0
        for b in books { if await fix(b, issue, quiet: true) != nil { failed += 1 } }
        Haptics.success()
        Toast.show(failed == 0 ? "Fixed \(books.count) books" : "Fixed \(books.count - failed) of \(books.count)")
        // The server's changes, into the library.
        await library.syncAll()
        done = []
    }
}
