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

    init() { memory.countLimit = 300 }

    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url.absoluteString as NSString) }

    func image(_ url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let m = memory.object(forKey: key) { return m }
        if url.isFileURL {
            let img = UIImage(contentsOfFile: url.path)
            if let img { memory.setObject(img, forKey: key) }
            return img
        }
        if let t = inflight[url] { return await t.value }
        let file = dir.appendingPathComponent(Self.hash(url.absoluteString))
        let t = Task { () -> UIImage? in
            if let data = try? Data(contentsOf: file), let img = UIImage(data: data) { return img }
            let req = API.shared.authorized(url)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: data) else { return nil }
            try? data.write(to: file)
            return img
        }
        inflight[url] = t
        let img = await t.value
        inflight[url] = nil
        if let img { memory.setObject(img, forKey: key) }
        return img
    }

    func clearDisk() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.removeAllObjects()
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
        // Takes exactly the space it's offered: the picture fills it (cropped), but
        // never reports its own pixel size to the layout.
        Color.clear
            .overlay {
                if let image {
                    if url == nil, let id = book?.id, let c = CoverCrops.shared.crops[id] {
                        // The book's own crop (set on its page).
                        GeometryReader { g in
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: g.size.width, height: g.size.height)
                                .scaleEffect(c.scale)
                                .offset(x: c.x * g.size.width, y: c.y * g.size.height)
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
            if let c = ImageLoader.shared.cached(u) { image = c; return }
            image = await ImageLoader.shared.image(u)
        }
    }
}
