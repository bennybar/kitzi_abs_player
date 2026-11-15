import SwiftUI

/// Now playing, Continue Listening, the books on the watch, the iPhone remote,
/// Sync now and Settings.
struct HomeView: View {
    @Environment(WatchModel.self) private var model
    @Environment(WatchPlayer.self) private var player
    @Environment(WatchDownloads.self) private var downloads
    @State private var syncResult: Bool?
    @State private var syncing = false

    var body: some View {
        List {
            if let np = player.nowPlaying {
                NavigationLink(value: WatchRoute.player) {
                    HStack(spacing: 10) {
                        CoverView(id: np.book.id, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Label(player.isPlaying ? "Now Playing" : "Paused", systemImage: player.isPlaying ? "waveform" : "pause.fill")
                                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                                .font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                            Text(np.book.title).font(.headline).lineLimit(2)
                            Bar(value: np.totalSec > 0 ? player.position / np.totalSec : 0).padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Continue Listening") {
                if model.shelf.isEmpty {
                    Text(model.online == false ? "Can't reach the server." : (model.refreshing ? "Loading…" : "Nothing in progress."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.shelf) { s in
                    NavigationLink(value: WatchRoute.book(s.id)) {
                        BookRow(id: s.id, title: s.book.title,
                                line: line(s.id, Format.left(s.currentTimeSec, of: s.durationSec)),
                                progress: s.durationSec > 0 ? min(s.currentTimeSec / s.durationSec, 1) : nil)
                    }
                }
            }

            Section {
                NavigationLink(value: WatchRoute.downloads) {
                    HStack {
                        Label("Downloads", systemImage: "arrow.down.circle.fill")
                        Spacer()
                        let n = downloads.downloadedIds.count, active = downloads.activeIds.count
                        if active > 0 {
                            Image(systemName: "arrow.down").foregroundStyle(Color.accentColor)
                                .symbolEffect(.pulse)
                        }
                        if n > 0 { Text("\(n)").foregroundStyle(.secondary) }
                    }
                }
                Button {
                    Task {
                        syncing = true
                        syncResult = await model.syncNow()
                        syncing = false
                    }
                } label: {
                    HStack {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if syncing { ProgressView().frame(width: 20) }
                        else if let r = syncResult { Image(systemName: r ? "checkmark" : "exclamationmark.triangle").foregroundStyle(r ? .green : .orange) }
                    }
                }
                .disabled(syncing)
            }
        }
        .navigationTitle("Kitzi")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: WatchRoute.settings) { Image(systemName: "gearshape.fill") }
                    .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: WatchRoute.remote) { Image(systemName: "iphone") }
                    .accessibilityLabel("iPhone Remote")
            }
        }
    }

    /// The download state when there is one, else the time left.
    private func line(_ id: String, _ fallback: String?) -> String? {
        switch downloads.state(id) {
        case .done: ["On watch", fallback].compactMap { $0 }.joined(separator: " · ")
        case .running(let f): "Downloading \(Int(f * 100))%"
        case .queued: "Waiting to download"
        case .failed: "Download failed"
        case .none: fallback
        }
    }
}

struct BookRow: View {
    let id: String
    let title: String
    let line: String?
    let progress: Double?

    var body: some View {
        HStack(spacing: 10) {
            CoverView(id: id, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
                if let line { Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                if let progress { Bar(value: progress).padding(.top, 2) }
            }
        }
        .padding(.vertical, 2)
    }
}
