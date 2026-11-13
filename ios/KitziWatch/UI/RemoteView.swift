import SwiftUI

/// Controls the Kitzi app on the iPhone: play/pause, skips, chapters, speed,
/// sleep timer and bookmarks. Refreshed while it's on screen.
struct RemoteView: View {
    @Environment(WatchLink.self) private var link
    @State private var state: PhoneState?
    @State private var loaded = false
    @State private var busy = false
    @State private var note: String?

    var body: some View {
        Group {
            if let s = state {
                PlayerFace(
                    coverId: s.itemId, title: s.title, chapter: note ?? s.chapter,
                    position: s.positionSec, total: s.durationSec, isPlaying: s.isPlaying,
                    speed: s.speed,
                    sleepLabel: s.sleepEndOfChapter ? "Chapter end" : s.sleepRemainingSec.map { Format.clock($0) },
                    busy: busy, skipBack: s.skipBackSec, skipForward: s.skipForwardSec,
                    back: { send(.back) }, toggle: { send(.toggle) }, forward: { send(.forward) }
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
        .task {
            while !Task.isCancelled {
                if !busy {
                    let s = await link.phoneState()
                    if !busy { state = s }
                    loaded = true
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func send(_ cmd: RemoteCommand, _ value: Double? = nil) {
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
