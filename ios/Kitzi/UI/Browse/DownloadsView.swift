import SwiftUI

/// Downloads in progress and books on this device, with storage used.
struct DownloadsView: View {
    @Environment(Downloads.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var confirmRemoveAll = false
    @Namespace private var zoom
    @State private var removing: String?
    @State private var cancelling: String?
    @State private var confirmRemoveFinished = false
    /// Biggest first (to free space), or by title.
    @AppStorage("downloads_by_size") private var bySize = false
    @State private var freeBytes: Int64?

    private func book(_ id: String) -> Book? { library.byId[id] ?? downloads.downloaded(id)?.book }

    private var active: [(String, Downloads.State)] {
        downloads.states.filter {
            switch $0.value { case .queued, .running, .waiting, .failed: true; default: false }
        }
        .sorted { $0.key < $1.key }
        .map { ($0.key, $0.value) }
    }

    private var done: [Book] {
        let all = downloads.downloadedIds.compactMap(book)
        return bySize ? all.sorted { downloads.bytes($0.id) > downloads.bytes($1.id) }
            : all.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Finished and still taking space (not the one that's loaded).
    private func finished(_ books: [Book]) -> [Book] {
        books.filter { library.progress[$0.id]?.isFinished == true && Player.shared.nowPlaying?.book.id != $0.id }
    }

    var body: some View {
        let done = self.done
        let finished = finished(done)
        let finishedBytes = finished.reduce(Int64(0)) { $0 + downloads.bytes($1.id) }
        List {
            if !done.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Format.size(downloads.totalBytes)).font(.title2.weight(.bold))
                            Text("in \(done.count) \(done.count == 1 ? "book" : "books")").foregroundStyle(.secondary)
                            Spacer()
                            if let free = freeBytes { Text("\(Format.size(free)) free").font(.subheadline).foregroundStyle(.secondary) }
                        }
                        if !finished.isEmpty {
                            // The quick win: books you've finished that are still here.
                            Button { confirmRemoveFinished = true } label: {
                                Label("Free up \(Format.size(finishedBytes)): remove \(finished.count) finished", systemImage: "checkmark.circle")
                                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
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
                                    // Animated: the bar glides and the digits roll, not jump.
                                    ProgressView(value: f).tint(.accentColor)
                                        .animation(.easeOut(duration: 0.3), value: f)
                                    Text("\(Int(f * 100))%").font(.caption).foregroundStyle(.secondary)
                                        .contentTransition(.numericText(value: f))
                                        .animation(.easeOut(duration: 0.3), value: Int(f * 100))
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
                        ZoomBookLink(book: b, source: "dl-\(b.id)") {
                            BookRow(book: b, zoomID: "dl-\(b.id)",
                                    detail: Format.size(downloads.bytes(b.id)) + (library.progress[b.id]?.isFinished == true ? " · Finished" : ""),
                                    showDownloaded: false)
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
                    Text(settings.wifiOnlyDownloads ? "Downloads use Wi-Fi only (change in Settings)." : "Downloads use Wi-Fi or cellular (change in Settings).")
                }
            }
        }
        // A finished download moves between sections instead of jumping.
        .environment(\.coverZoom, zoom)
        .animation(.kitzi, value: downloads.downloadedIds)
        .animation(.kitzi, value: active.map(\.0))
        .kitziBackground(grouped: true)
        .navigationTitle("Downloads")
        .toolbar {
            if !done.isEmpty {
                // In a menu: a big red button at the top was too easy to hit and too loud.
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $bySize) {
                            Label("By Title", systemImage: "textformat").tag(false)
                            Label("Biggest First", systemImage: "internaldrive").tag(true)
                        }
                        Button("Remove All Downloads", systemImage: "trash", role: .destructive) { confirmRemoveAll = true }
                    } label: { Image(systemName: "ellipsis").accessibilityLabel("More") }
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
        .task(id: downloads.downloadedIds.count) {
            freeBytes = (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        }
        .confirmationDialog("Remove finished books?", isPresented: $confirmRemoveFinished, titleVisibility: .visible) {
            Button("Remove \(finished.count) Finished", role: .destructive) { for b in finished { downloads.delete(b.id) } }
        } message: {
            Text("Their files are deleted from this device (\(Format.size(finishedBytes))). You can still stream them, and your place is kept.")
        }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { downloads.deleteAll() }
        } message: {
            Text("The files are deleted from this device. You can still stream the books.")
        }
    }
}
