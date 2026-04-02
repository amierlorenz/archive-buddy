import Foundation
import FoundationModels

// MARK: - GenerationSessionError

/// Normalised errors from a GenerationSession.
/// Decouples LLM's catch blocks from FoundationModels-specific error types,
/// making them reachable in tests without Apple Intelligence.
enum GenerationSessionError: Error {
    case exceededContextWindowSize
    case rateLimited
}

// MARK: - GenerationSession

/// Abstraction over LanguageModelSession that enables dependency injection in tests.
protocol GenerationSession: AnyObject {
    /// Streams content tokens for the given prompt.
    /// Implementations must convert framework-specific errors to GenerationSessionError.
    func stream(prompt: String) -> AsyncThrowingStream<String, Error>

    /// Returns a condensed copy of this session retaining only the first and last
    /// transcript entries, used to recover from context-window overflow.
    func condensed() -> any GenerationSession

    /// The current session transcript, used for persistence after each response.
    var transcript: Transcript { get }
}

// MARK: - LanguageModelSession conformance

extension LanguageModelSession: GenerationSession {
    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await partial in streamResponse(to: prompt) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch GenerationError.exceededContextWindowSize {
                    continuation.finish(throwing: GenerationSessionError.exceededContextWindowSize)
                } catch GenerationError.rateLimited {
                    continuation.finish(throwing: GenerationSessionError.rateLimited)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func condensed() -> any GenerationSession {
        var condensedEntries = [Transcript.Entry]()
        if let first = transcript.first {
            condensedEntries.append(first)
            if transcript.count > 1, let last = transcript.last {
                condensedEntries.append(last)
            }
        }
        return LanguageModelSession(transcript: Transcript(entries: condensedEntries))
    }
}

// MARK: - LLM

/// Manages on-device LLM generation and per-session GenerationSession state.
/// Knows nothing about archives — it receives a fully-formed augmented prompt from
/// ArchiveQueryService and generates a response.
@MainActor
@Observable
final class LLM {

    /// Updated with each streamed token so the UI can display a live preview.
    /// Cleared to "" when generation finishes or errors.
    var streamingResponse: String = ""

    /// True while a streamResponse call is in flight.
    var isResponding: Bool = false

    private let db: DatabaseManager
    /// One GenerationSession per chat session, keyed by session UUID.
    private var sessions: [UUID: any GenerationSession] = [:]
    /// Factory for creating new sessions. Injected in tests to avoid Apple Intelligence.
    private let makeSession: (Transcript?) -> any GenerationSession

    init(
        db: DatabaseManager,
        makeSession: @escaping (Transcript?) -> any GenerationSession = { transcript in
            if let transcript {
                LanguageModelSession(transcript: transcript)
            } else {
                LanguageModelSession()
            }
        }
    ) {
        self.db = db
        self.makeSession = makeSession
    }

    // MARK: - Session management

    /// Loads or creates the GenerationSession for a chat session.
    /// Call this when the user navigates to an existing session so the
    /// transcript is ready before the first message is sent.
    func switchToSession(_ session: ChatSession) {
        _ = generationSession(for: session.id)
    }

    /// Fetches all persisted messages for a session, ordered oldest-first.
    func loadMessages(for sessionId: UUID) -> [ChatMessage] {
        (try? db.fetchMessages(sessionId: sessionId)) ?? []
    }

    // MARK: - Generation

    /// Streams a response to the given augmented prompt, updating `streamingResponse`
    /// with each partial token. Returns the complete response string when done.
    /// Errors (rate limiting, guardrail violations, context overflow) are returned
    /// as user-facing strings rather than thrown so the ViewModel can save them as
    /// assistant messages without a separate error-handling path.
    @discardableResult
    func streamResponse(to prompt: String, sessionId: UUID) async -> String {
        isResponding = true
        defer {
            streamingResponse = ""
            isResponding = false
        }

        let session = generationSession(for: sessionId)
        return await generate(prompt: prompt, using: session, sessionId: sessionId)
    }

    /// Generates a short title from the first assistant response in a session.
    /// Uses a throwaway session so the title prompt does not pollute the chat transcript.
    func generateTitle(from response: String, sessionId: UUID) async -> String {
        let prompt = """
            Generate a short title (2–4 words) for a journal chat session based on \
            this assistant response. Return only the title — no punctuation, no quotes.

            Response: \(response)

            Title:
            """

        let throwaway = makeSession(nil)
        var result = ""
        do {
            for try await token in throwaway.stream(prompt: prompt) {
                result = token
            }
        } catch {
            return "New Chat"
        }

        let cleaned = result
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\u{201C}", with: "")
            .replacingOccurrences(of: "\u{201D}", with: "")
        return cleaned.isEmpty ? "New Chat" : cleaned
    }

    // MARK: - Private helpers

    private func generate(
        prompt: String,
        using session: any GenerationSession,
        sessionId: UUID
    ) async -> String {
        do {
            var fullResponse = ""
            for try await token in session.stream(prompt: prompt) {
                streamingResponse = token
                fullResponse = token
            }
            saveTranscript(session.transcript, sessionId: sessionId)
            return fullResponse

        } catch GenerationSessionError.exceededContextWindowSize {
            // Condense transcript to first + last entry, retry once
            let condensed = session.condensed()
            sessions[sessionId] = condensed
            do {
                var fullResponse = ""
                for try await token in condensed.stream(prompt: prompt) {
                    streamingResponse = token
                    fullResponse = token
                }
                saveTranscript(condensed.transcript, sessionId: sessionId)
                return fullResponse
            } catch {
                // Condensed session also failed — replace it with a fresh session so
                // subsequent messages are not permanently broken.
                sessions[sessionId] = makeSession(nil)
                return userFacingError(error)
            }

        } catch GenerationSessionError.rateLimited {
            return "The on-device model is currently busy. Please wait a moment and try again."

        } catch {
            return userFacingError(error)
        }
    }

    /// Returns an existing GenerationSession for a chat session, or creates one
    /// by loading the persisted transcript from the database.
    private func generationSession(for sessionId: UUID) -> any GenerationSession {
        if let existing = sessions[sessionId] { return existing }
        let session = makeSession(loadTranscript(for: sessionId))
        sessions[sessionId] = session
        return session
    }

    // MARK: - Transcript persistence

    private func saveTranscript(_ transcript: Transcript, sessionId: UUID) {
        guard let json = try? JSONEncoder().encode(transcript),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        try? db.updateTranscriptJSON(jsonString, sessionId: sessionId)
    }

    private func loadTranscript(for sessionId: UUID) -> Transcript? {
        guard let session = try? db.fetchChatSession(id: sessionId),
              !session.transcriptJSON.isEmpty,
              let data = session.transcriptJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    // MARK: - Error formatting

    private func userFacingError(_ error: Error) -> String {
        if error.localizedDescription.contains("GenerationError error 2") {
            return "Sorry, I can't respond to that query due to Apple's on-device safety guidelines. Try rephrasing your question."
        }
        return "Something went wrong generating a response. Please try again."
    }
}
