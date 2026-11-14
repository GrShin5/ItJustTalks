import Testing
@testable import ItJustTalksAI

@Suite("Japanese spacing")
struct JapaneseSpacingTests {
    @Test(arguments: [
        ("この 3つ", "この3つ"), ("、 GitHub", "、GitHub"),
        ("第 1部", "第1部"), ("GitHub の API", "GitHubのAPI"),
        ("この　3つ", "この3つ"), ("H T M L", "H T M L"),
        ("A P I の", "A P Iの"), ("このH T M Lの仕様", "このH T M Lの仕様"),
        ("日 A 日", "日A日"), ("「 1部」", "「1部」"),
        ("  この 3つ\n  A P I の仕様  \n", "  この3つ\n  A P Iの仕様  \n"),
    ])
    func normalizes(_ example: (String, String)) {
        let result = JapaneseSpacing.normalize(example.0)
        #expect(result == example.1)
        #expect(JapaneseSpacing.normalize(result) == result)
        #expect(result.filter { $0 != " " && $0 != "　" } == example.0.filter { $0 != " " && $0 != "　" })
    }

    @Test(arguments: ["", "Claude Code", "Read Only", "20 kg", "3 pm", "A Test", "HTML API",
                      "この  3つ", "この\t3つ", "この\n3つ", " 1部", "API \n", "日 本"])
    func preserves(_ text: String) {
        #expect(JapaneseSpacing.normalize(text) == text)
    }

    @Test func katakanaAndLatinWordsKeepTheirSpace() {
        #expect(JapaneseSpacing.normalize("クロードコード Tool") == "クロードコード Tool")
        #expect(JapaneseSpacing.normalize("Tool クロードコード") == "Tool クロードコード")
        #expect(JapaneseSpacing.normalize("ページ 3を見る") == "ページ3を見る")
    }
}
