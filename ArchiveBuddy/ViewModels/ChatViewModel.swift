import Foundation

/// Orchestrates a single chat session: sending messages, streaming responses,
/// persisting history, and triggering title generation on the first exchange.
@MainActor
@Observable
final class ChatViewModel {

    // MARK: - Observable state

    var messages: [ChatMessage] = []
    var session: ChatSession
    var isSending: Bool = false

    // MARK: - Dependencies

    private let db: DatabaseManager
    private let llm: LLM
    private let archiveQueryService: ArchiveQueryService

    init(session: ChatSession, db: DatabaseManager, llm: LLM, archiveQueryService: ArchiveQueryService) {
        self.session = session
        self.db = db
        self.llm = llm
        self.archiveQueryService = archiveQueryService
        self.messages = llm.loadMessages(for: session.id)
        llm.switchToSession(session)
    }

    // MARK: - Sending messages

    func sendMessage(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isSending else { return }

        isSending = true
        defer { isSending = false }
        let isFirstMessage = messages.isEmpty

        // 1. Persist and display user message immediately
        let userMessage = ChatMessage(
            sessionId: session.id,
            text: text,
            isUser: true
        )
        try? db.insertMessage(userMessage)
        messages.append(userMessage)

        // 2. Fan out RAG retrieval across selected archives
        let queryResult = await archiveQueryService.query(
            text,
            archiveIds: session.selectedArchiveIds
        )

        // 3. Stream LLM response (updates llm.streamingResponse live for UI)
        let responseText = await llm.streamResponse(
            to: queryResult.augmentedPrompt,
            sessionId: session.id
        )

        // 4. Persist and display assistant message with citations
        let assistantMessage = ChatMessage(
            sessionId: session.id,
            text: responseText,
            isUser: false,
            citations: queryResult.citations.isEmpty ? nil : queryResult.citations
        )
        try? db.insertMessage(assistantMessage)
        messages.append(assistantMessage)

        // 5. Generate and save a title after the first exchange
        if isFirstMessage {
            let title = await llm.generateTitle(from: responseText, sessionId: session.id)
            try? db.updateSessionTitle(title, sessionId: session.id)
            session.title = title
        }

        // 6. Bump updatedAt so this session sorts to the top of the list
        try? db.touchSession(session.id)
    }
}
