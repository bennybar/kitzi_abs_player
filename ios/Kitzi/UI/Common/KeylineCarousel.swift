import SwiftUI

/// A Material 3 Expressive carousel, ported: items sit on "keylines" (large →
/// medium → small) and change width as they move between them, the cover masked
/// to the item so a narrow item shows the middle of the art. Hero mode starts
/// with one big item and smaller ones peeking; multi-browse keeps several large.
struct KeylineCarousel<Item, Content: View>: View {
    let items: [Item]
    var height: CGFloat
    /// Item widths from the leading edge (e.g. large, large, medium, small).
    var keylines: (CGFloat) -> [CGFloat]
    var spacing: CGFloat = 8
    var onTap: (Item) -> Void = { _ in }
    @ViewBuilder var content: (Item, _ fullness: CGFloat) -> Content

    /// Scroll position in points, from a real (invisible) horizontal ScrollView:
    /// it gives native swiping, momentum and snapping — a custom drag gesture lost
    /// the touch to the covers' tap handling on a real device.
    @State private var scrollX: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - 32
            let k = keylines(width)
            let stride = (k.first ?? 100) + spacing
            let maxOffset = CGFloat(max(items.count - (k.count - 1), 0))
            let current = min(max(scrollX / stride, -0.35), maxOffset + 0.35)
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    let f = frame(CGFloat(i) - current, k)
                    if f.width > 1 && f.x < width + 40 && f.x + f.width > -40 {
                        content(item, min(max((f.width - (k.last ?? 0)) / max((k.first ?? 1) - (k.last ?? 0), 1), 0), 1))
                            .frame(width: f.width, height: height)
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                            .offset(x: f.x)
                    }
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .allowsHitTesting(false)
            .padding(.horizontal, 16)
            .overlay {
                // The touch surface: one invisible page per keyline step, snapping.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(0...Int(maxOffset), id: \.self) { _ in
                            Color.clear.frame(width: stride, height: height)
                        }
                        Color.clear.frame(width: max(geo.size.width - stride, 0), height: height)
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in scrollX = x }
                .contentShape(Rectangle())
                .onTapGesture { loc in
                    // Which cover is under the finger (positions are drawn, not laid out).
                    let x = loc.x - 16
                    for (i, item) in items.enumerated() {
                        let f = frame(CGFloat(i) - current, k)
                        if f.width > 1, x >= f.x, x <= f.x + f.width { onTap(item); return }
                    }
                }
            }
        }
        .frame(height: height)
    }

    /// Position (in keyline units, 0 = first keyline) → x and width.
    private func frame(_ p: CGFloat, _ k: [CGFloat]) -> (x: CGFloat, width: CGFloat) {
        guard !k.isEmpty else { return (0, 0) }
        var xs: [CGFloat] = []
        var x: CGFloat = 0
        for w in k { xs.append(x); x += w + spacing }
        if p < 0 {
            // Leaving on the left: shrink toward the smallest size, sliding out. Its
            // right edge stays one gap left of the item entering keyline 0.
            let t = min(-p, 1)
            return (-t * (k.last! + spacing), lerp(k[0], k.last!, t))
        }
        let i = Int(p.rounded(.down))
        if i >= k.count - 1 {
            let extra = p - CGFloat(k.count - 1)
            return (xs[k.count - 1] + extra * (k.last! + spacing), k.last!)
        }
        let t = p - CGFloat(i)
        return (lerp(xs[i], xs[i + 1], t), lerp(k[i], k[i + 1], t))
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}

/// A cover card for a carousel: title and caption on the art, fading as the item
/// narrows (text under a shrinking item would be clipped mid-word).
struct CarouselCover: View {
    let book: Book
    var caption: String?
    var progress: Double?
    var fullness: CGFloat
    var hero: Bool = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CoverImage(book: book)
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
                .opacity(Double(fullness))
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(hero ? .headline : .subheadline.weight(.semibold))
                    .lineLimit(1)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
            .opacity(Double(max(fullness * 1.6 - 0.6, 0)))
            if let progress, progress > 0 {
                GeometryReader { g in
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.35))
                            Rectangle().fill(Color.accentColor).frame(width: g.size.width * progress)
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
    }
}
