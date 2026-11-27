import SwiftUI

/// The mini-player in the tab bar's bottom accessory (already Liquid Glass):
/// cover, title, chapter or time left, and play/pause. Tapping it opens the player.
/// With nothing loaded it shows the last book; play resumes it.
struct MiniPlayer: View {
    var zoom: Namespace.ID
    var onExpand: () -> Void
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library

    private var book: Book? {
        if let np = player.nowPlaying { return np.book }
        return Store.string(Store.lastItemKey).flatMap { library.byId[$0] }
    }

    /// From the coarse values (chapter, minutes left): it redraws when they change,
    /// not at every position tick.
    private var subtitle: String {
        guard let np = player.nowPlaying else { return book?.author ?? "Tap play to resume" }
        let left = Format.hm(Double((player.minutesLeft ?? 0) * 60))
        if let i = player.chapterIndex, np.chapters.indices.contains(i) { return "\(np.chapters[i].title) · \(left) left" }
        return "\(left) left"
    }


    var body: some View {
        if let book {
            HStack(spacing: 10) {
                Button(action: onExpand) {
                    HStack(spacing: 10) {
                        CoverImage(book: book)
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .matchedTransitionSource(id: "np", in: zoom)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { Haptics.tap(); player.togglePlay() } label: {
                    ZStack {
                        MiniProgressRing()
                        Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2.5)
                        if player.preparing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 34, height: 34)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }
            .padding(.horizontal, 12)
        }
    }
}

/// The mini-player's progress ring: its own view, so only it follows the position.
private struct MiniProgressRing: View {
    @Environment(Player.self) private var player

    var body: some View {
        let total = player.nowPlaying?.totalSec ?? 0
        Circle()
            .trim(from: 0, to: total > 0 ? min(max(player.position / total, 0), 1) : 0)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}
