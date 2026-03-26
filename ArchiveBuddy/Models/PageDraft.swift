import Foundation

/// Transient type used to create a new Page.
/// Excludes id, pageNumber, and uploadedAt — all of which are assigned by
/// DatabaseManager.insertPage() at insert time.
struct PageDraft {
    var archiveId: UUID
    /// The date the user originally wrote this entry in their physical journal.
    var userDefinedDate: Date
    /// Finalized text: FM-cleaned OCR output, or user-edited version if they chose to edit.
    var finalText: String
}
