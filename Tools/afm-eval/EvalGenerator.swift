import Foundation
import FoundationModels
import ItJustTalksAI

/// The generator the cleanup pipeline sees in afm-eval: forwards to the harness generator, while keeping
/// the harness bookkeeping (process-wide call count → cold flag, fake-reply scripting for `--fake`).
/// Cases run one at a time, so the per-case plan is plain state.
final class EvalGenerator: TextGenerating, @unchecked Sendable {
    private let harness: Harness
    private let lock = NSLock()
    private var structuredPlan: FakeReplyPlan = .json("{}")
    private var textPlan: FakeReplyPlan = .text("")
    private var firstCold: Bool?

    init(harness: Harness) {
        self.harness = harness
    }

    var availability: ModelAvailability { harness.generator.availability }
    var contextSize: Int { min(harness.generator.contextSize, harness.options.contextLimit ?? harness.generator.contextSize) }
    var variantName: String? { harness.generator.variantName }

    /// Resets the per-case state and sets the fake reply for structured (stage A) calls.
    func beginCase(structured: FakeReplyPlan, text: FakeReplyPlan) {
        lock.withLock {
            structuredPlan = structured
            textPlan = text
            firstCold = nil
        }
    }

    /// Fake reply for the next plain-text call.
    func setTextPlan(_ plan: FakeReplyPlan) {
        lock.withLock { textPlan = plan }
    }

    /// Whether the case's first model call was the first generation of the process.
    var caseCold: Bool { lock.withLock { firstCold ?? false } }

    private func begin(structured: Bool) {
        let plan = lock.withLock { structured ? structuredPlan : textPlan }
        let cold = harness.beginGeneration(fakePlan: { plan })
        lock.withLock { if firstCold == nil { firstCold = cold } }
    }

    func tokenCount(for subject: TokenCountSubject) async throws(AIFailure) -> Int {
        try await harness.generator.tokenCount(for: subject)
    }

    func schemaTokenCount<Output: Generable>(for type: Output.Type) async throws(AIFailure) -> Int {
        try await harness.generator.schemaTokenCount(for: type)
    }

    func generate(_ request: GenerationRequest) async throws(AIFailure) -> GenerationResult {
        begin(structured: false)
        return try await harness.generator.generate(request)
    }

    func generate<Output: Generable & Sendable>(
        _ request: GenerationRequest,
        generating type: Output.Type
    ) async throws(AIFailure) -> StructuredGenerationResult<Output> {
        begin(structured: true)
        return try await harness.generator.generate(request, generating: type)
    }
}
