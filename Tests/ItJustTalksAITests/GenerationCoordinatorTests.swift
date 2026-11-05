import Foundation
import FoundationModels
import Testing
@testable import ItJustTalksAI

/// Generator that ignores cancellation: its reply arrives after the delay no matter what (models a framework
/// call that does not stop promptly). Records when each call started and finished.
final class StubbornGenerator: TextGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [ContinuousClock.Instant] = []
    private var ends: [ContinuousClock.Instant] = []
    let delay: Duration
    let availability: ModelAvailability = .available
    let contextSize = 4096
    let variantName: String? = "stubborn"

    init(delay: Duration) { self.delay = delay }

    var started: [ContinuousClock.Instant] { lock.withLock { starts } }
    var finished: [ContinuousClock.Instant] { lock.withLock { ends } }

    func tokenCount(for subject: TokenCountSubject) async throws(AIFailure) -> Int { 1 }
    func schemaTokenCount<Output: Generable>(for type: Output.Type) async throws(AIFailure) -> Int { 1 }

    func generate(_ request: GenerationRequest) async throws(AIFailure) -> GenerationResult {
        lock.withLock { starts.append(.now) }
        let delay = self.delay
        // A detached task is not cancelled with the caller, and awaiting its value ignores cancellation.
        await Task.detached { try? await Task.sleep(for: delay) }.value
        lock.withLock { ends.append(.now) }
        return GenerationResult(text: "late result", usage: TokenUsage(inputTokens: 1, outputTokens: 1), isTruncated: false, latency: delay)
    }

    func generate<Output: Generable & Sendable>(
        _ request: GenerationRequest, generating type: Output.Type
    ) async throws(AIFailure) -> StructuredGenerationResult<Output> {
        throw .unsupportedCapability
    }
}

/// Waits (bounded) until `condition` holds.
func eventually(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<400 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

let fastConfiguration = GenerationCoordinator.Configuration(
    minimumRequestSpacing: .zero, rateLimitDefaultWait: .milliseconds(10), cancelDrainLimit: .seconds(2)
)
let roomyDeadline = DeadlinePolicy(cap: .seconds(10))
let simpleRequest = GenerationRequest(instructions: "i", prompt: "p", maximumResponseTokens: 50)

/// Runs one plain generation as an operation and maps it to a comparable value.
func generateOnce(
    _ coordinator: GenerationCoordinator, operation: UUID = UUID(), priority: GenerationPriority = .interactive,
    deadline: DeadlinePolicy = roomyDeadline
) async -> CoordinatedOutcome<Result<String, AIFailure>> {
    await coordinator.perform(operation: operation, priority: priority, deadline: deadline) { context in
        do throws(AIFailure) {
            return .success(try await context.generate(simpleRequest, inputTokens: 10).text)
        } catch {
            return .failure(error)
        }
    }
}

func delivered(_ outcome: CoordinatedOutcome<Result<String, AIFailure>>) -> Result<String, AIFailure>? {
    if case .delivered(let value) = outcome { return value }
    return nil
}

func cancellation<T>(_ outcome: CoordinatedOutcome<T>) -> GenerationCancellation? {
    if case .cancelled(let cause) = outcome { return cause }
    return nil
}

@Suite("GenerationCoordinator")
struct GenerationCoordinatorTests {
    @Test func deliversResult() async {
        let fake = FakeGenerator(script: [.init(.text("ok", usage: TokenUsage(inputTokens: 1, outputTokens: 1)))])
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        #expect(delivered(await generateOnce(coordinator)) == .success("ok"))
    }

    @Test func delayedResponsePastDeadlineTimesOut() async {
        let fake = FakeGenerator(script: [.init(.text("late"), delay: .seconds(5))])
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        let start = ContinuousClock.now
        let outcome = await generateOnce(coordinator, deadline: DeadlinePolicy(cap: .milliseconds(150)))
        #expect(delivered(outcome) == .failure(.timeout))
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func deadlineFormulaUsesCapAndRates() {
        let policy = DeadlinePolicy(
            cap: .seconds(60), fixedWait: .seconds(2), readTokensPerSecond: 100,
            generationTokensPerSecond: 10, safetyFactor: 2
        )
        // 2 + 300/100 + 50/10 × 2 = 15 s
        #expect(policy.allowance(inputTokens: 300, reservedOutputTokens: 50) == .seconds(15))
        // Capped.
        #expect(policy.allowance(inputTokens: 300, reservedOutputTokens: 5_000) == .seconds(60))
        #expect(DeadlinePolicy.cleanup.cap == .seconds(60))
    }

    @Test func responseAfterCancelIsNeverDelivered() async {
        let stubborn = StubbornGenerator(delay: .milliseconds(400))
        let coordinator = GenerationCoordinator(generator: stubborn, configuration: fastConfiguration)
        let operation = UUID()
        let task = Task { await generateOnce(coordinator, operation: operation) }
        await eventually { !stubborn.started.isEmpty }
        let cancelAt = ContinuousClock.now
        await coordinator.cancel(operation: operation)
        let outcome = await task.value
        #expect(cancellation(outcome) == .cancelled)
        #expect(ContinuousClock.now - cancelAt < .milliseconds(300))
        // The reply does arrive later; it is not delivered anywhere.
        await eventually { !stubborn.finished.isEmpty }
        #expect(stubborn.finished.count == 1)
    }

    @Test func callerTaskCancellationCancels() async {
        let fake = FakeGenerator(script: [.init(.text("late"), delay: .seconds(5))])
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        let task = Task { await generateOnce(coordinator) }
        await eventually { !fake.receivedRequests.isEmpty }
        task.cancel()
        #expect(cancellation(await task.value) == .cancelled)
    }

    @Test func nextCallWaitsForAbandonedWork() async {
        let stubborn = StubbornGenerator(delay: .milliseconds(300))
        let coordinator = GenerationCoordinator(generator: stubborn, configuration: fastConfiguration)
        let operation = UUID()
        let first = Task { await generateOnce(coordinator, operation: operation) }
        await eventually { !stubborn.started.isEmpty }
        await coordinator.cancel(operation: operation)
        _ = await first.value
        let second = await generateOnce(coordinator)
        #expect(delivered(second) == .success("late result"))
        let starts = stubborn.started, ends = stubborn.finished
        #expect(starts.count == 2 && ends.count == 2)
        if starts.count == 2, let firstEnd = ends.first { #expect(starts[1] >= firstEnd) }
    }

    @Test func rateLimitedThenSuccessRetriesOnce() async {
        let fake = FakeGenerator(script: [
            .init(.failure(.rateLimited(resetDate: nil))),
            .init(.text("ok", usage: TokenUsage(inputTokens: 1, outputTokens: 1))),
        ])
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        #expect(delivered(await generateOnce(coordinator)) == .success("ok"))
        #expect(fake.receivedRequests.count == 2)
    }

    @Test func rateLimitedTwiceFails() async {
        let fake = FakeGenerator(script: [
            .init(.failure(.rateLimited(resetDate: nil))),
            .init(.failure(.rateLimited(resetDate: nil))),
            .init(.text("never")),
        ])
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        #expect(delivered(await generateOnce(coordinator)) == .failure(.rateLimited(resetDate: nil)))
        #expect(fake.receivedRequests.count == 2)
    }

    @Test func rateLimitedWaitBeyondDeadlineDoesNotRetry() async {
        let reset = Date().addingTimeInterval(30)
        let fake = FakeGenerator(script: [.init(.failure(.rateLimited(resetDate: reset))), .init(.text("never"))])
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        #expect(delivered(await generateOnce(coordinator, deadline: DeadlinePolicy(cap: .seconds(1)))) == .failure(.rateLimited(resetDate: reset)))
        #expect(fake.receivedRequests.count == 1)
    }

    @Test(arguments: [
        AIFailure.refusal, .guardrailViolation, .unsupportedLanguageOrLocale(languageCode: "xx"), .timeout,
        .contextSizeExceeded(contextSize: 4096, tokenCount: 5000), .modelUnavailable(.modelNotReady),
        .concurrentRequests,
    ])
    func otherFailuresAreNotRetried(_ failure: AIFailure) async {
        let fake = FakeGenerator(script: [.init(.failure(failure)), .init(.text("never"))])
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        #expect(delivered(await generateOnce(coordinator)) == .failure(failure))
        #expect(fake.receivedRequests.count == 1)
    }

    @Test func unavailableModelIsNotRetried() async {
        let fake = FakeGenerator(availability: .unavailable(.appleIntelligenceNotEnabled))
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        #expect(delivered(await generateOnce(coordinator)) == .failure(.modelUnavailable(.appleIntelligenceNotEnabled)))
    }

    @Test func staleGenerationAfterNewerRequest() async {
        let fake = FakeGenerator(script: [
            .init(.text("old"), delay: .seconds(5)),
            .init(.text("new", usage: TokenUsage(inputTokens: 1, outputTokens: 1))),
        ])
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        let operation = UUID()
        let old = Task { await generateOnce(coordinator, operation: operation) }
        await eventually { fake.receivedRequests.count == 1 }
        let newer = await generateOnce(coordinator, operation: operation)
        #expect(cancellation(await old.value) == .superseded)
        #expect(delivered(newer) == .success("new"))
    }

    @Test func staleTicketIsNotCurrent() async {
        let fake = FakeGenerator(fallback: .init(.text("x", usage: TokenUsage(inputTokens: 1, outputTokens: 1))))
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        let operation = UUID()
        let first = await coordinator.perform(operation: operation, priority: .interactive, deadline: roomyDeadline) { $0.ticket }
        guard case .delivered(let ticket1) = first else { Issue.record("not delivered"); return }
        #expect(await coordinator.isCurrent(ticket1))
        let second = await coordinator.perform(operation: operation, priority: .interactive, deadline: roomyDeadline) { $0.ticket }
        guard case .delivered(let ticket2) = second else { Issue.record("not delivered"); return }
        #expect(ticket2.generation > ticket1.generation)
        #expect(await !coordinator.isCurrent(ticket1))
        #expect(await coordinator.isCurrent(ticket2))
        await coordinator.cancel(operation: operation)
        #expect(await !coordinator.isCurrent(ticket2))
    }

    @Test func interactivePreemptsOptimization() async {
        let fake = FakeGenerator(script: [
            .init(.text("optimized"), delay: .seconds(5)),
            .init(.text("cleaned", usage: TokenUsage(inputTokens: 1, outputTokens: 1))),
        ])
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        let optimization = Task { await generateOnce(coordinator, priority: .optimization) }
        await eventually { fake.receivedRequests.count == 1 }
        let interactive = await generateOnce(coordinator, priority: .interactive)
        #expect(cancellation(await optimization.value) == .preempted)
        #expect(delivered(interactive) == .success("cleaned"))
    }

    @Test func singleInFlightAndInteractiveFirst() async {
        let stubborn = StubbornGenerator(delay: .milliseconds(80))
        let coordinator = GenerationCoordinator(generator: stubborn, configuration: fastConfiguration)
        let first = Task { await generateOnce(coordinator) }
        await eventually { stubborn.started.count == 1 }
        let second = Task { await generateOnce(coordinator) }
        let third = Task { await generateOnce(coordinator) }
        for task in [first, second, third] { #expect(delivered(await task.value) == .success("late result")) }
        let starts = stubborn.started, ends = stubborn.finished
        #expect(starts.count == 3)
        // Never two calls at once: every call starts after the previous one finished.
        for index in 1..<min(starts.count, ends.count) { #expect(starts[index] >= ends[index - 1]) }
    }

    @Test func minimumSpacingBetweenCalls() async {
        let stubborn = StubbornGenerator(delay: .milliseconds(10))
        let configuration = GenerationCoordinator.Configuration(minimumRequestSpacing: .milliseconds(150))
        let coordinator = GenerationCoordinator(generator: stubborn, configuration: configuration)
        _ = await generateOnce(coordinator)
        _ = await generateOnce(coordinator)
        let starts = stubborn.started, ends = stubborn.finished
        #expect(starts.count == 2)
        if starts.count == 2, let end = ends.first { #expect(starts[1] - end >= .milliseconds(140)) }
    }

    @Test func prewarmedSessionIsUsedOnceAndDiscardedOnCancel() async {
        let fake = FakeGenerator(fallback: .init(.text("x", usage: TokenUsage(inputTokens: 1, outputTokens: 1))))
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        let operation = UUID()
        await coordinator.prewarm(operation: operation, instructions: "i", guardrails: .default)
        #expect(await coordinator.hasPrewarmedSession)
        _ = await generateOnce(coordinator, operation: operation)
        #expect(fake.prewarmedSessionsCreated == 1)
        #expect(fake.prewarmedSessionsUsed == 1)
        #expect(await !coordinator.hasPrewarmedSession)

        let cancelled = UUID()
        await coordinator.prewarm(operation: cancelled, instructions: "i", guardrails: .default)
        await coordinator.cancel(operation: cancelled)
        #expect(await !coordinator.hasPrewarmedSession)
        _ = await generateOnce(coordinator, operation: UUID())
        #expect(fake.prewarmedSessionsCreated == 2)
        #expect(fake.prewarmedSessionsUsed == 1)
    }

    @Test func stillRunningAbandonedWorkIsNeverOverlapped() async {
        // The old call ignores cancellation for 600 ms; the new request's deadline is shorter.
        let stubborn = StubbornGenerator(delay: .milliseconds(600))
        let coordinator = GenerationCoordinator(generator: stubborn, configuration: fastConfiguration)
        let operation = UUID()
        let first = Task { await generateOnce(coordinator, operation: operation) }
        await eventually { !stubborn.started.isEmpty }
        await coordinator.cancel(operation: operation)
        _ = await first.value
        let second = await generateOnce(coordinator, deadline: DeadlinePolicy(cap: .milliseconds(150)))
        #expect(delivered(second) == .failure(.timeout))
        #expect(stubborn.started.count == 1)
        // The old work stays tracked: once it has stopped, the next request runs, strictly after it.
        let third = await generateOnce(coordinator)
        #expect(delivered(third) == .success("late result"))
        let starts = stubborn.started, ends = stubborn.finished
        #expect(starts.count == 2)
        if starts.count == 2, let firstEnd = ends.first { #expect(starts[1] >= firstEnd) }
    }

    @Test func drainLimitBoundsTheWaitWithoutOverlap() async {
        let stubborn = StubbornGenerator(delay: .milliseconds(600))
        let configuration = GenerationCoordinator.Configuration(
            minimumRequestSpacing: .zero, cancelDrainLimit: .milliseconds(100)
        )
        let coordinator = GenerationCoordinator(generator: stubborn, configuration: configuration)
        let operation = UUID()
        let first = Task { await generateOnce(coordinator, operation: operation) }
        await eventually { !stubborn.started.isEmpty }
        await coordinator.cancel(operation: operation)
        _ = await first.value
        let start = ContinuousClock.now
        #expect(delivered(await generateOnce(coordinator)) == .failure(.timeout))
        #expect(ContinuousClock.now - start < .milliseconds(450))
        #expect(stubborn.started.count == 1)
    }

    @Test func cancelBeforeRegistrationStillCancels() async {
        let fake = FakeGenerator(fallback: .init(.text("x", usage: TokenUsage(inputTokens: 1, outputTokens: 1))))
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        let operation = UUID()
        await coordinator.cancel(operation: operation)
        await coordinator.prewarm(operation: operation, instructions: "i", guardrails: .default)
        #expect(await !coordinator.hasPrewarmedSession)
        #expect(cancellation(await generateOnce(coordinator, operation: operation)) == .cancelled)
        #expect(fake.receivedRequests.isEmpty)
        // Other operations are unaffected.
        #expect(delivered(await generateOnce(coordinator)) == .success("x"))
    }

    @Test func failureReasonsAreStable() {
        #expect(AIFailureReason(.modelUnavailable(.deviceNotEligible)) == .deviceNotEligible)
        #expect(AIFailureReason(.modelUnavailable(.assetsUnavailable)) == .assetsUnavailable)
        #expect(AIFailureReason(.refusal) == .guardrail)
        #expect(AIFailureReason(.guardrailViolation) == .guardrail)
        #expect(AIFailureReason(.rateLimited(resetDate: nil)) == .rateLimited)
        #expect(AIFailureReason(.contextSizeExceeded(contextSize: nil, tokenCount: nil)) == .contextSizeExceeded)
        #expect(AIFailureReason(.unsupportedLanguageOrLocale(languageCode: nil)) == .unsupportedLanguage)
        #expect(AIFailureReason(.timeout) == .timeout)
        #expect(AIFailureReason(.cancelled) == .cancelled)
        #expect(AIFailureReason(.other(code: "x")) == .generationError)
    }
}
