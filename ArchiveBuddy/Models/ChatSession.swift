import Foundation
import GRDB

struct ChatSession: Identifiable, Codable, Equatable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "chatSessions" }

    var id: UUID
    var title: String
    /// JSON-backed storage for selectedArchiveIds.
    /// Private so all external access goes through the typed computed property below.
    private var selectedArchiveIdsJSON: String
    var createdAt: Date
    var updatedAt: Date
    /// JSON-serialized FoundationModels Transcript for session continuity.
    var transcriptJSON: String

    // MARK: - Typed access

    /// The archives this session queries. Locked at creation for MVP.
    /// Post-MVP: allow changing after creation.
    var selectedArchiveIds: [UUID] {
        get {
            (try? JSONDecoder().decode([UUID].self, from: Data(selectedArchiveIdsJSON.utf8))) ?? []
        }
        set {
            selectedArchiveIdsJSON = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "[]"
        }
    }

    var displayTitle: String {
        title.isEmpty ? "New Chat" : title
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        title: String,
        selectedArchiveIds: [UUID],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        transcriptJSON: String = ""
    ) {
        self.id = id
        self.title = title
        self.selectedArchiveIdsJSON = (try? String(data: JSONEncoder().encode(selectedArchiveIds), encoding: .utf8)) ?? "[]"
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.transcriptJSON = transcriptJSON
    }

    // MARK: - Codable

    // Maps the private backing property to the "selectedArchiveIds" DB column.
    // GRDB synthesizes init(row:) and encode(to:) from this — no explicit
    // implementations needed, which avoids the actor-isolation issue that
    // explicit FetchableRecord/PersistableRecord witness methods cause in Swift 6.
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case selectedArchiveIdsJSON = "selectedArchiveIds"
        case createdAt
        case updatedAt
        case transcriptJSON
    }
}
