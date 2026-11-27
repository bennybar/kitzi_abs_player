import SwiftUI

/// A narrator, as a navigation value.
struct NarratorRoute: Hashable { let name: String }

/// The library's narrators, most books first; each opens the books they read.
struct NarratorsView: View {
    @Environment(LibraryStore.self) private var library
    @State private var search = ""

    var body: some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        let all = library.narrators
        let shown = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }
        List {
            if shown.isEmpty {
                ContentUnavailableView(all.isEmpty ? "No narrators yet" : "No matches", systemImage: "mic",
                                       description: Text(all.isEmpty ? "Narrators appear once your library has synced." : "Try a different name."))
                    .listRowBackground(Color.clear)
            }
            ForEach(shown, id: \.name) { n in
                NavigationLink(value: NarratorRoute(name: n.name)) {
                    HStack {
                        Text(n.name)
                        Spacer()
                        Text("\(n.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .kitziBackground()
        .navigationTitle("Narrators")
        .searchable(text: $search, prompt: "Search narrators")
    }
}

/// A narrator's books in the library, and theirs on Audible.
struct NarratorView: View {
    let name: String
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let books = library.booksByNarrator(name)
        List {
            Section("\(books.count) in Your Library") {
                ForEach(books) { b in
                    NavigationLink(value: b) { ListBookRow(book: b) }
                }
            }
            .listRowBackground(Color.clear)
            Section {
                NavigationLink(value: AudibleListRoute.narrator(name)) {
                    Label("More Narrated by \(name) on Audible", systemImage: "text.magnifyingglass")
                }
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .kitziBackground()
        .navigationTitle(name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let following = Radar.shared.followedNarrators.contains(name)
                Button {
                    if following { Radar.shared.followedNarrators.remove(name) } else {
                        Radar.shared.followedNarrators.insert(name)
                        Haptics.success()
                        Toast.show(AppSettings.shared.radar ? "Following \(name): new books show in New Releases"
                                   : "Following \(name). Turn on New Releases in Settings to be notified")
                    }
                } label: {
                    Label(following ? "Following" : "Follow", systemImage: following ? "bell.fill" : "bell")
                }
            }
        }
    }
}
