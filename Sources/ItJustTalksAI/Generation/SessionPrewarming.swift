import Foundation

/// A session created ahead of time with an operation's static instructions (§6.2 prewarm). Single use: it
/// serves at most one request of the operation that created it and is discarded on cancel.
public protocol PrewarmedSession: AnyObject, Sendable {
    var instructions: String { get }
    var guardrails: GuardrailsMode { get }
}

/// Generators that can create a session early (at recording start) and answer one request with it.
public protocol SessionPrewarming: TextGenerating {
    /// Creates a new session with `instructions` and starts loading the model for it. Never generates.
    func makePrewarmedSession(instructions: String, guardrails: GuardrailsMode) -> any PrewarmedSession
    /// Answers `request` with `prewarmed` when its instructions and guardrails match the request; otherwise
    /// behaves exactly like `generate(_:)` (new session).
    func generate(_ request: GenerationRequest, prewarmed: any PrewarmedSession) async throws(AIFailure) -> GenerationResult
}
