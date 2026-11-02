import Foundation
import NaturalLanguage

/// Lexical retrieval (BM25) over document chunks, fully on device.
///
/// Used when attached or library documents are too long to fit in the context window:
/// only the passages most relevant to the user's message are placed in the prompt.
struct DocumentChunk: Hashable, Sendable {
    let documentTitle: String
    let index: Int
    let text: String
}

enum Retrieval {
    /// Splits text into overlapping chunks of roughly `targetCharacters`, on paragraph boundaries.
    static func chunk(_ text: String, title: String, targetCharacters: Int = 1_800, overlap: Int = 200) -> [DocumentChunk] {
        let paragraphs = text.components(separatedBy: "\n\n").map(\.trimmed).filter { !$0.isEmpty }
        var chunks: [DocumentChunk] = []
        var current = ""
        // Length of the overlap carried over from the previous chunk; a chunk is only
        // emitted once it holds new text beyond that.
        var carried = 0
        func flush() {
            guard current.count > carried else { return }
            chunks.append(DocumentChunk(documentTitle: title, index: chunks.count, text: current))
            current = String(current.suffix(overlap))
            carried = current.count
        }
        for paragraph in paragraphs {
            if paragraph.count > targetCharacters {
                // Very long paragraph: hard-split it.
                var remaining = Substring(paragraph)
                while !remaining.isEmpty {
                    let piece = remaining.prefix(targetCharacters)
                    current += (current.isEmpty ? "" : "\n\n") + piece
                    flush()
                    remaining = remaining.dropFirst(piece.count)
                }
                continue
            }
            if current.count + paragraph.count > targetCharacters { flush() }
            current += (current.isEmpty ? "" : "\n\n") + paragraph
        }
        flush()
        return chunks
    }

    static func tokens(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = text[range].lowercased()
            if word.count > 1 && !stopWords.contains(word) { words.append(word) }
            return true
        }
        return words
    }

    /// Returns the `limit` best chunks for `query`, in document order, within `characterBudget`.
    static func search(_ query: String, in chunks: [DocumentChunk], limit: Int = 6, characterBudget: Int) -> [DocumentChunk] {
        let queryTerms = Set(tokens(query))
        guard !chunks.isEmpty else { return [] }
        guard !queryTerms.isEmpty else { return Array(chunks.prefix(limit)) }

        let tokenized = chunks.map { tokens($0.text) }
        let averageLength = Double(tokenized.reduce(0) { $0 + $1.count }) / Double(max(tokenized.count, 1))
        var documentFrequency: [String: Int] = [:]
        for terms in tokenized {
            for term in Set(terms) where queryTerms.contains(term) { documentFrequency[term, default: 0] += 1 }
        }
        let k1 = 1.4
        let b = 0.75
        let n = Double(chunks.count)
        var scored: [(chunk: DocumentChunk, score: Double)] = []
        for (index, terms) in tokenized.enumerated() {
            var frequencies: [String: Int] = [:]
            for term in terms where queryTerms.contains(term) { frequencies[term, default: 0] += 1 }
            var score = 0.0
            for (term, frequency) in frequencies {
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let tf = Double(frequency)
                score += idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * Double(terms.count) / max(averageLength, 1)))
            }
            if score > 0 { scored.append((chunks[index], score)) }
        }
        var selected: [DocumentChunk] = []
        var used = 0
        for candidate in scored.sorted(by: { $0.score > $1.score }) where selected.count < limit {
            guard used + candidate.chunk.text.count <= characterBudget else { continue }
            selected.append(candidate.chunk)
            used += candidate.chunk.text.count
        }
        if selected.isEmpty { selected = Array(chunks.prefix(1)) }
        return selected.sorted { ($0.documentTitle, $0.index) < ($1.documentTitle, $1.index) }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our",
        "out", "has", "have", "this", "that", "with", "from", "they", "will", "would", "there", "their", "what",
        "about", "which", "when", "make", "like", "into", "than", "them", "then", "these", "some", "could", "been",
        "is", "it", "in", "of", "to", "a", "an", "on", "as", "at", "by", "be", "or", "if", "do", "does", "how", "why"
    ]
}
