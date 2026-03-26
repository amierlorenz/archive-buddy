// Requires: groue/GRDB.swift added via SPM (File > Add Package Dependencies in Xcode)

import Foundation
import GRDB

struct Archive: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "archives" }

    var id: UUID
    var title: String
    var description: String?
    var createdAt: Date

    /// The name of this archive's SVDB collection. Derived from id — never stored in the DB.
    var svdbCollectionName: String { id.uuidString }

    // Exclude svdbCollectionName from Codable synthesis so GRDB doesn't try to persist it.
    private enum CodingKeys: String, CodingKey {
        case id, title, description, createdAt
    }
}
