import Foundation
import SwiftData
import CoreML // Required for MLMultiArray

/// Errors specific to the JournalSearchService.
enum JournalSearchError: Error, LocalizedError {
    case embeddingGenerationFailed(Error)
    case noEmbeddingFoundForEntry(UUID)
    case searchFailed(Error)

    var errorDescription: String? {
        switch self {
        case .embeddingGenerationFailed(let error):
            return "Failed to generate embedding for search query: \(error.localizedDescription)"
        case .noEmbeddingFoundForEntry(let id):
            return "No embedding found for JournalEntry with ID: \(id.uuidString). Please ensure all entries have embeddings."
        case .searchFailed(let error):
            return "Journal search failed: \(error.localizedDescription)"
        }
    }
}

/// An actor responsible for performing semantic searches across journal entries.
actor JournalSearchService {
    private let modelContext: ModelContext
    private let embeddingService: EmbeddingService

    /// Initializes the search service.
    /// - Parameters:
    ///   - modelContext: The SwiftData model context for fetching entries.
    ///   - embeddingService: The service used to generate embeddings for search queries.
    init(modelContext: ModelContext, embeddingService: EmbeddingService) {
        self.modelContext = modelContext
        self.embeddingService = embeddingService
    }

    /// Performs a semantic search for journal entries based on a query string.
    /// - Parameters:
    ///   - query: The search query string.
    ///   - limit: The maximum number of results to return (default: 5).
    /// - Returns: An array of `JournalEntry` objects sorted by similarity, with the most similar first.
    /// - Throws: `JournalSearchError` if embedding generation or data fetching fails.
    func searchJournalEntries(query: String, limit: Int = 5) async throws -> [JournalEntry] {
        // 1. Generate embedding for the query
        let queryEmbeddingMLMultiArray: MLMultiArray
        do {
            queryEmbeddingMLMultiArray = try await embeddingService.generateEmbedding(for: query)
        } catch {
            throw JournalSearchError.embeddingGenerationFailed(error)
        }

        // 2. Fetch all JournalEntry objects from SwiftData
        var descriptor = FetchDescriptor<JournalEntry>()
        // Optimize: Only fetch entries that actually have an embedding stored.
        descriptor.predicate = #Predicate { $0.embedding != nil }

        let allEntries: [JournalEntry]
        do {
            allEntries = try modelContext.fetch(descriptor)
        } catch {
            throw JournalSearchError.searchFailed(error)
        }

        // 3. Calculate Cosine Similarity for each entry
        var scoredEntries: [(entry: JournalEntry, similarity: Double)] = []

        for entry in allEntries {
            guard let entryEmbeddingData = entry.embedding,
                  let entryEmbeddingMLMultiArray = try await MLMultiArray.fromData(entryEmbeddingData) else {
                // This case should be rare if predicate worked, but good for robustness.
                print("Warning: Skipping entry \(entry.id) due to missing or invalid embedding data.")
                continue
            }

            // Ensure embedding dimensions match, though NLEmbedding usually provides consistent dimensions.
            guard queryEmbeddingMLMultiArray.count == entryEmbeddingMLMultiArray.count else {
                print("Warning: Skipping entry \(entry.id) due to embedding dimension mismatch.")
                continue
            }

            let similarity = cosineSimilarity(vectorA: queryEmbeddingMLMultiArray, vectorB: entryEmbeddingMLMultiArray)
            scoredEntries.append((entry: entry, similarity: similarity))
        }

        // 4. Sort by similarity (descending) and return the top N results
        let topResults = scoredEntries
            .sorted { $0.similarity > $1.similarity }
            .prefix(limit)
            .map { $0.entry }

        return topResults
    }

    /// Calculates the cosine similarity between two `MLMultiArray` vectors.
    /// Assumes both vectors are 1D or can be treated as flattened 1D for calculation.
    /// - Parameters:
    ///   - vectorA: The first `MLMultiArray`.
    ///   - vectorB: The second `MLMultiArray`.
    /// - Returns: A `Double` representing the cosine similarity, ranging from -1 to 1.
    private func cosineSimilarity(vectorA: MLMultiArray, vectorB: MLMultiArray) -> Double {
        // This check is already done in searchJournalEntries, but good to keep for standalone use.
        guard vectorA.count == vectorB.count else {
            return 0.0
        }

        var dotProduct: Double = 0.0
        var magnitudeA: Double = 0.0
        var magnitudeB: Double = 0.0

        for i in 0..<vectorA.count {
            let valA = vectorA[i].doubleValue
            let valB = vectorB[i].doubleValue

            dotProduct += valA * valB
            magnitudeA += valA * valA
            magnitudeB += valB * valB
        }

        magnitudeA = sqrt(magnitudeA)
        magnitudeB = sqrt(magnitudeB)

        if magnitudeA == 0.0 || magnitudeB == 0.0 {
            return 0.0 // Avoid division by zero if a vector is zero (no magnitude)
        }

        return dotProduct / (magnitudeA * magnitudeB)
    }
}
