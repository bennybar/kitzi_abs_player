import SwiftUI
import WatchKit

/// The player, in three vertical pages: Kitzi's controls, the system's Now
/// Playing (the crown sets the volume, and the headphone picker is there), and more.
struct PlayerView: View {
    @Environment(WatchPlayer.self) private var player

    var body: some View {
        if player.nowPlaying != nil {
            TabView {
                ControlsPage()
                NowPlayingView()
                MorePage()
            }
            .tabViewStyle(.verticalPage)
        } else {
            Text("Nothing playing").foregroundStyle(.secondary)
        }
    }
}

private struct ControlsPage: View {
    @Environment(WatchPlayer.self) private var player
    @State private var error: String?

    var body: some View {
        if let np = player.nowPlaying {
            VStack(spacing: 6) {
                Text(np.book.title).font(.headline).lineLimit(1)
                if let c = player.chapterTitle {
                    Text(c).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressView(value: np.totalSec > 0 ? min(player.position / np.totalSec, 1) : 0)
                HStack {
                    Text(Format.clock(player.position))
                    Spacer()
                    Text("-" + Format.clock(max(np.totalSec - player.position, 0)))
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button { player.skip(-30) } label: { Image(systemName: "gobackward.30").font(.title3) }
                        .accessibilityLabel("Back 30 seconds")
                    Button { toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    .handGestureShortcut(.primaryAction)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    .disabled(player.loading)
                    Button { player.skip(30) } label: { Image(systemName: "goforward.30").font(.title3) }
                        .accessibilityLabel("Forward 30 seconds")
                }
                .buttonStyle(.plain)
                if let s = player.status {
                    Text(s).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)
            .alert("Can't play", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func toggle() {
        if player.isPlaying { player.pause(); return }
        Task { if let why = await player.resume() { error = why } }
    }
}

private struct MorePage: View {
    @Environment(WatchPlayer.self) private var player
    @Environment(WatchModel.self) private var model
    @State private var note: String?

    var body: some View {
        List {
            if let np = player.nowPlaying, np.chapters.count > 1 {
                NavigationLink { ChaptersList() } label: { Label("Chapters", systemImage: "list.bullet") }
                HStack {
                    Button { player.previousChapter() } label: { Image(systemName: "backward.end.fill") }
                        .accessibilityLabel("Previous chapter")
                    Spacer()
                    Button { player.nextChapter() } label: { Image(systemName: "forward.end.fill") }
                        .accessibilityLabel("Next chapter")
                }
                .buttonStyle(.plain)
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
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
            Button(role: .destructive) {
                Task {
                    await player.stop()
                    WatchNav.shared.path.removeAll()
                }
            } label: { Label("Close Book", systemImage: "xmark") }
        }
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
