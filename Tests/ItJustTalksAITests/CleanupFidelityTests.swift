import Testing
@testable import ItJustTalksAI

// All texts below are synthetic and differ from Evaluation/cases.

@Suite("ResultValidator — cleanup fidelity (self-corrections, request endings)")
struct CleanupFidelityTests {
    // MARK: Self-corrections

    @Test(arguments: [
        // (source, output that kept the retracted part)
        ("倉庫の二番、いや五番の棚に置きました", "倉庫の二番、五番の棚に置きました。"),
        ("打ち合わせは火曜日、やっぱり木曜日の午後にします", "打ち合わせは火曜日、木曜日の午後にします。"),
        ("この資料は佐藤さん、じゃなくて鈴木さんに渡してください", "この資料は佐藤さんではなく鈴木さんに渡してください。"),
        ("集合場所は正門、すみません裏門です", "集合場所は正門、裏門です。"),
        ("会場は大阪支店、訂正、名古屋支店です", "会場は大阪支店、名古屋支店です。"),
        ("お昼はラーメン、あ、違う、カレーにします", "お昼はラーメン、カレーにします。"),
        ("明日は出社なし、あ、やっぱり午前だけ出社します", "明日は出社なし、午前だけ出社します。"),
        ("テスト環境、いや開発環境で確認してください", "テスト環境、いや開発環境で確認してください。"),
        ("Book a table for six, no wait, eight people", "Book a table for six, eight people."),
        ("The launch is on May second, sorry, May ninth", "The launch is on May second."),
        ("Send the invoice to Mark, I mean, Julia", "Send the invoice to Mark, Julia."),
    ])
    func keptRetractionIsNotComplete(_ c: (String, String)) {
        let normal = V.cleanup(c.0, c.1)
        #expect(normal.reasons.contains(.selfCorrectionKept), "\(c.0)")
        #expect(!normal.isComplete)
        let handsFree = V.cleanup(c.0, c.1, handsFree: true)
        #expect(handsFree.reasons.contains(.selfCorrectionKept))
        if case .failed = handsFree {} else { Issue.record("hands-free must fail: \(c.0)") }
    }

    @Test func normalModeOnlyNeedsReview() {
        #expect(V.cleanup("打ち合わせは火曜日、やっぱり木曜日の午後にします", "打ち合わせは火曜日、木曜日の午後にします。")
            == .needsReview([.selfCorrectionKept]))
    }

    @Test(arguments: [
        // Faithful: only the corrected content remains.
        ("倉庫の二番、いや五番の棚に置きました", "倉庫の五番の棚に置きました。"),
        ("倉庫の二番、いや五番の棚に置きました", "倉庫の5番の棚に置きました。"),
        ("打ち合わせは火曜日、やっぱり木曜日の午後にします", "打ち合わせは木曜日の午後にします。"),
        ("この資料は佐藤さん、じゃなくて鈴木さんに渡してください", "この資料は鈴木さんに渡してください。"),
        ("集合場所は正門、すみません裏門です", "集合場所は裏門です。"),
        ("明日は出社なし、あ、やっぱり午前だけ出社します", "明日は午前だけ出社します。"),
        ("開始は9時、いや9時半です", "開始は9時半です。"),
        ("Book a table for six, no wait, eight people", "Book a table for eight people."),
        ("The launch is on May second, sorry, May ninth", "The launch is on May ninth."),
        ("Send the invoice to Mark, I mean, Julia", "Send the invoice to Julia."),
        // Not corrections: contrast without a pause, apologies, "as expected".
        ("この案は延期ではなく中止です", "この案は延期ではなく中止です。"),
        ("遅れてすみません、今駅に着きました", "遅れてすみません。今、駅に着きました。"),
        ("すみません、明日は休みます", "すみません、明日は休みます。"),
        ("雨が降った、やっぱり傘を持ってきてよかった", "雨が降った。やっぱり傘を持ってきてよかった。"),
        ("その日は無理、ごめん、来週なら行けます", "その日は無理、ごめん。来週なら行けます。"),
        ("佐藤さん、ごめん、明日行けない", "佐藤さん、ごめん、明日行けない。"),
        ("それはいやです", "それは嫌です。"),
        ("I'm sorry, I can't make it today", "I'm sorry, I can't make it today."),
        ("Thanks for waiting, sorry about that", "Thanks for waiting, sorry about that."),
        ("The report is done, actually it was finished yesterday", "The report is done. Actually, it was finished yesterday."),
        ("I would rather stay home tonight", "I would rather stay home tonight."),
    ])
    func faithfulOutputsPass(_ c: (String, String)) {
        #expect(V.cleanup(c.0, c.1) == .complete, "\(c.0)")
        #expect(V.cleanup(c.0, c.1, handsFree: true) == .complete, "\(c.0)")
    }

    @Test func repeatedMentionIsNotCountedAsKept() {
        // "二番" is said twice; one retraction leaves one legitimate mention.
        #expect(V.cleanup("二番の鍵で二番、いや五番の棚を開けます", "二番の鍵で五番の棚を開けます。") == .complete)
    }

    @Test func detectorShapes() {
        #expect(CleanupFidelity.corrections(in: "倉庫の二番、いや五番の棚") == [
            .init(retracted: "二番", replacement: "五番", isEnglish: false),
        ])
        #expect(CleanupFidelity.corrections(in: "この資料は佐藤さん、じゃなくて鈴木さんに") == [
            .init(retracted: "佐藤さん", replacement: "鈴木さん", isEnglish: false),
        ])
        #expect(CleanupFidelity.corrections(in: "明日は出社なし、あ、やっぱり午前だけ出社します") == [
            .init(retracted: "出社なし", replacement: nil, isEnglish: false),
        ])
        #expect(CleanupFidelity.corrections(in: "Book a table for six, no wait, eight people") == [
            .init(retracted: "6", replacement: "8 people", isEnglish: true),
        ])
        #expect(CleanupFidelity.corrections(in: "この案は延期ではなく中止です").isEmpty)
        #expect(CleanupFidelity.corrections(in: "I'm sorry, I can't make it").isEmpty)
    }

    // MARK: Request endings

    @Test(arguments: [
        ("来週の会議室の空きを確認してください", "来週の会議室の空き"),
        ("来週の会議室の空きを確認してください", "来週の会議室の空きを予約してください。"),
        ("この表を見やすく並べ替えて", "この表を見やすく。"),
        ("駅までの道順を教えてもらえますか", "駅までの道順を教えてもらえます。"),
        ("会議の資料はもう届いていますか？", "会議の資料はもう届いています。"),
        ("Could you check the hotel booking for Friday?", "Check the hotel booking for Friday."),
        ("please water the plants on the balcony", "Water the plants on the balcony."),
    ])
    func droppedEndingIsNotComplete(_ c: (String, String)) {
        let normal = V.cleanup(c.0, c.1)
        #expect(normal.reasons.contains(.requestEndingLost), "\(c.0)")
        let handsFree = V.cleanup(c.0, c.1, handsFree: true)
        if case .failed = handsFree {} else { Issue.record("hands-free must fail: \(c.0)") }
    }

    @Test(arguments: [
        ("来週の会議室の空きを確認してください", "来週の会議室の空きを確認してください。"),
        ("えーと来週の会議室の空きを確認して下さい", "来週の会議室の空きを確認して下さい。"),
        ("この表を見やすく並べ替えて", "この表を見やすく並べ替えて。"),
        ("この表を見やすく並べ替えて", "この表を見やすく並べ替えてください。"),
        ("駅までの道順を教えてもらえますか", "駅までの道順を教えてもらえますか？"),
        ("会議の資料はもう届いていますか？", "会議の資料はもう届いていますか？"),
        ("あのー、ファイルをおくってください", "ファイルを送ってください。"),
        ("Could you check the hotel booking for Friday?", "Could you check the hotel booking for Friday?"),
        ("um please water the plants on the balcony", "Please water the plants on the balcony."),
        ("明日の天気は", "明日の天気は？"),
    ])
    func keptEndingPasses(_ c: (String, String)) {
        #expect(V.cleanup(c.0, c.1) == .complete, "\(c.0)")
        #expect(V.cleanup(c.0, c.1, handsFree: true) == .complete, "\(c.0)")
    }

    @Test func notAppliedToCommandsOrCrossLanguage() {
        #expect(V.command(.proofreadRewrite, "来週の会議室の空きを確認してください", "来週の会議室の空きを確かめてください。")
            == .complete)
        #expect(!V.cleanup("来週の会議室の空きを確認してください", "Please check next week's meeting room availability.",
                           language: "en").reasons.contains(.requestEndingLost))
    }
}
