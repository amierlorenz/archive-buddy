// Requires: groue/GRDB.swift added via SPM

import Foundation
import GRDB

@Observable
final class DatabaseManager {

    private let dbQueue: DatabaseQueue

    init() {
        do {
            let path = try Self.databasePath()
            dbQueue = try DatabaseQueue(path: path)
            try Self.migrate(dbQueue)
        } catch {
            fatalError("DatabaseManager failed to initialize: \(error)")
        }
    }

    private static func databasePath() throws -> String {
        let dir = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("archive_buddy.sqlite3").path
    }
}

// MARK: - Migrations

private extension DatabaseManager {

    static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        // During development, wipe and re-create the DB if the schema changes.
        // This is safe because eraseDatabaseOnSchemaChange is a no-op in release builds
        // when the schema matches. Remove before shipping to production.
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            try db.create(table: "archives") { t in
                t.column("id", .blob).primaryKey()
                t.column("title", .text).notNull()
                t.column("description", .text)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "pages") { t in
                t.column("id", .blob).primaryKey()
                t.column("archiveId", .blob).notNull()
                    .references("archives", onDelete: .cascade)
                t.column("pageNumber", .integer).notNull()
                t.column("userDefinedDate", .datetime).notNull()
                t.column("uploadedAt", .datetime).notNull()
                t.column("finalText", .text).notNull()
                t.column("isEmbedded", .boolean).notNull().defaults(to: false)
            }

            // Stores chunk text in SQL so the SVDB collection can be fully rebuilt
            // from scratch if the vector store is lost or corrupted.
            try db.create(table: "pageChunks") { t in
                t.column("id", .blob).primaryKey()
                t.column("pageId", .blob).notNull()
                    .references("pages", onDelete: .cascade)
                t.column("archiveId", .blob).notNull()
                t.column("chunkText", .text).notNull()
                t.column("chunkIndex", .integer).notNull()
                t.column("isEmbedded", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "chatSessions") { t in
                t.column("id", .blob).primaryKey()
                t.column("title", .text).notNull()
                t.column("selectedArchiveIds", .text).notNull().defaults(to: "[]")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("transcriptJSON", .text).notNull().defaults(to: "")
            }

            try db.create(table: "chatMessages") { t in
                t.column("id", .blob).primaryKey()
                t.column("sessionId", .blob).notNull()
                    .references("chatSessions", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("isUser", .boolean).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("citations", .text)  // JSON blob, nullable
            }
        }

        try migrator.migrate(dbQueue)
    }
}

// MARK: - Private record type for pageChunks

private extension DatabaseManager {

    struct PageChunkRecord: Codable, FetchableRecord, PersistableRecord {
        static var databaseTableName: String { "pageChunks" }
        var id: UUID
        var pageId: UUID
        var archiveId: UUID
        var chunkText: String
        var chunkIndex: Int
        var isEmbedded: Bool
    }
}

// MARK: - Archives

extension DatabaseManager {

    func fetchAllArchives() throws -> [Archive] {
        try dbQueue.read { db in
            try Archive.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    func fetchArchive(id: UUID) throws -> Archive? {
        try dbQueue.read { db in
            try Archive.fetchOne(db, key: id)
        }
    }

    func insertArchive(_ archive: Archive) throws {
        try dbQueue.write { db in
            try archive.insert(db)
        }
    }

    func updateArchive(_ archive: Archive) throws {
        try dbQueue.write { db in
            try archive.update(db)
        }
    }

    /// Deletes the archive and cascades to pages, pageChunks, and chatSessions rows
    /// that reference it via selectedArchiveIds are NOT automatically cleaned up —
    /// that is the caller's responsibility (ArchiveListViewModel).
    /// The SVDB collection for this archive must also be deleted separately by the caller.
    func deleteArchive(id: UUID) throws {
        try dbQueue.write { db in
            _ = try Archive.deleteOne(db, key: id)
        }
    }
}

// MARK: - Pages

extension DatabaseManager {

    /// Creates a Page from a PageDraft, assigning pageNumber atomically inside a
    /// write transaction to prevent duplicate numbers from concurrent batch inserts.
    func insertPage(_ draft: PageDraft) throws -> Page {
        try dbQueue.write { db in
            let nextNumber = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(pageNumber), 0) + 1 FROM pages WHERE archiveId = ?",
                arguments: [draft.archiveId]
            ) ?? 1

            let page = Page(
                id: UUID(),
                archiveId: draft.archiveId,
                pageNumber: nextNumber,
                userDefinedDate: draft.userDefinedDate,
                uploadedAt: Date(),
                finalText: draft.finalText,
                isEmbedded: false
            )
            try page.insert(db)
            return page
        }
    }

    func fetchPages(archiveId: UUID) throws -> [Page] {
        try dbQueue.read { db in
            try Page
                .filter(Column("archiveId") == archiveId)
                .order(Column("pageNumber").asc)
                .fetchAll(db)
        }
    }

    func fetchPage(id: UUID) throws -> Page? {
        try dbQueue.read { db in
            try Page.fetchOne(db, key: id)
        }
    }

    func markPageAsEmbedded(_ pageId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE pages SET isEmbedded = 1 WHERE id = ?",
                arguments: [pageId]
            )
        }
    }

    func deletePage(id: UUID) throws {
        try dbQueue.write { db in
            _ = try Page.deleteOne(db, key: id)
        }
    }
}

// MARK: - Page Chunks

extension DatabaseManager {

    /// Inserts a chunk and returns its assigned id for later reference (e.g. markChunkAsEmbedded).
    @discardableResult
    func insertPageChunk(pageId: UUID, archiveId: UUID, chunkText: String, chunkIndex: Int) throws -> UUID {
        try dbQueue.write { db in
            let record = PageChunkRecord(
                id: UUID(),
                pageId: pageId,
                archiveId: archiveId,
                chunkText: chunkText,
                chunkIndex: chunkIndex,
                isEmbedded: false
            )
            try record.insert(db)
            return record.id
        }
    }

    func markChunkAsEmbedded(_ chunkId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE pageChunks SET isEmbedded = 1 WHERE id = ?",
                arguments: [chunkId]
            )
        }
    }

    /// Returns all unembedded chunks for an archive — used to rebuild a lost SVDB collection.
    func fetchUnembeddedChunks(archiveId: UUID) throws -> [(id: UUID, text: String)] {
        try dbQueue.read { db in
            let records = try PageChunkRecord
                .filter(Column("archiveId") == archiveId && Column("isEmbedded") == false)
                .order(Column("chunkIndex").asc)
                .fetchAll(db)
            return records.map { ($0.id, $0.chunkText) }
        }
    }

    /// Returns all chunks for an archive — used to fully rebuild the SVDB collection from scratch.
    func fetchAllChunks(archiveId: UUID) throws -> [(id: UUID, text: String)] {
        try dbQueue.read { db in
            let records = try PageChunkRecord
                .filter(Column("archiveId") == archiveId)
                .order(Column("chunkIndex").asc)
                .fetchAll(db)
            return records.map { ($0.id, $0.chunkText) }
        }
    }
}

// MARK: - Chat Sessions

extension DatabaseManager {

    func fetchAllChatSessions() throws -> [ChatSession] {
        try dbQueue.read { db in
            try ChatSession.order(Column("updatedAt").desc).fetchAll(db)
        }
    }

    func fetchChatSession(id: UUID) throws -> ChatSession? {
        try dbQueue.read { db in
            try ChatSession.fetchOne(db, key: id)
        }
    }

    func insertChatSession(_ session: ChatSession) throws {
        try dbQueue.write { db in
            try session.insert(db)
        }
    }

    func updateChatSession(_ session: ChatSession) throws {
        try dbQueue.write { db in
            try session.update(db)
        }
    }

    func deleteChatSession(id: UUID) throws {
        try dbQueue.write { db in
            _ = try ChatSession.deleteOne(db, key: id)
        }
    }

    func updateTranscriptJSON(_ json: String, sessionId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE chatSessions SET transcriptJSON = ?, updatedAt = ? WHERE id = ?",
                arguments: [json, Date(), sessionId]
            )
        }
    }

    func updateSessionTitle(_ title: String, sessionId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE chatSessions SET title = ?, updatedAt = ? WHERE id = ?",
                arguments: [title, Date(), sessionId]
            )
        }
    }

    func touchSession(_ sessionId: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE chatSessions SET updatedAt = ? WHERE id = ?",
                arguments: [Date(), sessionId]
            )
        }
    }
}

// MARK: - Chat Messages

extension DatabaseManager {

    func insertMessage(_ message: ChatMessage) throws {
        try dbQueue.write { db in
            try message.insert(db)
        }
    }

    func fetchMessages(sessionId: UUID) throws -> [ChatMessage] {
        try dbQueue.read { db in
            try ChatMessage
                .filter(Column("sessionId") == sessionId)
                .order(Column("timestamp").asc)
                .fetchAll(db)
        }
    }

    func deleteMessages(sessionId: UUID) throws {
        try dbQueue.write { db in
            _ = try ChatMessage
                .filter(Column("sessionId") == sessionId)
                .deleteAll(db)
        }
    }
}
