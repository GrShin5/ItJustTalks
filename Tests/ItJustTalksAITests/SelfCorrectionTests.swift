import Testing
@testable import ItJustTalksAI

// All texts below are synthetic and differ from Evaluation/cases and Evaluation/holdout.

@Suite("SelfCorrection — stage-A gate and deterministic application")
struct SelfCorrectionTests {
    // MARK: Gate

    @Test(arguments: [
        "倉庫の二番、いや五番の棚に置きました",
        "打ち合わせは火曜日、やっぱり木曜日にします",
        "この資料は佐藤さん、じゃなくて鈴木さんに渡して",
        "見積もりは三社ではなくて、四社から取ります",
        "集合場所は正門、すみません裏門です",
        "会場は大阪支店、訂正、名古屋支店です",
        "お昼はラーメン、あ違う、カレーにします",
        "メモは紙で、あ、アプリで残します",
        "Book a table for six, no wait, eight people",
        "The launch is on May second, sorry, May ninth",
        "Send the invoice to Mark, I mean Julia",
        "We meet at the cafe, actually, at the library",
        "Order the blue one. Scratch that, the red one",
        "リリースはbetaじゃなくてstableに出します",
    ])
    func cueDetected(_ transcript: String) {
        #expect(SelfCorrection.hasCue(in: transcript), "\(transcript)")
    }

    @Test(arguments: [
        "この案は延期ではなく中止です",
        "それはいやです",
        "雨の日は家で本を読みます",
        "I'm sorry I missed your call",
        "Actually I agree with the plan",
        "The umbrella is in the car",
    ])
    func noCue(_ transcript: String) {
        #expect(!SelfCorrection.hasCue(in: transcript), "\(transcript)")
    }

    // MARK: Application

    @Test(arguments: [
        ("倉庫の二番、いや五番の棚に置きました", "二番", "五番", "倉庫の五番の棚に置きました"),
        // The model may include the cue or punctuation in its spans.
        ("倉庫の二番、いや五番の棚に置きました", "二番、いや", "五番", "倉庫の五番の棚に置きました"),
        ("倉庫の二番、いや五番の棚に置きました", "二番", "、いや五番。", "倉庫の五番の棚に置きました"),
        // A tail repeated by the replacement goes with the retraction.
        ("宛先は経理部です、すみません、人事部です", "経理部", "人事部です", "宛先は人事部です"),
        // Filler glued to the cue.
        ("開始は9時、あ違う、10時です", "9時", "10時", "開始は10時です"),
        ("週末は家で休もうかな、やっぱり山に行く", "家で休もうかな", "山に行く", "週末は山に行く"),
        ("見積もりは三社ではなくて、四社から取ります", "三社", "四社", "見積もりは四社から取ります"),
        ("Book a table for six, no wait, eight people", "six", "eight", "Book a table for eight people"),
        ("Send it to Al, I mean, Alice", "Al", "Alice", "Send it to Alice"),
        ("Please keep the draft, I mean, delete the draft", "keep the draft", "delete the draft", "Please delete the draft"),
        // An English retraction stretched over the clause is narrowed to the replaced word.
        ("hang the map near the window no wait door before noon", "hang the map near the window", "door",
         "hang the map near the door before noon"),
        ("park the van by the north gate no wait south gate today", "park the van by the north gate", "south gate",
         "park the van by the south gate today"),
        ("move the lamp closer to the sofa no wait desk the rug stays here", "move the lamp closer to the sofa",
         "desk the rug stays here", "move the lamp closer to the desk the rug stays here"),
    ])
    func applies(_ c: (String, String, String, String)) {
        let outcome = SelfCorrection.apply([(c.1, c.2)], to: c.0)
        #expect(outcome.corrected == c.3, "\(c.0)")
        #expect(outcome.spans.count == 1)
        #expect(c.0.contains(outcome.spans.first?.retracted ?? "\u{0}"))
    }

    @Test func appliesSeveralCorrections() {
        let transcript = "部屋は二階、いや三階で、時間は四時、やっぱり五時です"
        let outcome = SelfCorrection.apply([("二階", "三階"), ("四時", "五時")], to: transcript)
        #expect(outcome.corrected == "部屋は三階で、時間は五時です")
        #expect(outcome.spans.map(\.retracted) == ["二階", "四時"])
    }

    @Test(arguments: [
        // Retracted text not in the transcript.
        ("倉庫の二番、いや五番の棚に置きました", "三番", "五番"),
        // No cue between the two.
        ("倉庫の二番と五番の棚に置きました", "二番", "五番"),
        // Neither order has a cue between the texts.
        ("倉庫の二番と五番、いや棚の上に置きました", "五番", "二番"),
        // Empty or identical texts.
        ("倉庫の二番、いや五番の棚に置きました", "", "五番"),
        ("倉庫の二番、いや五番の棚に置きました", "二番", "二番"),
        // Replacement far from the cue.
        ("Book a table for six, no wait, I think that we need eight people", "six", "eight"),
        // A tail the replacement does not repeat is not dropped.
        ("宛先は経理部の山田です、すみません、人事部です", "経理部", "人事部です"),
    ])
    func unverifiableFallsBack(_ c: (String, String, String)) {
        #expect(SelfCorrection.apply([(c.1, c.2)], to: c.0).corrected == nil, "\(c.0) / \(c.1)")
    }

    @Test func keepsVerifiedCorrectionAndDropsUnverifiableProposal() {
        let transcript = "部屋は二階、いや三階で、時間は四時、やっぱり五時です"
        let outcome = SelfCorrection.apply([("二階", "三階"), ("六時", "五時")], to: transcript)
        #expect(outcome.corrected == "部屋は三階で、時間は四時、やっぱり五時です")
        #expect(outcome.verifiedProposals == 1)
        #expect(outcome.droppedProposals == 1)
        #expect(outcome.spans.map(\.retracted) == ["二階"])
    }

    @Test(arguments: [
        "来週の月曜いや来週の火曜に",
        "14枚いや19枚",
        "東倉庫じゃなくて西倉庫",
    ])
    func unpunctuatedParallelCueTriggers(_ transcript: String) {
        #expect(SelfCorrection.hasCue(in: transcript))
    }

    @Test(arguments: ["じゃなくて", "ではなくて", "じゃなく", "ではなく", "でなくて", "でなく"])
    func unpunctuatedContrastDoesNotTrigger(_ cue: String) {
        for ending in ["夜の方が好き", "夜のほうが好き", "夜のが好き", "夜倉庫の方が好き"] {
            #expect(!SelfCorrection.hasCue(in: "朝倉庫" + cue + ending))
        }
        #expect(!SelfCorrection.hasCue(in: "朝じゃなくて夜の方が好き"))
    }

    @Test(arguments: [false, true])
    func overlappingUnverifiableProposalDropsBoth(_ reverse: Bool) {
        let pairs = [("二階", "三階"), ("二階", "六階")]
        let outcome = SelfCorrection.apply(reverse ? Array(pairs.reversed()) : pairs,
            to: "部屋は二階、いや三階で、時間は四時です")
        #expect(outcome.corrected == nil)
        #expect(outcome.spans.isEmpty)
        #expect(outcome.verifiedProposals == 0)
        #expect(outcome.droppedProposals == 2)
    }

    @Test(arguments: [
        ("予定は来週の月曜いや来週の火曜にします", "来週の月曜", "来週の火曜", "予定は来週の火曜にします"),
        ("注文は14枚いや19枚にします", "14枚", "19枚", "注文は19枚にします"),
        ("搬入は東倉庫じゃなくて西倉庫にします", "東倉庫", "西倉庫", "搬入は西倉庫にします"),
    ])
    func appliesUnpunctuatedCorrection(_ c: (String, String, String, String)) {
        let outcome = SelfCorrection.apply([(c.1, c.2)], to: c.0)
        #expect(outcome.corrected == c.3)
        #expect(outcome.verifiedProposals == 1)
        #expect(outcome.droppedProposals == 0)
    }

    @Test func stageMeasuresCountPartialVerification() async {
        let json = #"{"corrections":[{"retracted":"二階","replacement":"三階"},{"retracted":"六時","replacement":"五時"}]}"#
        let fake = FakeGenerator(script: [.init(.text(json, usage: TokenUsage(inputTokens: 1, outputTokens: 1)))])
        let result = await CleanupPipeline().selfCorrectionStage(
            CleanupInput(transcript: "部屋は二階、いや三階で、時間は四時、やっぱり五時です",
                         promptLanguage: .ja, handsFree: false),
            using: ChunkTestExecutor(generator: fake))
        #expect(result.transcriptForCleanup == "部屋は三階で、時間は四時、やっぱり五時です")
        #expect(result.measures["stageA.verifiedProposals"] == 1)
        #expect(result.measures["stageA.droppedProposals"] == 1)
    }

    @Test func conflictDoesNotDiscardIndependentCorrection() {
        let outcome = SelfCorrection.apply([("二階", "三階"), ("二階", "六階"), ("四時", "五時")],
            to: "部屋は二階、いや三階で、時間は四時、やっぱり五時です")
        #expect(outcome.corrected == "部屋は二階、いや三階で、時間は五時です")
        #expect(outcome.spans == [SelfCorrectionSpan(retracted: "四時", replacement: "五時")])
        #expect(outcome.verifiedProposals == 1)
        #expect(outcome.droppedProposals == 2)
    }

    @Test func suffixMatchBeyondFifteenCharactersDoesNotTrigger() {
        #expect(!SelfCorrection.hasCue(in: "甲倉庫いや" + String(repeating: "乙", count: 15) + "倉庫"))
        #expect(SelfCorrection.hasCue(in: "東倉庫じゃなくて、西倉庫の方が好き"))
    }

    @Test func noProposalsKeepTheTranscript() {
        let transcript = "すみません、明日は休みます"
        let outcome = SelfCorrection.apply([], to: transcript)
        #expect(outcome.corrected == transcript)
        #expect(outcome.spans.isEmpty)
    }

    @Test func deletingMostOfTheTranscriptIsRejected() {
        let transcript = "全部やり直します、いや、はい"
        #expect(SelfCorrection.apply([("全部やり直します", "はい")], to: transcript).corrected == nil)
    }
}

@Suite("ResultValidator — stage-A spans and residual fillers")
struct StageAValidationTests {
    static func validate(_ source: String, _ output: String, spans: [SelfCorrectionSpan]?, handsFree: Bool) -> ValidationOutcome {
        V.validator.validate(ValidationInput(
            task: .cleanup, source: source, output: output, isTruncated: false,
            protectedInstructions: [V.cleanupInstructionsJA, V.cleanupInstructionsEN],
            handsFree: handsFree, selfCorrections: spans))
    }

    @Test(arguments: [
        ("週末は家で休もうかな、やっぱり山に行く", "週末は家で休もうかな。", "家で休もうかな", "山に行く"),
        ("週末は家で休もうかな、やっぱり山に行く", "週末は家で休もうかな、山に行く。", "家で休もうかな", "山に行く"),
        ("宛先は経理部です、すみません、人事部です", "宛先は経理部です。人事部です。", "経理部", "人事部です"),
        ("Please keep the draft, I mean, delete the draft", "Please keep the draft.", "keep the draft", "delete the draft"),
    ])
    func keptSpanIsNotComplete(_ c: (String, String, String, String)) {
        let spans = [SelfCorrectionSpan(retracted: c.2, replacement: c.3)]
        let handsFree = Self.validate(c.0, c.1, spans: spans, handsFree: true)
        #expect(handsFree.reasons.contains(.selfCorrectionKept), "\(c.1)")
        if case .failed = handsFree {} else { Issue.record("hands-free must fail: \(c.1)") }
        #expect(!Self.validate(c.0, c.1, spans: spans, handsFree: false).isComplete)
    }

    @Test(arguments: [
        ("週末は家で休もうかな、やっぱり山に行く", "週末は山に行く。", "家で休もうかな", "山に行く"),
        ("宛先は経理部です、すみません、人事部です", "宛先は人事部です。", "経理部", "人事部です"),
        ("開始は9時、いや9時半です", "開始は9時半です。", "9時", "9時半"),
        ("Please keep the draft, I mean, delete the draft", "Please delete the draft.", "keep the draft", "delete the draft"),
    ])
    func appliedSpanIsComplete(_ c: (String, String, String, String)) {
        let spans = [SelfCorrectionSpan(retracted: c.2, replacement: c.3)]
        #expect(Self.validate(c.0, c.1, spans: spans, handsFree: true) == .complete, "\(c.1)")
    }

    // MARK: Residual fillers (hands-free)

    @Test(arguments: [
        ("えーと、明日の会議は十時からです", "えーと、明日の会議は十時からです。"),
        ("あの、資料を共有します", "あの、資料を共有します。"),
        ("えっと、駅の北口で待ってます", "えっと駅の北口で待ってます。"),
        ("まあ、その、来週には出せます", "まあ、来週には出せます。"),
        ("Um, the file is on the shared drive", "Um, the file is on the shared drive."),
        ("So, uh, I will call you back", "So, uh, I will call you back."),
    ])
    func residualFillerBlocksHandsFree(_ c: (String, String)) {
        let outcome = Self.validate(c.0, c.1, spans: nil, handsFree: true)
        #expect(outcome.reasons.contains(.residualFiller), "\(c.1)")
        if case .failed = outcome {} else { Issue.record("hands-free must fail: \(c.1)") }
        // Normal mode does not check fillers.
        #expect(!Self.validate(c.0, c.1, spans: nil, handsFree: false).reasons.contains(.residualFiller))
    }

    @Test(arguments: [
        ("えーと、明日の会議は十時からです", "明日の会議は十時からです。"),
        ("あの、あの人に資料を渡してください", "あの人に資料を渡してください。"),
        ("あのー、あの件はもう済みました", "あの件はもう済みました。"),
        ("その、その資料は昨日送りました", "その資料は昨日送りました。"),
        ("えー、エージェントの設定を変えます", "エージェントの設定を変えます。"),
        ("Um, the umbrella is in the car", "The umbrella is in the car."),
        ("Uh, the error is in the header", "The error is in the header."),
        // Expressive interjections are content.
        ("うーん、どうしようかな", "うーん、どうしようかな。"),
    ])
    func legitimateWordsPass(_ c: (String, String)) {
        #expect(Self.validate(c.0, c.1, spans: nil, handsFree: true) == .complete, "\(c.1)")
    }
}

@Suite("SelfCorrection — direction from the transcript")
struct SelfCorrectionDirectionTests {
    @Test func swappedFieldsFollowTheTranscriptOrder() {
        let outcome = SelfCorrection.apply([("五番", "二番")], to: "倉庫の二番、いや五番の棚に置きました")
        #expect(outcome.corrected == "倉庫の五番の棚に置きました")
        #expect(outcome.spans == [SelfCorrectionSpan(retracted: "二番", replacement: "五番")])
    }

    @Test func cueAsRetractionIsNotApplied() {
        #expect(SelfCorrection.apply([("すみません", "人事部")], to: "宛先は経理部です、すみません、人事部です").corrected == nil)
    }
}

@Suite("SelfCorrection — parallel tails")
struct SelfCorrectionTailTests {
    @Test(arguments: [
        ("夕飯は近所のそば屋にしようかな、やっぱり寿司屋にする", "そば屋", "寿司屋", "夕飯は近所の寿司屋にする"),
        ("発表は来週の月曜にします、すみません、水曜にします", "月曜", "水曜", "発表は来週の水曜にします"),
        // The replacement continues with the same words as the retraction.
        ("テストはmacOSで動かしてから、いやLinuxで動かしてから直す", "macOS", "Linux", "テストはLinuxで動かしてから直す"),
    ])
    func kanaTailFollowedByTheSameParticleGoesWithTheRetraction(_ c: (String, String, String, String)) {
        #expect(SelfCorrection.apply([(c.1, c.2)], to: c.0).corrected == c.3)
    }

    @Test func unverifiedRetractionStillReachesTheValidator() {
        let outcome = SelfCorrection.apply([("北口", "南口")], to: "待ち合わせは北口には行かない、いや南口にする")
        #expect(outcome.spans == [SelfCorrectionSpan(retracted: "北口", replacement: nil)])
    }

    @Test func tailWithContentWordsIsKept() {
        // "には行かない" has a kanji: not a kana tail, so the proposal cannot be verified.
        #expect(SelfCorrection.apply([("北口", "南口")], to: "待ち合わせは北口には行かない、いや南口にする").corrected == nil)
    }
}

@Suite("Self-correction review fixes")
struct SelfCorrectionReviewFixTests {
    @Test func apologyIsNotARetraction() {
        let outcome = SelfCorrection.apply([(retracted: "遅れてすみません", replacement: "10分で着きます")], to: "遅れてすみません、10分で着きます")
        #expect(outcome.corrected == nil || outcome.corrected == "遅れてすみません、10分で着きます")
    }

    @Test func emphaticYappariIsNotACue() {
        #expect(!SelfCorrection.hasCue(in: "夏はやっぱり夏祭りだよね"))
        #expect(SelfCorrection.hasCue(in: "封筒は14枚いや19枚用意して"))
    }

    @Test func englishWholeStatementWithPronounIsNotNarrowed() {
        let outcome = SelfCorrection.apply([("let's go to the park", "we stay home")],
                                           to: "let's go to the park, actually we stay home")
        #expect(outcome.corrected == "we stay home")
    }

    @Test func englishNarrowingNeedsADeterminerBeforeTheReplacedWords() {
        let a = SelfCorrection.apply([("Schedule the review with Priya on Thursday", "with Daniel")],
                                     to: "Schedule the review with Priya on Thursday, sorry, with Daniel")
        #expect(a.corrected != "Schedule the review with Priya with Daniel")
        let b = SelfCorrection.apply([("I'll take the blue one", "red")], to: "I'll take the blue one, actually red")
        #expect(b.corrected != "I'll take the blue red")
    }
}
