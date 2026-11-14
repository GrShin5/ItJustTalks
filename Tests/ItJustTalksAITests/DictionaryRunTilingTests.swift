import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("Dictionary run tiling and mixed-script fragments")
struct DictionaryRunTilingTests {
    private let entries = [
        DictionaryEntry(preferred: "Codex", readings: ["コーデックス"]),
        DictionaryEntry(preferred: "Claude Code", readings: ["クロードコード"]),
        DictionaryEntry(preferred: "Gemini", readings: ["ジェミニ"]),
        DictionaryEntry(preferred: "Antigravity", readings: ["アンチグラビティ"]),
    ]

    private func substitute(_ text: String, entries: [DictionaryEntry]? = nil) -> (text: String, count: Int) {
        let entries = entries ?? self.entries
        let selection = DictionarySelector().select(
            entries: entries, text: text, options: DictionarySelectionOptions(tokenBudget: 10_000)
        )
        return DictionaryLiteralSubstitution(selection: selection, entries: entries).apply(to: text)
    }

    @Test func fullRealExampleIsTiledAndSeparated() {
        let result = substitute("コーデックスクロードコードジェminiアンチグラビity")
        #expect(result.text == "Codex、Claude Code、Gemini、Antigravity")
        #expect(result.count == 4)
    }

    @Test func katakanaRunBetweenHiraganaAndKanjiNeighbors() {
        #expect(substitute("今日はコーデックスクロードコードを使う").text == "今日はCodex、Claude Codeを使う")
        #expect(substitute("新ジェミニアンチグラビティ版").text == "新Gemini、Antigravity版")
        #expect(substitute("コーデックスとジェミニ").text == "CodexとGemini")
    }

    @Test func partialTilingReplacesNothing() {
        for text in ["コーデックスクロードバックアップ", "コーデックスクロ", "スーパーコーデックス", "コーデックスアップ",
                     "ジェミニアンチ", "コーデックスxyz"] {
            #expect(substitute(text).text == text)
            #expect(substitute(text).count == 0)
        }
    }

    @Test func longVowelMarkDoesNotCountTowardTileLength() {
        let parts = [DictionaryEntry(preferred: "Claude", readings: ["クロード"]),
                     DictionaryEntry(preferred: "Code", readings: ["コード"])]
        #expect(substitute("クロードコード", entries: parts).text == "クロードコード")
        let tools = [DictionaryEntry(preferred: "Mail", readings: ["メール"]),
                     DictionaryEntry(preferred: "Tool", readings: ["ツール"]),
                     DictionaryEntry(preferred: "Codex", readings: ["コーデックス"])]
        #expect(substitute("コーデックスメール", entries: tools).text == "コーデックスメール")
        #expect(substitute("ツールメール", entries: tools).text == "ツールメール")
        // The full real example still tiles with the registered whole reading クロードコード.
        #expect(substitute("コーデックスクロードコードジェminiアンチグラビity").text == "Codex、Claude Code、Gemini、Antigravity")
    }

    @Test func twoCharacterReadingsAreNeverTiled() {
        let short = [DictionaryEntry(preferred: "Luna", readings: ["ルナ"]),
                     DictionaryEntry(preferred: "Terra", readings: ["テラ"]),
                     DictionaryEntry(preferred: "Sol", readings: ["ソル"])]
        for text in ["ルナとテラとソル", "ルナテラソル", "テラソル"] {
            #expect(substitute(text, entries: short).text == text)
        }
    }

    @Test func mixedScriptFragmentsMatchStandalone() {
        #expect(substitute("ジェminiで検索").text == "Geminiで検索")
        #expect(substitute("クロードcodeを開く").text == "Claude Codeを開く")
        #expect(substitute("アンチグラビity").text == "Antigravity")
        #expect(substitute("コーデックスジェMINI").text == "Codex、Gemini")
    }

    @Test func latinWordSpelledLikeAnEntryIsATile() {
        #expect(substitute("geminiクロードコードを比べた").text == "Gemini、Claude Codeを比べた")
        #expect(substitute("GEMINIコーデックス").text == "Gemini、Codex")
        // Japanese punctuation nearby is Japanese context, so the joint is 「、」 even between Latin words.
        #expect(substitute("資料、Slack geminiクロードコード Notes").text == "資料、Slack Gemini、Claude Code Notes")
        // A Latin word alone, or one tile next to it that is not an entry, changes nothing here.
        #expect(substitute("geminiを使う").text == "geminiを使う")
        #expect(substitute("geminisクロードコード").text == "geminisクロードコード")
    }

    @Test func coreOfTwoOrMoreTilesIsReplacedInsideALongerRun() {
        #expect(substitute("LLMリストクロードコードコーデックスアンチグravityジェmini").text
                == "LLMリストClaude Code、Codex、Antigravity、Gemini")
        #expect(substitute("コーデックスクロードコードバックアップ").text == "Codex、Claude Codeバックアップ")
        // One tile next to untiled katakana stays as spoken.
        for text in ["ビデオコーデックスです", "コーデックスアップデート", "リストクロードコード"] {
            #expect(substitute(text).text == text)
        }
    }

    @Test func mixedScriptFalsePositiveGuards() {
        for text in [
            "ジェnetを使う",      // Latin tail is not a suffix of the spelling
            "アンityを確認",      // too little of the word is covered
            "ジェniです",         // Latin tail shorter than 3 letters
            "ジminiです",         // katakana head shorter than 2 graphemes
            "スーパーminiです",   // katakana head is not a reading prefix
            "ジェmini5です",      // digits are not part of the Latin tail
        ] {
            #expect(substitute(text).text == text)
        }
        let noLatinSpelling = [DictionaryEntry(preferred: "双子座", readings: ["ジェミニ"])]
        #expect(substitute("ジェminiです", entries: noLatinSpelling).text == "ジェminiです")
    }

    @Test func outputSideAcceptsEntriesFoundOnlyThroughTiling() {
        let source = "コーデックスクロードコードジェmini"
        let selection = DictionarySelector().select(entries: entries, text: source)
        let output = DictionaryLiteralSubstitution(selection: selection, entries: entries, literalSource: source)
        #expect(Set(output.preferredSpellings) == ["Codex", "Claude Code", "Gemini"])
        #expect(output.apply(to: "コーデックスクロードコード").text == "Codex、Claude Code")
        #expect(output.apply(to: "ジェminiを使う").text == "Geminiを使う")
        #expect(output.apply(to: "アンチグラビity").text == "アンチグラビity")
    }
}
