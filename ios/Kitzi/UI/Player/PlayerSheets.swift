import SwiftUI

// MARK: chapters

/// The book's chapters: the playing one highlighted, played ones dimmed; tap to jump.
struct PlayerChaptersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Player.self) private var player

    var body: some View {
        NavigationStack {
            let chapters = player.nowPlaying?.chapters ?? []
            let total = player.nowPlaying?.totalSec ?? 0
            let current = player.currentChapter()?.index ?? -1
            ScrollViewReader { proxy in
                List(chapters.indices, id: \.self) { i in
                    let c = chapters[i]
                    let end = i + 1 < chapters.count ? chapters[i + 1].startSec : total
                    Button {
                        player.seek(to: c.startSec)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: i == current ? "play.fill" : "circle.fill")
                                .font(.system(size: i == current ? 13 : 5))
                                .foregroundStyle(i == current ? Color.accentColor : .secondary)
                                .frame(width: 18)
                            Text(c.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .fontWeight(i == current ? .semibold : .regular)
                                .foregroundStyle(i == current ? Color.accentColor : (i < current ? .secondary : .primary))
                            Spacer(minLength: 8)
                            Text(Format.clock(max(end - c.startSec, 0)))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(i == current ? Color.accentColor.opacity(0.12) : Color.clear)
                    .id(i)
                }
                .listStyle(.plain)
                .onAppear { if current >= 0 { proxy.scrollTo(current, anchor: .center) } }
            }
            .navigationTitle(current >= 0 ? "Chapter \(current + 1) of \(chapters.count)" : "Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: speed

struct PlayerSpeedSheet: View {
    @Environment(Player.self) private var player
    @State private var value: Double = Player.shared.speed

    var body: some View {
        VStack(spacing: 20) {
            Text("Playback speed").font(.headline).padding(.top, 20)
            Text(playerSpeedLabel(value)).font(.system(size: 44, weight: .bold).monospacedDigit())
            Slider(value: $value, in: 0.5...3.5, step: 0.05) {
                Text("Speed")
            } minimumValueLabel: { Text("0.5×").font(.caption) } maximumValueLabel: { Text("3.5×").font(.caption) }
                .onChange(of: value) { _, v in player.setSpeed(v) }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach([1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { s in
                        Button(playerSpeedLabel(s)) { value = s }
                            .font(.subheadline.weight(.semibold))
                            .buttonStyle(.glass)
                            .tint(abs(value - s) < 0.001 ? Color.accentColor : nil)
                    }
                }
            }
            Text("Remembered for this book.").font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.height(330)])
    }
}

// MARK: sleep

struct PlayerSleepSheet: View {
    @Environment(SleepTimer.self) private var sleep
    @Environment(Player.self) private var player
    @State private var minutes: Double = Store.double("sleep_minutes") ?? 30

    var body: some View {
        VStack(spacing: 18) {
            Text("Sleep timer").font(.headline).padding(.top, 20)
            switch sleep.mode {
            case .off:
                Text("\(Int(minutes)) min").font(.system(size: 44, weight: .bold).monospacedDigit())
                Slider(value: $minutes, in: 5...120, step: 5)
                Button {
                    Store.set(minutes, "sleep_minutes")
                    sleep.start(minutes: Int(minutes))
                } label: {
                    Text("Start timer").font(.headline).frame(maxWidth: .infinity).frame(height: 44)
                }
                .buttonStyle(.glassProminent)
                let hasChapters = (player.nowPlaying?.chapters.count ?? 0) > 1
                Button {
                    if !sleep.startEndOfChapter() { Toast.show("This book has no chapters") }
                } label: {
                    Label(hasChapters ? "End of chapter" : "End of chapter (no chapters)", systemImage: "book.pages")
                        .frame(maxWidth: .infinity).frame(height: 40)
                }
                .buttonStyle(.glass)
                .disabled(!hasChapters)
            case .duration, .endOfChapter:
                Text(sleep.mode == .endOfChapter ? "Until the end of the chapter" : "Pausing in")
                    .foregroundStyle(.secondary)
                Text(Format.clock(sleep.remainingSec)).font(.system(size: 44, weight: .bold).monospacedDigit())
                if case .duration = sleep.mode {
                    Button { sleep.addMinutes(5) } label: { Label("+5 min", systemImage: "plus") }
                        .buttonStyle(.glass)
                }
                Button(role: .destructive) { sleep.cancel() } label: {
                    Text("Cancel timer").font(.headline).frame(maxWidth: .infinity).frame(height: 44)
                }
                .buttonStyle(.glass)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.height(380)])
    }
}

// MARK: bookmarks

struct PlayerBookmarksSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @State private var marks: [Bookmark]?
    @State private var renaming: Bookmark?
    @State private var renameText = ""

    private var itemId: String? { player.nowPlaying?.book.id }

    var body: some View {
        NavigationStack {
            Group {
                if let m = marks {
                    if m.isEmpty {
                        ContentUnavailableView("No bookmarks yet", systemImage: "bookmark",
                                               description: Text("Use the bookmark button on the cover to save your spot."))
                    } else {
                        List {
                            ForEach(m) { bm in
                                Button {
                                    player.seek(to: bm.timeSec)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Image(systemName: "bookmark.fill").foregroundStyle(Color.accentColor)
                                        Text(bm.title).lineLimit(1)
                                        Spacer()
                                        Text(Format.clock(bm.timeSec)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { delete(bm) } label: { Label("Delete", systemImage: "trash") }
                                    Button { renameText = bm.title; renaming = bm } label: { Label("Rename", systemImage: "pencil") }
                                        .tint(.accentColor)
                                }
                                .contextMenu {
                                    Button { renameText = bm.title; renaming = bm } label: { Label("Rename", systemImage: "pencil") }
                                    Button(role: .destructive) { delete(bm) } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { if let id = itemId { marks = await library.bookmarks(id) } }
            .alert("Rename bookmark", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") { rename() }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func delete(_ bm: Bookmark) {
        marks?.removeAll { $0.timeSec == bm.timeSec }
        Task {
            let sent = await library.bookmarkOp(.init(kind: "delete", itemId: bm.itemId, timeSec: bm.timeSec, title: ""))
            Toast.show(sent ? "Bookmark deleted" : "Bookmark deleted — syncs when online")
        }
    }

    private func rename() {
        guard let bm = renaming else { return }
        let title = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !title.isEmpty else { return }
        marks = marks?.map { $0.timeSec == bm.timeSec ? Bookmark(itemId: $0.itemId, timeSec: $0.timeSec, title: title, createdAt: $0.createdAt) : $0 }
        Task { await library.bookmarkOp(.init(kind: "rename", itemId: bm.itemId, timeSec: bm.timeSec, title: title)) }
    }
}

// MARK: play history

/// Where playback paused, newest first; tap to jump back there.
struct PlayerHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Player.self) private var player

    var body: some View {
        NavigationStack {
            let entries = player.nowPlaying.map { PlayHistory.shared.entries($0.book.id) } ?? []
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("No history yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Each pause is recorded here."))
                } else {
                    List(entries) { e in
                        Button {
                            player.seek(to: e.position)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Format.clock(e.position)).font(.headline.monospacedDigit())
                                    if let c = e.chapter { Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                Text(Date(timeIntervalSince1970: Double(e.at) / 1000), format: .relative(presentation: .named))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Play history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: more

struct PlayerMoreSheet: View {
    /// Opens another sheet (nil = just close).
    var open: (PlayerSheetKind?) -> Void
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var confirmFinished = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            List {
                Button { confirmFinished = true } label: { Label("Mark as finished", systemImage: "checkmark.circle") }
                Button { open(.bookmarks) } label: { Label("Bookmarks", systemImage: "bookmark") }
                Button { open(.history) } label: { Label("Play history", systemImage: "clock.arrow.circlepath") }
                Toggle(isOn: $settings.playerGradient) { Label("Gradient background", systemImage: "circle.lefthalf.filled") }
                Toggle(isOn: $settings.chapterTicks) { Label("Chapter indicators", systemImage: "line.3.horizontal.decrease") }
                Button(role: .destructive) {
                    open(nil)
                    Task { await player.closeBook() }
                } label: { Label("Close book", systemImage: "xmark.circle") }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Mark as finished?", isPresented: $confirmFinished, titleVisibility: .visible) {
                Button("Mark as finished") { markFinished() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This marks the book finished here and on the server, and stops playback.")
            }
        }
        .presentationDetents([.medium])
    }

    private func markFinished() {
        guard let id = player.nowPlaying?.book.id else { return }
        let before = library.progress[id]
        open(nil)
        Task {
            if await library.setFinished(id, true) {
                Toast.show("Marked as finished", action: "Undo") {
                    Task {
                        if !(await LibraryStore.shared.restoreProgress(before, id)) {
                            Toast.show("Couldn't undo — check your connection")
                        }
                    }
                }
            } else {
                Toast.show("Couldn't update the server")
            }
        }
    }
}

// MARK: info

struct PlayerBookInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Player.self) private var player

    var body: some View {
        NavigationStack {
            if let np = player.nowPlaying {
                let b = np.book
                List {
                    Section {
                        row("Title", b.title)
                        if let a = b.author { row("Author", a) }
                        if !b.narrators.isEmpty { row("Narrated by", b.narrators.joined(separator: ", ")) }
                        if let s = b.seriesLabel { row("Series", s) }
                        if let p = b.publisher { row("Publisher", p) }
                        if let y = b.publishYear { row("Year", String(y)) }
                        if !b.genres.isEmpty { row("Genres", b.genres.joined(separator: ", ")) }
                    }
                    Section {
                        row("Duration", Format.clock(np.totalSec))
                        if let s = b.sizeBytes { row("Size", Format.size(s)) }
                        row("Chapters", "\(np.chapters.count)")
                        row("Tracks", "\(np.tracks.count)")
                        row("Source", np.isLocal ? "Downloaded" : "Streaming")
                    }
                    if let d = b.description, !d.isEmpty {
                        Section("Description") {
                            Text(playerPlainText(d)).font(.subheadline)
                        }
                    }
                }
                .navigationTitle("Book info")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}

/// Book descriptions arrive as HTML: tags dropped, common entities decoded.
func playerPlainText(_ html: String) -> String {
    var s = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: "</p>", with: "\n\n")
    s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
        s = s.replacingOccurrences(of: k, with: v)
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}
