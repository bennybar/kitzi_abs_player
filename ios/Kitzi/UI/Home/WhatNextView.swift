import SwiftUI

struct WhatNextRoute: Hashable {}

/// "What next?": picks from the library, no searching. After a book is
/// finished, what follows it first (the next in its series, more by its author
/// and narrator); then the series you're in the middle of, the quickest
/// listens, the best rated and the ones that have waited longest.
struct WhatNextView: View {
    @Environment(LibraryStore.self) private var library
    @Namespace private var zoom
    @State private var surprise: Book?

    /// The book finished most recently, if that was in the last two weeks.
    private var finished: Book? {
        guard let p = library.progress.values.filter(\.isFinished).max(by: { ($0.finishedAt ?? $0.lastUpdate) < ($1.finishedAt ?? $1.lastUpdate) }),
              Format.nowMs - (p.finishedAt ?? p.lastUpdate) < 14 * 86_400_000 else { return nil }
        return library.byId[p.itemId]
    }

    private func unstarted(_ b: Book) -> Bool {
        guard let p = library.progress[b.id] else { return true }
        return !p.isFinished && p.progress <= 0
    }

    var body: some View {
        // Worked out once per redraw.
        let nextInSeries = library.continueSeries
        let nextIds = Set(nextInSeries.map(\.id))
        // Worth starting cold: not started, and not the middle of a series (its
        // next book is fine).
        let startable = library.books.filter { b in
            unstarted(b) && (b.series == nil || (b.seriesSequence ?? 1) <= 1 || nextIds.contains(b.id))
        }
        let done = finished
        List {
            if let surprise {
                Section {
                    ZoomBookLink(book: surprise, source: "next-surprise") {
                        Label("Surprise Me", systemImage: "dice").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } footer: {
                    Text("Opens a book you haven't started, picked at random.")
                }
            }
            if let done {
                Section("Because You Finished \(done.title)") {
                    // The next of its series: your copy, or Audible's with Send to Shelfarr.
                    NextInSeriesCard(book: done)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: -12, trailing: 0))
                        .listRowBackground(Color.clear)
                    let author = done.authors.first ?? done.author
                    let byAuthor = author.map { a in library.booksByAuthor(a).filter { $0.id != done.id && unstarted($0) } } ?? []
                    if let author, !byAuthor.isEmpty { rows(byAuthor, "More by \(author)", key: "author") }
                    if let n = done.narrators.first {
                        let byNarrator = library.booksByNarrator(n).filter { b in b.id != done.id && unstarted(b) && !byAuthor.contains { $0.id == b.id } }
                        if !byNarrator.isEmpty { rows(byNarrator, "More read by \(n)", key: "narrator") }
                    }
                }
            }
            if !nextInSeries.isEmpty { Section("Carry On a Series") { rows(nextInSeries, nil, key: "series") } }
            let quick = startable.filter { ($0.durationSec ?? 0) > 600 }.sorted { ($0.durationSec ?? 0) < ($1.durationSec ?? 0) }
            if !quick.isEmpty { Section("Quick Listens") { rows(quick, nil, key: "quick") } }
            // (Ratings already known: looked up as books are seen, or by the "Highest rated" sort.)
            let rated = startable.compactMap { b in AudibleRating.shared.cached(b.id).map { (b, $0) } }
                .filter { $0.1.count >= 50 }.sorted { $0.1.stars > $1.1.stars }.map(\.0)
            if !rated.isEmpty { Section("Best Rated, Not Started") { rows(rated, nil, key: "rated", rating: true) } }
            let waiting = startable.filter { $0.addedAt != nil }.sorted { ($0.addedAt ?? 0) < ($1.addedAt ?? 0) }
            if !waiting.isEmpty { Section("Waiting the Longest") { rows(waiting, nil, key: "waiting") } }
            if startable.isEmpty && nextInSeries.isEmpty && done == nil {
                ContentUnavailableView("Nothing waiting", systemImage: "checkmark.seal",
                                       description: Text("Every book here is started or finished. Find Book has more."))
                    .listRowBackground(Color.clear)
            }
        }
        .environment(\.coverZoom, zoom)
        .kitziBackground(grouped: true)
        .navigationTitle("What Next?")
        .onAppear { if surprise == nil { surprise = startable.randomElement() } }
    }

    /// Up to five of them, under an optional caption.
    @ViewBuilder private func rows(_ books: [Book], _ caption: String?, key: String, rating: Bool = false) -> some View {
        if let caption { Text(caption).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).listRowSeparator(.hidden) }
        ForEach(books.prefix(5)) { b in
            ZoomBookLink(book: b, source: "next-\(key)-\(b.id)") { ListBookRow(book: b, zoomID: "next-\(key)-\(b.id)", showRating: rating) }
                .bookContextMenu(b)
        }
    }
}
