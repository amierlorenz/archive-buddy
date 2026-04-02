import Testing
import Foundation
@testable import ArchiveBuddy

// MARK: - ChatViewModel send-message tests

/// Tests ChatViewModel.sendMessage in isolation.
/// Uses an in-memory DatabaseManager and MockGenerationSession so no Apple Intelligence
/// or SVDB state is required. ChatSessions are created with empty selectedArchiveIds so
/// ArchiveQueryService returns the raw query text without touching SVDB.
@Suite("ChatViewModel message sending")
@MainActor
struct ChatViewModelTests {

    // MARK: - Fixtures

    let db: DatabaseManager
    let archiveQueryService: ArchiveQueryService

    init() {
        db = DatabaseManager.preview()
        archiveQueryService = ArchiveQueryService(db: db)
    }

    /// Creates and persists a ChatSession with no archives so RAG is bypassed.
    private func makeChat() throws -> ChatSession {
        let session = ChatSession(title: "", selectedArchiveIds: [])
        try db.insertChatSession(session)
        return session
    }

    /// Builds an LLM whose factory always returns the same mock session.
    private func llm(responding session: MockGenerationSession) -> LLM {
        LLM(db: db, makeSession: { session })
    }

    // MARK: - isSending invariants

    @Test("isSending is false after a successful send")
    func isSendingFalseAfterSuccess() async throws {
        let chat = try makeChat()
        let vm = ChatViewModel(
            session: chat,
            db: db,
            llm: llm(responding: MockGenerationSession(behavior: .succeed("hello"))),
            archiveQueryService: archiveQueryService
        )

        await vm.sendMessage("test")

        #expect(vm.isSending == false, "isSending must be false after the response completes")
    }

    @Test("isSending is false after an LLM error")
    func isSendingFalseAfterError() async throws {
        struct TestError: Error {}
        let chat = try makeChat()
        let vm = ChatViewModel(
            session: chat,
            db: db,
            llm: llm(responding: MockGenerationSession(behavior: .fail(TestError()))),
            archiveQueryService: archiveQueryService
        )

        await vm.sendMessage("test")

        #expect(vm.isSending == false, "isSending must be false even when the LLM returns an error")
    }

    @Test("isSending is false after a rate-limit error")
    func isSendingFalseAfterRateLimit() async throws {
        let chat = try makeChat()
        let vm = ChatViewModel(
            session: chat,
            db: db,
            llm: llm(responding: MockGenerationSession(behavior: .fail(GenerationSessionError.rateLimited))),
            archiveQueryService: archiveQueryService
        )

        await vm.sendMessage("test")

        #expect(vm.isSending == false)
    }

    @Test(
        "isSending is false after double context-window overflow",
        .bug("https://github.com/AmierD/archive-buddy/issues/12")
    )
    func isSendingFalseAfterDoubleOverflow() async throws {
        let chat = try makeChat()
        let overflowing = MockGenerationSession(behavior: .fail(GenerationSessionError.exceededContextWindowSize))
        overflowing.condensedBehavior = .fail(GenerationSessionError.exceededContextWindowSize)

        let vm = ChatViewModel(
            session: chat,
            db: db,
            llm: LLM(db: db, makeSession: { overflowing }),
            archiveQueryService: archiveQueryService
        )

        await vm.sendMessage("first")

        #expect(vm.isSending == false, "isSending must reset even after double context overflow")
    }

    // MARK: - Message accumulation

    @Test("Successful send appends one user and one assistant message")
    func successfulSendAppendsMessages() async throws {
        let chat = try makeChat()
        let vm = ChatViewModel(
            session: chat,
            db: db,
            llm: llm(responding: MockGenerationSession(behavior: .succeed("assistant reply"))),
            archiveQueryService: archiveQueryService
        )

        await vm.sendMessage("hello")

        #expect(vm.messages.count == 2)
        let userMsg = try #require(vm.messages.first)
        #expect(userMsg.isUser == true)
        #expect(userMsg.text == "hello")
        let assistantMsg = try #require(vm.messages.last)
        #expect(assistantMsg.isUser == false)
        #expect(assistantMsg.text == "assistant reply")
    }

    @Test("Error response is still persisted as an assistant message")
    func errorResponsePersistedAsAssistantMessage() async throws {
        struct TestError: Error {}
        let chat = try makeChat()
        let vm = ChatViewModel(
            session: chat,
            db: db,
            llm: llm(responding: MockGenerationSession(behavior: .fail(TestError()))),
            archiveQueryService: archiveQueryService
        )

        await vm.sendMessage("test")

        #expect(vm.messages.count == 2, "Even error responses must be saved so the user sees feedback")
        let assistantMsg = try #require(vm.messages.last)
        #expect(assistantMsg.isUser == false)
        #expect(assistantMsg.text.contains("Something went wrong"))
    }

    @Test("Messages from multiple sends accumulate in order")
    func messagesAccumulateInOrder() async throws {
        let chat = try makeChat()
        let vm = ChatViewModel(
            session: chat,
            db: db,
            llm: LLM(db: db, makeSession: { MockGenerationSession(behavior: .succeed("reply")) }),
            archiveQueryService: archiveQueryService
        )

        await vm.sendMessage("one")
        await vm.sendMessage("two")
        await vm.sendMessage("three")

        // 3 pairs of (user + assistant) = 6 messages
        #expect(vm.messages.count == 6)
        #expect(vm.isSending == false)
    }

    // MARK: - Guard conditions

    @Test("Whitespace-only messages are rejected without sending")
    func whitespaceMessageRejected() async throws {
        let chat = try makeChat()
        let vm = ChatViewModel(
            session: chat,
            db: db,
            llm: llm(responding: MockGenerationSession(behavior: .succeed("reply"))),
            archiveQueryService: archiveQueryService
        )

        await vm.sendMessage("   \n\t  ")

        #expect(vm.messages.isEmpty, "Whitespace message must be rejected before hitting the LLM")
        #expect(vm.isSending == false)
    }

    @Test("Empty string is rejected without sending")
    func emptyStringRejected() async throws {
        let chat = try makeChat()
        let vm = ChatViewModel(
            session: chat,
            db: db,
            llm: llm(responding: MockGenerationSession(behavior: .succeed("reply"))),
            archiveQueryService: archiveQueryService
        )

        await vm.sendMessage("")

        #expect(vm.messages.isEmpty)
    }

    // MARK: - Recovery

    @Test(
        "Chat recovers after double overflow: subsequent message succeeds",
        .bug("https://github.com/AmierD/archive-buddy/issues/12")
    )
    func chatRecoveryAfterDoubleOverflow() async throws {
        let chat = try makeChat()

        let session1 = MockGenerationSession(behavior: .fail(GenerationSessionError.exceededContextWindowSize))
        session1.condensedBehavior = .fail(GenerationSessionError.exceededContextWindowSize)

        let session2 = MockGenerationSession(behavior: .succeed(""))   // generateTitle (result discarded)

        // Each makeSession() call gets the next session from the queue.
        // session1 → first streamResponse (double overflow)
        // session2 → generateTitle after the first exchange (isFirstMessage = true)
        // session3 → second streamResponse (succeeds with "recovered")
        let session3 = MockGenerationSession(behavior: .succeed("recovered"))
        var sessionQueue = [session1, session2, session3] as [MockGenerationSession]
        let vm = ChatViewModel(
            session: chat,
            db: db,
            llm: LLM(db: db, makeSession: {
                sessionQueue.isEmpty
                    ? MockGenerationSession(behavior: .succeed(""))
                    : sessionQueue.removeFirst()
            }),
            archiveQueryService: archiveQueryService
        )

        await vm.sendMessage("first")
        let firstAssistant = try #require(vm.messages.last)
        #expect(firstAssistant.text.contains("Something went wrong"), "First message should show overflow error")

        await vm.sendMessage("second")
        let secondAssistant = try #require(vm.messages.last)
        #expect(secondAssistant.text == "recovered", "Chat must be fully usable after recovery")
        #expect(vm.isSending == false)
    }
}
