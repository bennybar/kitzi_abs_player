import SwiftUI
import UIKit

/// Per-book cover crops (zoom and position), set on the book's page and used
/// everywhere the cover shows, the player and the lock screen included. Kept on
/// this device only.
@Observable
final class CoverCrops {
    static let shared = CoverCrops()

    /// [scale] ≥ 1 zooms in; [x]/[y] move the picture, as fractions of the frame.
    struct Crop: Codable, Equatable {
        var scale: Double = 1
        var x: Double = 0
        var y: Double = 0
    }

    private(set) var crops: [String: Crop] = [:]
    private let key = "cover_crops"

    init() {
        if let d = Store.d.data(forKey: key), let c = try? JSONDecoder().decode([String: Crop].self, from: d) { crops = c }
    }

    func set(_ id: String, _ crop: Crop?) {
        crops[id] = (crop == nil || crop == Crop()) ? nil : crop
        Store.set(try? JSONEncoder().encode(crops), key)
    }

    /// The square part of [img] the crop shows (for the lock screen artwork).
    nonisolated static func apply(_ c: Crop, to original: UIImage) -> UIImage {
        // Crop in the picture as shown (EXIF rotation applied), not the raw pixels.
        let img = original.imageOrientation == .up ? original
            : UIGraphicsImageRenderer(size: original.size).image { _ in original.draw(at: .zero) }
        guard let cg = img.cgImage else { return original }
        let w = Double(cg.width), h = Double(cg.height), m = min(w, h)
        let side = m / c.scale
        let cx = w / 2 - c.x * m / c.scale, cy = h / 2 - c.y * m / c.scale
        let r = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side).integral
        guard let out = cg.cropping(to: r) else { return img }
        return UIImage(cgImage: out, scale: img.scale, orientation: .up)
    }
}

/// Pinch to zoom and drag to move a book's cover inside the square it's shown in.
struct CoverCropSheet: View {
    let book: Book
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var crop = CoverCrops.Crop()
    @State private var baseScale = 1.0
    @State private var baseOffset = CGPoint.zero
    private let side: CGFloat = 300

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Pinch to zoom, drag to move").font(.subheadline).foregroundStyle(.secondary)
                Color.clear
                    .frame(width: side, height: side)
                    .overlay {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: side, height: side)
                                .scaleEffect(crop.scale)
                                .offset(x: crop.x * side, y: crop.y * side)
                        } else {
                            ProgressView()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(SimultaneousGesture(
                        MagnifyGesture()
                            .onChanged { v in crop.scale = min(max(baseScale * v.magnification, 1), 4); clamp() }
                            .onEnded { _ in baseScale = crop.scale; baseOffset = CGPoint(x: crop.x, y: crop.y) },
                        DragGesture()
                            .onChanged { v in
                                crop.x = baseOffset.x + v.translation.width / side
                                crop.y = baseOffset.y + v.translation.height / side
                                clamp()
                            }
                            .onEnded { _ in baseOffset = CGPoint(x: crop.x, y: crop.y) }
                    ))
                Button("Reset") { crop = .init(); baseScale = 1; baseOffset = .zero }
                    .buttonStyle(.glass)
                    .disabled(crop == .init())
                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("Crop Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        CoverCrops.shared.set(book.id, crop)
                        // The lock screen shows the new crop at once.
                        if Player.shared.nowPlaying?.book.id == book.id { Player.shared.loadArtwork(book) }
                        dismiss()
                    }
                }
            }
        }
        .task {
            crop = CoverCrops.shared.crops[book.id] ?? .init()
            if let u = Downloads.shared.localCover(book.id) ?? book.coverURL(width: 600) {
                image = await ImageLoader.shared.image(u)
                clamp()
            }
            baseScale = crop.scale; baseOffset = CGPoint(x: crop.x, y: crop.y)
        }
    }

    /// Keeps the frame covered: the picture can't be moved past its own edges.
    private func clamp() {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let m = min(image.size.width, image.size.height)
        let maxX = max((crop.scale * image.size.width / m - 1) / 2, 0)
        let maxY = max((crop.scale * image.size.height / m - 1) / 2, 0)
        crop.x = min(max(crop.x, -maxX), maxX)
        crop.y = min(max(crop.y, -maxY), maxY)
    }
}
