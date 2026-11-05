import Testing
@testable import ItJustTalksAI

// All texts below are synthetic and differ from the Evaluation sets.

private func validate(_ source: String, _ output: String, handsFree: Bool, spans: [SelfCorrectionSpan]? = nil) -> ValidationOutcome {
    V.validator.validate(ValidationInput(
        task: .cleanup, source: source, output: output, isTruncated: false,
        protectedInstructions: [V.cleanupInstructionsJA, V.cleanupInstructionsEN],
        handsFree: handsFree, selfCorrections: spans))
}

private func expectBlocked(_ source: String, _ output: String, _ reason: ValidationReason, spans: [SelfCorrectionSpan]? = nil) {
    let handsFree = validate(source, output, handsFree: true, spans: spans)
    #expect(handsFree.reasons.contains(reason), "\(output)")
    if case .failed = handsFree {} else { Issue.record("hands-free must fail: \(output)") }
    #expect(!validate(source, output, handsFree: false, spans: spans).isComplete, "\(output)")
}

@Suite("CleanupFidelity — whole-clause retractions")
struct ClauseRetractionTests {
    @Test(arguments: [
        // A whole statement taken back by another one about the same thing.
        ("週末の旅行は電車で行きます、いや、旅行は中止になりました", "週末の旅行は電車で行きます。旅行は中止になりました。"),
        ("会議の資料は印刷して配ります、違う、会議の資料はメールで送ります", "会議の資料は印刷して配ります。会議の資料はメールで送ります。"),
        // The same predicate after two different nouns.
        ("提出は今週中にします。やっぱり来週中にします", "提出は今週中にします。来週中にします。"),
        ("集合は八時にします、いや、九時にします", "集合は八時にします。九時にします。"),
    ])
    func keptClauseIsNotComplete(_ c: (String, String)) {
        expectBlocked(c.0, c.1, .selfCorrectionKept)
    }

    @Test(arguments: [
        ("週末の旅行は電車で行きます、いや、旅行は中止になりました", "旅行は中止になりました。"),
        ("週末の旅行は電車で行きます、いや、旅行は中止になりました", "週末の旅行は中止になりました。"),
        ("提出は今週中にします。やっぱり来週中にします", "提出は来週中にします。"),
        ("集合は八時にします、いや、九時にします", "集合は九時にします。"),
        // Emphasis repeats the clause; "やっぱり" meaning "as expected"; a new topic without a shared word.
        ("昨日の試合は楽しかった、いや、本当に楽しかった", "昨日の試合は楽しかった。いや、本当に楽しかった。"),
        ("雨が降った、やっぱり傘を持ってきてよかった", "雨が降った。やっぱり傘を持ってきてよかった。"),
        ("そろそろ帰ります、いや、その前に少し休みます", "そろそろ帰ります。いや、その前に少し休みます。"),
    ])
    func faithfulOutputsPass(_ c: (String, String)) {
        #expect(validate(c.0, c.1, handsFree: true) == .complete, "\(c.1)")
    }

    @Test func stageAAppliesAWholeClause() {
        let transcript = "週末の旅行は電車で行きます、いや、旅行は中止になりました"
        let outcome = SelfCorrection.apply([("週末の旅行は電車で行きます", "旅行は中止になりました")], to: transcript)
        #expect(outcome.corrected == "旅行は中止になりました")
        #expect(outcome.spans.map(\.retracted) == ["週末の旅行は電車で行きます"])
    }

    @Test(arguments: [
        // A whole statement proposed for a replacement without its own topic is narrowed to the noun phrase.
        ("夕飯は近所のラーメン屋にしようかな、やっぱり寿司屋にする", "夕飯は近所のラーメン屋にしようかな", "寿司屋にする", "夕飯は近所の寿司屋にする"),
        // A replacement that is a statement of its own keeps the whole retraction.
        ("週末の旅行は電車で行きます、いや、旅行は中止になりました", "週末の旅行は電車で行きます", "旅行は中止になりました", "旅行は中止になりました"),
        // Not parallel (no noun + same particle in both): the whole retraction is kept, never "電車で中止に…".
        ("今週は在宅なし、いや、二日だけ在宅します", "今週は在宅なし", "二日だけ在宅します", "二日だけ在宅します"),
        ("週末は電車で行きます、いや、中止になりました", "週末は電車で行きます", "中止になりました", "中止になりました"),
        ("雨が降ったら中止です、いや、決行します", "雨が降ったら中止です", "決行します", "決行します"),
    ])
    func overExtendedStatementIsNarrowed(_ c: (String, String, String, String)) {
        #expect(SelfCorrection.apply([(c.1, c.2)], to: c.0).corrected == c.3)
    }

    @Test func proposalWithAnInventedReplacementGivesNoSpan() {
        // The replacement is not in the transcript: neither applied nor handed to the validator.
        let outcome = SelfCorrection.apply([("別の部署の", "その部署の")], to: "別の部署の木下さんと、訂正作業の件で話しました")
        #expect(outcome.corrected == nil)
        #expect(outcome.spans.isEmpty)
    }
}

@Suite("CleanupFidelity — English \"X, actually Y\"")
struct EnglishCorrectionClassTests {
    @Test(arguments: [
        ("Let's have lunch on Friday, actually Monday in the cafeteria", "Let's have lunch on Friday, Monday in the cafeteria."),
        ("Ship the order in March, actually April if possible", "Ship the order in March, April if possible."),
        ("Pick me up tomorrow, sorry, tonight at the station", "Pick me up tomorrow, tonight at the station."),
        ("It is on the second, actually the third floor", "It is on the second, the third floor."),
    ])
    func keptValueIsNotComplete(_ c: (String, String)) {
        expectBlocked(c.0, c.1, .selfCorrectionKept)
    }

    @Test(arguments: [
        ("Let's have lunch on Friday, actually Monday in the cafeteria", "Let's have lunch on Monday in the cafeteria."),
        ("Ship the order in March, actually April if possible", "Ship the order in April if possible."),
        // "actually" that does not replace a value.
        ("We met on Friday, actually it was a great day", "We met on Friday. Actually, it was a great day."),
        ("I work on Mondays, actually most weeks", "I work on Mondays, actually most weeks."),
    ])
    func faithfulOutputsPass(_ c: (String, String)) {
        #expect(validate(c.0, c.1, handsFree: true) == .complete, "\(c.1)")
    }

    @Test func detectorShape() {
        #expect(CleanupFidelity.corrections(in: "Lunch on Friday, actually Monday at noon") == [
            .init(retracted: "friday", replacement: "monday", isEnglish: true),
        ])
    }
}

@Suite("CleanupFidelity — two corrections in one utterance")
struct TwoCorrectionTests {
    static let transcript = "宛先は山田商店で、あ、山田書店で、金額は五千円、ではなく六千円です"

    @Test(arguments: [
        "宛先は山田商店で、山田書店で、金額は六千円です。",
        "宛先は山田商店で、金額は六千円です。",
    ])
    func keptFirstCorrectionIsNotComplete(_ output: String) {
        // Stage A only found the second correction.
        let spans = [SelfCorrectionSpan(retracted: "五千円", replacement: "六千円")]
        expectBlocked(Self.transcript, output, .selfCorrectionKept, spans: spans)
        expectBlocked(Self.transcript, output, .selfCorrectionKept, spans: nil)
    }

    @Test func faithfulOutputPasses() {
        let spans = [SelfCorrectionSpan(retracted: "五千円", replacement: "六千円")]
        #expect(validate(Self.transcript, "宛先は山田書店で、金額は六千円です。", handsFree: true, spans: spans) == .complete)
    }

    @Test func stageAAppliesBoth() {
        #expect(SelfCorrection.hasCue(in: Self.transcript))
        let outcome = SelfCorrection.apply([("山田商店", "山田書店"), ("五千円", "六千円")], to: Self.transcript)
        #expect(outcome.corrected == "宛先は山田書店で、金額は六千円です")
        #expect(outcome.spans.map(\.retracted) == ["山田商店", "五千円"])
    }

    @Test(arguments: [
        // "あ、" between nouns that are not parallel, or before a new topic, is not a correction.
        ("会議室はA、あ、Bも空いています", "会議室はA、Bも空いています。"),
        ("資料を送りました、あ、それと明日の件です", "資料を送りました。それと明日の件です。"),
        ("お茶、あ、コーヒーもお願いします", "お茶、コーヒーもお願いします。"),
    ])
    func interjectionWithoutParallelNounsPasses(_ c: (String, String)) {
        #expect(validate(c.0, c.1, handsFree: true) == .complete, "\(c.1)")
    }
}

@Suite("CleanupFidelity — negations")
struct NegationTests {
    @Test(arguments: [
        ("請求書はまだ送らないでください", "請求書はまだ送ってください。"),
        ("会議室では飲食できません", "会議室では飲食できます。"),
        ("この部屋は土足禁止です", "この部屋は土足です。"),
        ("確認せずに次へ進んでください", "確認して次へ進んでください。"),
        ("昨日は雨が降らなかった", "昨日は雨が降った。"),
        ("鍵を閉めてください", "鍵を閉めないでください。"),
        ("Please don't share the link with the client", "Please share the link with the client."),
        ("We will never ship on Fridays", "We will ship on Fridays."),
        ("Do not forward this email", "Forward this email."),
        ("Lock the door when you leave", "Don't lock the door when you leave."),
    ])
    func flippedNegationIsNotComplete(_ c: (String, String)) {
        #expect(CleanupFidelity.changesNegation(source: c.0, output: c.1), "\(c.1)")
        expectBlocked(c.0, c.1, .negationChanged)
    }

    @Test(arguments: [
        // Neutral paraphrases.
        ("今日は行けない", "今日は行けません。"),
        ("確認せずに次へ進んでください", "確認しないで次へ進んでください。"),
        ("Please do not share the link", "Please don't share the link."),
        ("I can not attend tomorrow", "I cannot attend tomorrow."),
        // A negation taken back by a self-correction (stage-A span, detected correction, contrastive cue).
        ("請求書を送らないで、いや、送ってください", "請求書を送ってください。"),
        ("集合は駅じゃなくて、公園です", "集合は公園です。"),
        ("Don't send it, no wait, send it today", "Send it today."),
        // Repetitions merged by the cleanup, apologies, words that only look negative.
        ("行かない、行かないです", "行かないです。"),
        ("No, no, the file is fine", "No, the file is fine."),
        ("まず資料を確認して、必ず返信してください", "まず資料を確認して、必ず返信してください。"),
        ("残りわずかなので、ずっと待っています", "残りわずかなので、ずっと待っています。"),
        ("See item No. 5 in the list", "See item No. 5 in the list."),
        ("問題なしです", "問題なしです。"),
    ])
    func legitimateOutputsPass(_ c: (String, String)) {
        #expect(!CleanupFidelity.changesNegation(source: c.0, output: c.1), "\(c.1)")
    }

    @Test func negationInAStageASpanMayGo() {
        let source = "駐車場は使えません、あ、違う、使えます"
        let spans = [SelfCorrectionSpan(retracted: "使えません", replacement: "使えます")]
        #expect(validate(source, "駐車場は使えます。", handsFree: true, spans: spans) == .complete)
        // Keeping the retracted negation is still caught (as a kept correction).
        #expect(!validate(source, "駐車場は使えません。", handsFree: true, spans: spans).isComplete)
    }

    @Test func faithfulCleanupsPass() {
        #expect(validate("えーと、明日の会議には出ないでください", "明日の会議には出ないでください。", handsFree: true) == .complete)
        #expect(validate("Um, please don't forward this", "Please don't forward this.", handsFree: true) == .complete)
    }
}

@Suite("CleanupFidelity — review fixes (round 3b)")
struct Round3ReviewTests {
    // C1: a verb is never taken for the noun of a narrowed retraction.
    @Test func verbIsNotNarrowedAway() {
        let outcome = SelfCorrection.apply([("明日は車で行きます", "やめます")], to: "明日は車で行きます、いや、やめます")
        #expect(outcome.corrected.map { !$0.contains("車でやめ") } ?? true)
    }

    // C2: a negation before a cue is optional only where a correction was found.
    @Test(arguments: [
        ("この書類は捨てないでください、あ、それと鍵もお願いします", "この書類は捨ててください。それと鍵もお願いします。"),
        ("この箱は開けないでください、いや、本当に大事なんです", "この箱は開けてください。本当に大事なんです。"),
        ("鍵は要らない、やっぱり便利な時代だ", "鍵は要る。やっぱり便利な時代だ。"),
        ("Please don't call him tonight, I mean, he is very tired", "Please call him tonight. I mean, he is very tired."),
        // M8: "ではなくなる" is a statement, not a contrastive cue.
        ("無料ではなくなりました", "無料になりました。"),
    ])
    func unexplainedNegationLossIsFlagged(_ c: (String, String)) {
        #expect(CleanupFidelity.changesNegation(source: c.0, output: c.1), "\(c.1)")
    }

    // M8: only the retracted occurrence next to its cue is optional, English on word boundaries.
    @Test func retractedTextIsMaskedOnlyNextToItsCue() {
        let source = "鈴木さんは来ない。佐藤さんは来ない、いや、来る"
        let spans = [SelfCorrectionSpan(retracted: "来ない", replacement: "来る")]
        #expect(CleanupFidelity.changesNegation(source: source, output: "鈴木さんは来る。佐藤さんは来る。", spans: spans))
        #expect(!CleanupFidelity.changesNegation(source: source, output: "鈴木さんは来ない。佐藤さんは来る。", spans: spans))
        let english = "Annie will not come, sorry, Ann will"
        #expect(CleanupFidelity.changesNegation(
            source: english, output: "Annie will come, Ann will.", spans: [SelfCorrectionSpan(retracted: "Ann", replacement: nil)]))
    }

    // M1: whole statements that both survive.
    @Test(arguments: [
        ("今夜は友人の家に泊まります、いや、旅行自体が中止になりました", "今夜は友人の家に泊まります。旅行自体が中止になりました。"),
        ("Let's meet at the cafe at noon. Scratch that, let's meet at the office", "Let's meet at the cafe at noon. Let's meet at the office."),
    ])
    func survivingStatementIsNotComplete(_ c: (String, String)) {
        expectBlocked(c.0, c.1, .selfCorrectionKept)
    }

    @Test(arguments: [
        ("今夜は友人の家に泊まります、いや、旅行自体が中止になりました", "旅行自体が中止になりました。"),
        ("Let's meet at the cafe at noon. Scratch that, let's meet at the office", "Let's meet at the office."),
        // M4: additions after "あ、", honorifics are not parallel nouns.
        ("田中さん、あ、鈴木さんも呼んでください", "田中さん、鈴木さんも呼んでください。"),
        ("お茶、あ、お水もお願いします", "お茶、お水もお願いします。"),
        // M5: additions, new clauses, "a second".
        ("I'm free today, actually tomorrow too", "I'm free today, actually tomorrow too."),
        ("Give me a second, sorry, first I need to check", "Give me a second. Sorry, first I need to check."),
        ("We have 3 options, actually 2 are viable", "We have 3 options, actually 2 are viable."),
        // M6: "やっぱり" meaning "as expected".
        ("彼は優秀です。やっぱり東大卒です", "彼は優秀です。やっぱり東大卒です。"),
        ("昨日は雨でした、やっぱり梅雨でした", "昨日は雨でした。やっぱり梅雨でした。"),
        // M7: escalation.
        ("値段が高い、いや、値段が高すぎる", "値段が高い、いや、値段が高すぎる。"),
    ])
    func legitimateOutputsPass(_ c: (String, String)) {
        #expect(validate(c.0, c.1, handsFree: true) == .complete, "\(c.1)")
    }

    // M2, M3, m1, m2: no negation change.
    @Test(arguments: [
        ("Send five copies, no, three copies", "Send three copies."),
        ("Five copies, no, wait, three", "Three."),
        ("三時じゃない、四時です", "四時です。"),
        ("今日中にしなきゃ", "今日中にしなければなりません。"),
        ("そろそろ行かないと", "そろそろ行かなければなりません。"),
        ("宿題をしなくちゃ", "宿題をしなくてはいけません。"),
        ("雨が降るかもしれない", "雨が降るかもしれません。"),
        ("申し訳ありません、遅れます", "申し訳ございません。遅れます。"),
        ("済みません、通ります", "通ります。"),
        ("思わず笑ってしまった", "思わず笑ってしまった。"),
        ("とりあえず必ず確認します", "必ず確認します。"),
        ("相変わらず参加者が少ない", "参加者が少ない。"),
        ("間もなく到着します", "まもなく到着します。"),
        ("No no I think it is fine", "No, I think it is fine."),
        ("行かない行かない", "行かない。"),
        ("Please don‘t touch it", "Please don't touch it."),
    ])
    func neutralChangesPass(_ c: (String, String)) {
        #expect(!CleanupFidelity.changesNegation(source: c.0, output: c.1), "\(c.1)")
    }

    // m3: the replacement check ignores width and punctuation.
    @Test func replacementContainmentIsNormalized() {
        let outcome = SelfCorrection.apply([("A口", "Ｂ口")], to: "待ち合わせはA口には行かない、いや B口にする")
        #expect(outcome.spans == [SelfCorrectionSpan(retracted: "A口", replacement: nil)])
    }

    // M9: a name replaced after a weak cue.
    @Test func replacedNameAfterWeakCue() {
        expectBlocked("Send it to Ann, actually Ben", "Send it to Ann, Ben.", .selfCorrectionKept)
        #expect(validate("Send it to Ann, actually Ben", "Send it to Ben.", handsFree: true) == .complete)
        #expect(validate("Thanks for the help, sorry, John", "Thanks for the help, sorry, John.", handsFree: true) == .complete)
    }
}

@Suite("CleanupFidelity — final review fixes (round 3c)")
struct Round3FinalReviewTests {
    // N1: a correction excuses a negation only when its clause is gone from the output.
    @Test(arguments: [
        ("Do not share the link, I mean, the link is private", "Share the link. I mean, the link is private."),
        ("この窓は開けないでください、いや、開けると虫が入るんです", "この窓は開けてください。開けると虫が入るんです。"),
        ("この書類は捨てないでください、いや、会議は中止になりました", "この書類は捨ててください。会議は中止になりました。"),
        // N8: a bare obligation before 、 is a condition.
        ("急がないと、遅れます", "急ぐと、遅れます。"),
        // N3: "forget that" inside a sentence is not a cue.
        ("We will never forget that day", "We will forget that day."),
    ])
    func flippedClauseStillInOutputIsFlagged(_ c: (String, String)) {
        #expect(CleanupFidelity.changesNegation(source: c.0, output: c.1), "\(c.1)")
    }

    @Test(arguments: [
        ("Do not share the link, I mean, the link is private", "Do not share the link. I mean, the link is private."),
        ("I don't want to go out tonight, I mean, I want to stay home", "I don't want to go out tonight. I mean, I want to stay home."),
        ("I don't want to go out tonight, I mean, I want to stay home", "I don't want to go out tonight, I mean, I want to stay home."),
        ("この窓は開けないでください、いや、開けると虫が入るんです", "この窓は開けないでください。いや、開けると虫が入るんです。"),
        // N3: statement cues need pauses on both sides.
        ("Tell the team not to forget that the deadline is Friday", "Tell the team not to forget that the deadline is Friday."),
        ("I can't afford a car, never mind a house", "I can't afford a car, never mind a house."),
        ("The client has actually no budget left", "The client has actually no budget left."),
        // N5: additions after "あ、".
        ("A社、あ、B社にも連絡してください", "A社、B社にも連絡してください。"),
        ("資料は田中さん、あ、鈴木さんからも集めます", "資料は田中さん、鈴木さんからも集めます。"),
        ("お茶、あ、紅茶やお水をください", "お茶、紅茶やお水をください。"),
        // N6: no name rule after "sorry" or after a closed-class word.
        ("I can't make it on Monday, sorry, Steve", "I can't make it on Monday, sorry, Steve."),
        // N9: a request is not a cancellation.
        ("この件は内密にお願いします、いや、他言はやめてください", "この件は内密にお願いします。いや、他言はやめてください。"),
    ])
    func verbatimOutputsPass(_ c: (String, String)) {
        #expect(validate(c.0, c.1, handsFree: true) == .complete, "\(c.1)")
    }

    // N2: contrastive English cues may go with their negation.
    @Test(arguments: [
        ("Can you send me the file? Never mind, I found it", "I found it."),
        ("Let's meet Friday, actually no, let's meet Monday", "Let's meet Monday."),
    ])
    func contrastiveCuesMayGo(_ c: (String, String)) {
        #expect(!CleanupFidelity.changesNegation(source: c.0, output: c.1), "\(c.1)")
    }

    @Test(arguments: [
        // N4: two people with honorifics followed by a case particle.
        ("担当は田中さん、あ、鈴木さんです", "担当は田中さん、鈴木さんです。"),
        ("連絡は佐藤さん、あ、伊藤さんにお願いします", "連絡は佐藤さん、伊藤さんにお願いします。"),
        // N7: degree words alone do not make an escalation.
        ("打ち合わせは午前です、いや、打ち合わせは昼過ぎになりました", "打ち合わせは午前です。打ち合わせは昼過ぎになりました。"),
        ("明日は車で行きます、いや、出張自体が本当になくなりました", "明日は車で行きます。出張自体が本当になくなりました。"),
        // N10: the whole sentence before "scratch that".
        ("Let's meet at the cafe, at noon. Scratch that, let's meet at the office", "Let's meet at the cafe, at noon. Let's meet at the office."),
        // "and" no longer hides a replacement.
        ("The visit is on Monday, actually Tuesday and Wednesday", "The visit is on Monday, Tuesday and Wednesday."),
    ])
    func keptRetractionIsNotComplete(_ c: (String, String)) {
        expectBlocked(c.0, c.1, .selfCorrectionKept)
    }

    @Test(arguments: [
        ("担当は田中さん、あ、鈴木さんです", "担当は鈴木さんです。"),
        ("The visit is on Monday, actually Tuesday and Wednesday", "The visit is on Tuesday and Wednesday."),
        ("Let's meet at the cafe, at noon. Scratch that, let's meet at the office", "Let's meet at the office."),
    ])
    func appliedCorrectionsPass(_ c: (String, String)) {
        #expect(validate(c.0, c.1, handsFree: true) == .complete, "\(c.1)")
    }
}

@Suite("CleanupFidelity — surgical fixes (round 3d)")
struct Round3SurgicalTests {
    // A1: two statements with different topics are not a retraction; cancellations still are.
    @Test func differentTopicsAreTwoStatements() {
        let source = "今日は無理です、いや、明日は大丈夫です"
        #expect(validate(source, "今日は無理です。いや、明日は大丈夫です。", handsFree: true) == .complete)
        #expect(!validate(source, "明日は大丈夫です。", handsFree: true).isComplete)
        expectBlocked("明日は車で行きます、いや、出張自体がなくなりました", "明日は車で行きます。出張自体がなくなりました。", .selfCorrectionKept)
    }

    // A2: the replacement check folds numerals like the validator does.
    @Test func replacementCheckFoldsNumerals() {
        let outcome = SelfCorrection.apply([("三時", "4時")], to: "会議は三時から、すみません、四時からです")
        #expect(outcome.corrected == nil)
        #expect(outcome.spans == [SelfCorrectionSpan(retracted: "三時", replacement: nil)])
    }

    // B1: "まず" is never a negation.
    @Test func mazuIsNotANegation() {
        #expect(!CleanupFidelity.changesNegation(source: "明日まず資料を確認して", output: "明日、まず資料を確認して。"))
        #expect(!CleanupFidelity.changesNegation(source: "明日、まず資料を確認して", output: "明日まず資料を確認して。"))
    }

    // B2: a sentence-initial vocative is not a replaced person.
    @Test func vocativeIsNotAReplacement() {
        let source = "田中さん、あ、鈴木さんがよろしくと言っていました"
        #expect(validate(source, "田中さん、あ、鈴木さんがよろしくと言っていました。", handsFree: true) == .complete)
    }

    // B3: a sentence-final particle may follow a bare obligation.
    @Test func obligationWithFinalParticle() {
        #expect(!CleanupFidelity.changesNegation(source: "そろそろ行かないとね", output: "そろそろ行かなければなりませんね。"))
        #expect(CleanupFidelity.changesNegation(source: "急がないと、遅れます", output: "急ぐと、遅れます。"))
    }

    // F1: affirmative → negative flips are caught when both clauses are kept; the corrected output passes.
    @Test(arguments: [
        ("Send the report to the team, no wait, don't send the report to the team",
         "Send the report to the team. Don't send the report to the team.", "Don't send the report to the team."),
        ("資料を共有してください、いや、共有しないでください", "資料を共有してください。共有しないでください。", "資料を共有しないでください。"),
        // The other direction keeps working.
        ("Don't send the report, no wait, send the report today", "Don't send the report. Send the report today.", "Send the report today."),
    ])
    func flippedPolarityBothKept(_ c: (String, String, String)) {
        expectBlocked(c.0, c.1, .selfCorrectionKept)
        #expect(validate(c.0, c.2, handsFree: true) == .complete, "\(c.2)")
    }
}
