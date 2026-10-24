import Foundation
import Testing
@testable import ArchiveBuddy

struct DocumentProcessorTests {

    @Test func emptyTextHasNoChunks() {
        #expect(DocumentProcessor.chunkText("").isEmpty)
        #expect(DocumentProcessor.chunkText("   \n ").isEmpty)
    }

    @Test func shortTextIsOneChunk() {
        let text = "I went to the lake today. The water was cold!"
        #expect(DocumentProcessor.chunkText(text) == [text])
    }

    @Test func chunksStayUnderTheLimitAndOverlap() {
        let text = (1...40).map { "Sentence number \($0) is about the journal." }.joined(separator: " ")
        let chunks = DocumentProcessor.chunkText(text, maxChunkSize: 120, overlapTokens: 10)

        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(DocumentProcessor.wordCount(chunk) <= 30)
        }
        // Each chunk starts with the last sentence of the one before it.
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            let lastSentence = previous.components(separatedBy: ". ").last!
            #expect(next.hasPrefix(lastSentence.hasSuffix(".") ? lastSentence : lastSentence + "."))
        }
    }

    @Test func longSentenceIsSplitWithoutLosingWords() {
        let words = (1...100).map { "word\($0)" }
        let chunks = DocumentProcessor.chunkText(words.joined(separator: " "), maxChunkSize: 80, overlapTokens: 0)

        #expect(chunks.count == 5)
        #expect(chunks.joined(separator: " ").split(separator: " ").map(String.init) == words)
    }
}
