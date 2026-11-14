import Testing
@testable import ItJustTalksAI

@Suite("EditProjector v3")
struct EditProjectorV3Tests {
    private func p(_ source: String, _ output: String, _ language: String = "ja") -> EditProjector.Result {
        EditProjector.project(.init(source: source, output: output, language: language))
    }

    @Test func rejectedEditDoesNotDoublePunctuation() {
        let r = p("資料についてはですね。どんな形式で", "資料は、どんな形式で")
        #expect(!r.text.contains("。、"))
        #expect(r.text.contains("ですね。"))
    }

    @Test func finalCommaDoesNotCloseOpenEnding() {
        #expect(p("確認です、", "確認です。").text == "確認です、")
        for comma in ["、", ","] {
            let source = "この形式で提出するのであれば" + comma
            #expect(p(source, "この形式で提出するのであれば。").text == source)
        }
    }

    @Test func denseDictionaryWithCaseAndSeparators() {
        let output = "Gemini、Claude Code、Codexを比べた"
        let r = EditProjector.project(.init(source: "geminiクロードコードコーデックスを比べた",
            output: output, language: "ja", dictionary: [
                ("Gemini", []), ("Claude Code", ["クロードコード"]), ("Codex", ["コーデックス"])
            ]))
        #expect(r.text == output)
        #expect(r.accepted[.dictionarySurface] != nil)
    }

    @Test(arguments: [("などなど確認します", "など確認します"),
                      ("いろいろ確認します", "いろ確認します"),
                      ("まだまだ確認します", "まだ確認します"),
                      ("一つ一つ確認します", "一つ確認します")])
    func reduplicationIsContent(_ pair: (String, String)) {
        #expect(p(pair.0, pair.1).text == pair.0)
    }

    @Test(arguments: [("この 3つ", "この3つ"), ("確認、 GitHub", "確認、GitHub"),
                      ("H T M Lを確認", "HTMLを確認"), ("Claude Codeです", "ClaudeCodeです")])
    func deterministicSpacing(_ pair: (String, String)) {
        let expected = pair.0.hasPrefix("Claude") ? pair.0 : pair.1
        #expect(p(pair.0, pair.1).text == expected)
    }

    @Test func englishCaseChanges() {
        let r = p("i meet sam on monday in june", "I meet Sam on Monday in June.", "en")
        #expect(r.text == "I meet Sam on Monday in June.")
        #expect(r.accepted[.caseChange] != nil)
        #expect(r.alignment == 1)
    }

    @Test(arguments: ["um", "uh", "er", "ah", "hmm", "mm"])
    func englishStrongFillers(_ filler: String) {
        #expect(p(filler + ", we can go.", "we can go.", "en").text == "we can go.")
        #expect(EditProjector.stripHesitations(filler + ", we can go.", language: "en") == "we can go.")
    }

    @Test(arguments: ["like", "you know", "I mean"])
    func englishWeakFillersRequirePausesAndProposal(_ filler: String) {
        let source = "We, " + filler + ", can go."
        #expect(p(source, "We, can go.", "en").text == "We, can go.")
        #expect(p(source, source, "en").text == source)
        let unpaused = "We " + filler + " can go."
        #expect(p(unpaused, "We can go.", "en").text == unpaused)
    }

    @Test(arguments: [("We will go.", "We’ll go."),
                      ("We can go.", "We should go."),
                      ("We discuss plans.", "We discuss plants."),
                      ("I like this plan.", "I this plan.")])
    func englishWordsAreAtomic(_ pair: (String, String)) {
        #expect(p(pair.0, pair.1, "en").text == pair.0)
    }

    @Test func englishOpenEndingAndPeriod() {
        #expect(p("We can go", "We can go.", "en").text == "We can go.")
        for word in ["and", "because", "with", "the", "which", "who", "to"] {
            let source = "We can go " + word
            let r = p(source, source + ".", "en")
            #expect(r.text == source)
            #expect(r.rejected[.terminalCompletion] != nil)
        }
    }

    @Test func japaneseNonRegression() {
        #expect(p("確認確認です", "確認です").text == "確認です")
        #expect(p("えっと、確認です", "確認です。").text == "確認です。")
        #expect(p("明日の予定です", "明日の計画です").text == "明日の予定です")
        #expect(p("3.5キロです", "35キロです。").text == "3.5キロです。")
    }

    @Test func englishUnitsAndGrammaticalDoublesStay() {
        #expect(EditProjector.stripHesitations("a 35 mm lens", language: "en") == "a 35 mm lens")
        let doubled = EditProjector.project(.init(source: "i said that that was fine", output: "I said that was fine.",
                                                  language: "en", dictionary: []))
        #expect(doubled.text == "I said that that was fine.")
    }

    @Test func proposalCannotPutBackRemovedJapaneseSpacing() {
        let r = EditProjector.project(.init(source: "この3つとGitHubの件", output: "この 3つと GitHub の件。", language: "ja", dictionary: []))
        #expect(r.text == "この3つとGitHubの件。")
        let latin = EditProjector.project(.init(source: "Claude Codeを使う", output: "Claude Code を使う。", language: "ja", dictionary: []))
        #expect(latin.text == "Claude Codeを使う。")
    }

    @Test func englishYouKnowAtTheEndAndAroundARepeatedWord() {
        func p(_ s: String, _ o: String) -> String { EditProjector.project(.init(source: s, output: o, language: "en", dictionary: [])).text }
        #expect(p("we should move the call to friday you know", "We should move the call to Friday.") == "We should move the call to Friday.")
        #expect(p("so where is it do you know", "So where is it?") == "So where is it do you know")
        #expect(p("I checked the, you know, the report from monday", "I checked the report from Monday.")
                == "I checked the report from Monday.")
    }

    @Test func reviewFixesForEnglish() {
        #expect(EditProjector.stripHesitations("Take him to the ER now", language: "en") == "Take him to the ER now")
        #expect(EditProjector.stripHesitations("Uh-huh, that works", language: "en") == "Uh-huh, that works")
        #expect(EditProjector.stripHesitations("Um, that works", language: "en") == "that works")
        func p(_ s: String, _ o: String) -> String { EditProjector.project(.init(source: s, output: o, language: "en", dictionary: [])).text }
        #expect(p("version 3 5 is out", "Version 3.5 is out.") == "Version 3 5 is out.")
        #expect(p("open report.pdf now", "Open report. Pdf now.").hasPrefix("Open report.pdf now"))
        #expect(p("write down everything you know", "Write down everything.") == "Write down everything you know")
        #expect(p("the code is 7 7 3", "The code is 7 3.") == "The code is 7 7 3.")
    }

    @Test func dictionaryRunNeedsWholeLatinWords() {
        let r = EditProjector.project(.init(source: "GitHubを開く", output: "Git Hubを開く。", language: "ja",
                                            dictionary: [(surface: "Git", readings: ["ギット"])]))
        #expect(r.text.hasPrefix("GitHub"))
    }
}
