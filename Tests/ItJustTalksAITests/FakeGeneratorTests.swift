import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("FakeGenerator")
struct FakeGeneratorTests {
    let request = GenerationRequest(instructions: "i", prompt: "p", maximumResponseTokens: 10)

    @Test func scriptedReplies() async throws {
        let fake = FakeGenerator(script: [
            .init(.text("一つ目", usage: TokenUsage(inputTokens: 5, outputTokens: 3))),
            .init(.failure(.rateLimited(resetDate: nil))),
        ])
        let first = try await fake.generate(request)
        #expect(first.text == "一つ目")
        #expect(first.usage?.outputTokens == 3)
        #expect(!first.isTruncated)
        await #expect(throws: AIFailure.rateLimited(resetDate: nil)) { try await fake.generate(request) }
        await #expect(throws: AIFailure.other(code: "FakeGenerator.scriptExhausted")) { try await fake.generate(request) }
        #expect(fake.receivedRequests.count == 3)
    }

    @Test func truncationFlag() async throws {
        let fake = FakeGenerator(script: [.init(.text("x", usage: TokenUsage(inputTokens: 5, outputTokens: 10)))])
        #expect(try await fake.generate(request).isTruncated)
    }

    @Test func truncationIsFailClosed() async throws {
        // Unknown usage with a requested limit counts as truncated.
        let fake = FakeGenerator(script: [.init(.text("明日の会議は11時からです。", usage: nil))])
        #expect(try await fake.generate(request).isTruncated)
        // No limit requested: framework default, not flagged.
        let unlimited = FakeGenerator(script: [.init(.text("x", usage: nil))])
        #expect(try await !unlimited.generate(GenerationRequest(instructions: "i", prompt: "p")).isTruncated)
    }

    @Test func truncationSecondSignal() {
        // Near the limit (≥ 90 %) and not ending like a sentence → truncated.
        #expect(TruncationRule.isTruncated(outputTokens: 95, maximumResponseTokens: 100, text: "明日の会議は11時"))
        #expect(!TruncationRule.isTruncated(outputTokens: 95, maximumResponseTokens: 100, text: "明日の会議は11時です。"))
        #expect(!TruncationRule.isTruncated(outputTokens: 50, maximumResponseTokens: 100, text: "明日の会議は11時"))
        #expect(TruncationRule.isTruncated(outputTokens: 100, maximumResponseTokens: 100, text: "終わり。"))
        #expect(TruncationRule.isTruncated(outputTokens: 0, maximumResponseTokens: 0, text: "x"))
        #expect(TruncationRule.isTruncated(outputTokens: nil, maximumResponseTokens: 100, text: "x"))
        #expect(!TruncationRule.isTruncated(outputTokens: nil, maximumResponseTokens: nil, text: "x"))
    }

    @Test func unavailableModel() async {
        let fake = FakeGenerator(availability: .unavailable(.appleIntelligenceNotEnabled))
        await #expect(throws: AIFailure.modelUnavailable(.appleIntelligenceNotEnabled)) { try await fake.generate(request) }
    }

    @Test func cancellationDuringDelay() async {
        let fake = FakeGenerator(script: [.init(.text("late"), delay: .seconds(30))])
        let task = Task { try await fake.generate(request) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.result
        switch result {
        case .success: Issue.record("cancelled request must not return a result")
        case .failure(let error): #expect(error as? AIFailure == .cancelled)
        }
    }

    @Test func cancelledBeforeStart() async {
        let fake = FakeGenerator(script: [.init(.text("x"))])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fake.generate(request)
        }
        let result = await task.result
        if case .failure(let error) = result { #expect(error as? AIFailure == .cancelled) } else {
            Issue.record("expected cancellation")
        }
    }

    @Test func structuredDefaultUsageAndExplicitUnknown() async throws {
        let json = "{\"taskType\":\"proofread_rewrite\",\"isReplacementArtifact\":false}"
        let fake = FakeGenerator(script: [.init(.text(json)), .init(.text(json, usage: nil)),
            .init(.text(json, usage: TokenUsage(inputTokens: 1, outputTokens: 10)))])
        #expect(try await !fake.generate(request, generating: TaskClassification.self).isTruncated)
        #expect(try await fake.generate(request, generating: TaskClassification.self).isTruncated)
        #expect(try await fake.generate(request, generating: TaskClassification.self).isTruncated)
    }

    @Test func structuredOutput() async throws {
        let fake = FakeGenerator(script: [
            .init(.text("{\"taskType\": \"summarize\", \"isReplacementArtifact\": false}")),
            .init(.text("not json")),
        ])
        let result = try await fake.generate(request, generating: TaskClassification.self)
        #expect(result.value == TaskClassification(taskType: .summarize, isReplacementArtifact: false))
        #expect(result.value.taskType.generationTask == .summarize)
        await #expect(throws: AIFailure.structuredParsingFailed) {
            try await fake.generate(request, generating: TaskClassification.self)
        }
    }
}
