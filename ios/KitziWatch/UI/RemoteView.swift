import SwiftUI

/// Controls the Kitzi app on the iPhone: play/pause, skips, chapters, speed,
/// sleep timer and bookmarks. Refreshed while it's on screen.
struct RemoteView: View {
    @Environment(WatchLink.self) private var link
    @Environment(\.scenePhase) private var phase
    @State private var state: PhoneState?
    @State private var loaded = false
    /// A command on its way (a second tap meanwhile is dropped, nothing dims).
    @State private var sending = false
    @State private var note: String?
    /// When the iPhone's state last arrived (pushed or asked for).
    @State private var stateAt = Date.distantPast

    var body: some View {
        Group {
            if let s = state {
                PlayerFace(
                    coverId: s.itemId, title: s.title, isPlaying: s.isPlaying,
                    busy: false, skipBack: s.skipBackSec, skipForward: s.skipForwardSec,
                    back: { send(.back) }, toggle: { send(.toggle) }, forward: { send(.forward) },
                    volume: .companion
                ) { _, _ in
                    RemoteFaceInfo(state: s, note: note, receivedAt: stateAt)
                }
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
        // playing); asking is only the fallback, every 30 s, only while the screen
        // is on, and not when a push just came.
        .onChange(of: link.pushedState) { _, s in if !sending, let s { show(s) } }
        .task(id: phase == .active) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                if !sending, Date().timeIntervalSince(stateAt) > 25 {
                    let s = await link.phoneState()
                    if !sending { if let s { show(s) } else { withAnimation(.snappy) { state = nil } } }
                    loaded = true
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func show(_ s: PhoneState) {
        withAnimation(.snappy) { state = s }
        stateAt = Date()
        loaded = true
    }

    private func send(_ cmd: RemoteCommand, _ value: Double? = nil) {
        guard !sending else { return }
        switch cmd {
        case .toggle: Haptic.play(state?.isPlaying == true ? .stop : .start)
        default: Haptic.play(.click)
        }
        // Play/Pause shows at once; the iPhone's answer confirms it.
        if cmd == .toggle, var s = state {
            s.positionSec = RemoteFaceInfo.position(s, at: Date())
            s.sentAt = Date().timeIntervalSince1970
            s.isPlaying.toggle()
            withAnimation(.snappy) { state = s }
            stateAt = Date()
        }
        sending = true
        Task {
            let s = await link.phoneState(command: cmd, value: value)
            if let s { note = nil; show(s) } else { note = "Your iPhone didn't answer." }
            if cmd == .bookmark, s != nil { note = "Bookmark added on iPhone" }
            sending = false
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

/// The remote's chapter line, bar and times, moved on between the iPhone's
/// updates once a second (no radio): only while it plays and the screen is on.
private struct RemoteFaceInfo: View {
    let state: PhoneState
    let note: String?
    let receivedAt: Date
    @Environment(\.isLuminanceReduced) private var dimmed

    /// Where the iPhone is at `date`: its last state, moved on by the time since, while playing.
    static func position(_ s: PhoneState, at date: Date) -> Double {
        guard s.isPlaying, let at = s.sentAt else { return s.positionSec }
        return min(s.positionSec + max(date.timeIntervalSince1970 - at, 0) * s.speed, s.durationSec)
    }

    var body: some View {
        TimelineView(.periodic(from: receivedAt, by: state.isPlaying && !dimmed ? 1 : 60)) { t in
            FaceInfo(chapter: note ?? state.chapter, note: nil,
                     position: Self.position(state, at: t.date), total: state.durationSec, speed: state.speed,
                     sleepLabel: state.sleepEndOfChapter ? "Chapter end" : state.sleepRemainingSec.map { Format.clock($0) },
                     chapterStart: state.chapterStartSec, chapterEnd: state.chapterEndSec)
        }
    }
}
