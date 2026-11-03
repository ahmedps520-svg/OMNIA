import SwiftUI
import UIKit

/// Decoded thumbnails, so a chat never decodes the same picture twice while scrolling.
@MainActor
enum ThumbnailCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    static func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    static func store(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }
}

/// A rounded thumbnail of an attached image, decoded off the main thread at display size.
struct ImageThumbnail: View {
    let id: UUID
    let data: Data
    var width: CGFloat = 56
    var height: CGFloat = 56

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Theme.faint)
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Image")
        .task(id: id) { await load() }
    }

    private func load() async {
        let pixels = Int(max(width, height) * displayScale)
        let key = "\(id.uuidString)-\(pixels)"
        if let cached = ThumbnailCache.image(for: key) {
            image = cached
            return
        }
        let data = self.data
        let decoded = await Task.detached(priority: .userInitiated) {
            ImageInput.thumbnail(data, maxPixelSize: pixels)
        }.value
        guard let decoded else { return }
        let thumbnail = UIImage(cgImage: decoded)
        ThumbnailCache.store(thumbnail, for: key)
        image = thumbnail
    }
}

/// An attached image shown on its own, to look at it closely or share it.
struct ImagePreviewSheet: View {
    let name: String
    let data: Data

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel(name)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let image {
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview(name, image: Image(uiImage: image))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .task {
            let data = self.data
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageInput.thumbnail(data, maxPixelSize: ImageInput.maxPixelSize)
            }.value
            image = decoded.map { UIImage(cgImage: $0) }
        }
    }
}
