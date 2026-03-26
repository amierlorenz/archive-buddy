import Foundation
import NaturalLanguage

/// Text chunking utility. Adapted from Aeru's DocumentProcessor — PDF extraction
/// and file-storage methods dropped; chunk + token logic kept unchanged.
enum DocumentProcessor {

    /// Splits text into overlapping chunks suitable for embedding.
    /// - Parameters:
    ///   - text: The full text to chunk (e.g. a page's finalText).
    ///   - maxChunkSize: Approximate max characters per chunk (~4 chars/token).
    ///   - overlapTokens: Number of tokens to repeat at the start of each new chunk.
    static func chunkText(_ text: String, maxChunkSize: Int = 3500, overlapTokens: Int = 125) -> [String] {
        let maxTokens = maxChunkSize / 4

        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { sentence in
                sentence.hasSuffix(".") || sentence.hasSuffix("!") || sentence.hasSuffix("?")
                    ? sentence : sentence + "."
            }

        var chunks: [String] = []
        var currentChunk = ""
        var currentTokenCount = 0
        var previousChunkSentences: [String] = []

        for sentence in sentences {
            let sentenceTokenCount = countTokens(in: sentence)
            let potentialTokenCount = currentTokenCount + sentenceTokenCount + (currentChunk.isEmpty ? 0 : 1)

            if potentialTokenCount <= maxTokens {
                currentChunk = currentChunk.isEmpty ? sentence : currentChunk + " " + sentence
                currentTokenCount = potentialTokenCount
            } else {
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk)
                    previousChunkSentences = currentChunk
                        .components(separatedBy: CharacterSet(charactersIn: ".!?"))
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }

                // Build overlap from the tail of the previous chunk
                var overlapText = ""
                var overlapTokenCount = 0
                for sentenceIndex in stride(from: previousChunkSentences.count - 1, through: 0, by: -1) {
                    let overlapSentence = previousChunkSentences[sentenceIndex]
                    let tokens = countTokens(in: overlapSentence)
                    guard overlapTokenCount + tokens <= overlapTokens else { break }
                    overlapText = overlapSentence + (overlapText.isEmpty ? "" : " " + overlapText)
                    overlapTokenCount += tokens
                }

                if sentenceTokenCount <= maxTokens {
                    currentChunk = overlapText.isEmpty ? sentence : overlapText + " " + sentence
                    currentTokenCount = overlapTokenCount + sentenceTokenCount + (overlapText.isEmpty ? 0 : 1)
                } else {
                    // Sentence exceeds max — truncate at word boundary
                    var truncated = ""
                    var truncatedTokens = 0
                    for word in sentence.components(separatedBy: .whitespaces) {
                        let wordTokens = countTokens(in: word)
                        guard truncatedTokens + wordTokens <= maxTokens else { break }
                        truncated += (truncated.isEmpty ? "" : " ") + word
                        truncatedTokens += wordTokens
                    }
                    if !truncated.isEmpty {
                        if !truncated.hasSuffix(".") && !truncated.hasSuffix("!") && !truncated.hasSuffix("?") {
                            truncated += "."
                        }
                        chunks.append(truncated)
                    }
                    currentChunk = ""
                    currentTokenCount = 0
                }
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        return chunks.filter { !$0.isEmpty }
    }

    private static func countTokens(in text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).count
    }
}
