import Foundation

/// Holds back generated text that might be the beginning of a stop sequence, and reports when one
/// is complete. Stop sequences themselves are never emitted.
struct StopSequenceMatcher: Sendable {
    let sequences: [String]
    private(set) var pending = ""

    init(_ sequences: [String]) {
        self.sequences = sequences.filter { !$0.isEmpty }
    }

    var isActive: Bool { !sequences.isEmpty }

    /// Returns the text that is safe to show, and whether a stop sequence was reached.
    mutating func feed(_ text: String) -> (text: String, stopped: Bool) {
        guard isActive else { return (text, false) }
        pending += text
        var earliest: Range<String.Index>?
        for sequence in sequences {
            if let range = pending.range(of: sequence),
               earliest.map({ range.lowerBound < $0.lowerBound }) ?? true {
                earliest = range
            }
        }
        if let earliest {
            let visible = String(pending[..<earliest.lowerBound])
            pending = ""
            return (visible, true)
        }
        // Keep the longest tail that could still grow into a stop sequence.
        let cut = pending.index(pending.endIndex, offsetBy: -heldBackCount())
        let visible = String(pending[..<cut])
        pending = String(pending[cut...])
        return (visible, false)
    }

    /// Text still held back when generation ends without completing a stop sequence.
    mutating func flush() -> String {
        defer { pending = "" }
        return pending
    }

    private func heldBackCount() -> Int {
        var longest = 0
        for sequence in sequences {
            var length = min(sequence.count - 1, pending.count)
            while length > longest {
                if pending.hasSuffix(String(sequence.prefix(length))) {
                    longest = length
                    break
                }
                length -= 1
            }
        }
        return longest
    }
}
