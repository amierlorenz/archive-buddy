import Foundation
import UIKit
import CoreGraphics // For CGImageDestination

enum ImageStorageError: Error, LocalizedError {
    case directoryCreationFailed(Error)
    case heicCompressionFailed
    case fileWritingFailed(Error)
    case invalidURL
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed(let error):
            return "Failed to create image storage directory: \(error.localizedDescription)"
        case .heicCompressionFailed:
            return "Failed to compress image to HEIC format."
        case .fileWritingFailed(let error):
            return "Failed to write image file: \(error.localizedDescription)"
        case .invalidURL:
            return "Invalid URL for image storage."
        case .fileNotFound:
            return "Image file not found at the specified path."
        }
    }
}

class ImageStorageService {
    private let fileManager: FileManager
    private let imagesDirectory: URL

    /// Initializes the ImageStorageService, ensuring the dedicated directory for images exists.
    /// Images are stored in the app's `Application Support` directory under "JournalImages".
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.imagesDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JournalImages", isDirectory: true)

        // Ensure the directory exists
        do {
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            // In a real app, you might want more robust error handling here,
            // as this is a critical setup step.
            print("Error creating images directory: \(error.localizedDescription)")
            // Potentially re-throw or crash in development, but print for now.
        }
    }

    /// Saves a UIImage as a HEIC file to the app's local file system.
    /// - Parameters:
    ///   - image: The UIImage to save.
    ///   - fileName: An optional file name. If nil, a UUID will be used.
    /// - Returns: The relative path to the saved image within the "JournalImages" directory.
    func saveImage(_ image: UIImage, fileName: String? = nil) async throws -> String {
        let uniqueFileName = fileName ?? UUID().uuidString + ".heic"
        let fileURL = imagesDirectory.appendingPathComponent(uniqueFileName)

        return try await withCheckedThrowingContinuation { continuation in
            guard let heicData = image.heicData(compressionQuality: 0.8) else {
                continuation.resume(throwing: ImageStorageError.heicCompressionFailed)
                return
            }

            do {
                try heicData.write(to: fileURL, options: .atomic)
                // Return relative path (e.g., "JournalImages/UUID.heic")
                // This path can be stored in SwiftData and easily converted back to an absolute URL.
                let relativePath = "JournalImages/\(uniqueFileName)"
                continuation.resume(returning: relativePath)
            } catch {
                continuation.resume(throwing: ImageStorageError.fileWritingFailed(error))
            }
        }
    }

    /// Loads a UIImage from the app's local file system using its relative path.
    /// - Parameter relativePath: The relative path of the image (e.g., "JournalImages/some_image.heic").
    /// - Returns: The loaded UIImage, or nil if the file cannot be found or loaded.
    func loadImage(relativePath: String) -> UIImage? {
        let absoluteURL = getAbsolutePath(relativePath: relativePath)
        return UIImage(contentsOfFile: absoluteURL.path)
    }

    /// Returns the absolute URL for a given relative image path.
    /// - Parameter relativePath: The relative path of the image.
    /// - Returns: An absolute URL pointing to the image file.
    func getAbsolutePath(relativePath: String) -> URL {
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(relativePath)
    }
}

// MARK: - UIImage Extension for HEIC Conversion

extension UIImage {
    /// Converts the UIImage into HEIC format Data.
    /// - Parameter compressionQuality: The compression quality (0.0 to 1.0). Default is 0.8.
    /// - Returns: Optional Data representing the HEIC image.
    func heicData(compressionQuality: CGFloat = 0.8) -> Data? {
        guard let mutableData = CFDataCreateMutable(nil, 0) else { return nil }
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.heic" as CFString, 1, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]

        if let cgImage = self.cgImage {
            CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                return mutableData as Data
            }
        }
        return nil
    }
}
