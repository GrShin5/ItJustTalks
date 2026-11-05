import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("Independent review safety fixes")
struct ReviewSafetyFixTests {
    private func cleanup(_ source: String, _ output: String, handsFree: Bool = false,
                         hints: [DictionaryHint] = [], spans: [SelfCorrectionSpan]? = nil) -> ValidationOutcome {
        ResultValidator().validate(ValidationInput(task: .cleanup, source: source, output: output,
            isTruncated: false, protectedInstructions: ["Clean up only."],
            allowedNewTerms: hints.map(\.preferred), selectedDictionary: hints,
            handsFree: handsFree, selfCorrections: spans))
    }

    @Test func droppedMeetingClauseRequiresReview() {
        let hints = [DictionaryHint(preferred: "Codex", readings: ["コーデックス"]),
                     DictionaryHint(preferred: "Gemini", readings: ["ジェミニ"]),
                     DictionaryHint(preferred: "Claude", readings: ["クロード"])]
        let source = "次の会議ではコーデックス、ジェミニ、クロードを比較します"
        let output = "Codex、Gemini、Claudeを比較します。"
        for handsFree in [false, true] {
            let result = cleanup(source, output, handsFree: handsFree, hints: hints)
            #expect(result.reasons.contains(.lowContentRetention))
            #expect(!result.isComplete)
        }
    }

    @Test func fillersDictionaryAndPunctuationRemainComplete() {
        let hints = [DictionaryHint(preferred: "Codex", readings: ["コーデックス"])]
        for handsFree in [false, true] {
            #expect(cleanup("えー、あの、えっと、次の会議ではコーデックスを比較します",
                "次の会議ではCodexを比較します。", handsFree: handsFree, hints: hints) == .complete)
            #expect(cleanup("あの人には次の会議で説明します", "あの人には次の会議で説明します。",
                handsFree: handsFree) == .complete)
        }
    }

    @Test func performedRestartAndCorrectionRemainComplete() {
        let source = RestartCollapser.collapse("会議資料を確認し、えっと、会議資料を確認してください")
        #expect(cleanup(source, source + "。") == .complete)
        #expect(cleanup("古い会議資料を確認、いや、新しい会議資料を確認します",
            "新しい会議資料を確認します。",
            spans: [SelfCorrectionSpan(retracted: "古い会議資料を確認", replacement: "新しい会議資料を確認します")]) == .complete)
    }

    @Test(arguments: [
        ("Let's meet at the cafe at noon. Scratch that, let's meet at the office", "Let's meet at the office."),
        ("Let's meet at the cafe, at noon. Scratch that, let's meet at the office", "Let's meet at the office."),
        ("Don't send the report, no wait, send the report today", "Send the report today."),
        ("Send the report to the team, no wait, don't send the report to the team", "Don't send the report to the team."),
        ("The launch is on May second, sorry, May ninth", "The launch is on May ninth."),
    ])
    func certifiedCorrectionsDoNotCountAsLostContent(_ pair: (String, String)) {
        for handsFree in [false, true] {
            #expect(cleanup(pair.0, pair.1, handsFree: handsFree) == .complete)
        }
    }

    @Test func correctionDoesNotExcuseAnotherFactWithSameValue() {
        let source = "The first launch is on May second. The next launch is on May second, sorry, May ninth."
        let kept = "The first launch is on May second. The next launch is on May ninth."
        let dropped = "The first launch is on May. The next launch is on May ninth."
        #expect(!cleanup(source, kept).reasons.contains { if case .numbersDropped = $0 { return true }; return false })
        #expect(cleanup(source, dropped).reasons.contains(.numbersDropped(count: 1)))
    }

    @Test func repeatedValueInDifferentFactsCannotDisappear() {
        for (source, output) in [
            ("会議は3時です。資料は3部です。", "会議は3時です。資料です。"),
            ("赤い箱は3個です。青い箱は3個です。", "赤い箱は3個です。青い箱です。"),
        ] {
            for handsFree in [false, true] {
                #expect(cleanup(source, output, handsFree: handsFree).reasons.contains(.numbersDropped(count: 1)))
            }
        }
        #expect(cleanup("会議は3時、3時からです", "会議は3時からです。") == .complete)
        #expect(cleanup("資料を5部、いや3部印刷してください", "資料を3部印刷してください。") == .complete)
        #expect(cleanup("Book a table for six, no wait, eight people", "Book a table for eight people.") == .complete)
        #expect(cleanup("資料を5部いや3部印刷してください", "資料を3部印刷してください。") == .complete)
    }

    @Test func iyaInsideWordDoesNotRetractQuantity() {
        #expect(cleanup("5部の使いやすい資料を確認します", "使いやすい資料を確認します。").reasons
            .contains(.numbersDropped(count: 1)))
        #expect(cleanup("5部の使いやすい資料と3部の報告です", "使いやすい資料と3部の報告です。").reasons
            .contains(.numbersDropped(count: 1)))
    }

    @Test func tinyAndOversizedNumbersStayDistinct() {
        #expect(NumberExtractor.sequence(in: "0.0000001", excludingIdioms: false) == ["0.0000001"])
        #expect(NumberExtractor.sequence(in: "1.23456789", excludingIdioms: false) !=
            NumberExtractor.sequence(in: "1.23456788", excludingIdioms: false))
        #expect(!cleanup("係数は0.0000001です", "係数は0です。").isComplete)
        let large = String(repeating: "9", count: 50)
        #expect(NumberExtractor.sequence(in: large, excludingIdioms: false) !=
            NumberExtractor.sequence(in: String(large.dropLast()) + "8", excludingIdioms: false))
        #expect(NumberExtractor.sequence(in: "-" + large, excludingIdioms: false) !=
            NumberExtractor.sequence(in: large, excludingIdioms: false))
    }

    @Test func equalNegationCountsCannotSwapPredicates() {
        #expect(CleanupFidelity.changesNegation(source: "保存しない。削除する。", output: "保存する。削除しない。"))
        #expect(cleanup("保存しない。削除する。", "保存する。削除しない。").reasons.contains(.negationChanged))
        #expect(!CleanupFidelity.changesNegation(source: "保存しない。削除する。", output: "保存しません。削除します。"))
    }

    @Test(arguments: [("明日行きます", "zh"), ("내일 갑니다", "zh"), ("明日行きます", "ko")])
    func unchangedForeignScriptRequiresReview(_ pair: (String, String)) {
        let outcome = ResultValidator().validate(ValidationInput(task: .translate, source: pair.0, output: pair.0,
            isTruncated: false, protectedInstructions: ["Translate only."], expectedOutputLanguage: pair.1, handsFree: false))
        #expect(outcome.reasons.contains(.translationUnchanged))
    }

    @Test func modalMayCannotPreserveFiveCopies() {
        for source in ["May I print 5 copies?", "May we print 5 copies?", "You may print 5 copies."] {
            let output = source.replacingOccurrences(of: "5 ", with: "")
            for handsFree in [false, true] {
                #expect(cleanup(source, output, handsFree: handsFree).reasons.contains(.numbersDropped(count: 1)))
            }
        }
        let source = "The launch is on May second. May I print 5 copies?"
        #expect(cleanup(source, "The launch is on May. May I print copies?").reasons.contains(.numbersDropped(count: 2)))
        #expect(cleanup("May I print 5 copies?", "May I print 5 copies?") == .complete)
    }

    @Test(arguments: [
        ("たぶん明日の会議に参加します", "明日の会議に参加します"),
        ("おそらく明日参加します", "明日参加します"),
        ("多分明日参加します", "明日参加します"),
        ("明日参加するかもしれない", "明日参加する"),
        ("もし雨が降れば延期します", "雨が降れば延期します"),
        ("雨なら延期します", "雨で延期します"),
        ("Maybe Alice will attend tomorrow", "Alice will attend tomorrow"),
        ("Alice will probably attend", "Alice will attend"),
        ("Perhaps Alice will attend", "Alice will attend"),
        ("Alice might attend", "Alice attend"),
        ("If Alice calls, answer", "Alice calls, answer"),
        ("Unless Alice calls, wait", "Alice calls, wait"),
        ("Only Alice sends files", "Alice sends files"),
    ])
    func shortQualificationsCannotDisappear(_ pair: (String, String)) {
        #expect(CleanupFidelity.dropsQualifier(source: pair.0, output: pair.1))
        #expect(!CleanupFidelity.dropsQualifier(source: pair.1, output: pair.0))
        for handsFree in [false, true] {
            #expect(cleanup(pair.0, pair.1, handsFree: handsFree).reasons.contains(.lowContentRetention))
            #expect(!cleanup(pair.0, pair.1, handsFree: handsFree).isComplete)
        }
    }

    @Test func qualificationsKeepNormalAndHandsFreeSeverity() {
        let source = "たぶん明日の会議に参加します", output = "明日の会議に参加します"
        if case .needsReview = cleanup(source, output) {} else { Issue.record("Expected review") }
        if case .failed = cleanup(source, output, handsFree: true) {} else { Issue.record("Expected failure") }
    }

    @Test func qualificationsAllowFillersSpellingAndCertifiedCorrections() {
        for handsFree in [false, true] {
            #expect(cleanup("えー、あの、えっと、たぶん明日参加します", "多分明日参加します。", handsFree: handsFree) == .complete)
            #expect(cleanup("Um, uh, maybe Alice will attend", "Maybe Alice will attend.", handsFree: handsFree) == .complete)
            #expect(cleanup("たぶん明日参加します、いや、必ず明日参加します", "必ず明日参加します。",
                handsFree: handsFree, spans: [SelfCorrectionSpan(retracted: "たぶん明日参加します", replacement: "必ず明日参加します")]) == .complete)
        }
        #expect(!CleanupFidelity.dropsQualifier(source: "雨が降るかもしれない", output: "雨が降るかもしれません。"))
        #expect(!CleanupFidelity.dropsQualifier(source: "The gift is ready", output: "The gift is ready."))
        #expect(!CleanupFidelity.dropsQualifier(source: "今日中にしなければならない", output: "今日中にしなきゃ。"))
    }

    @Test func equalQuantitiesBelongToEachSubjectAndClause() {
        for source in ["Alice ordered exactly 3 boxes. Bob ordered exactly 3 boxes.",
                       "Alice ordered exactly 3 boxes. Alice ordered exactly 3 boxes."] {
            let output = source.replacingOccurrences(of: "3 boxes.", with: "boxes.",
                range: source.range(of: "3 boxes.", options: .backwards))
            for handsFree in [false, true] {
                #expect(cleanup(source, output, handsFree: handsFree).reasons.contains(.numbersDropped(count: 1)))
                #expect(cleanup(source, source, handsFree: handsFree) == .complete)
            }
        }
        #expect(cleanup("会議は3時、3時からです", "会議は3時からです。") == .complete)
    }

    @Test func negationCannotMoveBetweenSubjectsOfSamePredicate() {
        let source = "Alice must not send files. Bob must send files."
        let swapped = "Alice must send files. Bob must not send files."
        #expect(CleanupFidelity.changesNegation(source: source, output: swapped))
        #expect(CleanupFidelity.changesNegation(source: swapped, output: source))
        for handsFree in [false, true] {
            #expect(cleanup(source, swapped, handsFree: handsFree).reasons.contains(.negationChanged))
            #expect(cleanup(source, source, handsFree: handsFree) == .complete)
        }
        #expect(CleanupFidelity.changesNegation(
            source: "Alice must not send files. Alice must not send files. Bob must not send files.",
            output: "Alice must not send files. Alice must send files. Bob must not send files. Bob must not send files."))
        #expect(!CleanupFidelity.changesNegation(source: "Alice does not send files. Bob sends files.",
            output: "Alice doesn't send files. Bob sends files."))
    }

    @Test(arguments: ["明日行きます。", "明日、行きます", "明日 行きます！"])
    func punctuationCannotHideUntranslatedJapanese(_ output: String) {
        let outcome = ResultValidator().validate(ValidationInput(task: .translate, source: "明日行きます", output: output,
            isTruncated: false, protectedInstructions: ["Translate only."], expectedOutputLanguage: "zh", handsFree: false))
        #expect(outcome.reasons.contains(.translationUnchanged))
        #expect(outcome.reasons.contains { if case .languageMismatch = $0 { return true }; return false })
    }

    @Test func shortChineseTranslationNeedsConsistentScript() {
        for (source, output, unchanged) in [("明日行きます", "明天去。", false), ("東京", "東京。", false),
                                           ("明日行きます", "明日行く。", true)] {
            let outcome = ResultValidator().validate(ValidationInput(task: .translate, source: source, output: output,
                isTruncated: false, protectedInstructions: ["Translate only."], expectedOutputLanguage: "zh", handsFree: false))
            #expect(outcome.reasons.contains { if case .languageMismatch = $0 { return true }; return false } == unchanged)
            #expect(!outcome.reasons.contains(.translationUnchanged))
        }
    }

    @Test func adjacentDictionaryJoinerFollowsContext() {
        let entries = [DictionaryEntry(preferred: "Codex", readings: ["コーデックス"]),
                       DictionaryEntry(preferred: "Gemini", readings: ["ジェミニ"])]
        for (source, expected) in [
            ("Use コーデックスジェミニ today", "Use Codex, Gemini today"),
            ("今日はコーデックスジェミニを使います", "今日はCodex、Geminiを使います"),
            ("APIでコーデックスジェミニを使います", "APIでCodex、Geminiを使います"),
        ] {
            let input = CleanupInput(transcript: source, dictionaryEntries: entries, promptLanguage: .ja, handsFree: false)
            #expect(CleanupPipeline().deterministicFallbackText(for: input) == expected)
        }
    }

    @Test func longMixedJapaneseKeepsFullStop() {
        let text = "このAPIを利用する前に必ず設定を確認してください。"
        #expect(CleanupPipeline.strippingShortPhraseFullStop(text, transcript: text) == text)
        #expect(CleanupPipeline.strippingShortPhraseFullStop("Thanks.", transcript: "Thanks") == "Thanks")
        #expect(CleanupPipeline.strippingShortPhraseFullStop("API確認。", transcript: "API確認") == "API確認")
    }

    @Test func degreeQuantityIsNotAnIdiom() {
        for source in ["室温は一度でした。室温は一度では作業できません。",
                       "角度は一度です。角度は一度では足りません。"] {
            #expect(RestartCollapser.collapse(source) == source)
        }
        #expect(RestartCollapser.collapse("もう一度確認し、もう一度確認してください") == "もう一度確認してください")
    }

    @Test func longDictationSpanAndFactChecksStayLinear() {
        let sentence = "えーと、明日の会議は10時からです、いや11時からです。資料を3部印刷しないでください。"
        let source = String(repeating: sentence, count: 260)
        let faithful = String(repeating: "明日の会議は11時からです。資料を3部印刷しないでください。", count: 260)
        let unrelated = String(repeating: "週末は天気が良ければ公園で散歩をする予定があります。", count: 300)
        let validator = ResultValidator()
        let elapsed = ContinuousClock().measure {
            for output in [faithful, unrelated] {
                let input = ValidationInput(task: .cleanup, source: source, output: output, isTruncated: false,
                    protectedInstructions: ["Clean up only."], handsFree: false)
                let dropped = CleanupFidelity.dropsContiguousSpan(input: input, source: validator.droppedSpanSource(input))
                // A wholesale rewrite is not a pure deletion; overlap checks own that case.
                if output == faithful { #expect(!dropped) }
                #expect((validator.droppedNumberCount(input: input, output: output) > 0) == (output == unrelated))
                #expect(CleanupFidelity.changesNegation(source: source, output: output) == (output == unrelated))
            }
        }
        // Quadratic span/fact searches took tens of seconds here; the linear ones take well under a second.
        #expect(elapsed < .seconds(6))
    }
}
