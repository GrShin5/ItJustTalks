import Foundation
import FoundationModels
import Testing
import ItJustTalksAI
@testable import ItJustTalks

private actor ServiceSuccessGate {
    private var open = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func wait(_ key: String) async {
        if open.contains(key) { return }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    func release(_ key: String) {
        open.insert(key)
        for waiter in waiters.removeValue(forKey: key) ?? [] { waiter.resume() }
    }

    func isOpen(_ key: String) -> Bool { open.contains(key) }
}

/// Delivers successful body text even when its generation task has been cancelled.
private final class GatedServiceSuccessGenerator: TextGenerating, Sendable {
    let gate = ServiceSuccessGate()
    let availability: ModelAvailability = .available
    let contextSize = 8192
    let variantName: String? = "synthetic-gated-success"
    let text = "明日の会議は午後から開始します。"

    func tokenCount(for subject: TokenCountSubject) async throws(AIFailure) -> Int { 100 }
    func schemaTokenCount<Output: Generable>(for type: Output.Type) async throws(AIFailure) -> Int { 10 }

    func generate(_ request: GenerationRequest) async throws(AIFailure) -> GenerationResult {
        await gate.release("body-started")
        await gate.wait("release-success")
        let result = GenerationResult(text: text, usage: TokenUsage(inputTokens: 100, outputTokens: 12),
            isTruncated: false, latency: .zero)
        await gate.release("success-returned")
        return result
    }

    func generate<Output: Generable & Sendable>(
        _ request: GenerationRequest, generating type: Output.Type
    ) async throws(AIFailure) -> StructuredGenerationResult<Output> {
        let value: Output
        do {
            value = try Output(GeneratedContent(json: "{\"taskType\":\"proofread_rewrite\",\"isReplacementArtifact\":true}"))
        } catch { throw .structuredParsingFailed }
        return StructuredGenerationResult(value: value, usage: TokenUsage(inputTokens: 100, outputTokens: 12),
            isTruncated: false, latency: .zero)
    }
}

@MainActor
@Suite struct LateServiceSuccessTests {
    private let configuration = GenerationCoordinator.Configuration(minimumRequestSpacing: .zero)

    @Test func fallbackDiscardsResultCancelledDuringComputation() async {
        let gate = ServiceSuccessGate()
        let service = DictationCleanupService(generator: FakeGenerator(), fallbackComputation: { input in
            await gate.release("fallback-started")
            await gate.wait("release-fallback")
            return input.transcript
        })
        let operation = UUID()
        let request = DictationCleanupRequest(transcript: "合成の文章です。", customInstruction: "", dictionaryEntries: [],
            sttLanguage: .japanese, outputLanguage: .automatic(.japanese), handsFree: false)
        let task = Task { await service.fallbackText(for: request.transcript, request: request, operation: operation) }
        await gate.wait("fallback-started")
        service.cancel(operation: operation)
        await gate.release("release-fallback")
        #expect(await task.value == nil)
    }

    @Test(arguments: [false, true])
    func fallbackWorkerObservesServiceCancellation(reset: Bool) async {
        let gate = ServiceSuccessGate()
        let service = DictationCleanupService(generator: FakeGenerator(), fallbackComputation: { input in
            await gate.release("fallback-started")
            await gate.wait("inspect-cancellation")
            let cancelled = Task.isCancelled
            await gate.release(cancelled ? "worker-cancelled" : "worker-running")
            return input.transcript
        })
        let operation = UUID()
        let request = DictationCleanupRequest(transcript: "合成の文章です。", customInstruction: "", dictionaryEntries: [],
            sttLanguage: .japanese, outputLanguage: .automatic(.japanese), handsFree: false)
        let task = Task { await service.fallbackText(for: request.transcript, request: request, operation: operation) }
        await gate.wait("fallback-started")
        if reset { service.reset() } else { service.cancel(operation: operation) }
        await gate.release("inspect-cancellation")
        #expect(await task.value == nil)
        #expect(await gate.isOpen("worker-cancelled"))
        #expect(!service.hasOperationInFlight)
    }

    @Test func commandDiscardsNonCooperativeSuccessAfterCancel() async {
        let generator = GatedServiceSuccessGenerator()
        let coordinator = GenerationCoordinator(generator: generator, configuration: configuration)
        let service = AICommandService(coordinator: { coordinator })
        let request = AICommandServiceRequest(spokenInstruction: "校正して", targetText: generator.text,
            customInstruction: "", dictionaryEntries: [], sttLanguage: .japanese,
            outputLanguage: .automatic(.japanese), outputLanguageWasSpoken: false)
        let operation = UUID()
        let task = Task { await service.execute(request, operation: operation) }
        await generator.gate.wait("body-started")
        service.cancel(operation: operation)
        await generator.gate.release("release-success")
        await generator.gate.wait("success-returned")
        let outcome = await task.value
        #expect(outcome == .cancelled)
        #expect(AICommandDispatchPolicy.dispatch(outcome, hasActualSource: true,
            explicitInsertionAllowedAtRecordingStart: true, explicitInsertionAllowedNow: true) == .discard)
    }

    @Test(arguments: [false, true])
    func cleanupDiscardsNonCooperativeSuccessAfterCancel(handsFree: Bool) async {
        let generator = GatedServiceSuccessGenerator()
        let service = DictationCleanupService(generator: generator, coordinatorConfiguration: configuration)
        let request = DictationCleanupRequest(transcript: generator.text, customInstruction: "", dictionaryEntries: [],
            sttLanguage: .japanese, outputLanguage: .automatic(.japanese), handsFree: handsFree)
        let operation = UUID()
        let task = Task { await service.cleanup(request, operation: operation) }
        await generator.gate.wait("body-started")
        service.cancel(operation: operation)
        await generator.gate.release("release-success")
        await generator.gate.wait("success-returned")
        let outcome = await task.value
        #expect(outcome == .cancelled)
        #expect(DictationCleanupDispositionPolicy.disposition(for: outcome,
            original: generator.text, handsFree: handsFree) == .discard)
    }
}
