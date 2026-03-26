import Foundation
import FoundationModels

/// Manages on-device LLM generation and per-session LanguageModelSession state.
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
    /// One LanguageModelSession per chat session, keyed by session UUID.
    private var sessions: [UUID: LanguageModelSession] = [:]

    init(db: DatabaseManager) {
        self.db = db
    }

    // MARK: - Session management

    /// Loads or creates the LanguageModelSession for a chat session.
    /// Call this when the user navigates to an existing session so the
    /// transcript is ready before the first message is sent.
    func switchToSession(_ session: ChatSession) {
        _ = languageModelSession(for: session.id)
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
        streamingResponse = ""

        let session = languageModelSession(for: sessionId)
        let result = await generate(prompt: prompt, using: session, sessionId: sessionId)

        streamingResponse = ""
        isResponding = false
        return result
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

        let throwaway = LanguageModelSession()
        var result = ""
        do {
            for try await partial in throwaway.streamResponse(to: prompt) {
                result = partial.content
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
        using session: LanguageModelSession,
        sessionId: UUID
    ) async -> String {
        do {
            var fullResponse = ""
            for try await partial in session.streamResponse(to: prompt) {
                streamingResponse = partial.content
                fullResponse = partial.content
            }
            saveTranscript(session.transcript, sessionId: sessionId)
            return fullResponse

        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // Condense transcript to first + last entry, retry once
            let condensed = newSession(previousSession: session)
            sessions[sessionId] = condensed
            do {
                var fullResponse = ""
                for try await partial in condensed.streamResponse(to: prompt) {
                    streamingResponse = partial.content
                    fullResponse = partial.content
                }
                saveTranscript(condensed.transcript, sessionId: sessionId)
                return fullResponse
            } catch {
                return userFacingError(error)
            }

        } catch LanguageModelSession.GenerationError.rateLimited {
            return "The on-device model is currently busy. Please wait a moment and try again."

        } catch {
            return userFacingError(error)
        }
    }

    /// Returns an existing LanguageModelSession for a chat session, or creates one
    /// by loading the persisted transcript from the database.
    private func languageModelSession(for sessionId: UUID) -> LanguageModelSession {
        if let existing = sessions[sessionId] { return existing }

        if let transcript = loadTranscript(for: sessionId) {
            let session = LanguageModelSession(transcript: transcript)
            sessions[sessionId] = session
            return session
        }

        let session = LanguageModelSession()
        sessions[sessionId] = session
        return session
    }

    /// Condenses an overflowed session to its first + last transcript entry.
    private func newSession(previousSession: LanguageModelSession) -> LanguageModelSession {
        let entries = previousSession.transcript
        var condensed = [Transcript.Entry]()
        if let first = entries.first {
            condensed.append(first)
            if entries.count > 1, let last = entries.last {
                condensed.append(last)
            }
        }
        return LanguageModelSession(transcript: Transcript(entries: condensed))
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
