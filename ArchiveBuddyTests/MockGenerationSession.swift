import Foundation
import Testing
import FoundationModels
@testable import ArchiveBuddy

// MARK: - MockGenerationSession

/// Test double for GenerationSession. Configured with a Behavior that
/// controls what stream(prompt:) does — succeed, fail, or hang.
/// condensed() returns a new MockGenerationSession with condensedBehavior.
final class MockGenerationSession: GenerationSession, @unchecked Sendable {

    enum Behavior {
        /// Stream yields this string as a single token, then finishes normally.
        case succeed(String)
        /// Stream immediately throws this error.
        case fail(any Error)
        /// Stream never yields or throws — simulates a hung FoundationModels session.
        case hang
    }

    var behavior: Behavior
    /// Behavior used when condensed() is called on this session.
    var condensedBehavior: Behavior = .succeed("")
    /// The last prompt passed to stream(prompt:), useful for inspecting injected history.
    private(set) var lastReceivedPrompt: String?

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        lastReceivedPrompt = prompt
        let b = behavior
        return AsyncThrowingStream { continuation in
            switch b {
            case .succeed(let text):
                continuation.yield(text)
                continuation.finish()
            case .fail(let error):
                continuation.finish(throwing: error)
            case .hang:
                // Intentionally never finishes — caller hangs on the for-await loop.
                break
            }
        }
    }

    func condensed() -> any GenerationSession {
        MockGenerationSession(behavior: condensedBehavior)
    }
}

// MARK: - GenerationSessionError: CustomTestStringConvertible

extension GenerationSessionError: @retroactive CustomTestStringConvertible {
    public var testDescription: String {
        switch self {
        case .exceededContextWindowSize: "exceededContextWindowSize"
        case .rateLimited: "rateLimited"
        }
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
