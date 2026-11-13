import SwiftUI
import WatchKit

/// The player: one screen with the controls, and a toolbar for the chapters,
/// the system's Now Playing (the crown sets the volume, and the headphone
/// picker is there) and everything else.
struct PlayerView: View {
    @Environment(WatchPlayer.self) private var player
    @State private var error: String?

    var body: some View {
        if let np = player.nowPlaying {
            PlayerFace(
                coverId: np.book.id, title: np.book.title, chapter: player.chapterTitle,
                position: player.position, total: np.totalSec, isPlaying: player.isPlaying,
                speed: player.speed, sleepLabel: sleepLabel, busy: player.loading,
                skipBack: 30, skipForward: 30,
                back: { player.skip(-30) }, toggle: toggle, forward: { player.skip(30) }
            )
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

    private var sleepLabel: String? {
        if player.sleepEndOfChapter { return "Chapter end" }
        if let at = player.sleepAt { return Format.clock(max(at.timeIntervalSinceNow, 0)) }
        return nil
    }

    private func toggle() {
        if player.isPlaying { player.pause(); return }
        Task { if let why = await player.resume() { error = why } }
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

/// The face shared by the watch's player and the iPhone remote: the book over
/// its cover's colours, where you are, and the three big controls.
struct PlayerFace: View {
    let coverId: String
    let title: String
    let chapter: String?
    let position: Double
    let total: Double
    let isPlaying: Bool
    let speed: Double
    let sleepLabel: String?
    let busy: Bool
    let skipBack: Int
    let skipForward: Int
    let back: () -> Void
    let toggle: () -> Void
    let forward: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                if let chapter { Text(chapter).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            VStack(spacing: 1) {
                Bar(value: total > 0 ? position / total : 0, color: .white)
                HStack {
                    Text(Format.clock(position))
                    Spacer()
                    if abs(speed - 1) > 0.001 { Text(SpeedList.label(speed)).foregroundStyle(.primary) }
                    if let sleepLabel { Label(sleepLabel, systemImage: "moon.zzz.fill").labelStyle(.titleAndIcon).foregroundStyle(.primary) }
                    Spacer()
                    Text("-" + Format.clock(max(total - position, 0)))
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
            HStack(spacing: 14) {
                Button(action: back) { Image(systemName: "gobackward.\(skipBack)").font(.title3).frame(width: 38, height: 38)
                    .glassEffect(.regular.interactive(), in: Circle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back \(skipBack) seconds")
                Button(action: toggle) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.title2)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 50, height: 50)
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
    }
}

private struct MorePage: View {
    @Environment(WatchPlayer.self) private var player
    @Environment(WatchModel.self) private var model
    @State private var note: String?

    var body: some View {
        List {
            if let np = player.nowPlaying, np.chapters.count > 1 {
                Button { player.previousChapter() } label: { Label("Previous Chapter", systemImage: "backward.end.fill") }
                Button { player.nextChapter() } label: { Label("Next Chapter", systemImage: "forward.end.fill") }
            }
            NavigationLink { SpeedList(speed: player.speed) { player.setSpeed($0) } } label: {
                LabeledContent { Text(SpeedList.label(player.speed)) } label: { Label("Speed", systemImage: "gauge.with.dots.needle.67percent") }
            }
            NavigationLink { SleepList(local: true) } label: {
                LabeledContent { Text(sleepLabel) } label: { Label("Sleep Timer", systemImage: "moon.zzz") }
            }
            Button {
                Task { note = await player.addBookmark() ? "Bookmark added" : "Couldn't add the bookmark. Check the connection." }
            } label: { Label("Add Bookmark", systemImage: "bookmark") }
            Button {
                Task { note = await model.syncNow() ? "Synced" : "Saved on watch. It syncs when there's a connection." }
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
            let current = player.chapterIndex()
            ScrollViewReader { proxy in
                List(Array(np.chapters.enumerated()), id: \.offset) { i, c in
                    Button {
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
