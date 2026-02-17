import Foundation
import SwiftUI
import SwiftData
import AVFoundation
import FoundationModels // New: Import FoundationModels

enum AIProcessingError: Error, LocalizedError {
    case languageModelNotAvailable
    case generationFailed(Error)
    case noTextGenerated

    var errorDescription: String? {
        switch self {
        case .languageModelNotAvailable:
            return "The system language model is not available on this device or iOS version."
        case .generationFailed(let error):
            return "AI text refinement failed: \(error.localizedDescription)"
        case .noTextGenerated:
            return "The AI did not generate any refined text."
        }
    }
}

/// ViewModel to manage the state and logic for the scanning and review flow.
@Observable
final class ScanViewModel {
    // MARK: - Dependencies
    private let modelContext: ModelContext // Changed to be a direct dependency as per user's init
    private let visionService: VisionService
    private let imageStorageService: ImageStorageService
    private var languageModelSession: LanguageModelSession? // New: For FoundationModels

    // MARK: - UI State
    var showingImagePicker: Bool = false
    var pickedImage: UIImage?
    var recognizedText: String = ""
    var originalText: String = "" // New: Stores text before AI refinement
    var currentImagePath: String?
    var showingReviewScreen: Bool = false
    var isLoading: Bool = false
    var errorMessage: String?
    var hasUsedAI: Bool = false // New: Flag to restrict AI use

    // MARK: - Initialization
    /// Initializes ScanViewModel with its required dependencies.
    /// - Parameters:
    ///   - modelContext: The SwiftData model context for persistence.
    ///   - visionService: The service for OCR operations.
    ///   - imageStorageService: The service for storing images.
    init(modelContext: ModelContext, visionService: VisionService = VisionService(), imageStorageService: ImageStorageService = ImageStorageService()) {
        self.modelContext = modelContext
        self.visionService = visionService
        self.imageStorageService = imageStorageService
        // Initialize LanguageModelSession if the system language model is available
        if SystemLanguageModel.default.isAvailable {
            self.languageModelSession = LanguageModelSession()
        }
    }

    // MARK: - Actions

    /// Captures a photo, stores it, performs OCR, and then transitions to the review screen.
    /// - Parameter image: The UIImage captured from the camera.
    func capturePhoto(image: UIImage) async {
        isLoading = true
        errorMessage = nil
        pickedImage = image
        showingImagePicker = false // Dismiss the image picker immediately

        do {
            // 1. Store the image locally as HEIC
            let path = try await imageStorageService.saveImage(image)
            self.currentImagePath = path

            // 2. Perform OCR on the image
            let text = try await visionService.recognizeText(in: image)
            self.recognizedText = text
            self.originalText = text // Set original text upon first recognition
            self.hasUsedAI = false // Reset AI usage flag for a new scan
            self.showingReviewScreen = true // Show the review screen
        } catch {
            errorMessage = error.localizedDescription
            print("Error during photo capture or OCR: \(error)")
        }
        isLoading = false
    }

    /// Refines the recognized text using an on-device AI model.
    func refineText() async {
        guard !hasUsedAI else {
            errorMessage = "AI refinement can only be used once per scan. Revert to original to try again."
            return
        }

        guard let session = languageModelSession else {
            errorMessage = AIProcessingError.languageModelNotAvailable.localizedDescription
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let prompt = """
                You are an expert editor specializing in transcribing messy, handwritten journals about various topics.

                Task: Refine the following OCR-extracted text.

                Correct spelling and grammar errors typical of OCR (e.g., 'ts' to 'is', 'outlie' to 'outline').

                Use context clues to fill in logical gaps or illegible words.
                
                Use context clues to make incoherent sentences coherent.

                Maintain the original list structure and informal tone.

                Output ONLY the cleaned text with no intro or outro.

                Current Text to Process: \(recognizedText)
                """
            
            let result = try await session.respond(to: prompt)

            let aiOutput = result.content

            self.recognizedText = aiOutput
            self.hasUsedAI = true // Mark that AI has been used
            print("AI refinement successful.")
        } catch {
            errorMessage = AIProcessingError.generationFailed(error).localizedDescription
            print("AI refinement failed: \(error.localizedDescription)")
        }
        isLoading = false
    }

    /// Reverts the recognized text to its original pre-AI state.
    func revertToOriginal() {
        if hasUsedAI { // Only revert if AI was actually used
            self.recognizedText = self.originalText
            self.hasUsedAI = false // Allow re-attempting AI refinement
            self.errorMessage = nil // Clear any previous AI error messages
            print("Text reverted to original.")
        }
    }

    /// Saves the current journal entry to SwiftData.
    /// - Parameter title: An optional title for the journal entry.
    func saveJournalEntry(title: String?) async {
        isLoading = true
        errorMessage = nil
        guard let imagePath = currentImagePath else {
            errorMessage = "No image path found to save. Please scan again."
            isLoading = false
            return
        }

        let newEntry = JournalEntry(rawText: recognizedText, imagePath: imagePath, journalTitle: title)

        do {
            modelContext.insert(newEntry)
            try modelContext.save() // Explicitly save the context
            resetScanState() // Clear state and dismiss review screen
            print("Journal entry saved successfully!")
        } catch {
            errorMessage = "Failed to save journal entry: \(error.localizedDescription)"
            print("Error saving entry: \(error)")
        }
        isLoading = false
    }

    /// Discards the current scan, clearing all temporary state.
    func discardScan() {
        resetScanState()
    }

    /// Resets all temporary state variables related to the scanning process.
    private func resetScanState() {
        pickedImage = nil
        recognizedText = ""
        originalText = "" // Reset originalText as well
        currentImagePath = nil
        showingReviewScreen = false
        isLoading = false
        errorMessage = nil
        hasUsedAI = false // Reset AI usage flag
    }
}
