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
    /// transcript entries, used as a last-resort retry when a single prompt overflows.
    func condensed() -> any GenerationSession
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

/// Manages on-device LLM generation.
/// Each call to streamResponse uses a fresh GenerationSession so the
/// LanguageModelSession transcript never accumulates across turns. Conversation
/// continuity is maintained by injecting the last few DB messages into the prompt.
@MainActor
@Observable
final class LLM {

    /// Updated with each streamed token so the UI can display a live preview.
    /// Cleared to "" when generation finishes or errors.
    var streamingResponse: String = ""

    /// True while a streamResponse call is in flight.
    var isResponding: Bool = false

    private let db: DatabaseManager
    /// Factory for creating new sessions. Injected in tests to avoid Apple Intelligence.
    private let makeSession: () -> any GenerationSession

    /// Number of prior messages to include as conversation history in each prompt.
    /// 6 messages = 3 user/assistant exchanges, keeping context manageable.
    private static let historyMessageLimit = 6

    init(
        db: DatabaseManager,
        makeSession: @escaping () -> any GenerationSession = { LanguageModelSession() }
    ) {
        self.db = db
        self.makeSession = makeSession
    }

    // MARK: - Session management

    /// No-op. Retained for call-site compatibility; sessions are now stateless per-turn.
    func switchToSession(_ session: ChatSession) {}

    /// Fetches all persisted messages for a session, ordered oldest-first.
    func loadMessages(for sessionId: UUID) -> [ChatMessage] {
        (try? db.fetchMessages(sessionId: sessionId)) ?? []
    }

    // MARK: - Generation

    /// Streams a response to the given augmented prompt, updating `streamingResponse`
    /// with each partial token. Returns the complete response string when done.
    /// Errors (rate limiting, guardrail violations, context overflow) are returned
    /// as user-facing strings so the ViewModel can save them as assistant messages.
    @discardableResult
    func streamResponse(to prompt: String, sessionId: UUID) async -> String {
        isResponding = true
        defer {
            streamingResponse = ""
            isResponding = false
        }
        let fullPrompt = promptWithHistory(augmentedPrompt: prompt, sessionId: sessionId)
        return await generate(prompt: fullPrompt, using: makeSession())
    }

    /// Generates a short title from the first assistant response in a session.
    /// Uses a throwaway session so the title prompt does not pollute any transcript.
    func generateTitle(from response: String, sessionId: UUID) async -> String {
        let prompt = """
            Generate a short title (2–4 words) for a journal chat session based on \
            this assistant response. Return only the title — no punctuation, no quotes.

            Response: \(response)

            Title:
            """

        var result = ""
        do {
            for try await token in makeSession().stream(prompt: prompt) {
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

    private func generate(prompt: String, using session: any GenerationSession) async -> String {
        do {
            var fullResponse = ""
            for try await token in session.stream(prompt: prompt) {
                streamingResponse = token
                fullResponse = token
            }
            return fullResponse

        } catch GenerationSessionError.exceededContextWindowSize {
            // The prompt itself is too large for a fresh session — retry once with
            // a condensed session as a last resort. With stateless sessions this is
            // rare; it means a single RAG context + history block exceeds the limit.
            let condensed = session.condensed()
            do {
                var fullResponse = ""
                for try await token in condensed.stream(prompt: prompt) {
                    streamingResponse = token
                    fullResponse = token
                }
                return fullResponse
            } catch {
                return userFacingError(error)
            }

        } catch GenerationSessionError.rateLimited {
            return "The on-device model is currently busy. Please wait a moment and try again."

        } catch {
            return userFacingError(error)
        }
    }

    /// Prepends the last N prior messages as a "Previous conversation" section so
    /// each fresh session still has conversational context without accumulating transcript.
    /// Drops the most recent DB message (the current user turn just inserted by
    /// ChatViewModel) so it is not duplicated alongside the "Question:" line.
    private func promptWithHistory(augmentedPrompt: String, sessionId: UUID) -> String {
        let allMessages = (try? db.fetchMessages(sessionId: sessionId)) ?? []
        let priorMessages = allMessages.dropLast()
        let recentMessages = priorMessages.suffix(Self.historyMessageLimit)

        guard !recentMessages.isEmpty else { return augmentedPrompt }

        let historyText = recentMessages.map { msg in
            "\(msg.isUser ? "User" : "Assistant"): \(msg.text)"
        }.joined(separator: "\n")

        // Inject history before the "Question:" line so the model sees prior
        // exchanges as context before answering the current question.
        guard let questionRange = augmentedPrompt.range(of: "\nQuestion:") else {
            return augmentedPrompt
        }

        let beforeQuestion = String(augmentedPrompt[..<questionRange.lowerBound])
        let fromQuestion = String(augmentedPrompt[questionRange.lowerBound...])

        return """
            \(beforeQuestion)

            Previous conversation:
            \(historyText)
            \(fromQuestion)
            """
    }

    // MARK: - Error formatting

    private func userFacingError(_ error: Error) -> String {
        if error.localizedDescription.contains("GenerationError error 2") {
            return "Sorry, I can't respond to that query due to Apple's on-device safety guidelines. Try rephrasing your question."
        }
        return "Something went wrong generating a response. Please try again."
    }
}
