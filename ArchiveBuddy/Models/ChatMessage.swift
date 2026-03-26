import Foundation
import GRDB

struct ChatMessage: Identifiable, Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "chatMessages" }

    var id: UUID
    var sessionId: UUID
    var text: String
    var isUser: Bool
    var timestamp: Date
    /// JSON-backed storage for citations.
    /// Private so all external access goes through the typed computed property below.
    private var citationsJSON: String?

    // MARK: - Typed access

    /// Source citations for assistant messages. nil for user messages.
    var citations: [PageCitation]? {
        get {
            guard let json = citationsJSON,
                  let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([PageCitation].self, from: data)
        }
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        text: String,
        isUser: Bool,
        timestamp: Date = Date(),
        citations: [PageCitation]? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.isUser = isUser
        self.timestamp = timestamp
        if let citations {
            self.citationsJSON = try? String(data: JSONEncoder().encode(citations), encoding: .utf8)
        } else {
            self.citationsJSON = nil
        }
    }

    // MARK: - Codable

    // Maps the private backing property to the "citations" DB column.
    // GRDB synthesizes init(row:) and encode(to:) from this — no explicit
    // implementations needed, which avoids the actor-isolation issue that
    // explicit FetchableRecord/PersistableRecord witness methods cause in Swift 6.
    private enum CodingKeys: String, CodingKey {
        case id
        case sessionId
        case text
        case isUser
        case timestamp
        case citationsJSON = "citations"
    }
}
