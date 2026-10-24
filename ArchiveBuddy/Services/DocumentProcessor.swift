import Foundation
import NaturalLanguage

/// Splits page text into overlapping, sentence-aligned chunks for embedding.
enum DocumentProcessor {

    private typealias Piece = (text: String, tokens: Int)

    /// Splits text into overlapping chunks suitable for embedding.
    /// - Parameters:
    ///   - text: The full text to chunk (e.g. a page's finalText).
    ///   - maxChunkSize: Approximate max characters per chunk (~4 chars/token).
    ///   - overlapTokens: Number of tokens to repeat at the start of each new chunk.
    static func chunkText(_ text: String, maxChunkSize: Int = 3500, overlapTokens: Int = 125) -> [String] {
        let maxTokens = max(1, maxChunkSize / 4)
        let pieces = sentences(in: text).flatMap { split($0, maxTokens: maxTokens) }

        var chunks: [String] = []
        var current: [Piece] = []
        var currentTokens = 0

        for piece in pieces {
            if currentTokens + piece.tokens > maxTokens, !current.isEmpty {
                chunks.append(current.map(\.text).joined(separator: " "))

                // Start the next chunk with whole sentences from the end of this one.
                var overlap: [Piece] = []
                var overlapCount = 0
                for previous in current.reversed() {
                    guard overlapCount + previous.tokens <= overlapTokens,
                          overlapCount + previous.tokens + piece.tokens <= maxTokens else { break }
                    overlap.insert(previous, at: 0)
                    overlapCount += previous.tokens
                }
                current = overlap
                currentTokens = overlapCount
            }
            current.append(piece)
            currentTokens += piece.tokens
        }

        if !current.isEmpty {
            chunks.append(current.map(\.text).joined(separator: " "))
        }
        return chunks
    }

    private static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
            .map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// One piece per sentence, or word windows when a sentence alone is over the limit,
    /// so no text is dropped.
    private static func split(_ sentence: String, maxTokens: Int) -> [Piece] {
        let total = wordCount(sentence)
        guard total > maxTokens else { return [(sentence, total)] }

        var pieces: [Piece] = []
        var window: [Substring] = []
        var windowTokens = 0
        for word in sentence.split(whereSeparator: \.isWhitespace) {
            let tokens = wordCount(String(word))
            if windowTokens + tokens > maxTokens, !window.isEmpty {
                pieces.append((window.joined(separator: " "), windowTokens))
                window = []
                windowTokens = 0
            }
            window.append(word)
            windowTokens += tokens
        }
        if !window.isEmpty {
            pieces.append((window.joined(separator: " "), windowTokens))
        }
        return pieces
    }

    static func wordCount(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).count
    }
}
