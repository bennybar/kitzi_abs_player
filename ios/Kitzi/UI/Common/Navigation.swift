import SwiftUI

/// A series by name, as a navigation value.
struct SeriesRoute: Hashable { let name: String }

extension View {
    /// The shared push destinations — an author (String) and a series — so their
    /// links work from every tab's stack, not only the Library's.
    func kitziDestinations() -> some View { modifier(KitziDestinations()) }
}

private struct KitziDestinations: ViewModifier {
    @Environment(LibraryStore.self) private var library

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: String.self) { name in AuthorDetailView(name: name) }
            .navigationDestination(for: SeriesRoute.self) { r in
                BookListView(title: r.name, books: library.series().first { $0.name == r.name }?.books
                    ?? library.books.filter { $0.series == r.name })
            }
    }
}

/// An author: photo and bio from the server, then their books by series, then the rest.
struct AuthorDetailView: View {
    let name: String
    @Environment(LibraryStore.self) private var library
    @State private var info: LibraryStore.AuthorInfo?
    @State private var expanded = false

    var body: some View {
        let books = library.booksByAuthor(name)
        let bySeries = Dictionary(grouping: books.filter { $0.series != nil }) { $0.series! }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        let others = books.filter { $0.series == nil }
        List {
            Section {
                VStack(spacing: 12) {
                    Group {
                        if let url = info?.imageURL {
                            CoverImage(book: nil, url: url)
                        } else {
                            Text(initials).font(.largeTitle.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.quaternary)
                        }
                    }
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                    Text(name).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                    Text("\(books.count) book\(books.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    if let d = info?.description, !d.isEmpty {
                        Text(d.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                            .font(.subheadline)
                            .lineLimit(expanded ? nil : 5)
                        Button(expanded ? "Less" : "More") { withAnimation { expanded.toggle() } }.font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            ForEach(bySeries, id: \.key) { series, list in
                Section(series) {
                    ForEach(list.sorted { ($0.seriesSequence ?? .infinity) < ($1.seriesSequence ?? .infinity) }) { b in
                        NavigationLink { BookDetailView(book: b) } label: { BookRow(book: b) }
                    }
                }
            }
            if !others.isEmpty {
                Section(bySeries.isEmpty ? "Books" : "Other Books") {
                    ForEach(others.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) { b in
                        NavigationLink { BookDetailView(book: b) } label: { BookRow(book: b) }
                    }
                }
            }
        }
        .kitziBackground(grouped: true)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: name) { info = await library.authorInfo(name) }
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined()
    }
}
