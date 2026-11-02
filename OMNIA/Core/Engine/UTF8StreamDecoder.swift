import Foundation

/// Turns a stream of token byte pieces into valid UTF-8 text.
///
/// A single token can end in the middle of a multi-byte character (emoji, CJK, accented
/// letters). Bytes of an incomplete trailing sequence are held back until the next piece
/// completes them, so the UI never shows replacement characters mid-stream.
struct UTF8StreamDecoder {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        pending.append(contentsOf: bytes)
        let complete = Self.completePrefixLength(pending)
        guard complete > 0 else { return "" }
        let text = String(decoding: pending[0..<complete], as: UTF8.self)
        pending.removeFirst(complete)
        return text
    }

    /// Emits whatever is left (invalid trailing bytes become U+FFFD).
    mutating func flush() -> String {
        defer { pending.removeAll() }
        return pending.isEmpty ? "" : String(decoding: pending, as: UTF8.self)
    }

    /// Length of the longest prefix that does not end inside a multi-byte sequence.
    static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        var index = bytes.count - 1
        var continuationBytes = 0
        while index >= 0 && continuationBytes < 4 {
            let byte = bytes[index]
            if byte & 0xC0 == 0x80 {
                continuationBytes += 1
                index -= 1
                continue
            }
            let expected: Int
            if byte & 0x80 == 0 {
                expected = 1
            } else if byte & 0xE0 == 0xC0 {
                expected = 2
            } else if byte & 0xF0 == 0xE0 {
                expected = 3
            } else if byte & 0xF8 == 0xF0 {
                expected = 4
            } else {
                return bytes.count // invalid lead byte: let the decoder substitute it
            }
            return continuationBytes + 1 >= expected ? bytes.count : index
        }
        return bytes.count
    }
}
