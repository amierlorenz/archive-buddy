import Foundation
import NaturalLanguage
import CoreML // Required for MLMultiArray

/// Errors specific to the EmbeddingService.
enum EmbeddingServiceError: Error, LocalizedError {
    case embeddingNotAvailable
    case embeddingGenerationFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .embeddingNotAvailable:
            return "Text embedding functionality is not available on this device or iOS version for the specified language."
        case .embeddingGenerationFailed(let error):
            return "Failed to generate text embedding: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}

/// An actor responsible for generating text embeddings using NLEmbedding.
actor EmbeddingService {
    private let embedding: NLEmbedding?

    init() {
        // Initialize the sentence embedding for English.
        // NLEmbedding.sentenceEmbedding is available from iOS 18.0+.
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
        if embedding == nil {
            print("Warning: NLEmbedding.sentenceEmbedding for English is not available on this device or iOS version.")
        }
    }

    /// Generates an MLMultiArray embedding for the given text.
    /// - Parameter text: The input string for which to generate the embedding.
    /// - Returns: An `MLMultiArray` representing the text embedding.
    /// - Throws: `EmbeddingServiceError` if the embedding model is unavailable or generation fails.
    func generateEmbedding(for text: String) async throws -> MLMultiArray {
        guard let embedding = embedding else {
            throw EmbeddingServiceError.embeddingNotAvailable
        }

        do {
            // Use the vector(for:) method which directly returns an array of Doubles.
            guard let vector = embedding.vector(for: text) else {
                throw EmbeddingServiceError.embeddingGenerationFailed(nil)
            }

            // Convert [Double] to MLMultiArray.
            // NLEmbedding sentence vectors are typically 1-dimensional.
            let shape: [NSNumber] = [NSNumber(value: vector.count)]
            let mlMultiArray = try MLMultiArray(shape: shape, dataType: .double)

            for (index, value) in vector.enumerated() {
                mlMultiArray[index] = NSNumber(value: value)
            }
            return mlMultiArray
        } catch {
            throw EmbeddingServiceError.embeddingGenerationFailed(error)
        }
    }

    /// Returns the dimension of the generated embeddings.
    func getEmbeddingDimension() -> Int {
        // We can get the dimension directly from the NLEmbedding instance
        return embedding?.dimension ?? 0
    }
}

// MARK: - MLMultiArray Persistence Utilities

extension MLMultiArray {
    /// Converts an `MLMultiArray` instance to `Data` for persistence.
    /// Uses `NSKeyedArchiver` for secure coding, as `MLMultiArray` conforms to `NSSecureCoding`.
    /// - Returns: `Data` representation of the `MLMultiArray`.
    /// - Throws: An error if archiving fails.
    func toData() throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(self, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// Creates an `MLMultiArray` instance from `Data`.
    /// Uses `NSKeyedUnarchiver` to decode the archived data.
    /// - Parameter data: The `Data` containing the archived `MLMultiArray`.
    /// - Returns: An optional `MLMultiArray` if decoding is successful.
    /// - Throws: An error if unarchiving fails.
    static func fromData(_ data: Data) throws -> MLMultiArray? {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true // Must be true for NSSecureCoding
        let multiArray = unarchiver.decodeObject(of: MLMultiArray.self, forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        return multiArray
    }
}
