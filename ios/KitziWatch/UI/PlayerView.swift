import SwiftUI
import WatchKit

/// The player: one screen with the controls, and a toolbar for the chapters,
/// the system's Now Playing (the crown sets the volume, and the headphone
/// picker is there) and everything else.
struct PlayerView: View {
    @Environment(WatchPlayer.self) private var player
    @State private var error: String?
    /// Play/Pause as tapped, until the player catches up (a resume can wait a
    /// few seconds for the server: the button showed the old state meanwhile).
    @State private var intended: Bool?

    var body: some View {
        // (Nothing here reads the position: only the time and bar below follow it.)
        if let np = player.nowPlaying {
            PlayerFace(
                coverId: np.book.id, title: np.book.title, isPlaying: intended ?? player.isPlaying,
                busy: false, waiting: player.loading || player.buffering || player.jumping,
                note: player.streamError == nil ? player.waitLabel : nil,
                skipBack: 30, skipForward: 30,
                back: { Haptic.play(.click); player.skip(-30) }, toggle: toggle,
                forward: { Haptic.play(.click); player.skip(30) }
            ) { showNote, note in
                WatchFaceInfo(note: showNote ? note : nil)
            }
            .onChange(of: player.isPlaying) { _, _ in intended = nil }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if np.chapters.count > 1 {
                        NavigationLink { ChaptersList() } label: { Image(systemName: "list.bullet") }
                            .accessibilityLabel("Chapters")
                    } else {
                        Spacer()
                    }
                    NavigationLink { NowPlayingView() } label: { Image(systemName: "speaker.wave.2.fill") }
                        .accessibilityLabel("Volume and headphones")
                    NavigationLink { MorePage() } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("More")
                }
            }
            .alert("Can't play", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        } else {
            Text("Nothing playing").foregroundStyle(.secondary)
        }
    }

    private func toggle() {
        if player.isPlaying { Haptic.play(.stop); intended = false; player.pause(); return }
        Haptic.play(.start)
        intended = true
        Task {
            if let why = await player.resume() { Haptic.play(.failure); error = why }
            intended = nil
        }
    }
}

/// The watch player's chapter line, bar and times: the only part that follows
/// the position (twice a second), so the rest of the face isn't redrawn with it.
private struct WatchFaceInfo: View {
    let note: String?
    @Environment(WatchPlayer.self) private var player

    var body: some View {
        let np = player.nowPlaying
        let bounds = player.chapterBounds
        FaceInfo(chapter: player.streamError ?? player.chapterTitle, note: note,
                 position: player.position, total: np?.totalSec ?? 0, speed: player.speed,
                 sleepLabel: sleepLabel, chapterStart: bounds?.start, chapterEnd: bounds?.end)
    }

    private var sleepLabel: String? {
        if player.sleepEndOfChapter { return "Chapter end" }
        if let at = player.sleepAt { return Format.clock(max(at.timeIntervalSinceNow, 0)) }
        return nil
    }
}

/// A turning arc around a round button: loading or buffering. Still (a quarter
/// ring) in always-on and with Reduce Motion.
struct RingSpinner: View {
    @State private var spin = false
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = dimmed || reduceMotion
        Circle().trim(from: 0, to: 0.25)
            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(spin && !still ? 360 : 0))
            .animation(still ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: spin && !still)
            .onAppear { spin = true }
            .accessibilityLabel("Loading")
    }
}

/// A thin progress line.
struct Bar: View {
    let value: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(color).frame(width: g.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityValue("\(Int(min(max(value, 0), 1) * 100)) percent")
    }
}

/// Under the title: the chapter (or a note while it waits), the bar and the times.
struct FaceInfo: View {
    let chapter: String?
    /// Shown in place of the chapter while it waits ("Buffering…").
    let note: String?
    let position: Double
    let total: Double
    let speed: Double
    let sleepLabel: String?
    /// The chapter the position is in: the bar and times show it (with the time
    /// left in the book after its name); nil shows the whole book.
    var chapterStart: Double? = nil
    var chapterEnd: Double? = nil
    @Environment(\.isLuminanceReduced) private var dimmed

    /// (elapsed, left, fraction) for the bar: the chapter's when known, else the book's.
    private var progress: (elapsed: Double, left: Double, fraction: Double) {
        if let s = chapterStart, let e = chapterEnd, e > s {
            return PositionRules.chapterProgress(position: position, start: s, end: e)
        }
        return (position, max(total - position, 0), total > 0 ? min(position / total, 1) : 0)
    }
    private var inChapter: Bool { chapterStart != nil && (chapterEnd ?? 0) > (chapterStart ?? 0) }

    /// Always-on: minutes only (the seconds would be stale between its rare updates).
    private func clock(_ s: Double) -> String { dimmed ? Format.hm(s) : Format.clock(s) }

    var body: some View {
        let p = progress
        VStack(spacing: 4) {
            // One line either way, so the face doesn't shift when the note comes and goes.
            ZStack {
                let line = chapter.map { inChapter && total > 0 ? "\($0) · \(Format.hm(max(total - position, 0))) left" : $0 }
                Text(line ?? " ").foregroundStyle(.secondary).opacity(note == nil ? 1 : 0)
                if let note { Text(note).foregroundStyle(Color.accentColor).transition(.opacity) }
            }
            .font(.caption2).lineLimit(1)
            .animation(.easeInOut(duration: 0.2), value: note)
            VStack(spacing: 1) {
                Bar(value: p.fraction, color: .white)
                HStack {
                    Text(clock(p.elapsed))
                    Spacer()
                    if abs(speed - 1) > 0.001 { Text(SpeedList.label(speed)).foregroundStyle(.primary) }
                    if let sleepLabel { Label(sleepLabel, systemImage: "moon.zzz.fill").labelStyle(.titleAndIcon).foregroundStyle(.primary) }
                    Spacer()
                    Text("-" + clock(p.left))
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }
}

/// The face shared by the watch's player and the iPhone remote: the book over
/// its cover's colours, where you are (`info`), and the three big controls.
struct PlayerFace<Info: View>: View {
    let coverId: String
    let title: String
    let isPlaying: Bool
    let busy: Bool
    /// Loading or buffering: a spinner around the play button.
    var waiting = false
    /// What it's waiting on ("Buffering…"), for `info`.
    var note: String? = nil
    let skipBack: Int
    let skipForward: Int
    let back: () -> Void
    let toggle: () -> Void
    let forward: () -> Void
    /// Whose volume the Digital Crown turns: the watch's, or the iPhone's (remote).
    var volume: WKInterfaceVolumeControl.Origin = .local
    /// The chapter line, bar and times; given whether to show the note, and the note.
    @ViewBuilder let info: (_ showNote: Bool, _ note: String?) -> Info
    /// The wait shows only after a moment: a resume or a skip that's quick no
    /// longer flashes "Opening…" and the spinner.
    @State private var showWait = false

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.headline).lineLimit(1)
                // The crown sets the volume here, as in the system's Now Playing.
                .padding(.trailing, 22)
                .overlay(alignment: .trailing) {
                    VolumeControl(origin: volume).frame(width: 22, height: 22)
                        .accessibilityLabel("Volume")
                }
            info(showWait, note)
            HStack(spacing: 14) {
                Button(action: back) { Image(systemName: "gobackward.\(skipBack)").font(.title3).frame(width: 38, height: 38)
                    .glassEffect(.regular.interactive(), in: Circle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back \(skipBack) seconds")
                Button(action: toggle) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.title2)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.snappy, value: isPlaying)
                        .frame(width: 50, height: 50)
                        .overlay {
                            if showWait { RingSpinner().padding(2).transition(.opacity) }
                        }
                        .glassEffect(.regular.tint(.accentColor).interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .handGestureShortcut(.primaryAction)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                Button(action: forward) { Image(systemName: "goforward.\(skipForward)").font(.title3).frame(width: 38, height: 38)
                    .glassEffect(.regular.interactive(), in: Circle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Forward \(skipForward) seconds")
            }
            .disabled(busy)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .coverBackground(coverId)
        .task(id: waiting) {
            if waiting {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
            }
            withAnimation(.easeInOut(duration: 0.2)) { showWait = waiting }
        }
    }
}

private struct MorePage: View {
    @Environment(WatchPlayer.self) private var player
    @Environment(WatchModel.self) private var model
    @State private var note: String?

    var body: some View {
        List {
            if let np = player.nowPlaying, np.chapters.count > 1 {
                Button { Haptic.play(.click); player.previousChapter() } label: { Label("Previous Chapter", systemImage: "backward.end.fill") }
                Button { Haptic.play(.click); player.nextChapter() } label: { Label("Next Chapter", systemImage: "forward.end.fill") }
            }
            NavigationLink { SpeedList(speed: player.speed) { player.setSpeed($0) } } label: {
                LabeledContent { Text(SpeedList.label(player.speed)) } label: { Label("Speed", systemImage: "gauge.with.dots.needle.67percent") }
            }
            NavigationLink { SleepList(local: true) } label: {
                LabeledContent { Text(sleepLabel) } label: { Label("Sleep Timer", systemImage: "moon.zzz") }
            }
            Button {
                Task {
                    let ok = await player.addBookmark()
                    Haptic.play(ok ? .success : .failure)
                    note = ok ? "Bookmark added" : "Couldn't add the bookmark. Check the connection."
                }
            } label: { Label("Add Bookmark", systemImage: "bookmark") }
            Button {
                Task {
                    let ok = await model.syncNow()
                    Haptic.play(ok ? .success : .failure)
                    note = ok ? "Synced" : "Saved on watch. It syncs when there's a connection."
                }
            } label: { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
            if let note = note ?? player.status { Text(note).font(.caption2).foregroundStyle(.secondary) }
            Button(role: .destructive) {
                Task {
                    await player.stop()
                    WatchNav.shared.path.removeAll()
                }
            } label: { Label("Close Book", systemImage: "xmark") }
        }
        .navigationTitle("More")
    }

    private var sleepLabel: String {
        if player.sleepEndOfChapter { return "Chapter end" }
        if let at = player.sleepAt { return Format.clock(max(at.timeIntervalSinceNow, 0)) }
        return "Off"
    }
}

struct ChaptersList: View {
    @Environment(WatchPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let np = player.nowPlaying {
            let current = player.currentChapter
            ScrollViewReader { proxy in
                List(Array(np.chapters.enumerated()), id: \.offset) { i, c in
                    Button {
                        Haptic.play(.click)
                        player.seek(to: c.startSec)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(c.title).lineLimit(2).foregroundStyle(i == current ? Color.accentColor : .primary)
                            Text(Format.clock(c.startSec)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .id(i)
                }
                .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            }
            .navigationTitle("Chapters")
        }
    }
}

struct SpeedList: View {
    let speed: Double
    let pick: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    static let speeds: [Double] = [0.8, 0.9, 1, 1.1, 1.2, 1.25, 1.3, 1.4, 1.5, 1.75, 2, 2.5, 3]

    static func label(_ s: Double) -> String {
        (s.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", s) : String(format: "%g", s)) + "×"
    }

    var body: some View {
        List(Self.speeds, id: \.self) { s in
            Button {
                pick(s)
                dismiss()
            } label: {
                HStack {
                    Text(Self.label(s))
                    Spacer()
                    if abs(s - speed) < 0.001 { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                }
            }
        }
        .navigationTitle("Speed")
    }
}

/// The sleep timer, for the watch's own player or (local: false) the iPhone's.
struct SleepList: View {
    let local: Bool
    var remote: ((RemoteCommand, Double?) -> Void)?
    @Environment(WatchPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach([5, 10, 15, 30, 45, 60, 90], id: \.self) { m in
                Button("\(m) minutes") {
                    if local { player.sleep(minutes: m) } else { remote?(.sleep, Double(m)) }
                    dismiss()
                }
            }
            Button("End of chapter") {
                if local { player.sleepAtChapterEnd() } else { remote?(.sleepEndOfChapter, nil) }
                dismiss()
            }
            Button("Off", role: .destructive) {
                if local { player.cancelSleep() } else { remote?(.sleepOff, nil) }
                dismiss()
            }
        }
        .navigationTitle("Sleep Timer")
    }
}

/// The system's volume indicator, holding the Digital Crown: turning it sets the
/// volume (the watch's own, or the iPhone's from the remote).
struct VolumeControl: WKInterfaceObjectRepresentable {
    let origin: WKInterfaceVolumeControl.Origin

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let v = WKInterfaceVolumeControl(origin: origin)
        v.setTintColor(.white)
        return v
    }

    func updateWKInterfaceObject(_ v: WKInterfaceVolumeControl, context: Context) {
        v.focus()
    }
}
