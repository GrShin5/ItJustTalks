import Foundation
import Testing
@testable import ItJustTalksAI
@testable import ItJustTalks

@Suite("Deterministic fallback text on AI cleanup failure")
@MainActor
struct DictationFallbackTextTests {
    // A cue-less restart that the AI path would collapse: the unvalidated fallback must keep every word.
    private let raw = "エクザンプルアプリを起動し、エクザンプルアプリを起動してください"
    private let processed = "ExampleAppを起動し、ExampleAppを起動してください"

    private func request(handsFree: Bool) -> DictationCleanupRequest {
        DictationCleanupRequest(
            transcript: raw, customInstruction: "",
            dictionaryEntries: [PersonalDictionaryEntry(preferredForm: "ExampleApp", spokenForms: ["エクザンプルアプリ"])],
            sttLanguage: .japanese, outputLanguage: .automatic(.japanese), handsFree: handsFree
        )
    }

    @Test(arguments: [AIFailureReason.validationFailed, .timeout, .guardrail, .appleIntelligenceNotEnabled])
    func normalModeInsertsProcessedTextAndKeepsRawOriginal(reason: AIFailureReason) async {
        let service = DictationCleanupService(generator: FakeGenerator(script: []))
        let request = request(handsFree: false)
        let fallback = await service.fallbackText(for: raw, request: request, operation: UUID())
        #expect(fallback == processed)
        let disposition = DictationCleanupDispositionPolicy.disposition(
            for: .failed(reason), original: raw, handsFree: false,
            fallback: { _ in fallback ?? raw }
        )
        #expect(disposition == .insertUnformatted(processed, reason: reason))
        // The value retained for "直前の原文" is the caller's raw transcript, never the processed text.
        #expect(request.transcript == raw)
    }

    @Test func noticeKeyReflectsWhetherDictionaryChangedTheText() async {
        #expect(DictationCleanupMessages.unformattedNoticeKey(inserted: processed, original: raw)
            == DictationCleanupMessages.dictionaryOnlyInsertedKey)
        #expect(DictationCleanupMessages.unformattedNoticeKey(inserted: raw, original: raw)
            == DictationCleanupMessages.unformattedInsertedKey)
        // Without a matching dictionary entry the production fallback is the raw transcript itself.
        let service = DictationCleanupService(generator: FakeGenerator(script: []))
        let plain = "了解しました、了解しましたと伝えてください"
        let request = DictationCleanupRequest(
            transcript: plain, customInstruction: "", dictionaryEntries: [],
            sttLanguage: .japanese, outputLanguage: .automatic(.japanese), handsFree: false
        )
        let inserted = await service.fallbackText(for: plain, request: request, operation: UUID()) ?? ""
        #expect(inserted == plain)
        #expect(DictationCleanupMessages.unformattedNoticeKey(inserted: inserted, original: plain)
            == DictationCleanupMessages.unformattedInsertedKey)
        #expect(DictationCleanupMessages.dictionaryOnlyInsertedKey.contains("「直前の原文をコピー」"))
    }

    @Test func handsFreeAndOtherOutcomesIgnoreFallback() {
        var calls = 0
        let fallback: (String) -> String = { calls += 1; return $0 }
        #expect(DictationCleanupDispositionPolicy.disposition(for: .failed(.timeout), original: raw, handsFree: true,
            fallback: fallback) == .showResult(raw, notice: .aiFailed(.timeout)))
        #expect(DictationCleanupDispositionPolicy.disposition(for: .complete("整形済み"), original: raw, handsFree: false,
            fallback: fallback) == .insert("整形済み"))
        #expect(DictationCleanupDispositionPolicy.disposition(for: .needsReview(nil), original: raw, handsFree: false,
            fallback: fallback) == .showResult(raw, notice: .needsReview))
        #expect(DictationCleanupDispositionPolicy.disposition(for: .cancelled, original: raw, handsFree: false,
            fallback: fallback) == .discard)
        #expect(calls == 0)
    }

    @Test func cancelledFallbackIsNeverDelivered() async {
        let service = DictationCleanupService(generator: FakeGenerator(script: []))
        let operation = UUID()
        service.cancel(operation: operation)
        #expect(await service.fallbackText(for: raw, request: request(handsFree: false), operation: operation) == nil)
    }
}
