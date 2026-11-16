import SwiftUI

/// Controls the Kitzi app on the iPhone: play/pause, skips, chapters, speed,
/// sleep timer and bookmarks. Refreshed while it's on screen.
struct RemoteView: View {
    @Environment(WatchLink.self) private var link
    @State private var state: PhoneState?
    @State private var loaded = false
    @State private var busy = false
    @State private var note: String?
    /// Moves the position on between the iPhone's updates (once a second, no radio).
    @State private var now = Date()

    /// Where the iPhone is now: its last state, moved on by the time since, while playing.
    private func position(_ s: PhoneState) -> Double {
        guard s.isPlaying, let at = s.sentAt else { return s.positionSec }
        return min(s.positionSec + max(now.timeIntervalSince1970 - at, 0) * s.speed, s.durationSec)
    }

    var body: some View {
        Group {
            if let s = state {
                PlayerFace(
                    coverId: s.itemId, title: s.title, chapter: note ?? s.chapter,
                    position: position(s), total: s.durationSec, isPlaying: s.isPlaying,
                    speed: s.speed,
                    sleepLabel: s.sleepEndOfChapter ? "Chapter end" : s.sleepRemainingSec.map { Format.clock($0) },
                    busy: busy, skipBack: s.skipBackSec, skipForward: s.skipForwardSec,
                    back: { send(.back) }, toggle: { send(.toggle) }, forward: { send(.forward) },
                    chapterStart: s.chapterStartSec, chapterEnd: s.chapterEndSec
                )
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        if s.chapter != nil {
                            Button { send(.previousChapter) } label: { Image(systemName: "backward.end.fill") }
                                .accessibilityLabel("Previous chapter")
                            Button { send(.nextChapter) } label: { Image(systemName: "forward.end.fill") }
                                .accessibilityLabel("Next chapter")
                        } else {
                            Spacer()
                        }
                        NavigationLink { more(s) } label: { Image(systemName: "ellipsis") }
                            .accessibilityLabel("More")
                    }
                }
            } else if !loaded {
                ProgressView()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text(link.reachable ? "Nothing is playing in Kitzi on your iPhone." : "Can't reach your iPhone. Open Kitzi on it and keep it nearby.")
                        .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("iPhone")
        // The iPhone sends its state when it changes (and every 30 s while
        // playing); asking is only the fallback, every 30 s.
        .onChange(of: link.pushedState) { _, s in if !busy, let s { state = s; loaded = true } }
        .task {
            while !Task.isCancelled {
                if !busy {
                    let s = await link.phoneState()
                    if !busy { state = s }
                    loaded = true
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
    }

    private func send(_ cmd: RemoteCommand, _ value: Double? = nil) {
        Haptic.play(.click)
        busy = true
        Task {
            let s = await link.phoneState(command: cmd, value: value)
            if s == nil { note = "Your iPhone didn't answer." } else { note = nil; state = s }
            if cmd == .bookmark, s != nil { note = "Bookmark added on iPhone" }
            busy = false
        }
    }

    private func more(_ s: PhoneState) -> some View {
        List {
            NavigationLink { SpeedList(speed: s.speed) { send(.speed, $0) } } label: {
                LabeledContent { Text(SpeedList.label(s.speed)) } label: { Label("Speed", systemImage: "gauge.with.dots.needle.67percent") }
            }
            NavigationLink { SleepList(local: false) { send($0, $1) } } label: {
                LabeledContent {
                    Text(s.sleepEndOfChapter ? "Chapter end" : s.sleepRemainingSec.map { Format.clock($0) } ?? "Off")
                } label: { Label("Sleep Timer", systemImage: "moon.zzz") }
            }
            Button { send(.bookmark) } label: { Label("Add Bookmark", systemImage: "bookmark") }
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
        .navigationTitle("More")
    }
}
