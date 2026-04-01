import Foundation

@MainActor
@Observable
final class ChatListViewModel {

    var sessions: [ChatSession] = []

    private let db: DatabaseManager

    init(db: DatabaseManager) {
        self.db = db
    }

    func loadSessions() {
        sessions = (try? db.fetchAllChatSessions()) ?? []
    }

    /// Creates a new ChatSession with the given archives, persists it, and returns it
    /// so the caller can navigate directly into the chat.
    func createSession(selectedArchiveIds: [UUID]) throws -> ChatSession {
        let session = ChatSession(title: "", selectedArchiveIds: selectedArchiveIds)
        try db.insertChatSession(session)
        loadSessions()
        return session
    }

    func deleteSession(_ session: ChatSession) {
        try? db.deleteChatSession(id: session.id)
        loadSessions()
    }
}
