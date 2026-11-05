import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("CleanupSpeechActRetry")
struct CleanupSpeechActRetryTests {
    private func run(_ source: String, fake: FakeGenerator, handsFree: Bool = false,
                     deadline: DeadlinePolicy = roomyDeadline) async -> CleanupResult? {
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        let outcome = await CleanupPipeline().run(
            CleanupInput(transcript: source, promptLanguage: .ja, handsFree: handsFree),
            operation: UUID(), coordinator: coordinator, deadline: deadline)
        guard case .delivered(let result) = outcome else { return nil }
        return result
    }

    @Test(arguments: ["。", "？", "！", "\n", " ", "", "。\n", "\r\n", "　"])
    func mergedActsRecover(separator: String) async {
        // Hands-free never retries: a failed result must not become sendable.
        let handsFreeFake = FakeGenerator(script: [.init(.text("配布資料を送ってください。"))])
        let handsFreeResult = await run("配布資料を送った" + separator + "配布資料を送ってください",
                                        fake: handsFreeFake, handsFree: true)
        #expect(handsFreeResult?.status != .complete)
        #expect(handsFreeFake.receivedRequests.count == 1)
        for handsFree in [false] {
            let fake = FakeGenerator(script: [
                .init(.text("配布資料を送ってください。")),
                .init(.text("配布資料を送った。")),
                .init(.text("配布資料を送ってください。")),
            ])
            let result = await run("配布資料を送った" + separator + "配布資料を送ってください",
                                   fake: fake, handsFree: handsFree)
            #expect(result?.status == .complete)
            #expect(result?.text == "配布資料を送った" + (separator.isEmpty ? "。" : separator) + "配布資料を送ってください。")
            #expect(result?.diagnostics.calls.count == 3)
            #expect(fake.receivedRequests.count == 3)
            #expect(fake.receivedRequests.dropFirst().allSatisfy {
                $0.instructions == fake.receivedRequests.first?.instructions
            })
            guard fake.receivedRequests.count == 3 else { continue }
            #expect(fake.receivedRequests[1].prompt.contains("配布資料を送った"))
            #expect(!fake.receivedRequests[1].prompt.contains("配布資料を送ってください"))
        }
    }

    @Test func unsuccessfulRetryKeepsFirstResult() async {
        for handsFree in [false, true] {
            let fake = FakeGenerator(script: [
                .init(.text("配布資料を送ってください。")),
                .init(.text("配布資料を送った。")),
                .init(.text("配布資料。")),
            ])
            let result = await run("配布資料を送った 配布資料を送ってください", fake: fake, handsFree: handsFree)
            #expect(result?.status == (handsFree ? .failed(.validationFailed) : .needsReview([.lowContentRetention])))
            #expect(result?.text == "配布資料を送ってください。")
            // Hands-free does not retry at all.
            #expect(fake.receivedRequests.count == (handsFree ? 1 : 3))
            #expect(result?.diagnostics.calls.count == (handsFree ? 1 : 3))
        }
    }

    @Test(arguments: [
        ("配布資料を送らなかった 配布資料を送ってください", "配布資料を送ってください。"),
        ("配布資料を3部送った 配布資料を送ってください", "配布資料を送ってください。"),
        ("配布資料を送っておいた 配布資料を送ってください", "配布資料を送ってください。"),
        ("たぶん配布資料を送った 配布資料を送ってください", "配布資料を送ってください。"),
        ("配布資料を送った 配布資料を送ってください", "配布資料を4部送ってください。"),
        ("配布資料と議事録を送った 配布資料と議事録を送ってください", "配布資料を送ってください。"),
    ])
    func otherFidelityFailuresDoNotRetry(pair: (String, String)) async {
        let fake = FakeGenerator(script: [.init(.text(pair.1))])
        let result = await run(pair.0, fake: fake)
        #expect(result?.status != .complete)
        #expect(fake.receivedRequests.count == 1)
    }

    @Test func completeFirstResultDoesNotRetry() async {
        let output = "配布資料を送った。配布資料を送ってください。"
        let fake = FakeGenerator(script: [.init(.text(output))])
        let result = await run("配布資料を送った 配布資料を送ってください", fake: fake)
        #expect(result?.status == .complete)
        #expect(fake.receivedRequests.count == 1)
    }

    @Test func joinedResultMustRetainBothSpeechActs() async {
        let fake = FakeGenerator(script: [
            .init(.text("配布資料を送ってください。")),
            .init(.text("配布資料を送ってください。")),
            .init(.text("配布資料を送ってください。")),
        ])
        let result = await run("配布資料を送った 配布資料を送ってください", fake: fake)
        #expect(result?.status == .needsReview([.lowContentRetention]))
        #expect(result?.text == "配布資料を送ってください。")
        #expect(fake.receivedRequests.count == 3)
    }

    @Test func publicCleanupStageAlsoRecovers() async {
        let source = "配布資料を送った配布資料を送ってください"
        let fake = FakeGenerator(script: [
            .init(.text("配布資料を送ってください。")),
            .init(.text("配布資料を送った。")),
            .init(.text("配布資料を送ってください。")),
        ])
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        let outcome = await coordinator.perform(operation: UUID(), priority: .interactive, deadline: roomyDeadline) {
            await CleanupPipeline().cleanupStage(
                CleanupInput(transcript: source, promptLanguage: .ja, handsFree: false),
                after: .notRun(transcript: source), using: $0)
        }
        guard case .delivered(let result) = outcome else { Issue.record("No result delivered"); return }
        #expect(result.status == .complete)
        #expect(fake.receivedRequests.count == 3)
    }

    @Test func operationDeadlineStopsRecovery() async {
        let fake = FakeGenerator(script: [
            .init(.text("配布資料を送ってください。")),
            .init(.text("配布資料を送った。"), delay: .seconds(2)),
            .init(.text("配布資料を送ってください。")),
        ])
        let result = await run("配布資料を送った 配布資料を送ってください", fake: fake,
                               deadline: DeadlinePolicy(cap: .milliseconds(300)))
        #expect(result?.status != .complete)
        #expect(fake.receivedRequests.count == 2)
    }

    @Test func cancellationStopsRecovery() async {
        let fake = FakeGenerator(script: [
            .init(.text("配布資料を送ってください。")),
            .init(.text("配布資料を送った。"), delay: .seconds(2)),
            .init(.text("配布資料を送ってください。")),
        ])
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        let operation = UUID()
        let task = Task {
            await CleanupPipeline().run(
                CleanupInput(transcript: "配布資料を送った 配布資料を送ってください", promptLanguage: .ja, handsFree: false),
                operation: operation, coordinator: coordinator, deadline: roomyDeadline)
        }
        await eventually { fake.receivedRequests.count == 2 }
        await coordinator.cancel(operation: operation)
        let outcome = await task.value
        guard case .cancelled(.cancelled) = outcome else { Issue.record("Cancellation must discard recovery"); return }
        #expect(fake.receivedRequests.count == 2)
    }

    @Test func retryFailureDoesNotStartAnotherRound() async {
        let fake = FakeGenerator(script: [
            .init(.text("配布資料を送ってください。")), .init(.failure(.timeout)),
        ])
        let result = await run("配布資料を送った配布資料を送ってください", fake: fake)
        #expect(result?.status == .needsReview([.lowContentRetention]))
        #expect(fake.receivedRequests.count == 2)
        #expect(result?.diagnostics.calls.last?.failure == .timeout)
    }
}
