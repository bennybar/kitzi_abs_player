import AVKit
import SwiftUI

/// Which sheet the full player shows.
enum PlayerSheetKind: String, Identifiable {
    case chapters, speed, sleep, bookmarks, history, more, info
    var id: String { rawValue }
}

/// The full-screen player: cover (with bookmark / last position / info buttons),
/// title, rating, scrubber with chapter ticks, transport, and action tiles.
struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(Downloads.self) private var downloads
    @Environment(SleepTimer.self) private var sleep

    @State private var sheet: PlayerSheetKind?
    /// While dragging the scrubber: the target, in the scrubber's own scope.
    @State private var scrub: Double?
    @State private var confirmCancelDownload = false
    @State private var confirmRemoveDownload = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            background
            if let np = player.nowPlaying {
                content(np)
            } else if player.preparing {
                // Between books (a reload, the queue's next book).
                ProgressView().controlSize(.large)
            } else {
                VStack(spacing: 16) {
                    Text("Nothing playing").font(.title3.weight(.semibold))
                    Button("Close") { dismiss() }.buttonStyle(.glass)
                }
            }
        }
        // The cover-tinted background is dark: text and glass follow it, whatever the
        // system appearance (as in Apple Music).
        .environment(\.colorScheme, settings.playerGradient ? .dark : colorScheme)
        .sheet(item: $sheet) { kind in sheetView(kind) }
        // Toasts from the player (Undo, bookmark added, sleep timer) — the root's toast
        // layer sits underneath this full-screen cover.
        .overlay(alignment: .bottom) { ToastView().padding(.bottom, 24) }
        // Only when the book is really gone: during a reload or the queue's advance
        // nowPlaying is briefly nil, and the player used to close on the user.
        .onChange(of: player.nowPlaying == nil) { _, gone in
            guard gone else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if player.nowPlaying == nil && !player.preparing { dismiss() }
            }
        }
    }

    // MARK: background

    @ViewBuilder private var background: some View {
        if settings.playerGradient, let b = player.nowPlaying?.book {
            // An overlay on a plain colour, so the blurred art can never size the layout.
            Color.black
                .overlay {
                    CoverImage(book: b, width: 300)
                        .blur(radius: 70)
                        .scaleEffect(1.4)
                }
                .overlay { Color.black.opacity(0.55) }
                .clipped()
                .ignoresSafeArea()
        } else {
            Color(.systemBackground).ignoresSafeArea()
        }
    }

    // MARK: layout — the Android player's structure, in Liquid Glass, on one screen

    /// The Android player's order, in Liquid Glass: cover, title block, then the
    /// scrubber and controls right under it, and the glass bar at the bottom.
    private func content(_ np: NowPlaying) -> some View {
        // Spare height (tall phones, a book with no narrator line) is spread evenly
        // between the groups instead of piling up in one gap.
        VStack(spacing: 0) {
            topBar(np)
            Spacer(minLength: 8)
            cover(np)
            Spacer(minLength: 10)
            infoBlock(np)
            Spacer(minLength: 12)
            scrubber(np)
            transport.padding(.top, 8)
            Spacer(minLength: 8)
            bar(np)
        }
        .padding(.horizontal, 22).padding(.bottom, 6)
    }

    private func topBar(_ np: NowPlaying) -> some View {
        HStack {
            glassIcon("chevron.down", "Close player") { dismiss() }
            Spacer()
            if let c = player.currentChapter(), np.chapters.count > 1 {
                Text("Chapter \(c.index + 1) of \(np.chapters.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            AirPlayButton()
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .padding(.top, 8)
    }

    private func glassIcon(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.headline).frame(width: 40, height: 40).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    /// The cover, with the bookmark and More info buttons on it (as on Android).
    /// "Last position" appears only after a jump, and only jumps back.
    private func cover(_ np: NowPlaying) -> some View {
        CoverImage(book: np.book, width: 1200)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
            .overlay(alignment: .topTrailing) {
                glassIcon("bookmark", "Add bookmark") { addBookmark(np) }.padding(12)
            }
            .overlay(alignment: .bottom) {
                HStack {
                    if settings.resumeFromHistory, let back = player.positionBeforeLastJump {
                        glassPill("arrow.uturn.backward", "Back to \(Format.clock(back))") { jumpBack(back) }
                            .transition(.scale.combined(with: .opacity))
                    }
                    Spacer()
                    glassPill("info.circle", "More info") { sheet = .info }
                }
                .padding(12)
                .animation(.spring(response: 0.35), value: player.positionBeforeLastJump)
            }
    }

    private func glassPill(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    /// Back to where you were before the last jump (scrub, chapter, bookmark).
    private func jumpBack(_ t: Double) {
        let from = player.position
        player.seek(to: t, isJump: false)
        Toast.show("Back to \(Format.clock(t))", action: "Undo") { Player.shared.seek(to: from) }
    }

    private func addBookmark(_ np: NowPlaying) {
        let pos = player.position
        let label = player.currentChapter()?.title ?? "Bookmark"
        Task {
            let sent = await library.bookmarkOp(.init(kind: "add", itemId: np.book.id, timeSec: (pos * 1000).rounded() / 1000, title: label))
            Toast.show(sent ? "Bookmark added at \(Format.clock(pos))" : "Bookmark saved at \(Format.clock(pos)) — syncs when online",
                       action: "View") { sheet = .bookmarks }
        }
    }

    // MARK: title, author, narrator, rating, length

    private func infoBlock(_ np: NowPlaying) -> some View {
        VStack(spacing: 4) {
            Text(np.book.title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let a = np.book.author {
                Text(a).font(.body).foregroundStyle(.secondary).lineLimit(1)
            }
            if let n = narrator(np) {
                Text("Narrated by \(n)").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                StarsView(book: np.book).font(.caption)
                lengthChip(np)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }

    private func narrator(_ np: NowPlaying) -> String? {
        np.book.narrators.first ?? LibraryStore.shared.byId[np.book.id]?.narrators.first
    }

    private func lengthChip(_ np: NowPlaying) -> some View {
        Label(Format.clock(np.totalSec), systemImage: "headphones")
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 10).padding(.vertical, 4)
            .glassEffect(.regular, in: Capsule())
    }

    // MARK: scrubber

    /// Chapter scope when the primary progress is the chapter (and there are chapters).
    private func chapterScope(_ np: NowPlaying) -> ChapterInfo? {
        guard settings.primaryProgress == "chapter", np.chapters.count > 1 else { return nil }
        return player.currentChapter()
    }

    private func scrubber(_ np: NowPlaying) -> some View {
        let chapter = chapterScope(np)
        let start = chapter?.startSec ?? 0
        let length = max(chapter?.durationSec ?? np.totalSec, 0.001)
        let current = scrub ?? (player.position - start)
        let fraction = min(max(current / length, 0), 1)
        let ticks: [Double] = (chapter == nil && settings.chapterTicks && np.totalSec > 0)
            ? np.chapters.dropFirst().map { $0.startSec / np.totalSec } : []

        return VStack(spacing: 6) {
            GeometryReader { g in
                let w = g.size.width
                let thick: CGFloat = scrub == nil ? 6 : 10
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.18)).frame(height: thick)
                    Capsule().fill(Color.accentColor).frame(width: max(w * fraction, thick), height: thick)
                    ForEach(ticks.indices, id: \.self) { i in
                        Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1.5, height: thick).offset(x: w * ticks[i])
                    }
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .animation(.spring(response: 0.25), value: scrub == nil)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in scrub = min(max(v.location.x / w, 0), 1) * length }
                        .onEnded { v in
                            let target = start + min(max(v.location.x / w, 0), 1) * length
                            let before = player.position
                            player.seek(to: target)
                            scrub = nil
                            // A stray tap can jump hours: offer the way back.
                            if abs(target - before) > 30 {
                                Toast.show("Jumped to \(Format.clock(target))", action: "Undo") { Player.shared.seek(to: before) }
                            }
                        }
                )
            }
            .frame(height: 24)

            HStack {
                Text(Format.clock(current)).monospacedDigit()
                Spacer()
                if let s = scrub, chapter == nil, let ch = np.chapters.last(where: { $0.startSec <= start + s + 0.25 })?.title {
                    Text(ch).lineLimit(1).truncationMode(.middle)
                } else if let c = player.currentChapter(), np.chapters.count > 1 {
                    Text(c.title).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text("-" + Format.clock(max(length - current, 0) / max(player.speed, 0.1))).monospacedDigit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            if settings.dualProgress, chapter != nil {
                // The book as a whole, under the chapter scrubber.
                HStack(spacing: 8) {
                    ProgressView(value: np.totalSec > 0 ? min(player.position / np.totalSec, 1) : 0)
                        .tint(.secondary)
                    Text("\(Format.clock(player.position)) / \(Format.clock(np.totalSec))")
                        .monospacedDigit().font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: transport (native glyphs, as in Apple Music)

    private var transport: some View {
        HStack {
            glyph("backward.end.fill", "Previous chapter", 22) { player.previousChapter() }
            Spacer()
            glyph("gobackward.\(validSkip(settings.seekBackSec))", "Back \(settings.seekBackSec) seconds", 30) {
                player.skip(-Double(settings.seekBackSec))
            }
            Spacer()
            if settings.expressivePlayButton {
                PlayPauseButton(size: 76)
            } else {
                Button { player.togglePlay() } label: {
                    ZStack {
                        if player.preparing { ProgressView().controlSize(.large) } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 50, weight: .regular))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 76, height: 76)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }
            Spacer()
            glyph("goforward.\(validSkip(settings.seekForwardSec))", "Forward \(settings.seekForwardSec) seconds", 30) {
                player.skip(Double(settings.seekForwardSec))
            }
            Spacer()
            glyph("forward.end.fill", "Next chapter", 22) { player.nextChapter() }
        }
        .foregroundStyle(.primary)
    }

    /// SF Symbols only has gobackward/goforward for some intervals.
    private func validSkip(_ s: Int) -> String {
        [5, 10, 15, 30, 45, 60, 75, 90].contains(s) ? String(s) : "plus"
    }

    private func glyph(_ icon: String, _ label: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .frame(width: 50, height: 50)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: the bottom bar (one Liquid Glass capsule, icons)

    private func bar(_ np: NowPlaying) -> some View {
        let id = np.book.id
        let dl = downloads.state(id)
        return GlassEffectContainer {
            HStack(spacing: 0) {
                barButton(text: playerSpeedLabel(player.speed), highlighted: player.speed != 1, label: "Speed") { sheet = .speed }
                barButton(icon: sleep.mode == .off ? "moon.zzz" : "moon.zzz.fill",
                          text: sleep.mode == .off ? nil : Format.clock(sleep.remainingSec),
                          highlighted: sleep.mode != .off, label: "Sleep timer") { sheet = .sleep }
                barButton(icon: "list.bullet", label: "Chapters", enabled: np.chapters.count > 1) { sheet = .chapters }
                barButton(icon: "clock.arrow.circlepath", label: "Play history") { sheet = .history }
                switch dl {
                case .queued, .running, .waiting:
                    barButton(icon: "arrow.down.circle.dotted", text: downloadLabel(dl), highlighted: true, label: "Cancel download") {
                        confirmCancelDownload = true
                    }
                case .done:
                    barButton(icon: "arrow.down.circle.fill", highlighted: true, label: "Downloaded") { confirmRemoveDownload = true }
                case .failed:
                    barButton(icon: "exclamationmark.arrow.circlepath", label: "Retry download") { Task { await downloads.start(id) } }
                case .none:
                    barButton(icon: "arrow.down.circle", label: "Download") {
                        Task {
                            if !(await downloads.start(id)) {
                                Toast.show("Nothing to download: the server lists no audio files for this book")
                            }
                        }
                    }
                }
                barButton(icon: "ellipsis", label: "More") { sheet = .more }
            }
            .frame(height: 56)
            .padding(.horizontal, 6)
            .glassEffect(.regular, in: Capsule())
        }
        .confirmationDialog("Cancel the download?", isPresented: $confirmCancelDownload, titleVisibility: .visible) {
            Button("Cancel download", role: .destructive) { downloads.cancel(id) }
            Button("Keep downloading", role: .cancel) {}
        }
        .confirmationDialog("Remove download?", isPresented: $confirmRemoveDownload, titleVisibility: .visible) {
            Button("Remove download", role: .destructive) { downloads.delete(id) }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The downloaded files are deleted from this device. You can still stream the book.")
        }
    }

    private func barButton(icon: String? = nil, text: String? = nil, highlighted: Bool = false, label: String,
                           enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                if let icon { Image(systemName: icon).font(.system(size: 19, weight: .semibold)) }
                if let text {
                    Text(text).font((icon == nil ? Font.subheadline : Font.caption2).weight(.semibold).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    private func downloadLabel(_ s: Downloads.State) -> String {
        switch s {
        case .running(let f): return "\(Int(f * 100))%"
        case .waiting: return "Wi-Fi"
        default: return "Waiting"
        }
    }

    // MARK: sheets

    @ViewBuilder private func sheetView(_ kind: PlayerSheetKind) -> some View {
        switch kind {
        case .chapters: PlayerChaptersSheet()
        case .speed: PlayerSpeedSheet()
        case .sleep: PlayerSleepSheet()
        case .bookmarks: PlayerBookmarksSheet()
        case .history: PlayerHistorySheet()
        case .info: PlayerBookInfoSheet()
        case .more: PlayerMoreSheet { next in switchSheet(to: next) }
        }
    }

    /// From one sheet to another: close, then open the next once the first is gone.
    private func switchSheet(to next: PlayerSheetKind?) {
        sheet = nil
        guard let next else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            sheet = next
        }
    }
}

/// "1×", "1.25×", "1.5×".
func playerSpeedLabel(_ v: Double) -> String {
    var s = String(format: "%.2f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s + "×"
}


/// The system AirPlay / Bluetooth route picker.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .label
        v.activeTintColor = UIColor.tintColor
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
