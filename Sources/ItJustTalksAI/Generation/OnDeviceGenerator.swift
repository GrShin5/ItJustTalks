import Foundation
import FoundationModels

/// Generator backed only by the on-device `SystemLanguageModel` (D1).
///
/// - Never accepts `any LanguageModel`, never uses Private Cloud Compute, never touches the network.
/// - Creates a new `LanguageModelSession` for every request (D6); no transcript is reused.
/// - Does not log or store prompt/instruction/output text.
/// - Cancellation always wins: an error caught after the task was cancelled is reported as `.cancelled`
///   (never as a retryable failure). Callers must still re-check cancellation / generation identity right
///   before inserting or sending a result (STATE-08).
@available(macOS 27, *)
public struct OnDeviceGenerator: TextGenerating {
    private let defaultModel: SystemLanguageModel
    private let permissiveModel: SystemLanguageModel

    public init() {
        self.defaultModel = SystemLanguageModel.default
        self.permissiveModel = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    private func model(for guardrails: GuardrailsMode) -> SystemLanguageModel {
        switch guardrails {
        case .default: return defaultModel
        case .permissiveContentTransformations: return permissiveModel
        }
    }

    public var availability: ModelAvailability {
        AIFailureMapper.map(defaultModel.availability)
    }

    /// Availability of the model actually used for `guardrails`.
    public func availability(for guardrails: GuardrailsMode) -> ModelAvailability {
        AIFailureMapper.map(model(for: guardrails).availability)
    }

    public var contextSize: Int {
        defaultModel.contextSize
    }

    /// Read-only presentation hint; does not affect availability or generation.
    public var isCore3: Bool {
        Self.isCore3Variant(defaultModel.variant)
    }

    /// Pure comparison so callers can test supplied variants without querying a model.
    public static func isCore3Variant(_ variant: SystemLanguageModel.Variant) -> Bool {
        variant == .core3
    }

    public var variantName: String? {
        defaultModel.variant.displayName
    }

    public func tokenCount(for subject: TokenCountSubject) async throws(AIFailure) -> Int {
        do {
            switch subject {
            case .instructions(let text):
                return try await defaultModel.tokenCount(for: Instructions(text))
            case .prompt(let text):
                return try await defaultModel.tokenCount(for: Prompt(text))
            }
        } catch {
            throw AIFailureMapper.mapCaught(error)
        }
    }

    public func schemaTokenCount<Output: Generable>(for type: Output.Type) async throws(AIFailure) -> Int {
        do {
            return try await defaultModel.tokenCount(for: Output.generationSchema)
        } catch {
            throw AIFailureMapper.mapCaught(error)
        }
    }

    public func generate(_ request: GenerationRequest) async throws(AIFailure) -> GenerationResult {
        try preflight(request)
        let session = LanguageModelSession(model: model(for: request.guardrails), instructions: request.instructions)
        return try await respond(request, session: session)
    }

    private func respond(_ request: GenerationRequest, session: LanguageModelSession) async throws(AIFailure) -> GenerationResult {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let response = try await session.respond(to: Prompt(request.prompt), options: options(for: request))
            try Self.checkNotCancelled()
            let usage = Self.usage(response.usage)
            return GenerationResult(
                text: response.content,
                usage: usage,
                isTruncated: Self.isTruncated(
                    outputTokens: usage.outputTokens,
                    maximumResponseTokens: request.maximumResponseTokens,
                    text: response.content
                ),
                latency: clock.now - start
            )
        } catch {
            throw AIFailureMapper.mapCaught(error)
        }
    }

    public func generate<Output: Generable & Sendable>(
        _ request: GenerationRequest,
        generating type: Output.Type
    ) async throws(AIFailure) -> StructuredGenerationResult<Output> {
        try preflight(request)
        let session = LanguageModelSession(model: model(for: request.guardrails), instructions: request.instructions)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let response = try await session.respond(
                to: Prompt(request.prompt),
                generating: type,
                options: options(for: request)
            )
            try Self.checkNotCancelled()
            let usage = Self.usage(response.usage)
            return StructuredGenerationResult(
                value: response.content,
                usage: usage,
                isTruncated: Self.isTruncated(
                    outputTokens: usage.outputTokens,
                    maximumResponseTokens: request.maximumResponseTokens
                ),
                latency: clock.now - start
            )
        } catch {
            throw AIFailureMapper.mapCaught(error)
        }
    }

    // MARK: - Helpers

    /// Session holder for `SessionPrewarming`. Used for at most one request (`take()`).
    final class Prewarmed: PrewarmedSession, @unchecked Sendable {
        let instructions: String
        let guardrails: GuardrailsMode
        private let lock = NSLock()
        private var session: LanguageModelSession?

        init(session: LanguageModelSession, instructions: String, guardrails: GuardrailsMode) {
            self.session = session
            self.instructions = instructions
            self.guardrails = guardrails
        }

        func take() -> LanguageModelSession? {
            lock.withLock {
                defer { session = nil }
                return session
            }
        }
    }

    /// Checks the availability of the model this request will actually use (default or permissive).
    private func preflight(_ request: GenerationRequest) throws(AIFailure) {
        if Task.isCancelled { throw .cancelled }
        if case .unavailable(let reason) = availability(for: request.guardrails) { throw .modelUnavailable(reason) }
    }

    /// A result that finishes after cancellation must not be returned (STATE-08).
    private static func checkNotCancelled() throws(AIFailure) {
        if Task.isCancelled { throw .cancelled }
    }

    private func options(for request: GenerationRequest) -> GenerationOptions {
        GenerationOptions(
            samplingMode: request.greedy ? .greedy : nil,
            maximumResponseTokens: request.maximumResponseTokens
        )
    }

    private static func usage(_ usage: LanguageModelSession.Usage) -> TokenUsage {
        TokenUsage(
            inputTokens: usage.input.totalTokenCount,
            cachedInputTokens: usage.input.cachedTokenCount,
            outputTokens: usage.output.totalTokenCount
        )
    }
}

@available(macOS 27, *)
extension OnDeviceGenerator: SessionPrewarming {
    /// Creates a new session with the static instructions and calls `prewarm()` (§6.2). Variable data stays
    /// in the prompt, so no prompt prefix is passed.
    public func makePrewarmedSession(instructions: String, guardrails: GuardrailsMode) -> any PrewarmedSession {
        let session = LanguageModelSession(model: model(for: guardrails), instructions: instructions)
        session.prewarm()
        return Prewarmed(session: session, instructions: instructions, guardrails: guardrails)
    }

    public func generate(_ request: GenerationRequest, prewarmed: any PrewarmedSession) async throws(AIFailure) -> GenerationResult {
        guard let holder = prewarmed as? Prewarmed, holder.instructions == request.instructions,
              holder.guardrails == request.guardrails else {
            return try await generate(request)
        }
        try preflight(request)
        guard let session = holder.take() else { return try await generate(request) }
        return try await respond(request, session: session)
    }
}
