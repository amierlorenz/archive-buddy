import Foundation
import Vision
import FoundationModels

/// Stateless OCR pipeline: Vision text recognition → FoundationModels cleanup.
/// Photos are never written to disk at any stage.
/// All intermediate data (rawOCRText, wordConfidenceMap) exists only in memory.
@Observable
final class OCRPipeline {

    // TUNE: words with confidence below this threshold are highlighted in the review UI
    static let confidenceHighlightThreshold: Float = 0.5

    // MARK: - Public interface

    /// Runs the full two-stage pipeline on a single image.
    /// Stage 1: VNRecognizeTextRequest (.accurate) → rawOCRText + wordConfidenceMap
    /// Stage 2: FoundationModels cleanup pass → cleanedText
    /// Returns OCRResult to the ViewModel; nothing is persisted here.
    func process(image: CGImage) async throws -> OCRResult {
        let (rawText, wordConfidenceMap) = try await recognizeText(in: image)
        let cleanedText = try await cleanText(rawText)
        return OCRResult(cleanedText: cleanedText, wordConfidenceMap: wordConfidenceMap)
    }

    // MARK: - Stage 1: Vision OCR

    private func recognizeText(in image: CGImage) async throws -> (rawText: String, wordConfidenceMap: [String: Float]) {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: ("", [:]))
                    return
                }

                var lines: [String] = []
                var wordConfidenceMap: [String: Float] = [:]

                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    lines.append(candidate.string)

                    // Assign the observation's line-level confidence to each word in that line.
                    // Words appearing in multiple observations keep their highest score.
                    let words = candidate.string
                        .lowercased()
                        .components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                    for word in words {
                        let existing = wordConfidenceMap[word] ?? 0
                        wordConfidenceMap[word] = max(existing, candidate.confidence)
                    }
                }

                let rawText = lines.joined(separator: "\n")
                continuation.resume(returning: (rawText, wordConfidenceMap))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false  // FM cleanup handles correction; skip double-processing

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Stage 2: FoundationModels cleanup

    private func cleanText(_ rawText: String) async throws -> String {
        guard !rawText.isEmpty else { return rawText }

        let session = LanguageModelSession()
        let prompt = """
            Here is OCR text extracted from a handwritten journal. \
            Correct obvious errors without changing the meaning. \
            Return only the corrected text.

            \(rawText)
            """

        var result = rawText  // fallback: return raw if FM fails or produces empty output
        let responseStream = session.streamResponse(to: prompt)
        for try await partial in responseStream {
            result = partial.content
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? rawText : trimmed
    }
}

// MARK: - OCRResult

struct OCRResult {
    /// FM-cleaned text, ready for user review and eventual embedding.
    let cleanedText: String
    /// Per-word confidence scores from VNRecognizeTextRequest.
    /// Keys are lowercased words; values are in [0, 1].
    /// Used by the review UI to highlight low-confidence words.
    let wordConfidenceMap: [String: Float]
}
