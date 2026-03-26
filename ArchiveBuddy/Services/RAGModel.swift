import Foundation
import Accelerate
import NaturalLanguage
import SVDB

/// Wraps one SVDB collection (one per Archive).
/// Keyed by archive.id.uuidString at the call site.
final class RAGModel {

    // TUNE: number of neighbors retrieved per archive before merging in ArchiveQueryService
    static let topKPerArchive: Int = 5

    let collectionName: String
    private var collection: Collection?

    init(collectionName: String) {
        self.collectionName = collectionName
    }

    // MARK: - Collection lifecycle

    func loadCollection() async {
        if let existing = SVDB.shared.getCollection(collectionName) {
            collection = existing
            return
        }
        do {
            collection = try SVDB.shared.collection(collectionName)
        } catch {
            // Collection unavailable — addEntry and findLLMNeighbors will no-op gracefully
        }
    }

    // MARK: - Indexing

    /// Encodes metadata into the stored text so citation data survives retrieval,
    /// then adds the document to the SVDB collection.
    ///
    /// The stored format is:
    /// ```
    /// __META__{"pageId":"…","archiveId":"…","archiveTitle":"…","pageNumber":3,"userDefinedDate":"2024-03-03"}
    /// __CONTENT__
    /// The actual chunk text here…
    /// ```
    func addEntry(chunkText: String, metadata: ChunkMetadata) async {
        guard let collection else { return }

        let metadataJSON: String
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(metadata)
            metadataJSON = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return
        }

        let stored = "__META__\(metadataJSON)\n__CONTENT__\n\(chunkText)"

        guard let embedding = generateEmbedding(for: chunkText) else { return }
        collection.addDocument(text: stored, embedding: embedding)
    }

    // MARK: - Search

    /// Returns the top-K neighbors for a query across this archive's collection.
    /// The returned text strings still contain the `__META__` header —
    /// `ArchiveQueryService` is responsible for stripping them.
    func findLLMNeighbors(for query: String) async -> [(text: String, score: Double)] {
        guard let collection else { return [] }
        guard let queryEmbedding = generateEmbedding(for: query) else { return [] }
        let results = collection.search(query: queryEmbedding, num_results: Self.topKPerArchive)
        return results.map { ($0.text, $0.score) }
    }

    // MARK: - Embedding

    func generateEmbedding(for sentence: String) -> [Double]? {
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return nil }

        let words = sentence.lowercased().split(separator: " ").map { String($0) }
        guard !words.isEmpty else { return nil }

        var validVectors: [[Double]] = []
        for word in words {
            if let vector = embedding.vector(for: word) {
                validVectors.append([Double](vector))
            }
        }
        guard !validVectors.isEmpty else { return nil }

        let length = validVectors[0].count
        var sum = [Double](repeating: 0, count: length)
        for vector in validVectors {
            vDSP_vaddD(sum, 1, vector, 1, &sum, 1, vDSP_Length(length))
        }
        var average = [Double](repeating: 0, count: length)
        var divisor = Double(validVectors.count)
        vDSP_vsdivD(sum, 1, &divisor, &average, 1, vDSP_Length(length))
        return average
    }
}

// MARK: - ChunkMetadata

/// Metadata embedded in every SVDB entry. Parsed back by ArchiveQueryService on retrieval.
struct ChunkMetadata: Codable {
    var pageId: UUID
    var archiveId: UUID
    var archiveTitle: String
    var pageNumber: Int
    var userDefinedDate: Date
}
