import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("Cue-less dictation restarts")
struct RestartCollapserTests {
    @Test func preservesUnpunctuatedDifferentSpeechActs() {
        for source in [
            "保管箱を閉じた保管箱を閉じてください",
            "保管箱を閉じた 保管箱を閉じてください",
            "窓を開けた窓を開けないでください",
            "書類を出しました書類を出してください",
            "荷物を運んだ荷物を運びたい",
            "部屋を片付けた部屋を片付けない",
        ] {
            #expect(RestartCollapser.collapse(source) == source)
        }
        #expect(RestartCollapser.collapse("まず今起動した、まず今起動しているアプリが最新か確認してください")
            == "まず今起動しているアプリが最新か確認してください")
        #expect(RestartCollapser.collapse("明日の会議と明日の会議室を確認してください")
            == "明日の会議と明日の会議室を確認してください")
    }

    @Test func collapsesFalseStartsAndIsIdempotent() {
        let cases = [
            ("まず今起動した。まず今起動してまず今起動しているアプリが最新か確認してください",
             "まず今起動した。まず今起動しているアプリが最新か確認してください"),
            ("資料を送っ、資料を送ってください", "資料を送ってください"),
            ("I want to, I want to schedule a call", "I want to schedule a call"),
            ("会議室を予約し。会議室を予約しておいてください", "会議室を予約し。会議室を予約しておいてください"),
            ("資料を送った。資料を送ってください", "資料を送った。資料を送ってください"),
            ("資料を確認します。資料を確認してください", "資料を確認します。資料を確認してください"),
            ("資料を送っ …\n資料を送ってください", "資料を送っ …\n資料を送ってください"),
            ("資料を送っ資料を送ってください", "資料を送ってください"),
            ("Ｉ WANT TO, I want to schedule a call", "I want to schedule a call"),
            ("Please reserve the room, please reserve the meeting room", "Please reserve the meeting room"),
            ("Done. We want to, we want to schedule a call", "Done. We want to schedule a call"),
            ("ok, We want to, we want to schedule a call", "ok, we want to schedule a call"),
            ("メモです。資料を送っ、資料を送ってください", "メモです。資料を送ってください"),
        ]
        for (source, expected) in cases {
            let result = RestartCollapser.collapse(source)
            #expect(result == expected)
            #expect(RestartCollapser.collapse(result) == result)
        }
    }

    @Test func repeatedIchidoCheckCollapsesWithoutLosingMeasurements() {
        let source = "一度確認して一度確認して一度確認してから送ります"
        let expected = "一度確認してから送ります"
        #expect(RestartCollapser.collapse(source) == expected)
        #expect(RestartCollapser.collapse(expected) == expected)
        for source in ["室温は一度でした。室温は一度では作業できません。",
                       "角度は一度です。角度は一度では足りません。",
                       "十一度確認し、十一度確認してください"] {
            #expect(RestartCollapser.collapse(source) == source)
        }
    }

    @Test func ichidoMeasurementContextsStayProtected() {
        for suffix in ["で", "です", "だ", "の", "以上", "以下", "未満", "前後", "くらい", "ぐらい", "程度", "上が", "下が", "上昇", "低下"] {
            let source = "一度\(suffix)調整し、一度\(suffix)調整してください"
            #expect(RestartCollapser.collapse(source) == source)
        }
        for prefix in ["零下", "マイナス", "約", "およそ", "摂氏", "華氏", "気温", "室温", "温度", "角度"] {
            let source = "\(prefix)一度確認し、\(prefix)一度確認してください"
            #expect(RestartCollapser.collapse(source) == source)
        }
    }

    @Test func preservesLookAlikesAndProtectedContent() {
        for source in [
            "明日の会議と明日の会議室", "東京と東京駅", "1,000円、1,000円",
            "どんどんどんどん", "AチームとBチームの比較",
            "確認します。確認しましたら連絡します",
            "第一会議室を予約し、第一会議室を予約してください",
            "第１会議室を予約し、第１会議室を予約してください",
            "予算は千万円、予算は千万円です", "どんどんとん、どんどんとんと進む",
            "We need three reports, we need three reports tomorrow",
            "資料を送ります。資料を送ってください", // Y exceeds two graphemes.
            "I want, I want a call", // Fewer than three words.
            "I want to maybe later, I want to schedule a call", // Y exceeds one word.
            "", "了解", "  untouched  \n",
        ] {
            #expect(RestartCollapser.collapse(source) == source)
        }
        for connector in ["と", "や", "の", "も", "に", "を", "は", "が", "で", "へ", "か"] {
            let source = "会議資料の確認\(connector)会議資料の確認方法"
            #expect(RestartCollapser.collapse(source) == source)
        }
        for connector in ["and", "or", "of", "to"] {
            let source = "We need help \(connector) we need help tomorrow"
            #expect(RestartCollapser.collapse(source) == source)
        }
    }

    @Test func collapsesLongTailsFillersIdiomsAndRepeatedRestarts() {
        let cases = [
            // Long abandoned tail (verb/aux ending) only when a filler ends the abandoned attempt.
            ("まず今起動しました、えーと、まず今起動しているアプリが最新か確認してください",
             "まず今起動しているアプリが最新か確認してください"),
            ("会議資料を確認しています、えーと、会議資料を確認してから返信します", "会議資料を確認してから返信します"),
            // Three and four consecutive restarts converge.
            ("まず今起動しました。えっと、まず今起動して、まず今起動しているアプリを確認してください",
             "まず今起動しました。えっと、まず今起動しているアプリを確認してください"),
            ("会議資料を確認し、えーと、会議資料を確認しました。あの、会議資料を確認して、会議資料を確認してから返信します",
             "会議資料を確認しました。あの、会議資料を確認してから返信します"),
            ("I want to, I want to, uh, I want to, I want to schedule a call", "I want to schedule a call"),
            // Fillers and pause punctuation between copies.
            ("資料を送っ、えーと、資料を送ってください", "資料を送ってください"),
            ("資料を送っ えっと 資料を送ってください", "資料を送ってください"),
            ("資料を送っ、あのー、資料を送ってください", "資料を送ってください"),
            ("資料を送っ、その、資料を送ってください", "資料を送ってください"),
            ("資料を送っ、まあ、資料を送ってください", "資料を送ってください"),
            ("I want to, um, I want to schedule a call", "I want to schedule a call"),
            ("I want to go, uh, I want to schedule a call", "I want to go, uh, I want to schedule a call"),
            // Idiomatic numeral words are not amounts.
            ("もう一度確認しました、えーと、もう一度確認してください", "もう一度確認してください"),
            ("もう一度確認し、もう一度確認してください", "もう一度確認してください"),
            ("一緒に確認し、一緒に確認してください", "一緒に確認してください"),
            ("一人で作業し、一人で作業してください", "一人で作業してください"),
        ]
        for (source, expected) in cases {
            let result = RestartCollapser.collapse(source)
            #expect(result == expected)
            #expect(RestartCollapser.collapse(result) == result)
        }
    }

    @Test func extendedRulesKeepFalseCollapseGuards() {
        for source in [
            "とてもとても", "とてもとても大事です", "本当に本当にありがとう",
            "まず今起動しましたまず今起動して", // Long tail without a pause or filler.
            "会議資料を確認する予定です。会議資料を確認してください", // Tail is not a verb/aux ending.
            "I want to go there, I want to schedule a call", // Two-word English tail needs a filler.
            "I want to go over there, uh, I want to schedule a call", // Three words.
            "I want to go there, uh, I want to schedule a call", // English keeps the one-word tail.
            "明日の会議と、えーと、明日の会議室", // Connector stays protected behind a filler.
            "1,000円、えーと、1,000円", "3回確認しました。3回確認してください",
            "十一人で作業し、十一人で作業してください", "二度確認しました。二度確認してください",
            "会議資料を確認しました。あの資料を確認して", // Demonstrative before a noun is not a filler.
            "田中さんがいます。田中さんが来てくれます", // います only completes an X ending in the te-form.
        ] {
            #expect(RestartCollapser.collapse(source) == source)
        }
    }

    @Test func punctuationAloneDoesNotDropCompleteClausesOrListItems() {
        for source in [
            // Long tail separated only by punctuation: two complete clauses.
            "契約書に署名しました。契約書に署名してください",
            "田中さんに伝えています。田中さんに伝えてください",
            "会議資料を確認しています、会議資料を確認してから返信します",
            "まず今起動しました。まず今起動しているアプリが最新か確認してください",
            // English long tail even with a filler, and one-word tails that are different words.
            "We need to call them, um, we need to email them",
            "We need more time, we need more money",
            // Short tail that is a different word, and exact repeats.
            "新しいプロジェクト案、新しいプロジェクト名",
            "お願いします、お願いします", "お願いします、お願いします。",
            // Bare 一人 is a head count, not an idiom.
            "一人に連絡し、一人に連絡してください",
        ] {
            #expect(RestartCollapser.collapse(source) == source)
        }
        // Repeated restarts without fillers keep the earliest complete clause rather than dropping it.
        #expect(RestartCollapser.collapse("まず今起動しました。まず今起動して、まず今起動しているアプリを確認してください")
            == "まず今起動しました。まず今起動しているアプリを確認してください")
    }

    @Test(arguments: ["。", "．", ".", "！", "？", "!", "?", "\n", "\r\n"])
    func terminalBoundariesAlwaysPreserveEarlierSentence(_ boundary: String) {
        for (first, second) in [("資料を送っ", "資料を送ってください"),
                                ("I want to", "I want to schedule a call")] {
            for filler in ["", " um, "] {
                let source = first + boundary + filler + second
                #expect(RestartCollapser.collapse(source) == source)
            }
        }
    }

    @Test func softPausesStillAllowRestarts() {
        for pause in ["、", ",", "…"] {
            #expect(RestartCollapser.collapse("資料を送っ" + pause + "資料を送ってください") == "資料を送ってください")
        }
        let source = "まず今起動した。まず今起動してまず今起動しているアプリを確認してください"
        let expected = "まず今起動した。まず今起動しているアプリを確認してください"
        #expect(RestartCollapser.collapse(source) == expected)
        #expect(RestartCollapser.collapse(expected) == expected)
    }

    @Test func deterministicFallbackOnlySubstitutesDictionaryLiterals() {
        // The fallback is not validated, so it never removes text: no restart collapsing.
        let raw = "エクザンプルアプリを起動し、エクザンプルアプリを起動してください"
        let input = CleanupInput(
            transcript: raw,
            dictionaryEntries: [DictionaryEntry(preferred: "ExampleApp", readings: ["エクザンプルアプリ"])],
            promptLanguage: .ja, handsFree: false
        )
        #expect(CleanupPipeline().deterministicFallbackText(for: input) == "ExampleAppを起動し、ExampleAppを起動してください")
        #expect(input.transcript == raw)
        #expect(CleanupPipeline().deterministicFallbackText(for: CleanupInput(transcript: "了解", promptLanguage: .ja, handsFree: false)) == "了解")
    }

    @Test func pipelineUsesCollapsedSourceInBothModes() async {
        for handsFree in [false, true] {
            for (source, expected, language) in [
                ("まず今起動した。まず今起動してまず今起動しているアプリが最新か確認してください",
                 "まず今起動した。まず今起動しているアプリが最新か確認してください", PromptLanguage.ja),
                ("I want to, I want to schedule a call", "I want to schedule a call", PromptLanguage.en),
            ] {
                let input = CleanupInput(transcript: source, promptLanguage: language, handsFree: handsFree)
                let fake = FakeGenerator(script: [.init(.text(expected, usage: TokenUsage(inputTokens: 100, outputTokens: 20)))])
                let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
                let outcome = await CleanupPipeline().run(input, operation: UUID(), coordinator: coordinator, deadline: roomyDeadline)
                guard case .delivered(let result) = outcome else { Issue.record("No result delivered"); continue }
                #expect(result.status == .complete)
                #expect(result.text == expected)
                #expect(result.validationInput?.source == expected)
                #expect(result.validationInput?.languageSource == expected)
                #expect(fake.receivedRequests.count == 1)
                #expect(fake.receivedRequests.first?.prompt == PromptAssembler.cleanupPrompt(transcript: expected, language: language))
                #expect(input.transcript == source) // The caller's restore-original value is untouched.
                #expect(result.diagnostics.promptKeys == ["cleanup@6/\(language.rawValue)"])
            }
        }
    }
}

@Suite("Restart before a comma (FD-038)")
struct RestartBeforeCommaTests {
    @Test func unfinishedFragmentsCollapseAtSoftPauses() {
        for pause in ["、", " ", "　", "、えーと、"] {
            for (fragment, completed) in [
                ("会議室を予約し", "会議室を予約しておいてください"),
                ("まず今起動した", "まず今起動しているアプリを確認してください"),
            ] {
                let result = RestartCollapser.collapse(fragment + pause + completed)
                #expect(result == completed)
                #expect(RestartCollapser.collapse(result) == result)
            }
            for (first, second) in [
                ("資料を送った", "資料を送ってください"),
                ("会議室を予約します", "会議室を予約しますので待ってください"),
                ("会議室を予約しません", "会議室を予約しませんでした"),
                ("明日の会議と", "明日の会議室"),
            ] {
                let source = first + pause + second
                #expect(RestartCollapser.collapse(source) == source)
            }
        }
    }

    @Test func abandonedPastFormBeforeCommaCollapses() {
        #expect(RestartCollapser.collapse("報告書をまとめた、報告書をまとめて共有してください") == "報告書をまとめて共有してください")
        #expect(RestartCollapser.collapse("一度確認したが、一度確認してください") == "一度確認したが、一度確認してください")
    }
}
