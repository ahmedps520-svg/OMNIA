import Accelerate
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Photos and screenshots attached to messages.
///
/// An image is stored once, as an upright, opaque sRGB JPEG no larger than `maxPixelSize` on
/// its long edge: more detail than any vision encoder keeps after its own resizing, small
/// enough to keep conversations light. Re-encoding also drops the original's metadata, such
/// as where a photo was taken.
enum ImageInput {
    enum ImageError: LocalizedError {
        case unreadable
        case tooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "This image couldn't be read. Try a JPEG, PNG or HEIC image."
            case .tooLarge(let bytes):
                "This image is too large to attach (\(ByteFormat.file(Int64(bytes))))."
            }
        }
    }

    struct Prepared: Sendable {
        /// JPEG data, ready to store and to hand to the model.
        let data: Data
        let width: Int
        let height: Int
    }

    /// Qwen3.5 sees about 1024 × 1024 pixels at OMNIA's 1,024-token image budget, and Gemma 4
    /// and Pixtral less, so a 2048-pixel edge keeps every detail a model can use.
    static let maxPixelSize = 2048
    static let maxInputBytes = 100 * 1024 * 1024
    static let compressionQuality = 0.88

    /// Content types offered when picking images from Files.
    static let supportedTypes: [UTType] = [.image]

    /// Decodes any image ImageIO reads (HEIC, JPEG, PNG, GIF, WebP, TIFF…) and stores it as
    /// described above.
    static func prepare(_ data: Data) throws -> Prepared {
        guard data.count <= maxInputBytes else { throw ImageError.tooLarge(data.count) }
        let image = try upright(data, maxPixelSize: maxPixelSize)
        let flattened = try render(image) { context in context.makeImage() }
        guard let flattened else { throw ImageError.unreadable }
        return Prepared(data: try jpeg(flattened), width: flattened.width, height: flattened.height)
    }

    /// Tightly packed RGB888 pixels (no row padding, no alpha), the format llama.cpp's image
    /// input (`mtmd_bitmap_init`) expects.
    static func rgbPixels(_ data: Data) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        let image = try upright(data, maxPixelSize: maxPixelSize)
        let width = image.width
        let height = image.height
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        let converted: Bool = try render(image) { context in
            guard let rgbx = context.data else { return false }
            return rgb.withUnsafeMutableBytes { destination in
                var source = vImage_Buffer(data: rgbx, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: context.bytesPerRow)
                var target = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: width * 3)
                return vImageConvert_RGBA8888toRGB888(&source, &target, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
        }
        guard converted else { throw ImageError.unreadable }
        return (width, height, rgb)
    }

    /// A small upright version for thumbnails.
    static func thumbnail(_ data: Data, maxPixelSize: Int) -> CGImage? {
        try? upright(data, maxPixelSize: maxPixelSize)
    }

    /// Identifies an image by content: the same picture always gets the same ID, so the model's
    /// cache can recognise it from one message to the next.
    static func contentID(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Decoding

    /// The primary image, rotated upright from its orientation metadata and scaled down (never
    /// up) to `maxPixelSize`. ImageIO decodes large photos at reduced size directly.
    private static func upright(_ data: Data, maxPixelSize: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw ImageError.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
              image.width > 0, image.height > 0 else { throw ImageError.unreadable }
        return image
    }

    /// Draws the image into an opaque sRGB RGBX bitmap, with transparent areas on white (as
    /// image viewers show them), and hands the context to `body`.
    private static func render<Result>(_ image: CGImage, _ body: (CGContext) throws -> Result) throws -> Result {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ImageError.unreadable
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        return try body(context)
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageError.unreadable
        }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.unreadable }
        return output as Data
    }
}
