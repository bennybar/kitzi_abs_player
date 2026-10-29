import SwiftUI

/// The mini-player in the tab bar's bottom accessory (already Liquid Glass):
/// cover, title, chapter or time left, and play/pause. Tapping it opens the player.
/// With nothing loaded it shows the last book; play resumes it.
struct MiniPlayer: View {
    var onExpand: () -> Void
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library

    private var book: Book? {
        if let np = player.nowPlaying { return np.book }
        return Store.string(Store.lastItemKey).flatMap { library.byId[$0] }
    }

    private var subtitle: String {
        guard let np = player.nowPlaying else { return book?.author ?? "Tap play to resume" }
        let left = max(np.totalSec - player.position, 0) / max(player.speed, 0.1)
        if let c = player.currentChapter() { return "\(c.title) · \(Format.hm(left)) left" }
        return "\(Format.hm(left)) left"
    }

    private var fraction: Double {
        guard let np = player.nowPlaying, np.totalSec > 0 else { return 0 }
        return min(max(player.position / np.totalSec, 0), 1)
    }

    var body: some View {
        if let book {
            HStack(spacing: 10) {
                Button(action: onExpand) {
                    HStack(spacing: 10) {
                        CoverImage(book: book)
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { player.togglePlay() } label: {
                    ZStack {
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
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
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }
            .padding(.horizontal, 12)
        }
    }
}
