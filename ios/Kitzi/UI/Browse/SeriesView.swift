import SwiftUI

/// Series, collections and playlists, each a list of groups with fanned covers.
struct SeriesView: View {
    @Environment(LibraryStore.self) private var library

    enum Kind: String, CaseIterable, Identifiable {
        case series = "Series", collections = "Collections", playlists = "Playlists"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .series
    @State private var collections: [LibraryStore.SeriesRow] = []
    @State private var playlists: [LibraryStore.SeriesRow] = []
    @State private var loading = false
    @State private var search = ""

    private var rows: [LibraryStore.SeriesRow] {
        let all: [LibraryStore.SeriesRow] = switch kind {
        case .series: library.series()
        case .collections: collections
        case .playlists: playlists
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
            }
            if loading && rows.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            } else if rows.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "rectangle.stack", description: Text(emptyMessage))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(rows) { row in
                    NavigationLink {
                        BookListView(title: row.name, books: row.books)
                    } label: {
                        HStack(spacing: 14) {
                            FannedCovers(books: Array(row.books.prefix(3)))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.name).font(.headline).lineLimit(2)
                                Text("\(row.books.count) book\(row.books.count == 1 ? "" : "s")")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.plain)
        .kitziBackground()
        .navigationTitle(kind.rawValue)
        .searchable(text: $search, prompt: "Search \(kind.rawValue.lowercased())")
        .task(id: kind) { await load() }
        .refreshable { await load() }
    }

    private var emptyTitle: String { search.isEmpty ? "No \(kind.rawValue.lowercased()) yet" : "No matches" }
    private var emptyMessage: String {
        if !search.isEmpty { return "Try adjusting your search." }
        return kind == .playlists ? "Playlists you make on your server appear here."
            : "\(kind.rawValue) appear when books are grouped together."
    }

    private func load() async {
        switch kind {
        case .series: return
        case .collections:
            loading = true
            collections = await library.collections()
        case .playlists:
            loading = true
            playlists = await library.playlists()
        }
        loading = false
    }
}

/// Up to three covers fanned out, the first in front.
struct FannedCovers: View {
    let books: [Book]
    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(books.enumerated().reversed()), id: \.offset) { i, b in
                CoverImage(book: b)
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(radius: i == 0 ? 3 : 1)
                    .brightness(i == 0 ? 0 : -0.15)
                    .rotationEffect(.degrees(Double(i) * 6))
                    .offset(x: CGFloat(i) * 12)
            }
        }
        .frame(width: 84, height: 62, alignment: .leading)
    }
}
