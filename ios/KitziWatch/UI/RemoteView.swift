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
                TabView {
                    controls(s)
                    more(s)
                }
                .tabViewStyle(.verticalPage)
            } else if !loaded {
                ProgressView()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.slash").font(.title2).foregroundStyle(.secondary)
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

    private func controls(_ s: PhoneState) -> some View {
        VStack(spacing: 6) {
            Text(s.title).font(.headline).lineLimit(1)
            if let c = s.chapter { Text(c).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            ProgressView(value: s.durationSec > 0 ? min(s.positionSec / s.durationSec, 1) : 0)
            HStack {
                Text(Format.clock(s.positionSec))
                Spacer()
                Text("-" + Format.clock(max(s.durationSec - s.positionSec, 0)))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button { send(.back) } label: { Image(systemName: "gobackward.\(s.skipBackSec)").font(.title3) }
                    .accessibilityLabel("Back \(s.skipBackSec) seconds")
                Button { send(.toggle) } label: {
                    Image(systemName: s.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(width: 52, height: 52)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .handGestureShortcut(.primaryAction)
                .accessibilityLabel(s.isPlaying ? "Pause" : "Play")
                Button { send(.forward) } label: { Image(systemName: "goforward.\(s.skipForwardSec)").font(.title3) }
                    .accessibilityLabel("Forward \(s.skipForwardSec) seconds")
            }
            .buttonStyle(.plain)
            .disabled(busy)
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 4)
    }

    private func more(_ s: PhoneState) -> some View {
        List {
            if s.chapter != nil {
                HStack {
                    Button { send(.previousChapter) } label: { Image(systemName: "backward.end.fill") }
                        .accessibilityLabel("Previous chapter")
                    Spacer()
                    Text("Chapter").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button { send(.nextChapter) } label: { Image(systemName: "forward.end.fill") }
                        .accessibilityLabel("Next chapter")
                }
                .buttonStyle(.plain)
            }
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
    }
}
