import Foundation
import SwiftData

@Model
final class JournalEntry {
    @Attribute(.unique) var id: UUID
    var date: Date
    var rawText: String
    var imagePath: String // Path to the HEIC image file
    var journalTitle: String? // Optional title for the journal entry
    var embedding: Data? // New: Stores the MLMultiArray embedding as Data

    init(id: UUID = UUID(), date: Date = .now, rawText: String, imagePath: String, journalTitle: String? = nil, embedding: Data? = nil) {
        self.id = id
        self.date = date
        self.rawText = rawText
        self.imagePath = imagePath
        self.journalTitle = journalTitle
        self.embedding = embedding // Initialize the new property
    }
}
