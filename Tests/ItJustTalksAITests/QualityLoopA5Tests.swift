import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("Quality loop A5 validation fixes")
struct QualityLoopA5Tests {
    private func outcome(_ source: String, _ output: String, handsFree: Bool) -> ValidationOutcome {
        ResultValidator().validate(ValidationInput(task: .cleanup, source: source, output: output,
            isTruncated: false, protectedInstructions: ["Clean up only."], handsFree: handsFree))
    }

    @Test(arguments: [
        ("The scores were 3, 3, and 5.", "The scores were 3 and 5."),
        ("The scores were 3, 3 and 5.", "The scores were 3 and 5."),
        ("The scores were 3, 3 or 5.", "The scores were 3 or 5."),
        ("The scores were 3, 3, 5.", "The scores were 3, 5."),
        ("The scores were 5 and 3, 3.", "The scores were 5 and 3."),
    ])
    func repeatedListNumbersRemainRequired(_ pair: (String, String)) {
        for handsFree in [false, true] {
            #expect(outcome(pair.0, pair.1, handsFree: handsFree).reasons.contains(.numbersDropped(count: 1)))
        }
    }

    @Test func immediateQuantityRestartStillCompletes() {
        for handsFree in [false, true] {
            #expect(outcome("Please print 3, 3 copies tomorrow.", "Please print 3 copies tomorrow.",
                handsFree: handsFree) == .complete)
        }
    }

    @Test(arguments: ["どれが必要なのか確認してください", "確認が必要なのです", "これは何なのか教えてください"])
    func grammaticalNanoIsNotSeven(_ source: String) {
        #expect(NumberExtractor.sequence(in: source, excludingIdioms: false).isEmpty)
        #expect(NumberExtractor.sequence(in: source, excludingIdioms: true).isEmpty)
    }

    @Test func questionCleanupDoesNotDropANumber() {
        for handsFree in [false, true] {
            #expect(outcome("どれが必要なのか確認してください", "どれが必要か確認してください",
                handsFree: handsFree) == .complete)
        }
    }

    @Test(arguments: [("会議は五月なのかに行います", "会議は5月7日に行います"),
                      ("なのかに会議を行います", "7日に会議を行います"),
                      ("なな個用意してください", "7個用意してください")])
    func contextualSevenRemainsNumeric(_ pair: (String, String)) {
        #expect(NumberExtractor.sequence(in: pair.0, excludingIdioms: false)
            == NumberExtractor.sequence(in: pair.1, excludingIdioms: false))
        for handsFree in [false, true] {
            #expect(!outcome(pair.0, "会議を行います", handsFree: handsFree).isComplete)
        }
    }

    @Test(arguments: [
        ("John's not sending the report today", "John is not sending the report today."),
        ("John’s never sending the report today", "John is never sending the report today."),
    ])
    func namedSubjectContractionsKeepNegation(_ pair: (String, String)) {
        #expect(!CleanupFidelity.changesNegation(source: pair.0, output: pair.1))
        #expect(!CleanupFidelity.changesNegation(source: pair.1, output: pair.0))
        for handsFree in [false, true] {
            #expect(outcome(pair.0, pair.1, handsFree: handsFree) == .complete)
        }
    }

    @Test func possessivesDoNotLicenseNegationTransfers() {
        #expect(CleanupFidelity.changesNegation(
            source: "John's not sending files. Mary is sending files.",
            output: "John is sending files. Mary is not sending files."))
        #expect(!CleanupFidelity.changesNegation(source: "John's report is not ready.",
            output: "John's report isn't ready."))
    }

    @Test func punctuationAfterNoKeepsItsTarget() {
        for handsFree in [false, true] {
            #expect(outcome("No thanks", "No, thanks.", handsFree: handsFree) == .complete)
        }
        #expect(!CleanupFidelity.changesNegation(source: "No thanks", output: "No, thanks."))
        #expect(!CleanupFidelity.changesNegation(source: "No, thanks.", output: "No thanks"))
        #expect(CleanupFidelity.changesNegation(source: "No thanks. Send files.", output: "Thanks. No, send files."))
    }

    @Test func translatedRestartDoesNotRecheckJapaneseNegation() async {
        for handsFree in [false, true] {
            let input = CleanupInput(transcript: "追加の確認は、追加の確認は不要です", promptLanguage: .ja,
                outputLanguage: OutputLanguage(code: "en", name: "English"), handsFree: handsFree)
            let fake = FakeGenerator(script: [.init(.text("No additional confirmation is necessary.",
                usage: TokenUsage(inputTokens: 100, outputTokens: 20)))])
            let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
            let delivered = await CleanupPipeline().run(input, operation: UUID(), coordinator: coordinator, deadline: roomyDeadline)
            guard case .delivered(let result) = delivered else { Issue.record("No result delivered"); continue }
            // Cross-language cleanup is already reviewed as overlapUnverifiable; the recheck must not add a negation change.
            #expect(result.diagnostics.validation?.outcome.reasons.contains(.negationChanged) == false)
        }
    }

    @Test(arguments: [
        ("「さくら」社の資料を確認してください。", "请确认「さくら」公司的资料。"),
        ("「하늘」社の資料を確認してください。", "请确认「하늘」公司的资料。"),
    ])
    func chineseTranslationRetainsSourceNames(_ pair: (String, String)) {
        let result = ResultValidator().validate(ValidationInput(task: .translate, source: pair.0, output: pair.1,
            isTruncated: false, protectedInstructions: ["Translate only."], expectedOutputLanguage: "zh", handsFree: false))
        #expect(!result.reasons.contains { if case .languageMismatch = $0 { return true }; return false })
    }

    @Test(arguments: ["明日行きます。", "请确认「さくら」公司的資料を確認してください。", "请确认「ひかり」公司的资料。"])
    func retainedNamesDoNotExcuseUntranslatedProse(_ output: String) {
        let result = ResultValidator().validate(ValidationInput(task: .translate,
            source: "明日「さくら」社の資料を確認してください。", output: output,
            isTruncated: false, protectedInstructions: ["Translate only."], expectedOutputLanguage: "zh", handsFree: false))
        #expect(result.reasons.contains { if case .languageMismatch = $0 { return true }; return false })
    }

    // A pause-delimited final "you know" is a filler; an unpunctuated one may be content ("Tell me what you know"),
    // so its removal is reviewed rather than silently accepted (content-safe default; CL-037 is reviewed).
    @Test(arguments: [".", "!", ""])
    func pausedFinalYouKnowIsFiller(_ punctuation: String) {
        let source = "um so I think we should uh move the meeting to Thursday, you know" + punctuation
        for handsFree in [false, true] {
            #expect(outcome(source, "so I think we should move the meeting to Thursday", handsFree: handsFree) == .complete)
        }
    }

    @Test func unpunctuatedFinalYouKnowIsNotSilentlyDropped() {
        for (source, output) in [("Tell me what you know.", "Tell me what."),
                                 ("Use the tools you know.", "Use the tools."),
                                 ("um so I think we should uh move the meeting to Thursday you know",
                                  "so I think we should move the meeting to Thursday")] {
            #expect(outcome(source, output, handsFree: false) != .complete)
            #expect(outcome(source, output, handsFree: true) != .complete)
        }
    }

    @Test func trailingListRepeatStaysRequired() {
        let result = ResultValidator().validate(ValidationInput(task: .cleanup, source: "The scores were 5, 3, 3.",
            output: "The scores were 5, 3.", isTruncated: false, protectedInstructions: [], handsFree: false))
        #expect(result.reasons.contains(.numbersDropped(count: 1)))
    }

    @Test func negationPredicateSkipsPausedDiscourseCue() {
        #expect(!CleanupFidelity.changesNegation(source: "I don't, you know, send confidential files.",
                                                  output: "I don't send confidential files."))
        #expect(!CleanupFidelity.changesNegation(source: "I, you know, don't send confidential files.",
                                                  output: "I don't send confidential files."))
        #expect(CleanupFidelity.changesNegation(source: "Alice, you know, doesn't send files. Bob sends files.",
                                                 output: "Alice sends files. Bob doesn't send files."))
    }

    @Test(arguments: ["everyone", "everybody", "anyone", "anybody", "someone", "somebody", "people", "all",
                      "something", "anything", "things", "the people", "the person", "those"])
    func finalRelativeYouKnowStaysContent(_ head: String) {
        for punctuation in ["", ".", "?", "!"] {
            let source = "Please invite " + head + " you know" + punctuation
            #expect(CleanupFidelity.removingEnglishFillers(source) == source)
            for handsFree in [false, true] {
                #expect(!outcome(source, "Please invite " + head + punctuation, handsFree: handsFree).isComplete)
            }
        }
    }
}
