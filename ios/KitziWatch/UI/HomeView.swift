import SwiftUI

/// Now playing, Continue Listening, the books on the watch, the iPhone remote,
/// Sync now and Settings.
struct HomeView: View {
    @Environment(WatchModel.self) private var model
    @Environment(WatchPlayer.self) private var player
    @Environment(WatchDownloads.self) private var downloads
    @State private var syncResult: Bool?
    @State private var syncing = false

    /// Books on the watch that aren't on the shelf (finished elsewhere, or not started).
    private var onWatchOnly: [WatchBookManifest] {
        downloads.downloadedIds.filter { id in !model.shelf.contains { $0.id == id } }
            .compactMap { downloads.downloaded($0) }
            .sorted { $0.book.title < $1.book.title }
    }

    var body: some View {
        List {
            if let np = player.nowPlaying {
                NavigationLink(value: WatchRoute.player) {
                    HStack(spacing: 10) {
                        CoverView(id: np.book.id, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(np.book.title).font(.headline).lineLimit(1)
                            Label(player.isPlaying ? "Playing" : "Paused", systemImage: player.isPlaying ? "waveform" : "pause.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .listItemTint(.accentColor)
            }

            Section("Continue Listening") {
                if model.shelf.isEmpty {
                    Text(model.online == false ? "Can't reach the server." : (model.refreshing ? "Loading…" : "Nothing in progress."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.shelf) { s in
                    NavigationLink(value: WatchRoute.book(s.id)) {
                        BookRow(id: s.id, title: s.book.title,
                                line: line(s.id, Format.left(s.currentTimeSec, of: s.durationSec)))
                    }
                }
            }

            if !onWatchOnly.isEmpty {
                Section("On Watch") {
                    ForEach(onWatchOnly, id: \.book.id) { m in
                        NavigationLink(value: WatchRoute.book(m.book.id)) {
                            BookRow(id: m.book.id, title: m.book.title, line: m.book.author)
                        }
                    }
                }
            }

            Section {
                NavigationLink(value: WatchRoute.remote) { Label("iPhone Remote", systemImage: "iphone") }
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
                NavigationLink(value: WatchRoute.settings) { Label("Settings", systemImage: "gear") }
            }
        }
        .navigationTitle("Kitzi")
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

    var body: some View {
        HStack(spacing: 10) {
            CoverView(id: id, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).lineLimit(2)
                if let line { Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}
