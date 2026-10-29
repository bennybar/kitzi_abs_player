import SwiftUI

/// Where "All Books" (or one of its filters) goes from Home.
struct AllBooksRoute: Hashable { var filter: BookFilter }

/// Home's other browse screens.
enum BrowseRoute: Hashable { case genres, authors }

/// The whole library on its own screen: by title with an A–Z index down the side
/// (or by another sort, as one list), filter and sort in the toolbar menu.
struct AllBooksView: View {
    @State var filter: BookFilter
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var sort: BookSort = .titleAsc
    @State private var search = ""

    var body: some View {
        let list = library.filtered(sort: sort, filter: filter, search: search)
        Group {
            if settings.gridLayout { grid(list) } else { listView(list) }
        }
        .searchable(text: $search, prompt: "Title, author, series, narrator")
        .kitziBackground()
        .navigationTitle(filter == .all ? "All Books" : filter.label)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Show", selection: $filter) { ForEach(BookFilter.allCases) { Text($0.label).tag($0) } }
                    Picker("Sort", selection: $sort) { ForEach(BookSort.allCases) { Text($0.label).tag($0) } }
                    Divider()
                    Toggle(isOn: Binding(get: { settings.gridLayout }, set: { settings.gridLayout = $0 })) {
                        Label("Show as Grid", systemImage: "square.grid.2x2")
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease") }
            }
        }
    }

    private var byTitle: Bool { sort == .titleAsc || sort == .titleDesc }

    /// Native list; by title, in letter sections with the A–Z index.
    private func listView(_ list: [Book]) -> some View {
        List {
            if byTitle {
                ForEach(Self.byLetter(list), id: \.0) { letter, books in
                    Section(letter) {
                        ForEach(books) { b in row(b) }
                    }
                    .sectionIndexLabel(letter)
                }
            } else {
                ForEach(list) { b in row(b) }
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
    }

    /// Cover grid; by title, under pinned letter headers.
    private func grid(_ list: [Book]) -> some View {
        let groups = byTitle ? Self.byLetter(list) : [("", list)]
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 16)], spacing: 20, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.0) { letter, books in
                    Section {
                        ForEach(books) { b in
                            NavigationLink(value: b) { CoverTile(book: b, size: nil, progress: library.progress[b.id]) }
                                .buttonStyle(.plain)
                                .bookContextMenu(b)
                        }
                    } header: {
                        if !letter.isEmpty {
                            Text(letter).font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .background(.bar)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 90)
        }
    }

    private func row(_ b: Book) -> some View {
        NavigationLink(value: b) { ListBookRow(book: b) }
            .bookContextMenu(b)
    }

    /// Books grouped by the first letter of the title ("#" for the rest), in order.
    static func byLetter(_ books: [Book]) -> [(String, [Book])] {
        var groups: [(String, [Book])] = []
        for b in books {
            let first = b.title.first.map { String($0).uppercased() } ?? "#"
            let key = first.rangeOfCharacter(from: .letters) != nil ? first : "#"
            if groups.last?.0 == key { groups[groups.count - 1].1.append(b) } else { groups.append((key, [b])) }
        }
        return groups
    }
}

/// A shelf per genre in the library, most books first; each opens the full list.
struct GenresView: View {
    @Binding var path: NavigationPath
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let skip: Set<String> = ["audiobook", "audiobooks"]
        var byGenre: [String: [Book]] = [:]
        for b in library.books {
            for g in b.genres where !skip.contains(g.lowercased()) { byGenre[g, default: []].append(b) }
        }
        let genres = byGenre.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if genres.isEmpty {
                    ContentUnavailableView("No genres", systemImage: "tag",
                                           description: Text("Your server hasn't tagged these books with genres."))
                }
                ForEach(genres, id: \.key) { g, books in
                    CoverShelf(title: g, books: books, showProgress: false, path: $path)
                }
            }
            .padding(.vertical, 8)
            .padding(.bottom, 90)
        }
        .kitziBackground()
        .navigationTitle("Genres")
    }
}
