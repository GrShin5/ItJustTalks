import Foundation
import FoundationModels

/// **TEST / EVALUATION SUPPORT ONLY — never reference from product code.**
///
/// Scriptable `TextGenerating` for tests and offline evaluation plumbing. Never calls the model.
/// It lives in the library target only until a dedicated test-support target exists in `Package.swift`
/// (review m5); it must move there and stop being part of the shipped library.
///
/// Each `generate` call consumes the next scripted step (FIFO). When the script is empty the
/// `fallback` step is used. Delays honor task cancellation and surface it as `.cancelled`.
public final class FakeGenerator: TextGenerating, @unchecked Sendable {
    public enum Reply: Sendable, Hashable {
        /// Plain text. For structured calls, the text must be JSON for the requested `Generable` type.
        /// Omitted usage represents a complete synthetic response; explicit nil tests unknown usage.
        case text(String, usage: TokenUsage? = TokenUsage(inputTokens: 0, outputTokens: 1))
        case failure(AIFailure)
    }

    public struct Step: Sendable, Hashable {
        public var reply: Reply
        public var delay: Duration

        public init(_ reply: Reply, delay: Duration = .zero) {
            self.reply = reply
            self.delay = delay
        }
    }

    private let lock = NSLock()
    private var script: [Step]
    private var recorded: [GenerationRequest] = []
    private var prewarmCreated = 0
    private var prewarmUsed = 0
    private let fallback: Step

    public let availability: ModelAvailability
    public let contextSize: Int
    public let variantName: String?
    /// Deterministic token estimate used by `tokenCount(for:)` (characters per token).
    public let charactersPerToken: Double

    public init(
        script: [Step] = [],
        fallback: Step = Step(.failure(.other(code: "FakeGenerator.scriptExhausted"))),
        availability: ModelAvailability = .available,
        contextSize: Int = 4096,
        variantName: String? = "fake",
        charactersPerToken: Double = 2.0
    ) {
        self.script = script
        self.fallback = fallback
        self.availability = availability
        self.contextSize = contextSize
        self.variantName = variantName
        self.charactersPerToken = charactersPerToken
    }

    /// Requests received so far (for assertions in tests only).
    public var receivedRequests: [GenerationRequest] {
        lock.withLock { recorded }
    }

    public func enqueue(_ step: Step) {
        lock.withLock { script.append(step) }
    }

    public func tokenCount(for subject: TokenCountSubject) async throws(AIFailure) -> Int {
        switch subject {
        case .instructions(let text), .prompt(let text):
            return Int((Double(text.count) / charactersPerToken).rounded(.up))
        }
    }

    public func schemaTokenCount<Output: Generable>(for type: Output.Type) async throws(AIFailure) -> Int {
        Int((Double(String(describing: Output.generationSchema).count) / charactersPerToken).rounded(.up))
    }

    public func generate(_ request: GenerationRequest) async throws(AIFailure) -> GenerationResult {
        let (text, usage, latency) = try await run(request)
        return GenerationResult(
            text: text,
            usage: usage,
            isTruncated: Self.isTruncated(
                outputTokens: usage?.outputTokens, maximumResponseTokens: request.maximumResponseTokens, text: text),
            latency: latency
        )
    }

    public func generate<Output: Generable & Sendable>(
        _ request: GenerationRequest,
        generating type: Output.Type
    ) async throws(AIFailure) -> StructuredGenerationResult<Output> {
        let (text, usage, latency) = try await run(request)
        let value: Output
        do {
            value = try Output(GeneratedContent(json: text))
        } catch {
            throw .structuredParsingFailed
        }
        return StructuredGenerationResult(
            value: value,
            usage: usage,
            isTruncated: Self.isTruncated(outputTokens: usage?.outputTokens, maximumResponseTokens: request.maximumResponseTokens),
            latency: latency
        )
    }

    private func nextStep(recording request: GenerationRequest) -> Step {
        lock.withLock {
            recorded.append(request)
            return script.isEmpty ? fallback : script.removeFirst()
        }
    }

    private func run(_ request: GenerationRequest) async throws(AIFailure) -> (String, TokenUsage?, Duration) {
        if Task.isCancelled { throw .cancelled }
        if case .unavailable(let reason) = availability { throw .modelUnavailable(reason) }
        let step = nextStep(recording: request)
        let clock = ContinuousClock()
        let start = clock.now
        if step.delay > .zero {
            do {
                try await Task.sleep(for: step.delay)
            } catch {
                throw .cancelled
            }
        }
        if Task.isCancelled { throw .cancelled }
        switch step.reply {
        case .failure(let failure):
            throw failure
        case .text(let text, let usage):
            return (text, usage, clock.now - start)
        }
    }
}

extension FakeGenerator: SessionPrewarming {
    final class Prewarmed: PrewarmedSession, @unchecked Sendable {
        let instructions: String
        let guardrails: GuardrailsMode
        init(instructions: String, guardrails: GuardrailsMode) {
            self.instructions = instructions
            self.guardrails = guardrails
        }
    }

    /// Counts created sessions (`prewarmedSessionsCreated`); never generates.
    public func makePrewarmedSession(instructions: String, guardrails: GuardrailsMode) -> any PrewarmedSession {
        lock.withLock { prewarmCreated += 1 }
        return Prewarmed(instructions: instructions, guardrails: guardrails)
    }

    /// Counts a matching prewarmed session as used (`prewarmedSessionsUsed`), then answers like `generate(_:)`.
    public func generate(_ request: GenerationRequest, prewarmed: any PrewarmedSession) async throws(AIFailure) -> GenerationResult {
        if prewarmed.instructions == request.instructions, prewarmed.guardrails == request.guardrails {
            lock.withLock { prewarmUsed += 1 }
        }
        return try await generate(request)
    }

    public var prewarmedSessionsCreated: Int { lock.withLock { prewarmCreated } }
    public var prewarmedSessionsUsed: Int { lock.withLock { prewarmUsed } }
}
