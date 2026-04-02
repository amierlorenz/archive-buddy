import Testing
import Foundation
@testable import ArchiveBuddy

// MARK: - LLM generation tests

/// Tests LLM.streamResponse behavior in isolation using MockGenerationSession.
/// All paths that previously required Apple Intelligence are exercised here.
@Suite("LLM generation")
@MainActor
struct LLMTests {

    // MARK: - Fixtures

    let db: DatabaseManager

    init() {
        db = DatabaseManager.preview()
    }

    /// Inserts a minimal ChatSession into the DB and returns it.
    private func makeChat() throws -> ChatSession {
        let session = ChatSession(title: "", selectedArchiveIds: [])
        try db.insertChatSession(session)
        return session
    }

    /// Builds an LLM whose session factory dispenses sessions from the given array in order.
    /// Any factory call beyond the array's length returns a session that succeeds with "".
    private func llm(sessions: [MockGenerationSession]) -> LLM {
        var remaining = sessions
        return LLM(db: db, makeSession: { _ in
            remaining.isEmpty
                ? MockGenerationSession(behavior: .succeed(""))
                : remaining.removeFirst()
        })
    }

    // MARK: - Happy path

    @Test("Normal response returns streamed text and clears isResponding")
    func normalResponse() async throws {
        let chat = try makeChat()
        let sut = llm(sessions: [MockGenerationSession(behavior: .succeed("hello world"))])

        let response = await sut.streamResponse(to: "hi", sessionId: chat.id)

        #expect(response == "hello world", "Response should match the streamed token")
        #expect(sut.isResponding == false, "isResponding must be false after completion")
        #expect(sut.streamingResponse == "", "streamingResponse must be cleared after completion")
    }

    // MARK: - Context overflow

    @Test("Single overflow condenses transcript and retries successfully")
    func singleOverflowRetrySucceeds() async throws {
        let chat = try makeChat()
        let overflowing = MockGenerationSession(behavior: .fail(GenerationSessionError.exceededContextWindowSize))
        overflowing.condensedBehavior = .succeed("condensed response")

        let sut = llm(sessions: [overflowing])

        let response = await sut.streamResponse(to: "hi", sessionId: chat.id)

        #expect(response == "condensed response")
        #expect(sut.isResponding == false)
    }

    @Test(
        "Double overflow stores a fresh session so the next call succeeds",
        .bug("https://github.com/AmierD/archive-buddy/issues/12")
    )
    func doubleOverflowReplacesBrokenSessionWithFreshOne() async throws {
        let chat = try makeChat()

        // Session 1: overflows. Its condensed version also overflows.
        let session1 = MockGenerationSession(behavior: .fail(GenerationSessionError.exceededContextWindowSize))
        session1.condensedBehavior = .fail(GenerationSessionError.exceededContextWindowSize)

        // Session 2: the fresh session the factory creates after the double failure.
        let session2 = MockGenerationSession(behavior: .succeed("recovered"))

        // Session 3: throwaway used by generateTitle after the first (error) exchange.
        let session3 = MockGenerationSession(behavior: .succeed(""))

        let sut = llm(sessions: [session1, session2, session3])

        // First message: double overflow → error string, but isResponding still resets
        let firstResponse = await sut.streamResponse(to: "first", sessionId: chat.id)
        #expect(firstResponse.contains("Something went wrong"), "Double overflow must surface an error message")
        #expect(sut.isResponding == false, "isResponding must reset even after double overflow")

        // Second message: must use the fresh session (session2) and succeed
        let secondResponse = await sut.streamResponse(to: "second", sessionId: chat.id)
        #expect(secondResponse == "recovered", "Chat must be usable again after double overflow")
        #expect(sut.isResponding == false)
    }

    // MARK: - Error messages

    @Test("Rate limited returns the busy-model message")
    func rateLimitedMessage() async throws {
        let chat = try makeChat()
        let sut = llm(sessions: [MockGenerationSession(behavior: .fail(GenerationSessionError.rateLimited))])

        let response = await sut.streamResponse(to: "hi", sessionId: chat.id)

        #expect(response.contains("busy"), "Rate-limit response should mention the model is busy")
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
        let sut = LLM(db: db, makeSession: { _ in session })

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
        let sut = LLM(db: db, makeSession: { _ in session })

        _ = await sut.streamResponse(to: "test", sessionId: chat.id)

        #expect(sut.isResponding == false, "isResponding must always be false on return")
    }
}

// MARK: - MockGenerationSession: CustomTestStringConvertible (for parameterized output)

extension MockGenerationSession: CustomTestStringConvertible {
    public var testDescription: String {
        switch behavior {
        case .succeed(let t): "succeed(\"\(t)\")"
        case .fail(let e): "fail(\(e))"
        case .hang: "hang"
        }
    }
}
