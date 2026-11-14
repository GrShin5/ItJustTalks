import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("Conservative edit projection")
struct EditProjectorTests {
    private func project(_ s: String, _ o: String, _ language: String = "ja") -> EditProjector.Result {
        EditProjector.project(.init(source: s, output: o, language: language))
    }

    @Test(arguments: [
        ("確認です", "確認です。", "確認です。"),
        ("確認です。", "確認です！", "確認です！"),
        ("確認です。", "確認です。。", "確認です。"),
        ("確認です。", "確認です、。", "確認です。"),
        ("確認です。", "、確認です。", "確認です。"),
        ("確認 です。", "確認です。", "確認です。"),
        ("確認です。", "確認 です。", "確認 です。"),
        ("確認です。", "確認です 。", "確認です。"),
        ("確認なので", "確認なので。", "確認なので"),
        ("確認だけど", "確認だけど。", "確認だけど"),
        ("明日の会議", "明日の会議。", "明日の会議"),
        ("確認して", "確認して。", "確認して"),
        ("思ってます", "思っています", "思ってます"),
        ("明日の予定です", "明日の予定ですよ", "明日の予定です"),
        ("明日の予定です", "明日の計画です", "明日の予定です"),
        ("重要な確認です", "確認です", "重要な確認です"),
        ("えっと、確認です", "確認です", "確認です"),
        ("えーと、確認です", "確認です", "確認です"),
        ("あのー、確認です", "確認です", "確認です"),
        ("あの人は担当です", "人は担当です", "あの人は担当です"),
        ("その件は確認です", "件は確認です", "その件は確認です"),
        ("確認確認です", "確認です", "確認です"),
        ("来週の月曜来週の火曜です", "来週の火曜に明日の予定を確認します", "来週の火曜です"),
        ("確認です。次です。", "確認です。\n次です。", "確認です。\n次です。"),
        ("確認です", "確認\nです", "確認です")
    ])
    func japaneseExamples(_ example: (String, String, String)) {
        #expect(project(example.0, example.1).text == example.2)
    }

    @Test(arguments: [
        ("We can go", "We can go.", "We can go."),
        ("We can go.", "We can go!", "We can go!"),
        ("We can go and", "We can go and.", "We can go and"),
        ("We can go because", "We can go because.", "We can go because"),
        ("We can go.", "We should go.", "We can go."),
        ("um, we can go.", "we can go.", "we can go."),
        ("uh, we can go.", "we can go.", "we can go."),
        ("we we can go.", "we can go.", "we can go."),
        ("I like this plan.", "I this plan.", "I like this plan.")
    ])
    func englishExamples(_ example: (String, String, String)) {
        #expect(project(example.0, example.1, "en").text == example.2)
    }

    @Test func diagnostics() {
        #expect(project("確認です", "確認です。").accepted[.punctuation] == 1)
        #expect(project("会議なので", "会議なので。").rejected[.terminalCompletion] == 1)
        #expect(project("思ってます", "思っています").rejected[.insertion] == 1)
        #expect(project("明日の予定です", "明日の計画です").rejected[.wordChange] == 1)
        #expect(project("重要な明日の予定を確認します", "明日の予定を確認します").rejected[.deletion] == 1)
        #expect(project("確認確認です", "確認です").accepted[.repetitionDeletion] == 1)
        #expect(project("えっと、確認です", "確認です").accepted[.fillerDeletion] == 1)
        #expect(project("確認です", "確認 です").accepted[.whitespace] == 1)
    }

    @Test func verifiedRetraction() {
        let s = "来週の月曜いや来週の火曜に明日の予定を確認します"
        let result = EditProjector.project(.init(source: s, output: "来週の火曜に明日の予定を確認します", language: "ja", verifiedRetractions: ["来週の月曜いや"]))
        #expect(result.text == "来週の火曜に明日の予定を確認します")
        #expect(result.accepted[.retractionDeletion] != nil)
        // Without Stage A, the cued restart is still recognised from its shared prefix.
        #expect(project(s, "来週の火曜に明日の予定を確認します").text == "来週の火曜に明日の予定を確認します")
    }

    @Test func dictionarySurfacesAndAdjacentWords() {
        let dictionary: [(surface: String, readings: [String])] = [("東京", ["とうきょう"]), ("大阪", ["おおさか"])]
        for output in ["東京大阪で明日の予定を確認します", "東京、大阪で明日の予定を確認します"] {
            let r = EditProjector.project(.init(source: "とうきょうおおさかで明日の予定を確認します", output: output, language: "ja", dictionary: dictionary))
            #expect(r.text == output)
            #expect(r.accepted[.dictionarySurface] != nil)
        }
    }

    @Test func kanaVariant() {
        let r = EditProjector.project(.init(source: "トウキョウで確認です", output: "東京で確認です", language: "ja", dictionary: [("東京", ["とうきょう"])]))
        #expect(r.text == "東京で確認です")
    }

    @Test func fallbackOnlyStripsFillers() {
        for output in ["", "別物"] {
            let r = project("えっと、明日の予定を確認します", output)
            #expect(r.fellBack)
            #expect(r.text == "明日の予定を確認します")
            #expect(r.alignment < 0.6)
        }
        #expect(project("", "").fellBack)
    }

    @Test func quotesAndGraphemes() {
        #expect(project("「えっと、」と発言です", "「」と発言です").text.contains("えっと"))
        #expect(project("👩🏽‍💻で確認です", "👩🏽‍💻で確認です。").text == "👩🏽‍💻で確認です。")
    }

    @Test func randomishContentInvariant() {
        let atoms = ["確認", "予定", "abc", "👩🏽‍💻", "か\u{3099}", "42"]
        for i in 0..<80 {
            let source = atoms[i % atoms.count] + "の" + atoms[(i * 7 + 1) % atoms.count] + "です"
            let proposal = i % 2 == 0 ? source + "追加。" : "未知" + source + "！"
            let r = project(source, proposal)
            let allowed = Set(source)
            #expect(r.text.allSatisfy { allowed.contains($0) || $0.isPunctuation || $0.isWhitespace })
        }
    }

    @Test func longInputAndExactAlignment() {
        let s = String(repeating: "確認です。", count: 400)
        let r = project(s, s)
        #expect(r.text == s)
        #expect(r.alignment == 1)
        #expect(!r.fellBack)
    }
}

@Suite("Edit projection: restarts and safe mode")
struct EditProjectorRestartTests {
    private func p(_ s: String, _ o: String, deletions: Bool = true) -> EditProjector.Result {
        EditProjector.project(.init(source: s, output: o, language: "ja", allowsContentDeletions: deletions))
    }

    @Test func cuelessRestartIsRemoved() {
        #expect(p("来週の月曜、来週の火曜に伺います", "来週の火曜に伺います。").text == "来週の火曜に伺います。")
    }

    @Test func cuedRestartIsRemoved() {
        #expect(p("封筒は14枚、いや19枚用意してください", "封筒は19枚用意してください。").text == "封筒は19枚用意してください。")
        #expect(p("受け取りは東倉庫じゃなくて西倉庫でお願いします", "受け取りは西倉庫でお願いします。").text == "受け取りは西倉庫でお願いします。")
    }

    @Test func contrastIsKept() {
        let s = "朝じゃなくて夜の方が好きです"
        #expect(p(s, "夜の方が好きです。").text == "朝じゃなくて夜の方が好きです。")
    }

    @Test func safeModeKeepsEveryWord() {
        let r = p("えーと来週の月曜、来週の火曜に伺います", "来週の火曜に伺います。", deletions: false)
        #expect(r.text == "来週の月曜、来週の火曜に伺います。")
    }

    @Test func paraphraseAndCompletionAreRejected() {
        #expect(p("資料を確認しておいてほしいです", "資料を確認してください。").text == "資料を確認しておいてほしいです。")
        #expect(p("その件は来週話すので", "その件は来週話します。").text == "その件は来週話すので")
    }
}

@Suite("Hesitation stripping")
struct HesitationStripTests {
    @Test func strongFillersAtPause() {
        #expect(EditProjector.stripHesitations("えーとあの件ですが") == "あの件ですが")
        #expect(EditProjector.stripHesitations("えーと、あの、確認です") == "確認です")
        #expect(EditProjector.stripHesitations("それは、えっと、明日です") == "それは、明日です")
        #expect(EditProjector.stripHesitations("「えーと」と言った") == "「えーと」と言った")
        #expect(EditProjector.stripHesitations("ええ、そうです") == "ええ、そうです")
        #expect(EditProjector.stripHesitations("うーん、そうですね") == "うーん、そうですね")
        #expect(EditProjector.stripHesitations("えーと") == "えーと")
    }
}

@Suite("Projection review fixes")
struct ProjectionReviewFixTests {
    private func p(_ s: String, _ o: String) -> String { EditProjector.project(.init(source: s, output: o, language: "ja")).text }

    @Test func hesitationNeedsAPauseBeforeHiragana() {
        #expect(EditProjector.stripHesitations("あのうどん屋に行きたい") == "あのうどん屋に行きたい")
        #expect(EditProjector.stripHesitations("えっとお願いします") == "えっとお願いします")
        #expect(EditProjector.stripHesitations("えーとお、お願いします") == "お願いします")
        #expect(EditProjector.stripHesitations("えーと会議は3時です") == "会議は3時です")
    }

    @Test func marksInsideNumbersAndWordsAreKept() {
        #expect(p("3.5キロです", "35キロです。") == "3.5キロです。")
        #expect(p("10〜20人です", "1020人です。") == "10〜20人です。")
    }

    @Test func leadingBracketsAndQuotesStay() {
        #expect(p("(株)サンプルの田中です", "(株)サンプルの田中です。") == "(株)サンプルの田中です。")
        #expect(p("「了解」と返信して", "「了解」と返信して").hasPrefix("「了解」"))
    }

    @Test func enumerationAndReduplicationAreNotRestarts() {
        #expect(p("A社の見積もり、A社の請求書を送ってください", "A社の請求書を送ってください。") == "A社の見積もり、A社の請求書を送ってください。")
        #expect(p("一つ一つ確認します", "一つ確認します。") == "一つ一つ確認します。")
        #expect(p("今日は無理ですすみません明日は行けます", "明日は行けます。").hasPrefix("今日は無理ですすみません明日は行けます"))
    }
}

@Suite("Projection dictionary spellings")
struct ProjectionDictionaryTests {
    @Test func soundMatchedSpellingsFromTheModelAreAccepted() {
        func p(_ s: String, _ o: String, _ d: [(surface: String, readings: [String])]) -> String {
            EditProjector.project(.init(source: s, output: o, language: "ja", dictionary: d)).text
        }
        #expect(p("渡辺部長に確認をお願いします", "渡邉部長に確認をお願いします。", [("渡邉", ["わたなべ"])]) == "渡邉部長に確認をお願いします。")
        #expect(p("ケイエムエスの設定を見直します", "KMSの設定を見直します。", [("KMS", ["けーえむえす"])]) == "KMSの設定を見直します。")
        #expect(p("みなといんさつに、ポスターの色校正を頼みました", "ミナト印刷に、ポスターの色校正を頼みました。", [("ミナト印刷", ["みなといんさつ"])]) == "ミナト印刷に、ポスターの色校正を頼みました。")
        // A dropped neighbour is not swallowed by the spelling.
        #expect(p("重要な渡辺部長の件です", "渡邉部長の件です。", [("渡邉", ["わたなべ"])]).contains("重要な"))
    }

    @Test func fillerChainAndPhraseRestart() {
        #expect(EditProjector.stripHesitations("えーとあのえっと明日です") == "明日です")
        #expect(CuedRestart.collapse("打ち合わせは渋谷のオフィスで、やっぱり新宿のオフィスでやりましょう") == "打ち合わせは新宿のオフィスでやりましょう")
    }
}
