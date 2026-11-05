import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("DictionaryLiteralSubstitution")
struct DictionaryLiteralSubstitutionTests {
    private func substitute(_ text: String, entries: [DictionaryEntry]) -> (text: String, count: Int) {
        let selection = DictionarySelector().select(
            entries: entries, text: text, options: DictionarySelectionOptions(tokenBudget: 10_000)
        )
        return DictionaryLiteralSubstitution(selection: selection, entries: entries).apply(to: text)
    }

    @Test func outputCandidatesRequireTranscriptReadingAndRetainAllEntryReadings() {
        let entries = [DictionaryEntry(preferred: "東京都架空区", readings: ["オフィス住所", "会社住所"]),
                       DictionaryEntry(preferred: "RegisteredButAbsent", readings: ["未登場キーワード"])]
        let source = "オフィス住所を入力して"
        let selection = DictionarySelector().select(entries: entries, text: source)
        let outputOnly = DictionaryLiteralSubstitution(selection: selection, entries: entries, literalSource: source)
        #expect(outputOnly.preferredSpellings == ["東京都架空区"])
        #expect(outputOnly.apply(to: "会社住所と未登場キーワード").text == "東京都架空区と未登場キーワード")
        let absent = DictionaryLiteralSubstitution(selection: selection, entries: entries, literalSource: "明日の会議")
        #expect(absent.preferredSpellings.isEmpty)
        #expect(absent.apply(to: "オフィス住所").text == "オフィス住所")
        let boundaryEntries = [DictionaryEntry(preferred: "App", readings: ["アップ"])]
        let boundarySelection = DictionarySelector().select(entries: boundaryEntries, text: "アップデート")
        let blocked = DictionaryLiteralSubstitution(selection: boundarySelection, entries: boundaryEntries, literalSource: "アップデート")
        #expect(blocked.preferredSpellings.isEmpty)
        #expect(blocked.apply(to: "アップ").text == "アップ")
    }

    @Test func eligibilityCountsGraphemesWithoutWhitespace() {
        for reading in ["A B", " A\tB ", "ガ\nギ".decomposedStringWithCanonicalMapping] {
            #expect(substitute(reading, entries: [DictionaryEntry(preferred: "Word", readings: [reading])]).count == 0)
        }
        #expect(substitute("A B C", entries: [DictionaryEntry(preferred: "Word", readings: ["A B C"])]).text == "Word")
    }

    @Test func kanjiToKatakanaBoundaryInsideNewOfficeAddressIsAccepted() {
        // Accepted design: 新 | オフィス is a script boundary, even inside a compound noun.
        #expect(substitute("新オフィス住所", entries: [
            DictionaryEntry(preferred: "東京都架空区", readings: ["オフィス住所"]),
        ]).text == "新東京都架空区")
    }

    @Test func duplicateReadingsHaveDeterministicOutputSideWinner() {
        let entries = [DictionaryEntry(preferred: "First", readings: ["エイリアス"]),
                       DictionaryEntry(preferred: "Second", readings: ["エイリアス"])]
        let source = "エイリアスを使う"
        let selection = DictionarySelector().select(entries: entries, text: source)
        let outputOnly = DictionaryLiteralSubstitution(selection: selection, entries: entries, literalSource: source)
        #expect(outputOnly.apply(to: source).text == "Firstを使う")
        #expect(DictionaryLiteralSubstitution(selection: selection, entries: entries, literalSource: source)
            .apply(to: source).text == "Firstを使う")
    }

    @Test func literalSpellingAndWhitespace() {
        let codex = [DictionaryEntry(preferred: "Codex", readings: ["コーデックス"])]
        let result = substitute("コーデックスの優先度とコーデックスの設定", entries: codex)
        #expect(result.text == "Codexの優先度とCodexの設定")
        #expect(result.count == 2)
        #expect(substitute("It just talksで入力", entries: [
            DictionaryEntry(preferred: "ItJustTalks", readings: ["it just talks"]),
        ]).text == "ItJustTalksで入力")
        #expect(substitute("ＩＴ　ＪＵＳＴ　ＴＡＬＫＳで入力", entries: [
            DictionaryEntry(preferred: "ItJustTalks", readings: ["it just talks"]),
        ]).text == "ItJustTalksで入力")
        #expect(substitute("こーでっくす。", entries: codex).text == "Codex。")
    }

    @Test func longVowelFoldingAgreesForTermsAndOriginalCharacterRanges() {
        let entries = [DictionaryEntry(preferred: "Codex", readings: ["コーデックス"])]
        let selection = DictionarySelector().select(entries: entries, text: "コーデックス。")
        #expect(selection.selected.first?.matchKind == .reading)
        let substitution = DictionaryLiteralSubstitution(selection: selection, entries: entries)
        for text in ["コーデックス。", "こーでっくす。", "ｺｰﾃﾞｯｸｽ。", "コ ー デ ッ ク ス。"] {
            let result = substitution.apply(to: text)
            #expect(result.text == "Codex。")
            #expect(result.count == 1)
        }
    }

    @Test func longestWins() {
        let entries = [
            DictionaryEntry(preferred: "Codex", readings: ["コーデックス"]),
            DictionaryEntry(preferred: "Codex App Server", readings: ["コーデックスアップサーバー"]),
        ]
        #expect(substitute("コーデックスアップサーバーを起動", entries: entries).text == "Codex App Serverを起動")
    }

    @Test func strictBoundaries() {
        let entries = [
            DictionaryEntry(preferred: "Luna", readings: ["ルナ"]),
            DictionaryEntry(preferred: "Terra", readings: ["テラ"]),
            DictionaryEntry(preferred: "Sol", readings: ["ソル"]),
            DictionaryEntry(preferred: "App", readings: ["アップ", "app"]),
        ]
        #expect(substitute("ルナとテラとソル", entries: entries).text == "ルナとテラとソル")
        for text in ["テラスで休む", "アップデートする", "Apple", "xapp", "app2", "ａｐｐｌｅ", "テラー", "テラリウム"] {
            #expect(substitute(text, entries: entries).text == text)
        }
        #expect(substitute("テラ・ルナ", entries: entries).text == "テラ・ルナ")
    }

    @Test func variantsAndStoredSeparators() {
        let entries = [
            DictionaryEntry(preferred: "Sonnet 5", readings: ["ソネットファイブ、ソネット5"]),
            DictionaryEntry(preferred: "Antigravity", readings: ["アンチグラヴィティ"]),
            DictionaryEntry(preferred: "Commit&Push", readings: ["コミットアンドプッシュ"]),
        ]
        // Stored "、"-joined readings are split; katakana+digit readings are substituted.
        #expect(substitute("ソネット5を使う", entries: entries).text == "Sonnet 5を使う")
        #expect(substitute("ソネットファイブを使う", entries: entries).text == "Sonnet 5を使う")
        #expect(substitute("アンチグラビティで開発", entries: entries).text == "Antigravityで開発")
        #expect(substitute("コミット&プッシュしてください", entries: entries).text == "Commit&Pushしてください")
    }

    @Test func existingPreferredSpellingsAreProtectedAndSubstitutionIsIdempotent() {
        let cases: [(entries: [DictionaryEntry], seed: String, text: String, expected: String)] = [
            ([DictionaryEntry(preferred: "ミナト物流", readings: ["ミナト"])], "ミナト", "ミナト物流に連絡", "ミナト物流に連絡"),
            ([DictionaryEntry(preferred: "ミナトー物流", readings: ["ミナトー"])], "ミナトー", "ミナトー物流とミナトーに連絡", "ミナトー物流とミナトー物流に連絡"),
            ([DictionaryEntry(preferred: "GitHub Copilot", readings: ["copilot"])], "copilot", "GitHub Copilotと copilot", "GitHub Copilotと GitHub Copilot"),
            ([DictionaryEntry(preferred: "Codex App Server", readings: ["コーデックスアップサーバー"]),
              DictionaryEntry(preferred: "Application", readings: ["app", "server"])],
             "コーデックスアップサーバーと server", "Codex App Serverとコーデックスアップサーバーを起動", "Codex App ServerとCodex App Serverを起動"),
        ]
        for item in cases {
            let selection = DictionarySelector().select(entries: item.entries, text: item.seed,
                options: DictionarySelectionOptions(tokenBudget: 10_000))
            let substitution = DictionaryLiteralSubstitution(selection: selection, entries: item.entries)
            let once = substitution.apply(to: item.text)
            let twice = substitution.apply(to: once.text)
            #expect(once.text == item.expected)
            #expect(twice.text == once.text)
            #expect(twice.count == 0)
        }
    }

    @Test func threeGraphemeReadingsInEveryScriptAreSubstituted() {
        let shortEntries = [DictionaryEntry(preferred: "Luna", readings: ["ルナ"]),
                            DictionaryEntry(preferred: "Terra", readings: ["テラ"])]
        let selection = DictionarySelector().select(entries: shortEntries, text: "ルナとテラ")
        #expect(selection.hints.count == 2)
        #expect(DictionaryLiteralSubstitution(selection: selection, entries: shortEntries).apply(to: "ルナとテラ").count == 0)
        for (reading, preferred, text, expected) in [
            ("アップ", "App", "写真をアップして", "写真をAppして"),
            // Hiragana followed by a hiragana particle has no script boundary: left to the model.
            ("ひとくじょうほう", "Confidential", "ひとくじょうほうを確認", "ひとくじょうほうを確認"),
            ("ひとくじょうほう", "Confidential", "「ひとくじょうほう」", "「Confidential」"),
            ("機密情報", "Confidential", "機密情報を確認", "Confidentialを確認"),
            ("矢印右", "→", "矢印右を入れてください", "→を入れてください"),
            ("123", "番号", "123を入力", "番号を入力"),
            ("ソネット5", "Sonnet 5", "ソネット50を使う", "ソネット50を使う"),
            ("app", "Application", "appを起動", "Applicationを起動"),
            ("アップ", "App", "アップデート", "アップデート"),
        ] {
            #expect(substitute(text, entries: [DictionaryEntry(preferred: preferred, readings: [reading])]).text == expected)
        }
        // Three decomposed graphemes qualify; two do not, even with multiple scalars.
        for (reading, expected) in [("ガギグ", "Word。"), ("ガギ", "ガギ。".decomposedStringWithCanonicalMapping)] {
            let decomposed = reading.decomposedStringWithCanonicalMapping
            #expect(substitute(decomposed + "。", entries: [DictionaryEntry(preferred: "Word", readings: [decomposed])]).text == expected)
        }
        #expect(substitute("コーデックスを起動", entries: [DictionaryEntry(preferred: "Codex", readings: ["コーデックス"])]).text == "Codexを起動")
        #expect(substitute("ソネット5を使う", entries: [DictionaryEntry(preferred: "Sonnet 5", readings: ["ソネット5"])]).text == "Sonnet 5を使う")
    }

    @Test func preferredASCIIBoundariesAndPreservedNewlines() {
        let entries = [DictionaryEntry(preferred: "Codex", readings: ["コーデックス"])]
        for text in ["コーデックスapp", "xコーデックス", "ｘコーデックス", "コーデックスａｐｐ"] {
            #expect(substitute(text, entries: entries).text == text)
        }
        #expect(substitute("コーデックスを起動", entries: [
            DictionaryEntry(preferred: "  Codex\nApp  ", readings: ["コーデックス"]),
        ]).text == "Codex\nAppを起動")
    }

    @Test func decomposedKatakanaUsesGraphemeBaseForBoundaries() {
        let entries = [DictionaryEntry(preferred: "Feed", readings: ["フィード"])]
        let word = "フィードバック".decomposedStringWithCanonicalMapping
        #expect(substitute(word, entries: entries).text == word)
        #expect(substitute("フィードを確認".decomposedStringWithCanonicalMapping, entries: entries).text == "Feedを確認")
    }

    @Test func latinTextWhitespaceMustBeLicensedByTheReading() {
        for (reading, preferred, seed, text, expected) in [
            ("app", "Application", "app", "a pp", "a pp"),
            ("copilot", "Assistant", "copilot", "co pilot", "co pilot"),
            ("it just talks", "ItJustTalks", "It just talks", "It just talks", "ItJustTalks"),
            ("it just talks", "ItJustTalks", "It just talks", "itjust talks", "ItJustTalks"),
            ("it just talks", "ItJustTalks", "It just talks", "i t just talks", "i t just talks"),
        ] {
            let entries = [DictionaryEntry(preferred: preferred, readings: [reading])]
            let selection = DictionarySelector().select(entries: entries, text: seed)
            #expect(DictionaryLiteralSubstitution(selection: selection, entries: entries).apply(to: text).text == expected)
        }
    }

    @Test func readingsWithDifferentWhitespacePositionsRemainUsable() {
        let entries = [DictionaryEntry(preferred: "ItJustTalks", readings: ["itjusttalks", "it just talks"])]
        #expect(substitute("It just talksで入力", entries: entries).text == "ItJustTalksで入力")
    }

    @Test func preferredOnlySelectionAlsoProtectsOtherEntries() {
        let entries = [DictionaryEntry(preferred: "Codex App Server", readings: ["コーデックスアップサーバー"]),
                       DictionaryEntry(preferred: "Application", readings: ["server"])]
        let text = "Codex App Serverとserver"
        let selection = DictionarySelector().select(entries: entries, text: text)
        #expect(selection.selected.contains { $0.entryIndex == 0 && $0.matchKind == .preferred })
        let substitution = DictionaryLiteralSubstitution(selection: selection, entries: entries)
        #expect(substitution.apply(to: text).text == "Codex App ServerとApplication")
    }

    @Test func unselectedEnabledPreferredSpellingIsAlsoProtected() {
        for enabled in [true, false] {
            let entries = [DictionaryEntry(preferred: "Assistant", readings: ["copilot"]),
                           DictionaryEntry(preferred: "GitHub Copilot", readings: ["ギットハブコパイロット"], isEnabled: enabled)]
            let selection = DictionarySelector().select(entries: entries, text: "copilot")
            #expect(selection.selected.map(\.entryIndex) == [0])
            let substitution = DictionaryLiteralSubstitution(selection: selection, entries: entries)
            #expect(substitution.apply(to: "GitHub Copilot").text == (enabled ? "GitHub Copilot" : "GitHub Assistant"))
        }
    }

    @Test func bothSpanFormsReachNegationAndRetentionChecks() {
        let entries = [DictionaryEntry(preferred: "Codex", readings: ["コーデックス"])]
        let selection = DictionarySelector().select(entries: entries, text: "コーデックスを使う")
        let substitution = DictionaryLiteralSubstitution(selection: selection, entries: entries)
        let original = SelfCorrectionSpan(retracted: "コーデックスを使わない", replacement: "クロードを使う")
        let changed = SelfCorrectionSpan(retracted: "Codexを使わない", replacement: "クロードを使う")
        let spans = substitution.validationSpans([original]) ?? []
        #expect(spans == [original, changed])
        let expectedExclusions = ContentWords.extract(from: original.retracted)
            .union(ContentWords.extract(from: changed.retracted))
            .subtracting(ContentWords.extract(from: original.replacement ?? ""))
        #expect(!expectedExclusions.isEmpty)
        for retracted in ["ベータ" + original.retracted, changed.retracted] {
            let source = "倉庫は開けない。" + retracted + "、いやクロードを使う"
            #expect(!CleanupFidelity.changesNegation(source: source, output: "倉庫は開けない。クロードを使う", spans: spans))
            #expect(CleanupFidelity.changesNegation(source: source, output: "倉庫は開ける。クロードを使う", spans: spans))
            let exclusions = CleanupFidelity.retentionExclusions(source: source, spans: spans)
            #expect(expectedExclusions.isSubset(of: exclusions))
        }
    }

    @Test func validationSpansKeepOriginalAndSubstitutedForms() {
        let entries = [DictionaryEntry(preferred: "Codex", readings: ["コーデックス"])]
        let selection = DictionarySelector().select(entries: entries, text: "コーデックスを使う")
        let substitution = DictionaryLiteralSubstitution(selection: selection, entries: entries)
        let original = SelfCorrectionSpan(retracted: "コーデックス", replacement: "クロード")
        let changed = SelfCorrectionSpan(retracted: "Codex", replacement: "クロード")
        let spans = substitution.validationSpans([original, original]) ?? []
        #expect(spans == [original, changed])
        #expect(substitution.validationSpans(nil) == nil)
        let source = "ベータコーデックス、いやクロードを使う"
        #expect(substitution.apply(to: source).text == source)
        #expect(CleanupFidelity.keepsRetractedSpan(spans, source: source, output: "ベータコーデックスを使う"))
        let evidence = CleanupFidelity.removingRetractions(from: "ベータコーデックスとCodex", spans: spans)
        #expect(!evidence.contains("コーデックス"))
        #expect(!evidence.contains("Codex"))
    }

    @Test func literalSubstitutionIsIndependentOfHintCaps() {
        let entries = (0..<20).map {
            DictionaryEntry(preferred: "固定文\($0)\n" + String(repeating: "本文", count: 100), readings: ["keyword\($0)"])
        }
        let text = (0..<20).map { "keyword\($0)" }.joined(separator: "、")
        for options in [DictionarySelectionOptions(maxItems: 8, tokenBudget: 10_000),
                        DictionarySelectionOptions(maxItems: 8, tokenBudget: 1)] {
            let selection = DictionarySelector().select(entries: entries, text: text, options: options)
            #expect(selection.selected.count <= 8)
            let substitution = DictionaryLiteralSubstitution(selection: selection, entries: entries)
            let result = substitution.apply(to: text)
            let outputOnly = DictionaryLiteralSubstitution(selection: selection, entries: entries, literalSource: text)
            #expect(outputOnly.apply(to: text).text == result.text)
            #expect(outputOnly.preferredSpellings.count == 20)
            #expect(result.count == 20)
            #expect(result.text == entries.map(\.preferred).joined(separator: "、"))
            #expect(substitution.apply(to: result.text).count == 0)
        }
        #expect(substitute("keyword0", entries: [DictionaryEntry(preferred: "無効", readings: ["keyword0"], isEnabled: false)]).count == 0)
    }

    @Test func largeDictionaryKeepsApplyBelowGenerousLatencyBound() {
        let entries = (0..<1_000).map { DictionaryEntry(preferred: "Preferred\($0)", readings: ["term\($0)"]) }
        let prefix = "term0 term1 term2 term3 term4 term5 term6 term7 "
        let text = prefix + String(repeating: "x", count: 5_000 - prefix.count)
        let selection = DictionarySelector().select(entries: entries, text: text,
            options: DictionarySelectionOptions(tokenBudget: 10_000, phoneticMinimumMorae: 0))
        #expect(selection.selected.count == 8)
        let substitution = DictionaryLiteralSubstitution(selection: selection, entries: entries)
        let start = ContinuousClock.now
        let result = substitution.apply(to: text)
        let elapsed = ContinuousClock.now - start
        #expect(result.count == 8)
        #expect(elapsed < .seconds(1))
    }

    @Test func phoneticEvidenceNeverExpandsWithoutALiteralReading() {
        let entries = [DictionaryEntry(preferred: "渡邉", readings: ["わたなべ"])]
        let selection = DictionarySelector().select(entries: entries, text: "渡辺部長に確認")
        #expect(selection.selected.first?.matchKind == .phonetic)
        let substitution = DictionaryLiteralSubstitution(selection: selection, entries: entries)
        #expect(substitution.apply(to: "渡辺部長に確認").count == 0)
        #expect(substitution.apply(to: "わたなべ、渡辺部長に確認").text == "渡邉、渡辺部長に確認")
        let preferred = DictionarySelector().select(entries: entries, text: "渡邉部長に確認")
        #expect(DictionaryLiteralSubstitution(selection: preferred, entries: entries).apply(to: "渡邉部長に確認").count == 0)
    }

    @Test func overlapTiesUseSelectionRankAndUnchangedSpansAreSkipped() {
        let entries = [
            DictionaryEntry(preferred: "First", readings: ["エイリアス"]),
            DictionaryEntry(preferred: "Second", readings: ["エイリアス"]),
        ]
        #expect(substitute("エイリアスを使う", entries: entries).text == "Firstを使う")
        #expect(substitute("Same", entries: [DictionaryEntry(preferred: "Same", readings: ["same"])]).count == 0)
    }
}
