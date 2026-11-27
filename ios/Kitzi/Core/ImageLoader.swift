import CryptoKit
import SwiftUI
import UIKit

/// Covers through the signed-in client, kept on disk: the server sends covers with
/// no cache headers, and the URL carries the item's updatedAt, so a replaced cover
/// is a new URL and is fetched fresh (same scheme as the Android app).
final class ImageLoader {
    static let shared = ImageLoader()
    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("covers")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// The largest copy of each cover in memory, by the cover without its size:
    /// a page asking for a bigger size shows that one at once, not a blank.
    private var best: [String: (width: CGFloat, image: UIImage)] = [:]

    init() {
        memory.countLimit = 400
        // Decoded covers are big (a 1200 px one is about 6 MB): bounded by bytes too.
        memory.totalCostLimit = 120 * 1024 * 1024
    }

    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url.absoluteString as NSString) }

    /// The exact cover if it's in memory, else the largest other size of it.
    func cachedAny(_ url: URL) -> UIImage? {
        cached(url) ?? best[Self.family(url)]?.image
    }

    /// The cover's address without its size (and timestamp kept: a new cover is a new family).
    private static func family(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.queryItems = c.queryItems?.filter { $0.name != "width" }
        return c.string ?? url.absoluteString
    }

    private func remember(_ img: UIImage, for url: URL) {
        let cost = Int(img.size.width * img.scale * img.size.height * img.scale * 4)
        memory.setObject(img, forKey: url.absoluteString as NSString, cost: cost)
        let f = Self.family(url)
        if (best[f]?.width ?? 0) < img.size.width * img.scale { best[f] = (img.size.width * img.scale, img) }
        if best.count > 500 { best.removeAll() }
    }

    func image(_ url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let m = memory.object(forKey: key) { return m }
        if let t = inflight[url] { return await t.value }
        let file = dir.appendingPathComponent(Self.hash(url.absoluteString))
        let req = url.isFileURL ? nil : API.shared.authorized(url)
        // Disk, network and decoding happen off the main thread (scrolling stays smooth).
        let t = Task.detached { () -> UIImage? in
            if url.isFileURL { return await UIImage(contentsOfFile: url.path)?.byPreparingForDisplay() }
            if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
                return await img.byPreparingForDisplay() ?? img
            }
            guard let req, let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: data) else { return nil }
            try? data.write(to: file)
            return await img.byPreparingForDisplay() ?? img
        }
        inflight[url] = t
        let img = await t.value
        inflight[url] = nil
        if let img { remember(img, for: url) }
        return img
    }

    func clearDisk() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.removeAllObjects()
        best.removeAll()
    }

    var diskBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A cover: the downloaded copy when there is one, else the server's.
struct CoverImage: View {
    let book: Book?
    var url: URL? = nil
    var width: Int = 600
    @State private var image: UIImage?

    private var resolved: URL? {
        if let url { return url }
        guard let book else { return nil }
        return Downloads.shared.localCover(book.id) ?? book.coverURL(width: width)
    }

    var body: some View {
        // What's in memory shows in the first frame (it used to flash the
        // placeholder until the task ran), and another size of the same cover
        // stands in while this size loads.
        let image = image ?? resolved.flatMap { ImageLoader.shared.cachedAny($0) }
        // Takes exactly the space it's offered: the picture fills it (cropped), but
        // never reports its own pixel size to the layout.
        Color.clear
            .overlay {
                if let image {
                    if url == nil, let id = book?.id, let c = CoverCrops.shared.crops[id] {
                        // The book's own crop (set on its page).
                        GeometryReader { g in
                            // x/y are fractions of the picture's short side as filled
                            // into this frame (in a square frame: the frame's side).
                            let fill = max(g.size.width / max(image.size.width, 1), g.size.height / max(image.size.height, 1))
                            let unit = min(image.size.width, image.size.height) * fill
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: g.size.width, height: g.size.height)
                                .scaleEffect(c.scale)
                                .offset(x: c.x * unit, y: c.y * unit)
                        }
                    } else {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "book.closed").font(.title2).foregroundStyle(.tertiary))
                }
            }
            .clipped()
        .task(id: resolved) {
            guard let u = resolved else { return }
            if let c = ImageLoader.shared.cached(u) { self.image = c; return }
            let hadOne = ImageLoader.shared.cachedAny(u) != nil
            let loaded = await ImageLoader.shared.image(u)
            // From the network with nothing shown yet: faded in, not popped.
            if hadOne || UIAccessibility.isReduceMotionEnabled { self.image = loaded }
            else { withAnimation(.easeOut(duration: 0.2)) { self.image = loaded } }
        }
    }
}
