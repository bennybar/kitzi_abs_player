import SwiftUI

/// The shape-shifting play button's outline: a rounded square (paused) morphing
/// into a scalloped "cookie" (playing). Animatable, so it springs between them.
nonisolated struct MorphShape: Shape {
    /// 0 = rounded square, 1 = cookie.
    var t: Double
    var animatableData: Double { get { t } set { t = newValue } }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        let n = 240
        for i in 0...n {
            let a = Double(i) / Double(n) * 2 * .pi
            // Squircle (superellipse, n=4) radius at this angle.
            let sq = 1 / pow(pow(abs(cos(a)), 4) + pow(abs(sin(a)), 4), 0.25)
            // 9 scallops.
            let cookie = 0.9 + 0.1 * cos(9 * a - .pi / 2)
            let rr = r * ((1 - t) * min(sq, 1.0) * 0.97 + t * cookie)
            let pt = CGPoint(x: c.x + rr * cos(a), y: c.y + rr * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Play/pause: morphing Liquid Glass (setting on, the default) or a plain circle.
struct PlayPauseButton: View {
    var size: CGFloat
    @Environment(AppSettings.self) private var settings
    @Environment(Player.self) private var player

    var body: some View {
        let morph = settings.expressivePlayButton
        Button { player.togglePlay() } label: {
            ZStack {
                if player.preparing {
                    ProgressView().controlSize(size > 60 ? .large : .regular).tint(.white)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .background {
                if morph {
                    MorphShape(t: player.isPlaying ? 1 : 0).fill(Color.accentColor.gradient)
                } else {
                    Circle().fill(Color.accentColor.gradient)
                }
            }
            .glassEffect(.regular.interactive(), in: morph ? AnyShape(MorphShape(t: player.isPlaying ? 1 : 0)) : AnyShape(Circle()))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.5, dampingFraction: 0.6), value: player.isPlaying)
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }
}

struct ToastView: View {
    @Environment(Toast.self) private var toast
    var body: some View {
        if let t = toast.current {
            HStack(spacing: 12) {
                Text(t.text).font(.subheadline).lineLimit(2)
                if let action = t.action {
                    Spacer(minLength: 4)
                    Button(action) { t.run?(); withAnimation { toast.current = nil } }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(t.id)
        }
    }
}

/// A library row: cover with progress, title, series, author, narrator, duration, state.
struct BookRow: View {
    let book: Book
    @Environment(LibraryStore.self) private var library
    @Environment(Downloads.self) private var downloads
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let p = library.progress[book.id]
        HStack(spacing: 14) {
            ZStack(alignment: .bottom) {
                CoverImage(book: book)
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if let p, p.progress > 0, !p.isFinished {
                    ProgressView(value: p.progress).tint(.accentColor).padding(.horizontal, 6).padding(.bottom, 4)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.headline).lineLimit(2)
                if let s = book.seriesLabel, !(settings.hideSeriesWhenSameAsAuthor && book.series == book.author) {
                    Text(s).font(.subheadline).foregroundStyle(Color.accentColor).lineLimit(1)
                }
                if let a = book.author { Text(a).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                HStack(spacing: 8) {
                    if let d = book.durationSec { Label(Format.hm(d), systemImage: "clock").labelStyle(.titleAndIcon) }
                    if downloads.isDownloaded(book.id) { Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor) }
                    if p?.isFinished == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

struct BookGridCell: View {
    let book: Book
    @Environment(LibraryStore.self) private var library
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(book: book)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let p = library.progress[book.id], p.progress > 0, !p.isFinished {
                        ProgressView(value: p.progress).tint(.accentColor).padding(8)
                    }
                }
            Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(book.author ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// A section title with an icon, like the Android home screen.
struct SectionHeader: View {
    var icon: String
    var title: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.subheadline.weight(.semibold))
                .frame(width: 34, height: 34)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).font(.title2.weight(.bold))
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}

/// Audible star rating (tap opens Audible when enabled).
struct StarsView: View {
    let book: Book
    @State private var rating: AudibleRating.Result?
    @Environment(AppSettings.self) private var settings

    var body: some View {
        // A ZStack with a placeholder, not an empty Group: SwiftUI never runs the
        // .task of a view with nothing in it, so the lookup never started.
        ZStack(alignment: .leading) {
            Color.clear.frame(width: 1, height: 1)
            if let r = rating {
                Button {
                    if settings.audibleLink, let u = URL(string: "https://www.audible.com/pd/\(r.asin)") { UIApplication.shared.open(u) }
                } label: {
                    HStack(spacing: 4) {
                        ForEach(0..<5) { i in
                            let v = r.stars - Double(i)
                            Image(systemName: v >= 0.75 ? "star.fill" : (v >= 0.25 ? "star.leadinghalf.filled" : "star"))
                        }
                        .foregroundStyle(.orange)
                        Text(String(format: "%.1f", r.stars)).fontWeight(.semibold)
                        Text("(\(r.count.formatted(.number.notation(.compactName))))").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: book.id) {
            rating = nil
            rating = await AudibleRating.shared.rating(for: book)
        }
    }
}
