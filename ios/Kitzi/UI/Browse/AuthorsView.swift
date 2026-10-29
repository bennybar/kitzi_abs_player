import SwiftUI

/// Authors with their photos (from the server), searchable; tap for their books.
struct AuthorsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var authors: [Author] = []
    @State private var loading = true
    @State private var search = ""

    private var shown: [Author] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? authors : authors.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ScrollView {
            if loading && authors.isEmpty {
                ProgressView().padding(.top, 60)
            } else if shown.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No authors yet" : "No matches",
                                       systemImage: "person.2",
                                       description: Text(search.isEmpty ? "Authors appear once your library has synced." : "Try a different name."))
                    .padding(.top, 40)
            } else if settings.authorsList {
                LazyVStack(spacing: 0) {
                    ForEach(shown, id: \.identity) { a in
                        NavigationLink { AuthorDetailView(name: a.name) } label: {
                            HStack(spacing: 14) {
                                AuthorAvatar(author: a, size: 48)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name).font(.body.weight(.medium)).lineLimit(1)
                                    Text("\(a.bookCount) book\(a.bookCount == 1 ? "" : "s")").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 62)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 20) {
                    ForEach(shown, id: \.identity) { a in
                        NavigationLink {
                            AuthorDetailView(name: a.name)
                        } label: {
                            AuthorCell(author: a)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .padding(.bottom, 80)
            }
        }
        .navigationTitle("Authors")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { settings.authorsList.toggle() } label: {
                    Image(systemName: settings.authorsList ? "square.grid.2x2" : "list.bullet")
                }
                .accessibilityLabel(settings.authorsList ? "Show as grid" : "Show as list")
            }
        }
        .searchable(text: $search, prompt: "Search authors")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        authors = await library.authors()
        loading = false
    }
}

private struct AuthorCell: View {
    let author: Author

    var body: some View {
        VStack(spacing: 8) {
            AuthorAvatar(author: author, size: 92)
            Text(author.name).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
            Text("\(author.bookCount) book\(author.bookCount == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The author's photo, or their initials.
private struct AuthorAvatar: View {
    let author: Author
    let size: CGFloat

    var body: some View {
            ZStack {
                if author.imageURL != nil {
                    CoverImage(book: nil, url: author.imageURL)
                } else {
                    Circle().fill(Color.accentColor.opacity(0.25))
                    Text(initials).font(size > 60 ? .title2.weight(.semibold) : .headline).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .glassEffect(.regular, in: Circle())
    }

    private var initials: String {
        author.name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }
}
