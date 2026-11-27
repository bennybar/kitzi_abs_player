import SwiftUI

/// The books on the watch: tap to play, swipe to remove, and the ones still
/// downloading (swipe to cancel). Storage used and left at the top.
struct DownloadsView: View {
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchPlayer.self) private var player
    @Environment(WatchModel.self) private var model
    @State private var removing: WatchBookManifest?
    @State private var error: String?
    @State private var loadingId: String?
    @State private var freeBytes: Int64?
    @Environment(\.isLuminanceReduced) private var dimmed

    private var onWatch: [WatchBookManifest] {
        downloads.downloadedIds.compactMap { downloads.downloaded($0) }.sorted { $0.book.title < $1.book.title }
    }

    private var active: [WatchBookManifest] {
        downloads.activeIds.compactMap { downloads.planned($0) }.sorted { $0.book.title < $1.book.title }
    }

    var body: some View {
        // Once per redraw.
        let onWatch = self.onWatch, active = self.active
        List {
            Section {
                storage
            }
            if !active.isEmpty {
                Section("Downloading") {
                    ForEach(active, id: \.book.id) { m in
                        // A failed one: tap to try again.
                        Button {
                            guard downloads.state(m.book.id) == .failed else { return }
                            Task { if let why = await downloads.start(m.book.id) { error = why } }
                        } label: { activeRow(m) }
                            .swipeActions {
                                Button(role: .destructive) { downloads.cancel(m.book.id) } label: { Label("Cancel", systemImage: "xmark") }
                            }
                    }
                }
            }
            Section(onWatch.isEmpty ? "" : "On Watch") {
                if onWatch.isEmpty && active.isEmpty {
                    Text("No books on your watch yet. Open a book and tap Download, or send one from Kitzi on your iPhone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(onWatch, id: \.book.id) { m in
                    Button { Task { await play(m) } } label: { bookRow(m) }
                        .swipeActions {
                            Button(role: .destructive) { removing = m } label: { Label("Remove", systemImage: "trash") }
                        }
                        .disabled(player.loading)
                }
            }
            if !onWatch.isEmpty {
                Text("Tap a book to play it. Swipe left to remove it from the watch.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Downloads")
        .animation(.snappy, value: downloads.downloadedIds)
        .animation(.snappy, value: downloads.activeIds)
        .task { freeBytes = WatchDownloads.freeBytes }
        .confirmationDialog("Remove from your watch?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { m in
            Button("Remove", role: .destructive) { downloads.delete(m.book.id) }
        } message: { m in
            Text("\(m.book.title) is deleted from the watch. You can still stream it, and your place is kept.")
        }
        .alert("Kitzi", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "internaldrive").foregroundStyle(Color.accentColor)
                Text(Format.size(downloads.totalBytes)).font(.headline)
                Text("used").foregroundStyle(.secondary)
            }
            if let free = freeBytes {
                Text("\(Format.size(free)) free on the watch").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color.clear)
    }

    private func bookRow(_ m: WatchBookManifest) -> some View {
        let id = m.book.id
        let playing = player.nowPlaying?.book.id == id
        return HStack(spacing: 10) {
            CoverView(id: id, size: 40)
                .overlay { if loadingId == id { ProgressView().background(.black.opacity(0.5), in: Circle()) } }
            VStack(alignment: .leading, spacing: 3) {
                Text(m.book.title).font(.body.weight(.medium)).lineLimit(2)
                // The playing book's line follows the player in its own view (the
                // whole list was redrawn twice a second).
                if playing {
                    PlayingDownloadLine(manifest: m, size: downloads.bytes(id), dimmed: dimmed)
                } else {
                    DownloadLine(manifest: m, pos: model.shelf.first { $0.id == id }?.currentTimeSec ?? Store.position(id)?.sec ?? 0,
                                 size: downloads.bytes(id))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func activeRow(_ m: WatchBookManifest) -> some View {
        let state = downloads.state(m.book.id)
        let text: String = switch state {
        case .running(let f): "\(Int(f * 100))%"
        case .queued: "Waiting…"
        case .failed: "Failed. Tap to try again."
        default: ""
        }
        var fraction: Double? { if case .running(let f) = state { f } else { nil } }
        return HStack(spacing: 10) {
            CoverView(id: m.book.id, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(m.book.title).font(.body.weight(.medium)).lineLimit(2)
                Text(text).font(.caption2).foregroundStyle(state == .failed ? .orange : .secondary)
                if let fraction { Bar(value: fraction).padding(.top, 2) }
            }
        }
        .padding(.vertical, 2)
    }

    private func play(_ m: WatchBookManifest) async {
        if player.nowPlaying?.book.id == m.book.id {
            WatchNav.shared.path.append(.player)
            return
        }
        let shelf = model.shelf.first { $0.id == m.book.id }
        loadingId = m.book.id
        defer { loadingId = nil }
        if let why = await player.play(m.book, fallbackSec: shelf?.currentTimeSec ?? 0, fallbackAt: shelf?.lastUpdate ?? 0) {
            error = why
        } else {
            WatchNav.shared.path.append(.player)
        }
    }
}

/// A downloaded book's time left, size and progress.
private struct DownloadLine: View {
    let manifest: WatchBookManifest
    let pos: Double
    let size: Int64
    var playing: Bool? = nil
    var dimmed = false

    var body: some View {
        let total = manifest.book.durationSec ?? manifest.tracks.reduce(0) { $0 + $1.durationSec }
        let left = Format.left(pos, of: total)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let playing {
                    Image(systemName: playing ? "waveform" : "pause.fill").foregroundStyle(Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.variableColor.iterative, isActive: playing && !dimmed)
                }
                Text([pos > 0 ? left : nil, Format.size(size)].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.caption2)
            if total > 0, pos > 0 { Bar(value: pos / total).padding(.top, 2) }
        }
    }
}

/// The same for the book that's loaded: from the player.
private struct PlayingDownloadLine: View {
    let manifest: WatchBookManifest
    let size: Int64
    let dimmed: Bool
    @Environment(WatchPlayer.self) private var player

    var body: some View {
        DownloadLine(manifest: manifest, pos: player.position, size: size, playing: player.isPlaying, dimmed: dimmed)
    }
}
