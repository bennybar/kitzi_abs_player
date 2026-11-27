import ImageIO
import SwiftUI
import WatchKit

/// A tap on the wrist for something the user did (or that finished).
enum Haptic {
    static func play(_ t: WKHapticType) { WKInterfaceDevice.current().play(t) }
}

/// Where the watch app can go from Home.
enum WatchRoute: Hashable {
    case book(String)
    case player
    case remote
    case settings
    case downloads
    case library
    /// A book from the library (not necessarily on the shelf or the watch).
    case libraryBook(Book)
}

/// The navigation stack, shared so a screen can open the player.
@Observable
final class WatchNav {
    static let shared = WatchNav()
    var path: [WatchRoute] = []
}

/// The namespace the covers zoom in from (a list row's cover into its page).
extension EnvironmentValues {
    @Entry var coverZoom: Namespace.ID?
}

extension View {
    /// Zooms in from the cover marked `id` (see zoomSource) when there is one.
    @ViewBuilder func zoomIn(_ id: String, _ ns: Namespace.ID?) -> some View {
        if let ns { navigationTransition(.zoom(sourceID: id, in: ns)) } else { self }
    }

    /// A cover pages can zoom in from.
    @ViewBuilder func zoomSource(_ id: String, _ ns: Namespace.ID?) -> some View {
        if let ns { matchedTransitionSource(id: id, in: ns) } else { self }
    }
}

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @State private var nav = WatchNav.shared
    @Namespace private var zoom

    var body: some View {
        content
    }

    @ViewBuilder private var content: some View {
        if model.signedIn {
            NavigationStack(path: $nav.path) {
                HomeView()
                    .navigationDestination(for: WatchRoute.self) { r in
                        switch r {
                        case .book(let id): BookView(id: id).zoomIn("book-\(id)", zoom)
                        case .libraryBook(let b): BookView(id: b.id, given: b)
                        case .library: LibraryView()
                        case .player: PlayerView().zoomIn("player", zoom)
                        case .remote: RemoteView()
                        case .settings: SettingsView()
                        case .downloads: DownloadsView()
                        }
                    }
            }
            .environment(\.coverZoom, zoom)
        } else {
            NavigationStack { LoginView() }
        }
    }
}

/// A book's cover: the downloaded copy, else from the server (cached on the watch).
struct CoverView: View {
    let id: String
    var size: CGFloat = 40
    @State private var image: UIImage?

    var body: some View {
        // In memory: shown in the first frame (the placeholder flashed until the
        // task ran). Fetched: faded in.
        let image = image ?? Covers.cached(id)
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "book.closed.fill").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.gray.opacity(0.25))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15, style: .continuous))
        .task(id: id) {
            guard Covers.cached(id) == nil else { return }
            let img = await Covers.load(id)
            withAnimation(.easeOut(duration: 0.2)) { self.image = img }
        }
    }
}

/// A screen's background: its book's cover, blurred and dimmed.
private struct CoverBackground: ViewModifier {
    let id: String
    @State private var image: UIImage?

    func body(content: Content) -> some View {
        // A tiny copy of the cover stretched smooth: looks blurred, costs nothing
        // to draw (a live blur ran under every screen, under the glass too).
        let image = image ?? Covers.cachedBackdrop(id)
        content
            .containerBackground(for: .navigation) {
                ZStack {
                    Color.black
                    if let image {
                        Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
                            .opacity(0.75)
                            .transition(.opacity)
                    }
                    LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                }
                .ignoresSafeArea()
            }
            .task(id: id) {
                guard Covers.cachedBackdrop(id) == nil else { return }
                let img = await Covers.backdrop(id)
                withAnimation(.easeIn(duration: 0.3)) { self.image = img }
            }
    }
}

extension View {
    func coverBackground(_ id: String) -> some View { modifier(CoverBackground(id: id)) }
}

/// Covers, read and decoded off the main thread at the size the watch shows
/// them (at most 192 px: a 96 pt cover), kept in memory (the last 80).
enum Covers {
    private static var memory: [String: UIImage] = [:]
    private static var backdrops: [String: UIImage] = [:]
    private static var order: [String] = []

    static func cached(_ id: String) -> UIImage? { memory[id] }
    static func cachedBackdrop(_ id: String) -> UIImage? { backdrops[id] }

    static func load(_ id: String) async -> UIImage? {
        if let m = memory[id] { return m }
        let cached = cacheFile(id)
        for file in [WatchDownloads.shared.coverFile(id), cached] {
            if let file, let img = await decode(file, maxPixels: 192) { remember(id, img); return img }
        }
        guard let base = API.shared.base, let url = URL(string: "\(base)/api/items/\(id)/cover?width=200&format=jpeg"),
              let (data, resp) = try? await URLSession.shared.data(for: API.shared.authorized(url)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        try? data.write(to: cached)
        guard let img = await decode(cached, maxPixels: 192) else { return nil }
        remember(id, img)
        return img
    }

    /// The cover at 12 px, for a background (stretched, it reads as a blur).
    static func backdrop(_ id: String) async -> UIImage? {
        if let b = backdrops[id] { return b }
        _ = await load(id)
        for file in [WatchDownloads.shared.coverFile(id), cacheFile(id)] {
            if let file, let img = await decode(file, maxPixels: 12) {
                backdrops[id] = img
                return img
            }
        }
        return nil
    }

    private static func cacheFile(_ id: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("cover-\(id).jpg")
    }

    private static func remember(_ id: String, _ img: UIImage) {
        memory[id] = img
        order.removeAll { $0 == id }
        order.append(id)
        if order.count > 80 {
            let gone = order.removeFirst()
            memory[gone] = nil
            backdrops[gone] = nil
        }
    }

    /// Read and scaled down (and so decoded) off the main thread.
    private static func decode(_ file: URL, maxPixels: Int) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let src = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}

extension Format {
    /// "2h 13m left", or nil when there's no length.
    static func left(_ pos: Double, of total: Double) -> String? {
        total > 0 ? "\(hm(max(total - pos, 0))) left" : nil
    }
}
