import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("Final-round cleanup fidelity")
struct FinalRoundFidelityTests {
    private func outcome(_ source: String, _ output: String, handsFree: Bool) -> ValidationOutcome {
        ResultValidator().validate(ValidationInput(task: .cleanup, source: source, output: output,
            isTruncated: false, protectedInstructions: ["Clean up only."], handsFree: handsFree))
    }

    @Test(arguments: ["せず", "せずに", "しない", "しなく", "しなかった", "しません", "しなければ"])
    func negativeAndConditionalTailsStay(_ tail: String) {
        let source = "資料を確認\(tail)、資料を確認したと報告しました"
        #expect(RestartCollapser.collapse(source) == source)
        if !tail.hasSuffix("なければ") {
            for handsFree in [false, true] {
                #expect(!outcome(source, "資料を確認したと報告しました", handsFree: handsFree).isComplete)
            }
        }
    }

    @Test(arguments: [
        "I need to call Alice, um, I need to call Bob too.",
        "会議資料の案、えーと、会議資料の名前を確認します",
        "I will send not, um, I will send the report.",
        "I will send never, um, I will send the report.",
        "I will send no, um, I will send the report.",
    ])
    func fillerDoesNotRetractContent(_ source: String) {
        #expect(RestartCollapser.collapse(source) == source)
    }

    @Test func addedEnglishTaskCannotDisappearInPipeline() async {
        for handsFree in [false, true] {
            let input = CleanupInput(transcript: "I need to call Alice, um, I need to call Bob too.", promptLanguage: .en, handsFree: handsFree)
            let fake = FakeGenerator(script: [.init(.text("I need to call Bob too.", usage: TokenUsage(inputTokens: 100, outputTokens: 20)))])
            let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
            let delivered = await CleanupPipeline().run(input, operation: UUID(), coordinator: coordinator, deadline: roomyDeadline)
            guard case .delivered(let result) = delivered else { Issue.record("No result delivered"); continue }
            #expect(result.status != .complete)
        }
    }

    @Test func genuineRestartsStillCollapse() {
        #expect(RestartCollapser.collapse("I want to, um, I want to schedule a call") == "I want to schedule a call")
        #expect(RestartCollapser.collapse("報告書をまとめた、報告書をまとめて共有してください") == "報告書をまとめて共有してください")
        #expect(RestartCollapser.collapse("まず今起動しました、えーと、まず今起動しているアプリを確認してください")
            == "まず今起動しているアプリを確認してください")
    }

    @Test func pipelineChecksOriginalNegativeClause() async {
        let source = "資料を確認せず、資料を確認したと報告しました"
        let output = "資料を確認したと報告しました"
        for handsFree in [false, true] {
            let input = CleanupInput(transcript: source, promptLanguage: .ja, handsFree: handsFree)
            let fake = FakeGenerator(script: [.init(.text(output, usage: TokenUsage(inputTokens: 100, outputTokens: 20)))])
            let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
            let delivered = await CleanupPipeline().run(input, operation: UUID(), coordinator: coordinator, deadline: roomyDeadline)
            guard case .delivered(let result) = delivered else { Issue.record("No result delivered"); continue }
            #expect(result.status != .complete)
            #expect(result.diagnostics.validation?.outcome.reasons.contains(.negationChanged) == true)
        }
    }

    @Test(arguments: [
        ("Please invite everyone you know.", "Please invite everyone."),
        ("Please invite everyone you know", "Please invite everyone"),
        ("Please explain what I mean.", "Please explain what."),
    ])
    func relativeClausesAreContent(_ pair: (String, String)) {
        #expect(CleanupFidelity.removingEnglishFillers(pair.0) == pair.0)
        for handsFree in [false, true] {
            #expect(!outcome(pair.0, pair.1, handsFree: handsFree).isComplete)
        }
    }

    @Test(arguments: [
        ("You know, please invite everyone.", "Please invite everyone."),
        ("Please, you know, invite everyone.", "Please invite everyone."),
        ("Please invite everyone, you know.", "Please invite everyone."),
        ("I mean, please invite everyone.", "Please invite everyone."),
        ("Please, I mean, invite everyone.", "Please invite everyone."),
    ])
    func punctuatedDiscourseFillersCanDisappear(_ pair: (String, String)) {
        for handsFree in [false, true] {
            #expect(outcome(pair.0, pair.1, handsFree: handsFree) == .complete)
        }
    }

    @Test(arguments: [
        ("ぜひ資料を確認してください", "是非資料を確認してください", "資料を確認してください"),
        ("およそ10分かかります", "約10分かかります", "10分かかります"),
        ("たぶん資料を確認します", "多分資料を確認します", "資料を確認します"),
        ("なるべく資料を確認してください", "成るべく資料を確認してください", "資料を確認してください"),
    ])
    func qualificationVariantsKeepMeaning(_ example: (String, String, String)) {
        #expect(!CleanupFidelity.dropsQualifier(source: example.0, output: example.1))
        #expect(!CleanupFidelity.dropsQualifier(source: example.1, output: example.0))
        #expect(CleanupFidelity.dropsQualifier(source: example.0, output: example.2))
        for handsFree in [false, true] {
            #expect(outcome(example.0, example.1, handsFree: handsFree) == .complete)
            #expect(outcome(example.1, example.0, handsFree: handsFree) == .complete)
            #expect(!outcome(example.0, example.2, handsFree: handsFree).isComplete)
            #expect(!outcome(example.1, example.2, handsFree: handsFree).isComplete)
        }
    }

    @Test func comparisonNormalizesQualifierSpellingsWithoutLosingThem() {
        for pair in [("およそ10分かかります", "約10分かかります"),
                     ("成るべく資料を確認してください", "なるべく資料を確認してください")] {
            #expect(CleanupFidelity.normalizingQualifierSpellings(pair.0)
                == CleanupFidelity.normalizingQualifierSpellings(pair.1))
        }
        #expect(CleanupFidelity.normalizingQualifierSpellings("契約内容を確認します") == "契約内容を確認します")
        for handsFree in [false, true] {
            #expect(!outcome("ほぼ10分かかります", "略10分かかります", handsFree: handsFree).isComplete)
        }
    }

    @Test func contextualParticleSplitsStillProtectQualifiers() {
        for word in ["のみ", "まで"] {
            #expect(CleanupFidelity.dropsQualifier(source: "確認は\(word)明日行います", output: "確認は明日行います"))
        }
    }

    @Test func adjacentFillersKeepTheirPauseEvidence() {
        let source = "Er, you know, I mean, send the report tomorrow"
        let compared = CleanupFidelity.removingEnglishFillers(source)
        #expect(ResultValidator.normalizeForMatch(compared) == "sendthereporttomorrow")
        #expect(!CleanupFidelity.keepsRetractedSegment(source: "Please, I mean, invite everyone.", output: "Please invite everyone."))
    }

    @Test func qualificationSubstringsAreNotParticles() {
        #expect(!CleanupFidelity.dropsQualifier(source: "おもしろい資料を確認します", output: "面白い資料を確認します"))
        #expect(!CleanupFidelity.dropsQualifier(source: "そうだけど資料を確認します", output: "そうですが資料を確認します"))
        #expect(CleanupFidelity.dropsQualifier(source: "資料だけ確認します", output: "資料を確認します"))
    }

    @Test(arguments: [
        ("She’s not sending the report today", "She is not sending the report today."),
        ("She's not sending the report today", "She is not sending the report today."),
        ("He's not sending the report today", "He is not sending the report today."),
        ("It's not working today", "It is not working today."),
        ("That's not working today", "That is not working today."),
        ("There's not enough paper", "There is not enough paper."),
        ("I'm not sending the report today", "I am not sending the report today."),
        ("You're not sending the report today", "You are not sending the report today."),
        ("We're not sending the report today", "We are not sending the report today."),
        ("They're not sending the report today", "They are not sending the report today."),
        ("She isn't sending the report today", "She is not sending the report today."),
        ("They aren't sending the report today", "They are not sending the report today."),
        ("They don't send the report today", "They do not send the report today."),
        ("She doesn't send the report today", "She does not send the report today."),
        ("She won't send the report today", "She will not send the report today."),
        ("She can't send the report today", "She can not send the report today."),
    ])
    func contractedNegationKeepsItsSubject(_ pair: (String, String)) {
        #expect(!CleanupFidelity.changesNegation(source: pair.0, output: pair.1))
        #expect(!CleanupFidelity.changesNegation(source: pair.1, output: pair.0))
    }

    @Test func contractionExpansionIsCompleteInBothModes() {
        for handsFree in [false, true] {
            #expect(outcome("She's not sending the report today", "She is not sending the report today.", handsFree: handsFree) == .complete)
        }
    }

    @Test func contractionsDoNotLicenseNegationTransfers() {
        #expect(CleanupFidelity.changesNegation(source: "She's not sending files. He's sending files.",
            output: "She is sending files. He is not sending files."))
    }

    @Test func immediateNumberPauseRepeatIsNotADroppedFact() {
        let source = "Please print 3, 3 copies tomorrow.", output = "Please print 3 copies tomorrow."
        for handsFree in [false, true] {
            #expect(outcome(source, output, handsFree: handsFree) == .complete)
        }
        for source in ["Please print 3. Print 3 copies tomorrow.", "Please print 3\n3 copies tomorrow.",
                       "Please print 3 copies today, and 3 copies tomorrow."] {
            let input = ValidationInput(task: .cleanup, source: source, output: output, isTruncated: false,
                protectedInstructions: ["Clean up only."], handsFree: false)
            #expect(ResultValidator().droppedNumberCount(input: input, output: output) == 1)
        }
    }
}
