import Foundation
import SVDB

@MainActor
@Observable
final class ArchiveListViewModel {

    var archives: [Archive] = []

    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    // MARK: - Load

    func loadArchives() {
        archives = (try? db.fetchAllArchives()) ?? []
    }

    // MARK: - Create

    func createArchive(title: String, description: String?) throws {
        let archive = Archive(
            id: UUID(),
            title: title,
            description: description,
            createdAt: Date()
        )
        try db.insertArchive(archive)
        loadArchives()
    }

    // MARK: - Update

    func updateArchive(_ archive: Archive) throws {
        try db.updateArchive(archive)
        loadArchives()
    }

    // MARK: - Delete

    /// Deletes the archive and cleans up its SVDB collection.
    /// DB cascade handles pages and pageChunks automatically.
    /// Chat sessions whose selectedArchiveIds include this archive's id
    /// are not cleaned up automatically — post-MVP responsibility.
    func deleteArchive(_ archive: Archive) {
        // Clear documents and release the in-memory collection handle
        SVDB.shared.getCollection(archive.svdbCollectionName)?.clear()
        SVDB.shared.releaseCollection(archive.svdbCollectionName)

        // Delete the persisted SVDB file from disk
        if let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let fileURL = documentsDir
                .appendingPathComponent("SVDB")
                .appendingPathComponent("\(archive.svdbCollectionName).json")
            try? FileManager.default.removeItem(at: fileURL)
        }

        // Delete from DB — cascades to pages and pageChunks
        try? db.deleteArchive(id: archive.id)
        loadArchives()
    }
}
