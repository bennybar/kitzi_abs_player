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
    @Environment(AppSettings.self) private var settings

    @State private var showAchew = false
    @State private var showFinishBy = false
    @State private var achewReplacing: String?
    @State private var chaptersVersion = 0
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
    @State private var chapters: [Chapter] = []
    @State private var showChapters = false
    @State private var showAudibleChapters = false
    @State private var showTitle = false

    /// The cached copy when there is one (fresher metadata), else what was passed in.
    private var b: Book { library.byId[book.id] ?? book }
    private var progress: Progress? { library.progress[book.id] }
    private var isLoaded: Bool { player.nowPlaying?.book.id == book.id }

    var body: some View {
        layout
        // No title over the cover art; the book's own once its title scrolls away.
        .navigationTitle(showTitle ? b.title : "")
        .navigationBarTitleDisplayMode(.inline)
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
        .sensoryFeedback(.error, trigger: playError) { _, new in new != nil }
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
        .task(id: book.id) {
            // What's saved here at once (the card no longer jumps into place), the
            // server's after the zoom in has finished (it parses all of /api/me).
            bookmarks = library.localBookmarks(book.id)
            try? await Task.sleep(for: .milliseconds(450))
            let fresh = await library.bookmarks(book.id)
            if fresh != bookmarks { withAnimation(.kitzi) { bookmarks = fresh } }
        }
        .task(id: "\(book.id)#\(chaptersVersion)") {
            // The downloaded copy's chapters work offline, and catch up with the
            // server when it can be reached; else just ask the server.
            if let saved = downloads.downloaded(book.id) {
                chapters = saved.chapters
                if let fresh = await downloads.refreshChapters(book.id) { chapters = fresh }
            } else if let item = try? await API.shared.item(book.id, expanded: true) {
                chapters = API.chapters(item.obj("media")?.arr("chapters") ?? [])
            }
        }
        .sheet(isPresented: $showChapters) {
            BookChaptersSheet(chapters: chapters, totalSec: b.durationSec ?? 0,
                              currentSec: progress.flatMap { $0.isFinished ? nil : $0.currentTimeSec }) { c in
                showChapters = false
                Task { await play(from: c) }
            }
        }
        .sheet(isPresented: $showMoreInfo) { BookMoreInfoSheet(book: b) }
        .sheet(isPresented: $showFinishBy) { FinishBySheet(book: b).presentationDetents([.medium, .large]) }
        #if DEBUG
        .task { if ProcessInfo.processInfo.environment["KITZI_TEST_FINISHBY"] != nil { try? await Task.sleep(for: .seconds(2)); showFinishBy = true } }
        #endif
        .sheet(isPresented: $showAudibleChapters) {
            AudibleChaptersSheet(book: b, current: chapters) { new in
                chapters = new
                player.chaptersChanged(book.id, new)
                chaptersVersion += 1 // the downloaded copy picks them up too
            }
        }
        .sheet(isPresented: $cropping) { CoverCropSheet(book: b) }
        .toolbar {
            let achew = settings.achewEnabled && Achew.shared.configured
            let watch = PhoneLink.shared.watchReady && downloads.isDownloaded(book.id)
            ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if watch {
                            if let f = PhoneLink.shared.sendProgress(book.id) {
                                Label("Sending to Apple Watch… \(Int(f * 100))%", systemImage: "applewatch").disabled(true)
                            } else {
                                Button {
                                    Toast.show(PhoneLink.shared.send(book.id)
                                               ? "Sending to your watch. It carries on in the background."
                                               : "Couldn't send this book to your watch")
                                } label: { Label("Send to Apple Watch", systemImage: "applewatch") }
                            }
                        }
                        Button { showAudibleChapters = true } label: { Label("Chapters from Audible", systemImage: "list.bullet.rectangle") }
                        if achew {
                            Button { Task { await fixChapters() } } label: { Label("Fix Chapters in Achew", systemImage: "wand.and.stars") }
                        }
                    } label: {
                        Image(systemName: "ellipsis").accessibilityLabel("More")
                    }
                }
        }
        // Back from Achew: it may have saved new chapters.
        .fullScreenCover(isPresented: $showAchew, onDismiss: { chaptersVersion += 1 }) { AchewView() }
        .confirmationDialog("Achew is working on another book", isPresented: Binding(get: { achewReplacing != nil }, set: { if !$0 { achewReplacing = nil } }),
                            titleVisibility: .visible, presenting: achewReplacing) { _ in
            Button("Fix This Book Instead", role: .destructive) { Task { await startAchew() } }
            Button("Open Achew") { showAchew = true }
        } message: { title in
            Text("Starting this book replaces your work on \(title).")
        }
        #if DEBUG
        .task { if ProcessInfo.processInfo.environment["KITZI_TEST_AUDIBLE_CHAPTERS"] != nil { showAudibleChapters = true } }
        // Test hook (simulator screenshots): open Achew as it is, without starting this book.
        .task { if ProcessInfo.processInfo.environment["KITZI_ACHEW_OPEN"] != nil { showAchew = true } }
        // Or start this book id there first, after the launch hook has connected.
        .task {
            if let id = ProcessInfo.processInfo.environment["KITZI_ACHEW_START"] {
                try? await Task.sleep(for: .seconds(3))
                do {
                    try await Achew.shared.start(itemId: id)
                    showAchew = true
                } catch {
                    print("KITZITEST achew start failed: \(error.localizedDescription)")
                }
            }
        }
        #endif
    }

    /// Achew works on one book at a time: don't silently replace another.
    private func fixChapters() async {
        do {
            if let job = try await Achew.shared.currentJob() {
                if job.itemId == book.id { showAchew = true } else { achewReplacing = job.title }
            } else {
                await startAchew()
            }
        } catch {
            Toast.show(error.localizedDescription)
        }
    }

    private func startAchew() async {
        do {
            try await Achew.shared.start(itemId: book.id)
            showAchew = true
        } catch {
            Toast.show(error.localizedDescription)
        }
    }

    /// The cover edge to edge at the top, then title, one big play button,
    /// round actions, and the about / details / bookmarks cards.
    private var layout: some View {
        ScrollView {
            VStack(spacing: 18) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { CoverImage(book: b, width: 1200) }
                    .clipped()
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 70)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Button { cropping = true } label: {
                            Image(systemName: "crop").font(.headline).frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("Crop cover")
                        .padding(.trailing, 16).padding(.bottom, 34)
                    }
                VStack(spacing: 8) {
                    Text(b.title).font(.title2.bold()).multilineTextAlignment(.center)
                    authorLink.font(.headline)
                    if let n = b.narrators.first {
                        NavigationLink(value: NarratorRoute(name: n)) {
                            (Text("Narrated by ").foregroundStyle(.secondary) + Text(n).foregroundStyle(Color.accentColor))
                                .font(.subheadline).multilineTextAlignment(.center)
                        }
                        .buttonStyle(.plain)
                    }
                    StarsView(book: b).font(.subheadline)
                    metaChips.padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, -20)
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        bigPlayButton
                        if let line = progressLine {
                            Text(line).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let done = library.finishEstimate(b) {
                            Button { showFinishBy = true } label: {
                                Label("At your pace, done \(Self.day(done))", systemImage: "flag.checkered")
                                    .font(.footnote.weight(.medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                    iconActions
                    if let d = b.description.map(Self.stripHTMLCached), !d.isEmpty { descriptionCard(d) }
                    detailsCard
                    // No spacing here: each Audible section brings its own gap when
                    // it has something, so empty ones leave no hole.
                    VStack(spacing: 0) {
                        // Your own bookmarks come before Audible's sections; with
                        // none yet, the hint about them goes last.
                        if !bookmarks.isEmpty { bookmarksCard.padding(.bottom, 18) }
                        if settings.seriesMissing, b.series != nil, b.seriesSequence != nil { NextInSeriesCard(book: b) }
                        if settings.audibleReviews { LibraryBookReviews(book: b) }
                        if settings.similarBooks { SimilarBooksRow(book: b) }
                        if bookmarks.isEmpty { bookmarksCard }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 80)
        }
        // Past the cover and the title under it: the title goes to the bar.
        .onScrollGeometryChange(for: Bool.self, of: { $0.contentOffset.y > $0.containerSize.width + 20 }) { _, past in
            showTitle = past
        }
        .ignoresSafeArea(edges: .top)
    }


    @ViewBuilder private var authorLink: some View {
        if let author = b.author {
            let first = author.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? author
            NavigationLink(value: b.authors.first ?? first) {
                Text(author).foregroundStyle(Color.accentColor).lineLimit(2).multilineTextAlignment(.center)
            }
            .buttonStyle(.plain)
        }
    }

    private var metaChips: some View {
        HStack(spacing: 8) {
            if let d = b.durationSec { chip("clock", Format.hm(d)) }
            if let y = b.publishYear { chip("calendar", String(y)) }
            if let s = b.sizeBytes, s > 0 { chip("internaldrive", Format.size(s)) }
        }
    }

    /// "35% · last listened 2 days ago", or "Finished on 12 Oct 2026".
    private var progressLine: String? {
        guard let p = progress else { return nil }
        if p.isFinished {
            let at = Date(timeIntervalSince1970: Double(p.finishedAt ?? p.lastUpdate) / 1000)
            return "Finished on \(at.formatted(date: .abbreviated, time: .omitted))"
        }
        guard p.progress > 0 else { return nil }
        let at = Date(timeIntervalSince1970: Double(p.lastUpdate) / 1000)
        let ago = at.timeIntervalSinceNow > -60 ? "just now" : Self.relative.localizedString(for: at, relativeTo: Date())
        return "\(Int(p.progress * 100))% · last listened \(ago)"
    }

    private var bigPlayButton: some View {
        let p = progress
        let started = (p?.progress ?? 0) > 0 && p?.isFinished != true
        return Button { Task { await play() } } label: {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: isLoaded && player.isPlaying ? "waveform" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.variableColor.iterative, isActive: isLoaded && player.isPlaying && !UIAccessibility.isReduceMotionEnabled)
                    Text(started ? "Resume" : "Play")
                    if started, let left = library.timeLeft(b) { Text("· \(Format.hm(left)) left").opacity(0.8) }
                }
                .font(.headline)
                if started {
                    ProgressView(value: p?.progress ?? 0).tint(.white).frame(width: 180)
                }
            }
            .frame(maxWidth: .infinity).frame(height: started ? 58 : 50)
            .animation(.kitzi, value: started)
        }
        .buttonStyle(.glassProminent)
        .disabled(player.preparing)
    }

    private var iconActions: some View {
        let state = downloads.state(book.id)
        let dl: (String, String) = {
            switch state {
            case Downloads.State.none: ("arrow.down", "Download")
            case .queued, .waiting: ("hourglass", "Waiting")
            case .running(let f): ("xmark", "\(Int(f * 100))%")
            case .failed: ("arrow.clockwise", "Retry")
            case .done: ("arrow.down.circle.fill", "Downloaded")
            }
        }()
        return GlassEffectContainer(spacing: 14) {
            HStack(spacing: 0) {
                iconAction(dl.0, dl.1, highlighted: state == .done) { downloadTapped(state) }
                iconAction("text.line.first.and.arrowtriangle.forward", "Play Next") {
                    queue.addNext(book.id); Haptics.tap(); Toast.show("Plays next", action: "Undo") { PlayQueue.shared.remove(book.id) }
                }
                iconAction("text.badge.plus", "Add to Queue") {
                    queue.add(book.id); Haptics.tap(); Toast.show("Added to queue", action: "Undo") { PlayQueue.shared.remove(book.id) }
                }
                iconAction(progress?.isFinished == true ? "arrow.uturn.backward" : "checkmark.circle",
                           progress?.isFinished == true ? "Mark Unfinished" : "Mark Finished") { confirmFinished = true }
            }
        }
    }

    /// `highlighted`: in the accent colour (a state that's on, like "Downloaded").
    private func iconAction(_ icon: String, _ label: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(highlighted ? .title2 : .title3)
                    .foregroundStyle(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                    .frame(width: 54, height: 54)
                    .glassEffect(.regular.interactive(), in: .circle)
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassEffect(.regular, in: Capsule())
    }

    private func downloadTapped(_ state: Downloads.State) {
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
    }

    /// Starts (or carries on with) this book at [c].
    private func play(from c: Chapter) async {
        if isLoaded {
            player.resume()
        } else if let err = await player.play(b) {
            playError = err
            return
        }
        player.seek(to: c.startSec)
        openPlayer()
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

    private func descriptionCard(_ text: String) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("About").font(.headline)
                Text(text)
                    .font(.body)
                    .lineLimit(descriptionExpanded ? nil : 6)
                if text.count > 300 {
                    Button(descriptionExpanded ? "Less" : "More") {
                        withAnimation(.kitzi) { descriptionExpanded.toggle() }
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
                    // The count the library already knows shows at once; the list loads behind it.
                    if let count = chapters.isEmpty ? b.chapterCount.flatMap({ $0 > 1 ? $0 : nil }) : chapters.count {
                        Button { showChapters = true } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(systemName: "list.bullet").foregroundStyle(Color.accentColor).frame(width: 22)
                                Text("Chapters").foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                                Text("\(count)").foregroundStyle(Color.accentColor).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .font(.subheadline)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(chapters.isEmpty) // (the list is still loading)
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
                            Text("Technical Info").fontWeight(.semibold)
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
                                Image(systemName: "ellipsis").frame(width: 44, height: 44)
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
            Haptics.success()
            Toast.show(wasFinished ? "Marked as unfinished" : "Marked as finished", action: "Undo") {
                Task {
                    if !(await LibraryStore.shared.restoreProgress(before, book.id)) {
                        Toast.show("Couldn't undo — check your connection")
                    }
                }
            }
        } else {
            Haptics.failure()
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
    /// "today", "tomorrow", "Thursday", or "Dec 4" further out.
    static func day(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "today" }
        if cal.isDateInTomorrow(d) { return "tomorrow" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 0
        return days < 7 ? d.formatted(.dateTime.weekday(.wide)) : d.formatted(.dateTime.month(.abbreviated).day())
    }

    private static let relative = RelativeDateTimeFormatter()
    /// The last description stripped (the page redraws often, e.g. on download progress).
    private static var stripped: (raw: String, text: String)?
    static func stripHTMLCached(_ s: String) -> String {
        if let c = stripped, c.raw == s { return c.text }
        let t = stripHTML(s)
        stripped = (s, t)
        return t
    }

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
            .navigationTitle("Technical Info")
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

/// A book's chapters before (or without) playing it; tap one to start there.
struct BookChaptersSheet: View {
    let chapters: [Chapter]
    let totalSec: Double
    /// Where the listener is (nil: not started or finished).
    let currentSec: Double?
    var onPick: (Chapter) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(chapters.enumerated()), id: \.offset) { i, c in
                let end = i + 1 < chapters.count ? chapters[i + 1].startSec : totalSec
                let current = currentSec.map { $0 >= c.startSec && $0 < end } ?? false
                Button { onPick(c) } label: {
                    HStack(spacing: 12) {
                        Text("\(i + 1)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.body.weight(current ? .semibold : .regular))
                                .foregroundStyle(current ? Color.accentColor : .primary)
                            Text(Format.clock(c.startSec)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if current { Image(systemName: "waveform").foregroundStyle(Color.accentColor) }
                        Text(Format.hm(max(end - c.startSec, 0))).font(.footnote).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .navigationTitle("\(chapters.count) Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// "At your pace": when the book will be done at the recent daily listening,
/// and the speed it needs to be done by a chosen day.
struct FinishBySheet: View {
    let book: Book
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var target = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()

    private var currentSpeed: Double {
        player.nowPlaying?.book.id == book.id ? player.speed
            : (Store.double("playback_speed:\(book.id)") ?? Store.double("playback_speed") ?? 1)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Your pace", value: "\(Format.hm(library.dailyPaceSec)) a day")
                    if let left = library.timeLeft(book) { LabeledContent("Left at \(SpeedLabel.text(currentSpeed))", value: Format.hm(left)) }
                    if let done = library.finishEstimate(book) {
                        LabeledContent("Done", value: done.formatted(date: .abbreviated, time: .omitted))
                    }
                } footer: {
                    Text("Your average over the last 14 days, days off included.")
                }
                Section("Finish By") {
                    DatePicker("Day", selection: $target, in: Date()..., displayedComponents: .date)
                        .onChange(of: target) { _, _ in Haptics.tap() }
                    if library.dailyPaceSec < 5 * 60 {
                        Text("A few days of listening first: there isn't enough yet to work out your pace.").foregroundStyle(.secondary)
                    } else if let s = library.speedToFinish(book, by: target) {
                        let speed = (max(s, 0.5) * 20).rounded(.up) / 20
                        if speed > 3.5 {
                            Text("Even at 3.5× that needs more than your usual listening.").foregroundStyle(.secondary)
                        } else if speed <= currentSpeed + 0.001 {
                            Text("You're on track at \(SpeedLabel.text(currentSpeed)).").foregroundStyle(.secondary)
                        } else {
                            Button {
                                if player.nowPlaying?.book.id == book.id { player.setSpeed(speed) }
                                else { Store.set(speed, "playback_speed:\(book.id)") }
                                Haptics.success()
                                dismiss()
                            } label: {
                                Label("Listen at \(SpeedLabel.text(speed))", systemImage: "speedometer")
                            }
                        }
                    }
                }
            }
            .animation(.kitzi, value: target)
            .navigationTitle("At Your Pace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

enum SpeedLabel {
    static func text(_ s: Double) -> String {
        let t = s.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.1f", s) : String(format: "%g", (s * 100).rounded() / 100)
        return t + "×"
    }
}
