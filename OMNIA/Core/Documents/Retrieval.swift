import Foundation
import NaturalLanguage

/// Retrieval over document chunks, fully on device: keyword ranking (BM25), fused with ranking
/// by meaning when the library's embedding model has indexed the documents (`SemanticIndex`).
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
    ///
    /// `similarities` (each chunk's closeness in meaning to the query, from embeddings) adds a
    /// second ranking; the two are fused by reciprocal rank, so a passage that says the same
    /// thing in other words is found as well as one that shares the query's words.
    static func search(_ query: String, in chunks: [DocumentChunk], similarities: [Float]? = nil,
                       limit: Int = 6, characterBudget: Int) -> [DocumentChunk] {
        guard !chunks.isEmpty else { return [] }
        let meaning = similarities.flatMap { $0.count == chunks.count ? $0 : nil }
        let keywords = keywordScores(query, in: chunks)
        guard keywords != nil || meaning != nil else { return Array(chunks.prefix(limit)) }

        var fused = [Double](repeating: 0, count: chunks.count)
        if let keywords {
            let ranked = chunks.indices.filter { keywords[$0] > 0 }.sorted { keywords[$0] > keywords[$1] }
            for (rank, index) in ranked.enumerated() { fused[index] += 1 / (fusionConstant + Double(rank + 1)) }
        }
        if let meaning {
            let ranked = chunks.indices.sorted { meaning[$0] > meaning[$1] }
            for (rank, index) in ranked.enumerated() { fused[index] += 1 / (fusionConstant + Double(rank + 1)) }
        }
        var selected: [DocumentChunk] = []
        var used = 0
        for index in chunks.indices.filter({ fused[$0] > 0 }).sorted(by: { fused[$0] > fused[$1] }) where selected.count < limit {
            let chunk = chunks[index]
            guard used + chunk.text.count <= characterBudget else { continue }
            selected.append(chunk)
            used += chunk.text.count
        }
        if selected.isEmpty { selected = Array(chunks.prefix(1)) }
        return selected.sorted { ($0.documentTitle, $0.index) < ($1.documentTitle, $1.index) }
    }

    /// Reciprocal rank fusion's usual constant: it keeps one list's top result from outweighing
    /// strong agreement between both lists.
    static let fusionConstant = 60.0

    /// BM25 score of every chunk (0 when no query word occurs), or nil when the query has no
    /// searchable words.
    static func keywordScores(_ query: String, in chunks: [DocumentChunk]) -> [Double]? {
        let queryTerms = Set(tokens(query))
        guard !queryTerms.isEmpty else { return nil }
        let tokenized = chunks.map { tokens($0.text) }
        let averageLength = Double(tokenized.reduce(0) { $0 + $1.count }) / Double(max(tokenized.count, 1))
        var documentFrequency: [String: Int] = [:]
        for terms in tokenized {
            for term in Set(terms) where queryTerms.contains(term) { documentFrequency[term, default: 0] += 1 }
        }
        let k1 = 1.4
        let b = 0.75
        let n = Double(chunks.count)
        return tokenized.map { terms in
            var frequencies: [String: Int] = [:]
            for term in terms where queryTerms.contains(term) { frequencies[term, default: 0] += 1 }
            var score = 0.0
            for (term, frequency) in frequencies {
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let tf = Double(frequency)
                score += idf * (tf * (k1 + 1)) / (tf + k1 * (1 - b + b * Double(terms.count) / max(averageLength, 1)))
            }
            return score
        }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our",
        "out", "has", "have", "this", "that", "with", "from", "they", "will", "would", "there", "their", "what",
        "about", "which", "when", "make", "like", "into", "than", "them", "then", "these", "some", "could", "been",
        "is", "it", "in", "of", "to", "a", "an", "on", "as", "at", "by", "be", "or", "if", "do", "does", "how", "why"
    ]
}
