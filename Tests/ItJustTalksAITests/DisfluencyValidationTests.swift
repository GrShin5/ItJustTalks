import Testing
@testable import ItJustTalksAI

@Suite("Cleanup disfluencies and qualifications")
struct DisfluencyValidationTests {
    private func cleanup(_ source: String, _ output: String, handsFree: Bool,
                         hints: [DictionaryHint] = []) -> ValidationOutcome {
        ResultValidator().validate(ValidationInput(task: .cleanup, source: source, output: output,
            isTruncated: false, protectedInstructions: ["Clean up only."],
            allowedNewTerms: hints.map(\.preferred), selectedDictionary: hints, handsFree: handsFree))
    }

    @Test(arguments: [
        ("So um, I wanted to uh, follow up on the, you know, the invoice from last week", "So I wanted to follow up on the invoice from last week"),
        ("Uh so the, the, um, the shipment should arrive on, uh, Friday morning", "so the shipment should arrive on Friday morning"),
        ("来週の会議の資料をえーと来週の会議の資料をあの来週の会議の資料を作成します", "来週の会議の資料を作成します"),
        ("報告書をほう報告書を提出します", "報告書を提出します"),
        ("Um, so, uh, you should, um, never share the code with anyone", "so you should never share the code with anyone"),
        ("Er, I mean, send the, the report tomorrow", "send the report tomorrow"),
    ])
    func faithfulDisfluencyRemovalIsComplete(_ pair: (String, String)) {
        for handsFree in [false, true] {
            #expect(cleanup(pair.0, pair.1, handsFree: handsFree) == .complete)
        }
    }

    @Test(arguments: [
        ("um so I was thinking we could maybe push the demo to Thursday if that works for you", "so I was thinking we could push the demo to Thursday if that works for you"),
        ("I kind of like the second option better, to be honest", "I kind of like the second option better"),
        ("えーと、今日のタスクは、あの、PR のレビュー、えっと、バグ修正、あと、リリースノートの作成です", "PR のレビュー、バグ修正、リリースノートの作成です"),
    ])
    func meaningfulDropsKeepSeverity(_ pair: (String, String)) {
        if case .needsReview = cleanup(pair.0, pair.1, handsFree: false) {} else { Issue.record("Expected review") }
        if case .failed = cleanup(pair.0, pair.1, handsFree: true) {} else { Issue.record("Expected failure") }
    }

    @Test func dictionaryEnumerationStillRequiresItsIntroductoryClause() {
        let hints = [DictionaryHint(preferred: "Luminous", readings: ["ルミナス"]),
                     DictionaryHint(preferred: "Zephyrion", readings: ["ゼフィリオン"]),
                     DictionaryHint(preferred: "Quantara", readings: ["クアンタラ"])]
        for handsFree in [false, true] {
            #expect(!cleanup("次の会議ではルミナスとゼフィリオンとクアンタラを比較します",
                "LuminousとZephyrionとQuantaraを比較します", handsFree: handsFree, hints: hints).isComplete)
        }
    }

    @Test(arguments: ["できれば", "なるべく", "だけ", "のみ", "しか", "少なくとも", "最低", "必ず", "絶対",
                      "ぜひ", "念のため", "一応", "特に", "ほぼ", "約", "およそ", "以上", "以下", "未満", "以内", "まで", "までに"])
    func shortQualificationsAreProtected(_ word: String) {
        // Synthetic contexts isolate qualification loss from the length/overlap checks.
        let source = "確認は\(word)明日行います", output = "確認は明日行います"
        #expect(CleanupFidelity.dropsQualifier(source: source, output: output))
        for handsFree in [false, true] {
            #expect(cleanup(source, source, handsFree: handsFree) == .complete)
            #expect(!cleanup(source, output, handsFree: handsFree).isComplete)
        }
    }

    @Test func conditionalRequestCannotLoseDekireba() {
        let source = "できれば明日までに資料を送ってください", output = "明日までに資料を送ってください"
        if case .needsReview = cleanup(source, output, handsFree: false) {} else { Issue.record("Expected review") }
        if case .failed = cleanup(source, output, handsFree: true) {} else { Issue.record("Expected failure") }
    }

    @Test(arguments: ["たが", "たけど", "たけれど", "たけれども", "たので", "たから", "たのに", "たし", "たら"])
    func completedClausesAreNotAbandonedTails(_ ending: String) {
        let source = "一度確認し\(ending)、一度確認してください"
        #expect(RestartCollapser.collapse(source) == source)
    }

    @Test func comparisonKeepsSentenceBoundariesAndNonmatchingKana() {
        for source in ["報告書を。報告書を提出します", "報告書を\n報告書を提出します", "報告書をまだ報告書を提出します"] {
            #expect(CleanupFidelity.removingDisfluencies(source) == source)
        }
        #expect(CleanupFidelity.changesNegation(
            source: "Alice must, um, not send files. Bob must send files.",
            output: "Alice must send files. Bob must not send files."))
    }
}
