import Foundation
import llama

/// Carries a conversation's images through prompt formatting to llama.cpp's multimodal tokenizer.
///
/// Before the chat template runs, each image becomes a unique placeholder in its turn's text, so
/// formatting, tool flattening and the trimming of old turns treat it like any other text. In the
/// formatted prompt, the placeholders still present become llama.cpp's media marker, in order:
/// they name exactly the images the model will see.
struct ImagePrompt {
    /// Image files in placeholder order.
    let images: [Data]
    /// The turns, with placeholders where their images were.
    let turns: [ChatTurn]

    var isEmpty: Bool { images.isEmpty }

    private static let open = "\u{F8F0}omnia-image-"
    private static let close = "\u{F8F1}"

    init(turns: [ChatTurn], marker: String) {
        guard turns.contains(where: { !$0.images.isEmpty }) else {
            images = []
            self.turns = turns
            return
        }
        var collected: [Data] = []
        self.turns = turns.map { original in
            var turn = original
            turn.content = Self.sanitize(turn.content, marker: marker)
            guard !turn.images.isEmpty else { return turn }
            let placeholders = turn.images.map { data in
                collected.append(data)
                return Self.placeholder(collected.count - 1)
            }
            turn.content = (placeholders + (turn.content.isEmpty ? [] : [turn.content])).joined(separator: "\n")
            turn.images = []
            return turn
        }
        images = collected
    }

    static func placeholder(_ index: Int) -> String { "\(open)\(index)\(close)" }

    /// Keeps text from posing as an image: llama.cpp reads a literal media marker as the place
    /// for an image, and the placeholder delimiters are reserved.
    static func sanitize(_ text: String, marker: String) -> String {
        var clean = text
        if !marker.isEmpty, clean.contains(marker) {
            clean = clean.replacingOccurrences(of: marker, with: String(marker.prefix(1)) + "\u{200B}" + String(marker.dropFirst()))
        }
        if clean.unicodeScalars.contains(where: { $0 == "\u{F8F0}" || $0 == "\u{F8F1}" }) {
            clean = String(clean.unicodeScalars.filter { $0 != "\u{F8F0}" && $0 != "\u{F8F1}" })
        }
        return clean
    }

    /// Replaces the placeholders in a formatted prompt with `marker`. Returns the images to pass
    /// with it, as indices into `images`, in the order the template placed them.
    func resolve(_ text: String, marker: String) -> (text: String, order: [Int]) {
        guard !images.isEmpty else { return (text, []) }
        var result = ""
        var order: [Int] = []
        var rest = Substring(text)
        while let start = rest.range(of: Self.open) {
            result += rest[..<start.lowerBound]
            let tail = rest[start.upperBound...]
            guard let end = tail.range(of: Self.close), let index = Int(tail[..<end.lowerBound]),
                  images.indices.contains(index) else {
                rest = tail
                continue
            }
            result += marker
            order.append(index)
            rest = tail[end.upperBound...]
        }
        result += rest
        return (result, order)
    }
}

/// One image chunk of a tokenized prompt.
struct MediaSpan: Equatable, Sendable {
    /// The image's content ID: the same picture always matches, so a cached image is reused.
    let id: String
    /// KV-cache cells the image fills.
    let tokenCount: Int
    /// Positions it advances: fewer than its cells for M-RoPE models (Qwen3.5 and its family).
    let positionCount: Int
}

/// An image chunk waiting to be evaluated. `chunk` belongs to the prompt's `MediaChunks`.
struct PromptMedia {
    let span: MediaSpan
    let chunk: OpaquePointer
}

/// The decoded pictures for one prompt (`mtmd_bitmap`), made once each and freed together.
/// Used only on the runtime's queue.
final class ImageBitmaps {
    private let images: [Data]
    private var bitmaps: [Int: OpaquePointer] = [:]

    init(_ images: [Data]) {
        self.images = images
    }

    func bitmap(_ index: Int) throws -> OpaquePointer {
        if let existing = bitmaps[index] { return existing }
        let decoded: (width: Int, height: Int, pixels: [UInt8])
        do {
            decoded = try ImageInput.rgbPixels(images[index])
        } catch {
            throw InferenceError.imageUnreadable
        }
        guard let bitmap = mtmd_bitmap_init(UInt32(decoded.width), UInt32(decoded.height), decoded.pixels) else {
            throw InferenceError.imageUnreadable
        }
        mtmd_bitmap_set_id(bitmap, ImageInput.contentID(images[index]))
        bitmaps[index] = bitmap
        return bitmap
    }

    deinit {
        bitmaps.values.forEach { mtmd_bitmap_free($0) }
    }
}

/// A tokenized multimodal prompt (`mtmd_input_chunks`), kept alive until its images are
/// evaluated. Image chunks hold their own preprocessed copy of each picture.
final class MediaChunks {
    let pointer: OpaquePointer

    init?() {
        guard let chunks = mtmd_input_chunks_init() else { return nil }
        pointer = chunks
    }

    deinit {
        mtmd_input_chunks_free(pointer)
    }
}
