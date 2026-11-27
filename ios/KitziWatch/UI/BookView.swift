import SwiftUI

/// A book: cover, where you are, Play/Resume, and its download on the watch.
struct BookView: View {
    let id: String
    /// The book as the library listed it, for one that's neither on the shelf nor the watch.
    var given: Book? = nil
    @Environment(WatchModel.self) private var model
    @Environment(WatchPlayer.self) private var player
    @Environment(WatchDownloads.self) private var downloads
    @State private var error: String?
    @State private var confirmRemove = false

    private var shelf: ShelfBook? { model.shelf.first { $0.id == id } }
    private var book: Book? { shelf?.book ?? downloads.downloaded(id)?.book ?? given }

    var body: some View {
        ScrollView {
            if let book {
                VStack(spacing: 8) {
                    CoverView(id: id, size: 96).shadow(radius: 8)
                    Text(book.title).font(.headline).multilineTextAlignment(.center)
                    if let a = book.author { Text(a).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    if let s = shelf, s.durationSec > 0 {
                        Bar(value: s.currentTimeSec / s.durationSec).padding(.horizontal, 12)
                        Text("\(Format.clock(s.currentTimeSec)) of \(Format.clock(s.durationSec))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Button {
                        Task {
                            if let why = await player.play(book, fallbackSec: shelf?.currentTimeSec ?? 0, fallbackAt: shelf?.lastUpdate ?? 0) {
                                error = why
                            } else {
                                WatchNav.shared.path.append(.player)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if player.loading { ProgressView().frame(width: 18, height: 18) }
                            Label(player.nowPlaying?.book.id == id || (shelf?.currentTimeSec ?? 0) > 0 ? "Resume" : "Play",
                                  systemImage: "play.fill")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(player.loading)
                    .padding(.top, 4)
                    downloadButton
                        .buttonStyle(.glass)
                        .animation(.snappy, value: downloads.state(id))
                }
                .padding(.horizontal, 4)
            } else {
                Text("This book isn't on your shelf any more.").foregroundStyle(.secondary)
            }
        }
        .coverBackground(id)
        .alert("Kitzi", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .confirmationDialog("Remove the download from your watch?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { downloads.delete(id) }
        }
    }

    @ViewBuilder private var downloadButton: some View {
        switch downloads.state(id) {
        case .done:
            Button(role: .destructive) { confirmRemove = true } label: { Label("Remove Download", systemImage: "trash").frame(maxWidth: .infinity) }
        case .running(let f):
            Button { downloads.cancel(id) } label: {
                VStack(spacing: 4) {
                    ProgressView(value: f).tint(.accentColor)
                    Label("Downloading \(Int(f * 100))%", systemImage: "arrow.down.circle")
                    Text("Tap to cancel").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .queued:
            Button { downloads.cancel(id) } label: {
                VStack(spacing: 4) {
                    Label("Waiting…", systemImage: "hourglass")
                    Text("Tap to cancel").font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .failed, .none:
            Button {
                Task { error = await downloads.start(id) }
            } label: {
                Label(downloads.state(id) == .failed ? "Retry Download" : "Download", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
