import SwiftUI

/// The whole library from the watch: recently added (more on demand), or a
/// search (dictated or scribbled). Each book opens its page, to play or download.
struct LibraryView: View {
    @State private var libraryId: String?
    @State private var recent: [Book] = []
    @State private var page = 1
    @State private var more = true
    @State private var loading = false
    @State private var query = ""
    @State private var results: [Book]?
    @State private var failed = false

    var body: some View {
        List {
            TextField("Search", text: $query)
                .textInputAutocapitalization(.never)
                .onSubmit { Task { await search() } }
            if let results {
                Section("Results") {
                    if results.isEmpty { Text("Nothing found.").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(results) { row($0) }
                }
            } else {
                Section("Recently Added") {
                    if failed && recent.isEmpty {
                        Text("Can't reach the server.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(recent) { row($0) }
                    if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if more && !recent.isEmpty {
                        Button("Load More") { Task { await loadPage() } }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .task { if recent.isEmpty { await loadPage() } }
        .onChange(of: query) { _, q in if q.isEmpty { results = nil } }
    }

    private func row(_ b: Book) -> some View {
        NavigationLink(value: WatchRoute.libraryBook(b)) {
            BookRow(id: b.id, title: b.title, line: b.author, progress: nil)
        }
    }

    private func library() async -> String? {
        if let libraryId { return libraryId }
        let id = try? await API.shared.libraries().first { $0.mediaType == "book" }?.id
        libraryId = id
        return id
    }

    private func loadPage() async {
        guard !loading, more else { return }
        loading = true
        defer { loading = false }
        guard let lib = await library(),
              let r = try? await API.shared.libraryItems(library: lib, page: page, limit: 20, sort: "addedAt", desc: true) else {
            failed = true
            return
        }
        failed = false
        let books = r.items.compactMap(Book.from).filter(\.isAudioBook)
        let have = Set(recent.map(\.id))
        recent += books.filter { !have.contains($0.id) }
        page += 1
        more = r.items.count >= 20
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let lib = await library() else { results = nil; return }
        loading = true
        defer { loading = false }
        results = ((try? await API.shared.search(library: lib, query: q)) ?? []).compactMap(Book.from).filter(\.isAudioBook)
    }
}
