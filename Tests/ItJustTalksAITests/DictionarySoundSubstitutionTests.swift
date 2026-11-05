import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("DictionarySoundSubstitution")
struct DictionarySoundSubstitutionTests {
    private let midori = DictionaryEntry(preferred: "ミドリ精機", readings: ["ミドリセイキ"])

    /// Sound matching applies to entries the selector found in the request; select every entry here.
    private func substitution(_ entries: [DictionaryEntry]) -> DictionaryLiteralSubstitution {
        let text = entries.flatMap(\.readings).joined(separator: " ")
        let selection = DictionarySelector().select(entries: entries, text: text)
        return DictionaryLiteralSubstitution(selection: selection, entries: entries)
    }

    @Test func unselectedEntriesAreNotSoundMatched() {
        let none = DictionarySelection(selected: [], matchedCount: 0, omittedCount: 0, totalTokens: 0)
        let engine = DictionaryLiteralSubstitution(selection: none, entries: [midori])
        #expect(engine.apply(to: "緑精機に確認する。").text == "緑精機に確認する。")
    }

    @Test func validationSourceKeepsLiteralOnly() {
        let engine = substitution([midori])
        #expect(engine.apply(to: "緑精機に確認する。", includeSound: false).text == "緑精機に確認する。")
    }

    @Test func kanjiHomophoneAndAlreadyPreferred() {
        let engine = substitution([midori])
        let result = engine.apply(to: "緑精機に確認する。")
        #expect(result.text == "ミドリ精機に確認する。")
        #expect(result.count == 1)
        #expect(engine.apply(to: result.text).count == 0)
    }

    @Test func twoAndThreeTermsKeepSurroundingTextAndCounts() {
        let engine = substitution([midori,
            DictionaryEntry(preferred: "Codex", readings: ["コーデックス"]),
            DictionaryEntry(preferred: "Template", readings: ["テンプレート"]),
        ])
        let two = engine.apply(to: "緑精機とコーデックスを確認する。")
        #expect(two.text == "ミドリ精機とCodexを確認する。")
        #expect(two.count == 2)
        let three = engine.apply(to: "緑精機とコーデックスとてんぷれーとを確認する。\n")
        #expect(three.text == "ミドリ精機とCodexとTemplateを確認する。\n")
        #expect(three.count == 3)
    }

    @Test func hiraganaSoundVariant() {
        let result = substitution([midori]).apply(to: "みどりせーきを確認する。")
        #expect(result.text == "ミドリ精機を確認する。")
        #expect(result.count == 1)
    }

    @Test func shortCommonWordsAndNumeralsStayUnchanged() {
        let cases: [(String, String)] = [
            ("桜", "サクラ"), ("今度", "コンド"), ("今度", "コンドウ"),
            ("斉藤", "サイト"), ("斉藤", "サイトウ"), ("三角形", "サンカクケイ"),
            ("３回目", "サンカイメ"),
        ]
        for (source, reading) in cases {
            let result = substitution([DictionaryEntry(preferred: "Registered", readings: [reading])]).apply(to: source)
            #expect(result.text == source)
            #expect(result.count == 0)
        }
    }

    @Test func compoundRequiresFourMoraeAndWholeWords() {
        let three = "蚊猫"
        let four = "猫犬"
        #expect(PhoneticReading.units(three).filter(\.startsWord).count >= 2)
        #expect(PhoneticReading.units(four).filter(\.startsWord).count >= 2)
        #expect(PhoneticReading.key(of: three) == PhoneticReading.key(of: "カネコ"))
        #expect(PhoneticReading.key(of: three)?.morae == 3)
        // The system tokenizer reads 犬 as ケン in this compound, rather than イヌ.
        #expect(PhoneticReading.key(of: four) == PhoneticReading.key(of: "ネコケン"))
        #expect(PhoneticReading.key(of: four)?.morae == 4)
        let engine = substitution([
            DictionaryEntry(preferred: "ShortCompound", readings: ["カネコ"]),
            DictionaryEntry(preferred: "FourMoraCompound", readings: ["ネコケン"]),
        ])
        #expect(engine.apply(to: three).text == three)
        let result = engine.apply(to: four)
        #expect(result.text == "FourMoraCompound")
        #expect(result.count == 1)
        // A reading matching only the head of this tokenizer word must not replace it.
        #expect(substitution([DictionaryEntry(preferred: "Head", readings: ["カブシキ"])]).apply(to: "株式会社").count == 0)
    }

    @Test func longestWinsAndSoundTiesPreserveText() {
        let longer = DictionaryEntry(preferred: "ミドリ精機工場", readings: ["ミドリセイキコウジョウ"])
        #expect(substitution([midori, longer]).apply(to: "緑精機工場").text == "ミドリ精機工場")
        let conflicting = DictionaryEntry(preferred: "別表記", readings: ["ミドリセイキ"])
        for entries in [[midori, conflicting], [conflicting, midori]] {
            let result = substitution(entries).apply(to: "緑精機")
            #expect(result.text == "緑精機")
            #expect(result.count == 0)
        }
        let aliases = DictionaryEntry(preferred: "ミドリ精機", readings: ["ミドリセイキ", "みどりせーき"])
        #expect(substitution([aliases]).apply(to: "緑精機").count == 1)
    }

    @Test func validationSpansRetainBothForms() {
        let original = SelfCorrectionSpan(retracted: "緑精機に頼む", replacement: "コーデックスを使う")
        let engine = substitution([midori, DictionaryEntry(preferred: "Codex", readings: ["コーデックス"])])
        let changed = SelfCorrectionSpan(retracted: "ミドリ精機に頼む", replacement: "Codexを使う")
        #expect(engine.validationSpans([original, original]) == [original, changed])
        #expect(engine.validationSpans(nil) == nil)
    }

    @Test func outputSideStillRequiresLiteralSourceAndDisabledEntriesStayDisabled() {
        let empty = DictionarySelection(selected: [], matchedCount: 0, omittedCount: 0, totalTokens: 0)
        let restricted = DictionaryLiteralSubstitution(selection: empty, entries: [midori], literalSource: "緑精機")
        #expect(restricted.apply(to: "緑精機").count == 0)
        let disabled = DictionaryEntry(preferred: "ミドリ精機", readings: ["ミドリセイキ"], isEnabled: false)
        #expect(substitution([disabled]).apply(to: "緑精機").count == 0)
    }

    @Test func existingLiteralExample() {
        let result = substitution([DictionaryEntry(preferred: "Codex", readings: ["コーデックス"])])
            .apply(to: "コーデックスの優先度とコーデックスの設定")
        #expect(result.text == "Codexの優先度とCodexの設定")
        #expect(result.count == 2)
    }
}
