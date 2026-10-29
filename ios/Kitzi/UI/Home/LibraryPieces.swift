import SwiftUI

// MARK: - pieces

/// Where a "See All" goes.
struct ShelfRoute: Hashable { var title: String; var ids: [String] }

/// "Title ›" — the iOS section header that opens the full list.
struct ShelfHeader: View {
    var title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.title2.bold())
                Image(systemName: "chevron.right").font(.headline.bold()).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }
}

/// An Apple Books shelf: covers in a row, title and time left under each.
struct CoverShelf: View {
    var title: String
    var books: [Book]
    var showProgress: Bool
    @Binding var path: NavigationPath
    var big = false
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if !books.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ShelfHeader(title: title) { path.append(ShelfRoute(title: title, ids: books.map(\.id))) }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(books) { b in
                            Button { path.append(b) } label: {
                                CoverTile(book: b, size: big ? 170 : 130, progress: showProgress ? library.progress[b.id] : nil)
                            }
                            .buttonStyle(.plain)
                            .bookContextMenu(b)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 20)
                }
                .scrollTargetBehavior(.viewAligned)
            }
            .padding(.vertical, big ? 8 : 0)
        }
    }
}

/// A cover with its title (and progress) beneath, as in Apple Books.
struct CoverTile: View {
    let book: Book
    var size: CGFloat?
    var progress: Progress?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(book: book)
                .aspectRatio(1, contentMode: .fit)
                .frame(width: size)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            if let p = progress, p.progress > 0 {
                ProgressView(value: p.progress).tint(.accentColor).frame(width: size)
                let left = max((p.durationSec > 0 ? p.durationSec : (book.durationSec ?? 0)) - p.currentTimeSec, 0)
                Text("\(Format.hm(left)) left").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(book.title).font(.footnote.weight(.medium)).lineLimit(1).frame(width: size, alignment: .leading)
                Text(book.author ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: size, alignment: .leading)
            }
        }
    }
}

/// Apple Books' Reading Goals, for listening: today vs a daily goal, and the streak.
struct GoalCard: View {
    @Environment(LibraryStore.self) private var library
    var body: some View {
        let goal = 30.0 * 60
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.accentColor.opacity(0.2), lineWidth: 8)
                Circle().trim(from: 0, to: min(library.todaySec / goal, 1))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(Format.hm(library.todaySec)).font(.caption.bold().monospacedDigit())
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Today's Listening").font(.headline)
                Text("\(Format.hm(library.todaySec)) of 30 min").font(.subheadline).foregroundStyle(.secondary)
                Label("\(library.streakDays)-day streak · best \(library.bestStreak)", systemImage: "flame.fill")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// A native list row: small cover, title, author, time.
struct ListBookRow: View {
    let book: Book
    @Environment(LibraryStore.self) private var library
    var body: some View {
        HStack(spacing: 12) {
            CoverImage(book: book).frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(.body).lineLimit(1)
                Text(book.author ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let p = library.progress[book.id], p.progress > 0, !p.isFinished {
                    ProgressView(value: p.progress).tint(.accentColor).frame(maxWidth: 140)
                }
            }
            Spacer()
            if library.progress[book.id]?.isFinished == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else if let d = book.durationSec {
                Text(Format.hm(d)).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

extension View {
    /// Long-press actions, as everywhere in iOS: play, queue, download.
    func bookContextMenu(_ b: Book) -> some View {
        contextMenu {
            Button { Task { await Player.shared.play(b) } } label: { Label("Play", systemImage: "play.fill") }
            Button { PlayQueue.shared.addNext(b.id) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { PlayQueue.shared.add(b.id) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
            if !Downloads.shared.isDownloaded(b.id) {
                Button { Task { await Downloads.shared.start(b.id) } } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        } preview: {
            CoverImage(book: b, width: 600).frame(width: 260, height: 260)
        }
    }
}
