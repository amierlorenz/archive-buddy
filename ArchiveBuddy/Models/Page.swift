// Requires: groue/GRDB.swift added via SPM (File > Add Package Dependencies in Xcode)

import Foundation
import GRDB

struct Page: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "pages" }

    var id: UUID
    var archiveId: UUID
    /// Auto-assigned by DatabaseManager.insertPage() inside a write transaction.
    /// Never set by the caller — use PageDraft to create pages.
    var pageNumber: Int
    /// The date the user originally wrote this entry in their physical journal.
    var userDefinedDate: Date
    var uploadedAt: Date
    /// The single persisted text for this page.
    /// If the user edited during review: their edited text.
    /// If the user accepted without editing: the FM-cleaned OCR text.
    /// rawOCRText, cleanedText, and wordConfidenceMap are transient and never stored.
    var finalText: String
    var isEmbedded: Bool
}
