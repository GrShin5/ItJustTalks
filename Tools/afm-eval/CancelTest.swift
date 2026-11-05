import Foundation
import ItJustTalksAI

/// V-04: cancel a long-ish generation and measure how fast the generator returns, that no text comes back
/// after the cancel, and how long the next request takes.
struct CancelRoundRecord: Codable, Sendable {
    var round: Int
    var cancelAfterMs: Int
    /// The generation had already finished before the cancel was sent (not a valid cancel sample).
    var finishedBeforeCancel: Bool
    var cancelToReturnMs: Double?
    /// Failure code the cancelled call ended with ("cancelled" expected), or "none" when it returned text.
    var cancelledCallOutcome: String
    /// Text came back after the cancel was sent. Must be false.
    var textAfterCancel: Bool
    var nextRequestMs: Double?
    var nextRequestOutcome: String
    var nextRequestHadText: Bool
}

struct CancelSummary: Codable, Sendable {
    var settings: SettingsRecord
    var model: ModelRecord
    var rounds: Int
    var cancelAfterMs: Int
    var validCancelSamples: Int
    var finishedBeforeCancel: Int
    var textAfterCancelCount: Int
    var cancelToReturn: LatencyStats
    var nextRequest: LatencyStats
    var nextRequestFailures: Int
}

private final class CompletionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var completedAt: ContinuousClock.Instant?

    func markCompleted() { lock.withLock { completedAt = ContinuousClock.now } }
    var value: ContinuousClock.Instant? { lock.withLock { completedAt } }
}

private func failureCode(_ error: any Error) -> String {
    (error as? AIFailure)?.code ?? "other"
}

enum CancelTest {
    /// Synthetic transcript, long enough that generating it takes seconds on the device.
    private static func syntheticTranscript(paragraphs: Int) -> String {
        (1...paragraphs).map { number in
            "えーと、\(number)件目の確認事項です。ルミナ端末の更新作業は\(number + 2)日の午後\(number % 9 + 1)時から始めて、あの、担当は水無瀬さんと堀江さんです。"
                + "予算は\(number * 12)万円で、予備日は\(number % 20 + 1)日になります。"
        }.joined()
    }

    static func run(_ options: CancelTestOptions) async throws {
        let runOptions = RunOptions(
            casesDirectory: options.outDirectory, outDirectory: options.outDirectory,
            promptLanguage: PromptLanguageChoice(rawValue: options.promptLanguage.rawValue) ?? .ja, fake: options.fake
        )
        let harness = try Harness(options: runOptions)
        guard harness.availability.isAvailable else {
            throw OptionError.message("model unavailable: \(harness.availability)")
        }
        let generator = harness.generator
        let template = PromptCatalog.template(.cleanup, language: options.promptLanguage)
        let longText = syntheticTranscript(paragraphs: 14)
        let longPrompt = PromptAssembler.cleanupPrompt(transcript: longText, language: options.promptLanguage)
        let shortPrompt = PromptAssembler.cleanupPrompt(transcript: "えーと、明日の会議は午後3時からです", language: options.promptLanguage)
        let longRequest = harness.makeRequest(task: .cleanup, instructions: template.text, prompt: longPrompt, maximumResponseTokens: 1200)
        let shortRequest = harness.makeRequest(task: .cleanup, instructions: template.text, prompt: shortPrompt, maximumResponseTokens: 120)

        try FileManager.default.createDirectory(at: options.outDirectory, withIntermediateDirectories: true)
        let file = try JSONLinesFile(url: options.outDirectory.appendingPathComponent("cancel-test.jsonl"))
        defer { file.close() }

        // One warm-up so round 1 is not dominated by the cold start.
        if let fake = harness.fake { fake.enqueue(.init(.text("ok"))) }
        _ = try? await generator.generate(shortRequest)

        var rounds: [CancelRoundRecord] = []
        for round in 1...options.count {
            if let fake = harness.fake {
                fake.enqueue(.init(.text("late text that must never be returned"), delay: .seconds(20)))
                fake.enqueue(.init(.text("ok"), delay: .milliseconds(30)))
            }
            let clock = CompletionClock()
            let task = Task { () -> Result<GenerationResult, AIFailure> in
                do throws(AIFailure) {
                    let result = try await generator.generate(longRequest)
                    clock.markCompleted()
                    return .success(result)
                } catch {
                    clock.markCompleted()
                    return .failure(error)
                }
            }
            try? await Task.sleep(for: .milliseconds(options.cancelAfterMs))
            let cancelSent = ContinuousClock.now
            let finishedBefore = clock.value != nil
            task.cancel()
            let outcome = await task.value
            let returned = clock.value ?? ContinuousClock.now

            var cancelledOutcome = "none"
            var textAfterCancel = false
            switch outcome {
            case .success(let result):
                textAfterCancel = !finishedBefore && !result.text.isEmpty
            case .failure(let failure):
                cancelledOutcome = failure.code
            }

            // The next request, issued right after the cancelled call returned.
            let nextStart = ContinuousClock.now
            var nextOutcome = "ok"
            var nextHadText = false
            do {
                let next = try await generator.generate(shortRequest)
                nextHadText = !next.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } catch {
                nextOutcome = failureCode(error)
            }
            let nextMs = harness.milliseconds(ContinuousClock.now - nextStart)

            let record = CancelRoundRecord(
                round: round, cancelAfterMs: options.cancelAfterMs, finishedBeforeCancel: finishedBefore,
                cancelToReturnMs: finishedBefore ? nil : harness.milliseconds(returned - cancelSent),
                cancelledCallOutcome: cancelledOutcome, textAfterCancel: textAfterCancel,
                nextRequestMs: nextMs, nextRequestOutcome: nextOutcome, nextRequestHadText: nextHadText
            )
            try file.append(record)
            rounds.append(record)
        }

        let valid = rounds.filter { !$0.finishedBeforeCancel }
        let summary = CancelSummary(
            settings: harness.settings, model: harness.model, rounds: rounds.count, cancelAfterMs: options.cancelAfterMs,
            validCancelSamples: valid.count, finishedBeforeCancel: rounds.count - valid.count,
            textAfterCancelCount: rounds.filter(\.textAfterCancel).count,
            cancelToReturn: LatencyStats(valid.compactMap(\.cancelToReturnMs)),
            nextRequest: LatencyStats(rounds.compactMap(\.nextRequestMs)),
            nextRequestFailures: rounds.filter { CancelRecovery.failed(outcome: $0.nextRequestOutcome, hadText: $0.nextRequestHadText) }.count
        )
        try JSONLines.prettyEncoder.encode(summary).write(to: options.outDirectory.appendingPathComponent("cancel-summary.json"))

        func ms(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "-" }
        let markdown = """
        # afm-eval cancel-test (V-04)

        - rounds \(summary.rounds), cancel after \(summary.cancelAfterMs) ms, valid cancel samples \(summary.validCancelSamples) (finished before cancel: \(summary.finishedBeforeCancel))
        - text returned after cancel: \(summary.textAfterCancelCount) (must be 0)
        - cancel to generator return (ms): p50 \(ms(summary.cancelToReturn.p50Ms)), p95 \(ms(summary.cancelToReturn.p95Ms)), max \(ms(summary.cancelToReturn.maxMs))
        - next short request after cancel (ms): p50 \(ms(summary.nextRequest.p50Ms)), p95 \(ms(summary.nextRequest.p95Ms)), max \(ms(summary.nextRequest.maxMs)); failures \(summary.nextRequestFailures)
        - model: variant `\(summary.model.variant ?? "-")`, contextSize \(summary.model.contextSize), OS `\(summary.model.os)`, fake \(summary.settings.fake)

        """
        try markdown.write(to: options.outDirectory.appendingPathComponent("cancel-summary.md"), atomically: true, encoding: .utf8)
        print("cancel-test: rounds=\(summary.rounds) valid=\(summary.validCancelSamples) textAfterCancel=\(summary.textAfterCancelCount) cancelToReturn p50=\(ms(summary.cancelToReturn.p50Ms))ms p95=\(ms(summary.cancelToReturn.p95Ms))ms next p50=\(ms(summary.nextRequest.p50Ms))ms failures=\(summary.nextRequestFailures)")
    }
}
