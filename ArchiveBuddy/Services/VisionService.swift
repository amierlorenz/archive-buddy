import Foundation
import Vision
import UIKit // For UIImage, but Vision operates on CGImage internally

enum VisionServiceError: Error, LocalizedError {
    case imageProcessingFailed
    case textRecognitionFailed(Error)
    case noTextDetected

    var errorDescription: String? {
        switch self {
        case .imageProcessingFailed:
            return "Failed to process the image for text recognition."
        case .textRecognitionFailed(let error):
            return "Text recognition failed: \(error.localizedDescription)"
        case .noTextDetected:
            return "No text was detected in the image."
        }
    }
}

class VisionService {
    /// Recognizes text in a given UIImage using VNRecognizeTextRequest.
    /// - Parameter image: The UIImage to perform OCR on.
    /// - Returns: A String containing the recognized text, joined by newlines.
    func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw VisionServiceError.imageProcessingFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: VisionServiceError.textRecognitionFailed(error))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation],
                      !observations.isEmpty else {
                    continuation.resume(throwing: VisionServiceError.noTextDetected)
                    return
                }

                // Extract and join recognized text
                let recognizedText = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")

                continuation.resume(returning: recognizedText)
            }

            // Configure the text recognition request
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"] // Assuming English, can be made configurable later

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: VisionServiceError.textRecognitionFailed(error))
            }
        }
    }
}
