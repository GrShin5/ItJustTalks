import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("Deterministic isolated filler removal")
struct FillerStripperTests {
    @Test func removesSourceBackedJapaneseHesitations() {
        let examples = [
            ("まあ 控えの用紙は えっと 引き出しの奥にあります", "まあ 控えの用紙は 引き出しの奥にあります", "控えの用紙は 引き出しの奥にあります"),
            ("なんか 次の確認は 13時からです", "なんか 次の確認は 13時からです", "次の確認は 13時からです"),
            ("検査済みの札を まあ 外しておいてもらえますか", "検査済みの札を まあ 外しておいてもらえますか", "検査済みの札を 外しておいてもらえますか"),
            ("まあ draftを保存してOrmeviaへ渡しておいてください", "まあ draftを保存してOrmeviaへ渡しておいてください", "draftを保存してOrmeviaへ渡しておいてください"),
        ]
        for (source, output, expected) in examples {
            #expect(FillerStripper.strip(output, source: source) == expected)
        }
        #expect(FillerStripper.strip("確認。まあ、次です", source: "まあ 次です") == "確認。次です")
        #expect(FillerStripper.strip("確認\nなんか 次です", source: "なんか 次です") == "確認\n次です")
    }

    @Test func preservesAmbiguousJapaneseWordsAndUnbackedOutput() {
        for text in ["まあまあ、良い", "なんかの 話", "なんか食べたい", "まあ良い", "「まあ」", "「まあ、良い」"] {
            #expect(FillerStripper.strip(text, source: "まあ なんか 話") == text)
        }
        for source in ["まあまあ 良い", "なんかの 話", "なんか食べたい", "「まあ、良い」", "まあ良い"] {
            #expect(FillerStripper.strip("まあ、なんか 話", source: source) == "まあ、なんか 話")
        }
        #expect(FillerStripper.strip("まあ、話", source: "別の話") == "まあ、話")
        #expect(FillerStripper.strip("話まあ、次", source: "まあ 次") == "話まあ、次")
        #expect(FillerStripper.strip("まあ。次", source: "まあ 次") == "まあ。次")
    }

    @Test func removesOnlyIsolatedFillersAtPauses() {
        for filler in ["えっと", "えーと", "えーーっと", "ええと", "えー", "えーー", "あのー", "あのう", "um", "ummm", "uh", "uhhh", "Um"] {
            for separator in ["、", ",", " ", "　", "\t"] {
                for prefix in ["", "予定です。", "予定は、", "本当？", "確認！", "予定です\n", "予定です\r\n"] {
                    let result = FillerStripper.strip(prefix + filler + separator + "明日の会議")
                    #expect(result == prefix + "明日の会議")
                    #expect(FillerStripper.strip(result) == result)
                }
            }
            // A hesitation word alone stays: never turn a dictation into empty text.
            #expect(FillerStripper.strip(filler) == filler)
        }
        #expect(FillerStripper.strip("えっと、えーと、明日の会議") == "明日の会議")
    }

    @Test func preservesAmbiguousEmbeddedAndQuotedText() {
        for source in [
            "あの店に行きます", "あの、店に行きます", "まあ、そうですね", "なんか、変です", "like this",
            "えっと考えます", "あのー店", "うーんと考えます", "umbrella", "uhuru", "summary",
            "今日は um 会議です", "考え中 えっと、明日です", "えっと。明日です", "えっと\n明日です",
            "「えっと、明日です」", "『うーん、そうです』", "“um, tomorrow”", "‘uh, tomorrow’",
            "\"えーと、明日\"", "'um, tomorrow'", "「発言。えっと、明日」", "「引用『えっと、明日』です」",
            "「えっと、閉じていない", "  untouched  \n", "",
        ] {
            #expect(FillerStripper.strip(source) == source)
        }
        #expect(FillerStripper.strip("「えっと、明日」。えーと、予定です") == "「えっと、明日」。予定です")
        #expect(FillerStripper.strip("It's ready。um, tomorrow") == "It's ready。tomorrow")
    }

    @Test func pipelineStripsOnlyOutputAndRetainsValidationSource() async {
        for handsFree in [false, true] {
            let source = "えーと、明日の会議は十時からです"
            let expected = "明日の会議は十時からです"
            let input = CleanupInput(transcript: source, promptLanguage: .ja, handsFree: handsFree)
            let fake = FakeGenerator(script: [.init(.text("えっと、" + expected, usage: TokenUsage(inputTokens: 100, outputTokens: 20)))])
            let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
            let outcome = await CleanupPipeline().run(input, operation: UUID(), coordinator: coordinator, deadline: roomyDeadline)
            guard case .delivered(let result) = outcome else { Issue.record("No result delivered"); continue }
            #expect(result.text == expected)
            #expect(result.status == .complete)
            #expect(result.validationInput?.source == source)
            #expect(result.validationInput?.languageSource == source)
            // The model sees the transcript unchanged; only its output is stripped.
            #expect(fake.receivedRequests.first?.prompt == PromptAssembler.cleanupPrompt(transcript: source, language: .ja))
            #expect(input.transcript == source)
            #expect(CleanupPipeline().deterministicFallbackText(for: input) == source)
        }
    }

    @Test func removalDoesNotMaskLostRequestEnding() async {
        let source = "えっと、会議室を予約しておいてください"
        let fake = FakeGenerator(script: [.init(.text("えーと、会議室を予約してください", usage: TokenUsage(inputTokens: 100, outputTokens: 20)))])
        let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
        let input = CleanupInput(transcript: source, promptLanguage: .ja, handsFree: false)
        let outcome = await CleanupPipeline().run(input, operation: UUID(), coordinator: coordinator, deadline: roomyDeadline)
        guard case .delivered(let result) = outcome else { Issue.record("No result delivered"); return }
        #expect(result.validationInput?.source == source)
        #expect(result.diagnostics.validation?.outcome.reasons.contains(.requestEndingLost) == true)
        #expect(result.status != .complete)
    }

    @Test func responseWordsAndAbbreviationsStay() {
        for source in ["ええ、承知しました", "ううん、大丈夫です", "うーん、難しいですね", "UM, the unit manager", "ええ"] {
            #expect(FillerStripper.strip(source, source: source) == source)
        }
        // Only the speaker's own hesitation is removed from the output.
        #expect(FillerStripper.strip("えっと、明日です", source: "明日です") == "えっと、明日です")
        #expect(FillerStripper.strip("えっと、明日です", source: "えーと、明日です") == "明日です")
        #expect(FillerStripper.strip("えーと", source: "えーと") == "えーと")
    }
}
