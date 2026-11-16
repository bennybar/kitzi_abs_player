import SwiftUI

/// The Search tab: your library as you type (and books just added on the
/// server), with Audible one tap away for what you don't have.
struct SearchView: View {
    @Environment(LibraryStore.self) private var library
    @State private var query = ""
    @State private var serverResults: [Book] = []
    @Namespace private var zoom

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        // Filtered once per redraw.
        let found = q.isEmpty ? [] : Array(library.filtered(sort: .titleAsc, filter: .all, search: q).prefix(60))
        let extra = serverResults.filter { library.byId[$0.id] == nil }
        List {
            if q.isEmpty {
                ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass",
                                       description: Text("Titles, authors, series and narrators."))
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                Section {
                    NavigationLink(value: FindBookRoute()) {
                        Label("Browse Audible", systemImage: "text.magnifyingglass")
                    }
                } footer: {
                    Text("Bestsellers by genre, and any book on Audible: ratings, reviews and what it's about.")
                }
            } else {
                Section("In Your Library") {
                    if found.isEmpty {
                        Text("Nothing in your library matches.").foregroundStyle(.secondary)
                    }
                    ForEach(found) { b in
                        ZoomBookLink(book: b, source: "search-\(b.id)") { ListBookRow(book: b, zoomID: "search-\(b.id)") }
                            .bookContextMenu(b)
                    }
                }
                // Not in the local copy yet (just added on the server).
                if !extra.isEmpty {
                    Section("On the Server") {
                        ForEach(extra) { b in
                            ZoomBookLink(book: b, source: "search-\(b.id)") { ListBookRow(book: b, zoomID: "search-\(b.id)") }
                        }
                    }
                }
                Section {
                    NavigationLink(value: FindBookRoute(query: q)) {
                        Label("Search Audible for “\(q)”", systemImage: "text.magnifyingglass")
                    }
                }
            }
        }
        .environment(\.coverZoom, zoom)
        .kitziBackground(grouped: true)
        .scrollContentBackground(.hidden)
        .navigationTitle("Search")
        // Always showing: a search screen with its field hidden until you pull down is no use.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Title, author, series, narrator")
        .navigationDestination(for: FindBookRoute.self) { FindBookView(initialQuery: $0.query) }
        #if DEBUG
        // Test hook (simulator screenshots): start with a search typed.
        .onAppear { if query.isEmpty, let t = ProcessInfo.processInfo.environment["KITZI_TEST_SEARCH"] { query = t } }
        #endif
        .task(id: q) {
            guard q.count >= 3 else { serverResults = []; return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            serverResults = await library.searchServer(q)
        }
    }
}
