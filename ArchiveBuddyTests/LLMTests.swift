import Testing
import Foundation
@testable import ArchiveBuddy

// MARK: - LLM generation tests

/// Tests LLM.streamResponse in isolation using MockGenerationSession.
/// Because LLM now creates a fresh session per call, all paths can be exercised
/// without Apple Intelligence on the test host.
@Suite("LLM generation")
@MainActor
struct LLMTests {

    // MARK: - Fixtures

    let db: DatabaseManager

    init() {
        db = DatabaseManager.preview()
    }

    /// Inserts a minimal ChatSession and returns it.
    private func makeChat() throws -> ChatSession {
        let session = ChatSession(title: "", selectedArchiveIds: [])
        try db.insertChatSession(session)
        return session
    }

    /// Builds an LLM whose factory dispenses sessions from the given array in order.
    /// Any call beyond the array returns a session that succeeds with "".
    private func llm(sessions: [MockGenerationSession]) -> LLM {
        var remaining = sessions
        return LLM(db: db, makeSession: {
            remaining.isEmpty
                ? MockGenerationSession(behavior: .succeed(""))
                : remaining.removeFirst()
        })
    }

    // MARK: - Happy path

    @Test("Normal response streams text and resets isResponding")
    func normalResponse() async throws {
        let chat = try makeChat()
        let sut = llm(sessions: [MockGenerationSession(behavior: .succeed("hello world"))])

        let response = await sut.streamResponse(to: "hi", sessionId: chat.id)

        #expect(response == "hello world", "Response should match the streamed token")
        #expect(sut.isResponding == false, "isResponding must be false after completion")
        #expect(sut.streamingResponse == "", "streamingResponse must be cleared after completion")
    }

    @Test("Each call gets a fresh session — no cross-turn transcript accumulation")
    func eachCallGetsFreshSession() async throws {
        let chat = try makeChat()
        var callCount = 0
        let sut = LLM(db: db, makeSession: {
            callCount += 1
            return MockGenerationSession(behavior: .succeed("reply \(callCount)"))
        })

        _ = await sut.streamResponse(to: "turn 1", sessionId: chat.id)
        _ = await sut.streamResponse(to: "turn 2", sessionId: chat.id)
        _ = await sut.streamResponse(to: "turn 3", sessionId: chat.id)

        // Expect 3 calls (1 per streamResponse) plus 0 title generation calls
        // since we're calling streamResponse directly, not via ChatViewModel.
        #expect(callCount == 3, "A fresh session must be created for every call, preventing transcript accumulation")
    }

    // MARK: - History injection

    @Test("Prior messages are injected as conversation history in the prompt", .bug("https://github.com/AmierD/archive-buddy/issues/12"))
    func historyInjectedIntoPrompt() async throws {
        let chat = try makeChat()

        // Seed two prior messages into the DB to simulate a previous exchange.
        let userMsg = ChatMessage(sessionId: chat.id, text: "what is Rome like?", isUser: true)
        let assistantMsg = ChatMessage(sessionId: chat.id, text: "Rome is beautiful.", isUser: false)
        try db.insertMessage(userMsg)
        try db.insertMessage(assistantMsg)

        // Insert the current user turn (as ChatViewModel does before calling streamResponse).
        let currentMsg = ChatMessage(sessionId: chat.id, text: "what about Florence?", isUser: true)
        try db.insertMessage(currentMsg)

        let captureSession = MockGenerationSession(behavior: .succeed("Florence is lovely."))
        let sut = LLM(db: db, makeSession: { captureSession })

        let augmentedPrompt = "Context:\nsome archive text\n\nQuestion: what about Florence?\n\nAnswer:"
        _ = await sut.streamResponse(to: augmentedPrompt, sessionId: chat.id)

        let receivedPrompt = try #require(captureSession.lastReceivedPrompt, "Session must receive a prompt")
        #expect(receivedPrompt.contains("Previous conversation:"), "Prompt must include a history section")
        #expect(receivedPrompt.contains("what is Rome like?"), "Prior user turn must appear in history")
        #expect(receivedPrompt.contains("Rome is beautiful."), "Prior assistant turn must appear in history")
        // The current user turn must appear exactly once — only in the "Question:" line,
        // not duplicated in the "Previous conversation:" block.
        let occurrences = receivedPrompt.components(separatedBy: "what about Florence?").count - 1
        #expect(occurrences == 1, "Current user message must appear exactly once (in the Question: line), not also in the history block")
    }

    @Test("First message has no history section in the prompt")
    func firstMessageHasNoHistory() async throws {
        let chat = try makeChat()

        // Insert only the current user turn — no prior exchange yet.
        let currentMsg = ChatMessage(sessionId: chat.id, text: "hello", isUser: true)
        try db.insertMessage(currentMsg)

        let captureSession = MockGenerationSession(behavior: .succeed("hi there"))
        let sut = LLM(db: db, makeSession: { captureSession })

        let augmentedPrompt = "Context:\nsome text\n\nQuestion: hello\n\nAnswer:"
        _ = await sut.streamResponse(to: augmentedPrompt, sessionId: chat.id)

        let receivedPrompt = try #require(captureSession.lastReceivedPrompt)
        #expect(receivedPrompt.contains("Previous conversation:") == false,
                "First message should not include a history section")
    }

    // MARK: - Overflow handling

    @Test("Single overflow condenses and retries successfully")
    func singleOverflowRetrySucceeds() async throws {
        let chat = try makeChat()
        let overflowing = MockGenerationSession(behavior: .fail(GenerationSessionError.exceededContextWindowSize))
        overflowing.condensedBehavior = .succeed("condensed response")
        let sut = llm(sessions: [overflowing])

        let response = await sut.streamResponse(to: "hi", sessionId: chat.id)

        #expect(response == "condensed response")
        #expect(sut.isResponding == false)
    }

    @Test("Double overflow returns an error message")
    func doubleOverflowReturnsError() async throws {
        let chat = try makeChat()
        let overflowing = MockGenerationSession(behavior: .fail(GenerationSessionError.exceededContextWindowSize))
        overflowing.condensedBehavior = .fail(GenerationSessionError.exceededContextWindowSize)
        let sut = llm(sessions: [overflowing])

        let response = await sut.streamResponse(to: "hi", sessionId: chat.id)

        #expect(response.contains("Something went wrong"))
        #expect(sut.isResponding == false)
    }

    @Test(
        "After double overflow, the next call creates a fresh session and succeeds",
        .bug("https://github.com/AmierD/archive-buddy/issues/12")
    )
    func subsequentCallAfterDoubleOverflowSucceeds() async throws {
        let chat = try makeChat()

        let overflowing = MockGenerationSession(behavior: .fail(GenerationSessionError.exceededContextWindowSize))
        overflowing.condensedBehavior = .fail(GenerationSessionError.exceededContextWindowSize)

        let sut = llm(sessions: [
            overflowing,                                          // call 1: overflow
            MockGenerationSession(behavior: .succeed("recovered")), // call 2: succeeds
        ])

        _ = await sut.streamResponse(to: "first", sessionId: chat.id)
        let secondResponse = await sut.streamResponse(to: "second", sessionId: chat.id)

        #expect(secondResponse == "recovered", "Session must be fully usable after double overflow")
        #expect(sut.isResponding == false)
    }

    // MARK: - Error messages

    @Test("Rate limited returns the busy-model message")
    func rateLimitedMessage() async throws {
        let chat = try makeChat()
        let sut = llm(sessions: [MockGenerationSession(behavior: .fail(GenerationSessionError.rateLimited))])

        let response = await sut.streamResponse(to: "hi", sessionId: chat.id)

        #expect(response.contains("busy"))
        #expect(sut.isResponding == false)
    }

    @Test("Unknown error returns the generic error message")
    func unknownErrorReturnsGenericMessage() async throws {
        struct UnknownError: Error {}
        let chat = try makeChat()
        let sut = llm(sessions: [MockGenerationSession(behavior: .fail(UnknownError()))])

        let response = await sut.streamResponse(to: "hi", sessionId: chat.id)

        #expect(response.contains("Something went wrong"))
        #expect(sut.isResponding == false)
    }

    // MARK: - State invariants

    @Test("streamingResponse is always empty after streamResponse returns", arguments: [
        MockGenerationSession(behavior: .succeed("hello")),
        MockGenerationSession(behavior: .fail(GenerationSessionError.rateLimited)),
        MockGenerationSession(behavior: .fail(GenerationSessionError.exceededContextWindowSize)),
    ])
    func streamingResponseAlwaysCleared(session: MockGenerationSession) async throws {
        let chat = try makeChat()
        let sut = LLM(db: db, makeSession: { session })

        _ = await sut.streamResponse(to: "test", sessionId: chat.id)

        #expect(sut.streamingResponse == "", "streamingResponse must always be cleared on return")
    }

    @Test("isResponding is always false after streamResponse returns", arguments: [
        MockGenerationSession(behavior: .succeed("hello")),
        MockGenerationSession(behavior: .fail(GenerationSessionError.rateLimited)),
        MockGenerationSession(behavior: .fail(GenerationSessionError.exceededContextWindowSize)),
    ])
    func isRespondingAlwaysFalse(session: MockGenerationSession) async throws {
        let chat = try makeChat()
        let sut = LLM(db: db, makeSession: { session })

        _ = await sut.streamResponse(to: "test", sessionId: chat.id)

        #expect(sut.isResponding == false, "isResponding must always be false on return")
    }
}
