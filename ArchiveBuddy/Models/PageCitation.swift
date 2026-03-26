import Foundation

/// A reference to the physical journal page that a chunk of RAG context came from.
/// Not persisted as its own table — stored as a JSON blob inside ChatMessage.citations.
struct PageCitation: Identifiable, Codable, Equatable {
    var id: UUID { pageId }
    var pageId: UUID
    var archiveId: UUID
    var archiveTitle: String
    var pageNumber: Int
    var userDefinedDate: Date

    /// Human-readable summary for display in the chat UI alongside a response.
    /// Example: "Diary · Page 12 · March 3, 2024"
    var displayString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return "\(archiveTitle) · Page \(pageNumber) · \(formatter.string(from: userDefinedDate))"
    }
}
