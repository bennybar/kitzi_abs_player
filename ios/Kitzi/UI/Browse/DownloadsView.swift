import SwiftUI

/// Downloads in progress and books on this device, with storage used.
struct DownloadsView: View {
    @Environment(Downloads.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var confirmRemoveAll = false
    @State private var removing: String?
    @State private var cancelling: String?

    private func book(_ id: String) -> Book? { library.byId[id] ?? downloads.downloaded(id)?.book }

    private var active: [(String, Downloads.State)] {
        downloads.states.filter {
            switch $0.value { case .queued, .running, .waiting, .failed: true; default: false }
        }
        .sorted { $0.key < $1.key }
        .map { ($0.key, $0.value) }
    }

    private var done: [Book] {
        downloads.downloadedIds.compactMap(book).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            if !active.isEmpty {
                Section("In Progress") {
                    ForEach(active, id: \.0) { id, state in
                        HStack(spacing: 12) {
                            CoverImage(book: book(id))
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(book(id)?.title ?? "Book").font(.subheadline.weight(.semibold)).lineLimit(1)
                                switch state {
                                case .running(let f):
                                    ProgressView(value: f).tint(.accentColor)
                                    Text("\(Int(f * 100))%").font(.caption).foregroundStyle(.secondary)
                                        .contentTransition(.numericText(value: f))
                                case .queued:
                                    ProgressView().progressViewStyle(.linear)
                                    Text(settings.wifiOnlyDownloads ? "Waiting (Wi-Fi only)" : "Waiting to download")
                                        .font(.caption).foregroundStyle(.secondary)
                                case .waiting(let f):
                                    ProgressView(value: f).tint(.secondary)
                                    Text("Waiting for Wi-Fi").font(.caption).foregroundStyle(.secondary)
                                case .failed:
                                    Text("Download failed").font(.caption).foregroundStyle(.red)
                                default:
                                    EmptyView()
                                }
                            }
                            Spacer()
                            if state == .failed {
                                Button { Task { await downloads.start(id) } } label: { Image(systemName: "arrow.clockwise") }
                                    .buttonStyle(.glass)
                            }
                            Button { cancelling = id } label: { Image(systemName: "xmark") }
                                .buttonStyle(.glass)
                        }
                        .swipeActions {
                            Button { cancelling = id } label: { Label("Cancel", systemImage: "xmark") }.tint(.red)
                        }
                    }
                }
            }

            Section {
                if done.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                           description: Text("Download a book from its page to listen offline."))
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(done) { b in
                        NavigationLink {
                            BookDetailView(book: b)
                        } label: {
                            HStack {
                                BookRow(book: b)
                                Text(Format.size(downloads.bytes(b.id))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button { removing = b.id } label: { Label("Remove", systemImage: "trash") }.tint(.red)
                        }
                    }
                }
            } header: {
                if !done.isEmpty { Text("On This Device") }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Using \(Format.size(downloads.totalBytes)).")
                    Text(settings.wifiOnlyDownloads ? "Downloads use Wi-Fi only (change in Settings)." : "Downloads use Wi-Fi or cellular (change in Settings).")
                }
            }
        }
        // A finished download moves between sections instead of jumping.
        .animation(.default, value: downloads.downloadedIds)
        .animation(.default, value: active.map(\.0))
        .kitziBackground(grouped: true)
        .navigationTitle("Downloads")
        .toolbar {
            if !done.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Remove all", role: .destructive) { confirmRemoveAll = true }
                }
            }
        }
        .confirmationDialog("Remove download?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { id in
            Button("Remove download", role: .destructive) { downloads.delete(id) }
        } message: { id in
            Text("\(book(id)?.title ?? "The book")'s files are deleted from this device. You can still stream it.")
        }
        .confirmationDialog("Cancel download?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
                            titleVisibility: .visible, presenting: cancelling) { id in
            Button("Cancel download", role: .destructive) { downloads.cancel(id) }
        }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { downloads.deleteAll() }
        } message: {
            Text("The files are deleted from this device. You can still stream the books.")
        }
    }
}
