import Testing
import ItJustTalksAI
@testable import ItJustTalks

@Suite("Dictation validation reason codes")
struct DictationReasonCodeTests {
    @Test func reviewCarriesCodesWithoutChangingPresentation() {
        let codes = [ValidationReason.newNumbers(count: 2), .languageMismatch(expected: "ja", detected: "en")]
            .map(\.diagnosticName)
        #expect(codes == ["newNumbers", "languageMismatch"])
        for handsFree in [false, true] {
            for generated in [String?.none, "", "review"] {
                let disposition = DictationCleanupDispositionPolicy.disposition(
                    for: .needsReview(generated, reasonCodes: codes),
                    original: "original", handsFree: handsFree
                )
                guard case .showResult(let text, let notice) = disposition else {
                    Issue.record("Review must remain in the result window")
                    continue
                }
                #expect(text == (generated == "review" ? "review" : "original"))
                #expect(notice == .validationReview(codes))
                #expect(DictationCleanupMessages.noticeKeys(notice)
                    == DictationCleanupMessages.noticeKeys(.needsReview))
            }
        }
    }
}
