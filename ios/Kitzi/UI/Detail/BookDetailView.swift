import SwiftUI

/// Opens the full-screen player. MainView provides the real action; the default
/// does nothing (e.g. in previews).
struct OpenPlayerAction {
    var action: () -> Void = {}
    func callAsFunction() { action() }
}

private struct OpenPlayerKey: EnvironmentKey {
    static let defaultValue = OpenPlayerAction()
}

extension EnvironmentValues {
    var openPlayer: OpenPlayerAction {
        get { self[OpenPlayerKey.self] }
        set { self[OpenPlayerKey.self] = newValue }
    }
}

/// A book's page: cover and facts, play / download / queue, progress, mark
/// finished (with Undo), description, details and bookmarks.
struct BookDetailView: View {
    let book: Book

    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(Downloads.self) private var downloads
    @Environment(PlayQueue.self) private var queue
    @Environment(\.openPlayer) private var openPlayer

    @State private var playError: String?
    @State private var confirmFinished = false
    @State private var confirmCancelDownload = false
    @State private var confirmRemoveDownload = false
    @State private var bookmarks: [Bookmark] = []
    @State private var renaming: Bookmark?
    @State private var renameText = ""
    @State private var descriptionExpanded = false
    @State private var showMoreInfo = false
    @State private var cropping = false

    /// The cached copy when there is one (fresher metadata), else what was passed in.
    private var b: Book { library.byId[book.id] ?? book }
    private var progress: Progress? { library.progress[book.id] }
    private var isLoaded: Bool { player.nowPlaying?.book.id == book.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                queueRow
                if let p = progress, p.progress > 0 || p.isFinished { progressCard(p) }
                if let d = b.description.map(Self.stripHTML), !d.isEmpty { descriptionCard(d) }
                detailsCard
                bookmarksCard
            }
            .padding(16)
            .padding(.bottom, 80)
        }
        .navigationTitle("Book details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { cropping = true } label: { Image(systemName: "crop") }
                    .accessibilityLabel("Crop cover")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(progress?.isFinished == true ? "Mark as unfinished" : "Mark as finished") { confirmFinished = true }
            }
        }
        .confirmationDialog(
            progress?.isFinished == true ? "Mark as unfinished?" : "Mark as finished?",
            isPresented: $confirmFinished, titleVisibility: .visible
        ) {
            Button(progress?.isFinished == true ? "Mark as unfinished" : "Mark as finished") { Task { await toggleFinished() } }
        } message: {
            Text(progress?.isFinished == true
                 ? "This clears the finished mark and resets your position to the start, here and on the server."
                 : "This marks the book finished here and on the server. If it's playing, playback stops.")
        }
        .confirmationDialog("Cancel download?", isPresented: $confirmCancelDownload, titleVisibility: .visible) {
            Button("Cancel download", role: .destructive) { downloads.cancel(book.id) }
        }
        .confirmationDialog("Remove download?", isPresented: $confirmRemoveDownload, titleVisibility: .visible) {
            Button("Remove download", role: .destructive) { downloads.delete(book.id) }
        } message: {
            Text("The downloaded files are deleted from this device. You can still stream the book.")
        }
        .alert("Couldn't start this book", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playError ?? "")
        }
        .alert("Rename bookmark", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: book.id) { bookmarks = await library.bookmarks(book.id) }
        .sheet(isPresented: $showMoreInfo) { BookMoreInfoSheet(book: b) }
        .sheet(isPresented: $cropping) { CoverCropSheet(book: b) }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverImage(book: b)
                .frame(width: 130, height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text(b.title).font(.title2.weight(.bold)).lineLimit(4)
                if let author = b.author {
                    let first = author.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? author
                    NavigationLink(value: b.authors.first ?? first) {
                        Text(author).font(.headline).foregroundStyle(Color.accentColor).lineLimit(2)
                    }
                    .buttonStyle(.plain)
                }
                if let n = b.narrators.first {
                    Text("Narrated by \(n)").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                StarsView(book: b)
                HStack(spacing: 8) {
                    if let d = b.durationSec { chip("clock", Format.hm(d)) }
                    if let s = b.sizeBytes, s > 0 { chip("internaldrive", Format.size(s)) }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
    }

    // MARK: actions

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                Task { await play() }
            } label: {
                HStack(spacing: 8) {
                    if player.preparing && !isLoaded {
                        ProgressView().tint(.white)
                        Text("Starting…")
                    } else {
                        Image(systemName: isLoaded && player.isPlaying ? "waveform" : "play.fill")
                        Text((progress?.progress ?? 0) > 0 && progress?.isFinished != true ? "Resume" : "Play")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity).frame(height: 44)
            }
            .buttonStyle(.glassProminent)
            .disabled(player.preparing)

            downloadButton
        }
    }

    @ViewBuilder private var downloadButton: some View {
        let state = downloads.state(book.id)
        Button {
            switch state {
            case .queued, .running, .waiting: confirmCancelDownload = true
            case .done: confirmRemoveDownload = true
            case .failed, Downloads.State.none:
                Task {
                    if !(await downloads.start(book.id)) {
                        Toast.show("Nothing to download: the server lists no audio files for this book")
                    }
                }
            }
        } label: {
            Group {
                switch state {
                case Downloads.State.none: Label("Download", systemImage: "arrow.down.circle")
                case .queued: Label("Waiting", systemImage: "hourglass")
                case .running(let f): Label("Downloading \(Int(f * 100))%", systemImage: "xmark.circle")
                case .waiting: Label("Waiting for Wi-Fi", systemImage: "wifi")
                case .failed: Label("Retry", systemImage: "arrow.clockwise")
                case .done: Label("Remove", systemImage: "trash")
                }
            }
            .font(.headline)
            .lineLimit(1).minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity).frame(height: 44)
        }
        .buttonStyle(.glass)
    }

    private var queueRow: some View {
        HStack(spacing: 12) {
            Button {
                queue.addNext(book.id)
                Toast.show("Plays next", action: "Undo") { PlayQueue.shared.remove(book.id) }
            } label: {
                Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .frame(maxWidth: .infinity).frame(height: 38)
            }
            .buttonStyle(.glass)
            Button {
                queue.add(book.id)
                Toast.show("Added to queue", action: "Undo") { PlayQueue.shared.remove(book.id) }
            } label: {
                Label("Add to queue", systemImage: "text.badge.plus")
                    .frame(maxWidth: .infinity).frame(height: 38)
            }
            .buttonStyle(.glass)
        }
        .font(.subheadline.weight(.semibold))
    }

    private func play() async {
        if isLoaded {
            // Already the loaded book: carry on, don't reload it.
            player.resume()
            openPlayer()
            return
        }
        if let err = await player.play(b) {
            playError = err
        } else {
            openPlayer()
        }
    }

    // MARK: cards

    private func progressCard(_ p: Progress) -> some View {
        let total = p.durationSec > 0 ? p.durationSec : (b.durationSec ?? 0)
        let left = max(total - p.currentTimeSec, 0)
        return card {
            VStack(alignment: .leading, spacing: 8) {
                Text(p.isFinished ? "Finished" : "\(Int(p.progress * 100))% complete")
                    .font(.headline)
                if !p.isFinished {
                    Text("\(Format.hm(p.currentTimeSec)) in · \(Format.hm(left)) left")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ProgressView(value: p.isFinished ? 1 : p.progress).tint(.accentColor)
            }
        }
    }

    private func descriptionCard(_ text: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("About").font(.headline)
                Text(text)
                    .font(.body)
                    .lineLimit(descriptionExpanded ? nil : 6)
                if text.count > 300 {
                    Button(descriptionExpanded ? "Less" : "More") {
                        withAnimation(.snappy) { descriptionExpanded.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    @ViewBuilder private var detailsCard: some View {
        let genres = b.genres.filter { $0.replacingOccurrences(of: " ", with: "").lowercased() != "audiobook" }
        card {
                VStack(alignment: .leading, spacing: 10) {
                    if let s = b.seriesLabel, let name = b.series {
                        // The whole series, from any tab (see kitziDestinations).
                        NavigationLink(value: SeriesRoute(name: name)) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(systemName: "books.vertical").foregroundStyle(Color.accentColor).frame(width: 22)
                                Text("Series").foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                                Text(s).foregroundStyle(Color.accentColor).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                    }
                    if let y = b.publishYear { detailRow("calendar", "Year", String(y)) }
                    if let p = b.publisher { detailRow("building.2", "Publisher", p) }
                    if b.narrators.count > 1 { detailRow("mic", "Narrators", b.narrators.joined(separator: ", ")) }
                    if !genres.isEmpty { detailRow("tag", "Genres", genres.joined(separator: ", ")) }
                    Divider()
                    // Language, ISBN, file type, bitrate…
                    Button { showMoreInfo = true } label: {
                        HStack {
                            Image(systemName: "info.circle").foregroundStyle(Color.accentColor).frame(width: 22)
                            Text("More info").fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .font(.subheadline)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
    }

    private func detailRow(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 22)
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }

    private var bookmarksCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bookmarks").font(.headline)
                if bookmarks.isEmpty {
                    Label("No bookmarks yet. Use the bookmark button in the player to save your spot.", systemImage: "bookmark")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(bookmarks) { bm in
                        HStack(spacing: 10) {
                            Button { Task { await open(bm) } } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "bookmark.fill").foregroundStyle(Color.accentColor)
                                    Text(bm.title).lineLimit(1)
                                    Spacer()
                                    Text(Format.clock(bm.timeSec)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Menu {
                                Button { renameText = bm.title; renaming = bm } label: { Label("Rename", systemImage: "pencil") }
                                Button(role: .destructive) { Task { await delete(bm) } } label: { Label("Delete", systemImage: "trash") }
                            } label: {
                                Image(systemName: "ellipsis").frame(width: 30, height: 30)
                            }
                        }
                        .font(.subheadline)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: behaviour

    private func toggleFinished() async {
        let wasFinished = progress?.isFinished == true
        let before = progress
        if await library.setFinished(book.id, !wasFinished) {
            Toast.show(wasFinished ? "Marked as unfinished" : "Marked as finished", action: "Undo") {
                Task {
                    if !(await LibraryStore.shared.restoreProgress(before, book.id)) {
                        Toast.show("Couldn't undo — check your connection")
                    }
                }
            }
        } else {
            Toast.show("Couldn't update the server. Nothing was changed.")
        }
    }

    /// Jump to a bookmark: seek if the book is loaded, else start it first; then the player.
    private func open(_ bm: Bookmark) async {
        if isLoaded {
            player.seek(to: bm.timeSec)
            player.resume()
        } else {
            if let err = await player.play(b) { playError = err; return }
            player.seek(to: bm.timeSec)
        }
        openPlayer()
    }

    private func delete(_ bm: Bookmark) async {
        let sent = await library.bookmarkOp(.init(kind: "delete", itemId: book.id, timeSec: bm.timeSec, title: ""))
        bookmarks.removeAll { $0.timeSec == bm.timeSec }
        Toast.show(sent ? "Bookmark deleted" : "Bookmark deleted — syncs when online")
    }

    private func rename() async {
        guard let bm = renaming else { return }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !title.isEmpty else { return }
        await library.bookmarkOp(.init(kind: "rename", itemId: book.id, timeSec: bm.timeSec, title: title))
        bookmarks = bookmarks.map { $0.timeSec == bm.timeSec ? Bookmark(itemId: $0.itemId, timeSec: $0.timeSec, title: title, createdAt: $0.createdAt) : $0 }
    }

    /// Book descriptions arrive as HTML.
    static func stripHTML(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "</p>", with: "\n\n")
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (e, r) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            t = t.replacingOccurrences(of: e, with: r)
        }
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The book's technical details from the server: language, ISBN/ASIN, file type,
/// codec, bitrate (Android's "More info").
struct BookMoreInfoSheet: View {
    let book: Book
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [(String, String)]?

    var body: some View {
        NavigationStack {
            Group {
                if let rows {
                    if rows.isEmpty {
                        ContentUnavailableView("No details", systemImage: "info.circle",
                                               description: Text("The server didn't return details for this book."))
                    } else {
                        List(rows, id: \.0) { r in LabeledContent(r.0, value: r.1) }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("More info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task { rows = await load() }
    }

    private func load() async -> [(String, String)] {
        var out: [(String, String)] = []
        func add(_ label: String, _ value: String?) {
            if let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty { out.append((label, v)) }
        }
        guard let item = try? await API.shared.item(book.id, expanded: true) else { return [] }
        let media = item.obj("media")
        let meta = media?.obj("metadata")
        add("Language", meta?.str("language"))
        add("ISBN", meta?.str("isbn"))
        add("ASIN", meta?.str("asin"))
        add("Published", meta?.str("publishedDate") ?? meta?.str("publishedYear"))
        add("Explicit", meta?.bool("explicit") == true ? "Yes" : nil)
        let files = media?.objs("audioFiles") ?? []
        if let f = files.first {
            let fileMeta = f.obj("metadata")
            add("File type", (fileMeta?.str("ext") ?? f.str("mimeType"))?.replacingOccurrences(of: ".", with: "").uppercased())
            add("Codec", f.str("codec"))
            if let br = f.num("bitRate"), br > 0 { add("Bitrate", "\(Int((br / 1000).rounded())) kbps") }
            if let ch = f.int("channels"), ch > 0 { add("Channels", ch == 1 ? "Mono" : (ch == 2 ? "Stereo" : "\(ch)")) }
            if let sr = f.num("sampleRate") ?? f.obj("metadata")?.num("sampleRate"), sr > 0 { add("Sample rate", "\(Int(sr)) Hz") }
        }
        if files.count > 1 { add("Audio files", String(files.count)) }
        if let s = media?.num("size") ?? item.num("size"), s > 0 { add("Size", Format.size(Int64(s))) }
        if let d = media?.num("duration"), d > 0 { add("Duration", Format.hm(d)) }
        if let p = item.str("relPath") ?? item.str("path") { add("Path", p) }
        return out
    }
}
