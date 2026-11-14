import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("DictionarySelector")
struct DictionarySelectorTests {
    @Test func resolvedLiteralEntriesAreNotSoundHints() {
        let entries = [DictionaryEntry(preferred: "ExampleTool", readings: ["エグザンプルツール"], memo: "reference")]
        let selection = selector.select(entries: entries, text: "エグザンプルツールを使う", options: roomy)
        let body = DictionaryLiteralSubstitution(selection: selection, entries: entries).apply(to: "エグザンプルツールを使う").text
        #expect(body == "ExampleToolを使う")
        #expect(selector.select(entries: entries, text: body, options: roomy).unresolvedHints(in: body).isEmpty)
        let hint = DictionaryHint(preferred: "ExampleTool", readings: ["example"], memo: "reference")
        let unresolved = DictionarySelection(selected: [SelectedDictionaryEntry(entryIndex: 0, hint: hint,
            matchKind: .phonetic, matchLength: 7, tokens: 1)], matchedCount: 1, omittedCount: 0, totalTokens: 1)
        #expect(unresolved.unresolvedHints(in: "exampleを使う") == [hint])
        // Entries the literal pass cannot resolve (no reading, short reading) stay hints.
        let short = [DictionaryEntry(preferred: "GitHub", readings: [], memo: nil), DictionaryEntry(preferred: "AB社", readings: ["えーび"], memo: nil)]
        let mixed = selector.select(entries: short, text: "githubとえーびの件", options: roomy)
        #expect(Set(mixed.unresolvedHints(in: "githubとえーびの件").map(\.preferred)) == Set(mixed.hints.map(\.preferred)))
    }

    /// 1 token per character: deterministic and easy to reason about.
    let selector = DictionarySelector(tokenCounter: { $0.count })
    let roomy = DictionarySelectionOptions(maxItems: 8, tokenBudget: 10_000, includeMemo: false)

    private func preferred(_ selection: DictionarySelection) -> [String] {
        selection.hints.map(\.preferred)
    }

    @Test func registrationAndImportReadingSeparators() {
        // Both the editor save path and CSV import use this helper; import caps apply afterwards.
        for separator in [",", "、", "，", "､"] {
            #expect(DictionaryEntry.splitReadings(" ソネットファイブ\(separator) ソネット5\(separator) ") == ["ソネットファイブ", "ソネット5"])
        }
        #expect(DictionaryEntry.normalizedReadings([" 一、二", "二，三", "､"]) == ["一", "二", "三"])
    }

    @Test func storedCombinedReadingsAndTermVariants() {
        let entries = [
            DictionaryEntry(preferred: "Sonnet 5", readings: ["ソネットファイブ、ソネット5"]),
            DictionaryEntry(preferred: "Antigravity", readings: ["アンチグラヴィティ"]),
            DictionaryEntry(preferred: "Commit&Push", readings: ["コミットアンドプッシュ"]),
        ]
        for (text, spelling, original) in [
            ("ソネット5を使う", "Sonnet 5", "ソネット5"),
            ("アンチグラビティで開発", "Antigravity", "アンチグラヴィティ"),
            ("コミット&プッシュ", "Commit&Push", "コミットアンドプッシュ"),
        ] {
            let selection = selector.select(entries: entries, text: text, options: roomy)
            #expect(selection.selected.first?.matchKind == .reading)
            #expect(selection.hints.first?.preferred == spelling)
            #expect(selection.hints.first?.readings.first == original)
        }
    }

    @Test func variantsPreserveKindAndOriginalHints() {
        for (term, text) in [("ヴァヴィヴゥヴェヴォヴ", "バビブベボブ"), ("Commit and Push", "Commit&Push"),
                             ("Commit&Push", "Commit and Push"), ("コミット&プッシュ", "コミットアンドプッシュ")] {
            let reading = selector.select(entries: [DictionaryEntry(preferred: "Target", readings: [term])], text: text, options: roomy)
            #expect(reading.selected.first?.matchKind == .reading)
            #expect(reading.hints.first?.readings == [term])
            let preferred = selector.select(entries: [DictionaryEntry(preferred: term)], text: text, options: roomy)
            #expect(preferred.selected.first?.matchKind == .preferredWithoutReadings)
        }
    }

    @Test func andSymbolVariantRequiresKatakanaWordsOnBothSides() {
        #expect(DictionarySelector.termVariants("コミットアンドプッシュ").contains("コミット&プッシュ"))
        #expect(DictionarySelector.termVariants("アンドロイド") == ["アンドロイド"])
        #expect(DictionarySelector.termVariants("アアンドイ") == ["アアンドイ"])
        #expect(!DictionarySelector.termVariants("アンド").contains("&"))
    }

    @Test func shortKatakanaUsesWrittenScriptBoundaries() {
        let entries = [DictionaryEntry(preferred: "Luna", readings: ["ルナ"]),
                       DictionaryEntry(preferred: "Terra", readings: ["テラ"]),
                       DictionaryEntry(preferred: "Sol", readings: ["ソル"])]
        #expect(Set(preferred(selector.select(entries: entries, text: "ルナとテラとソル", options: roomy))) == ["Luna", "Terra", "Sol"])
        #expect(selector.select(entries: entries, text: "テラスで休む", options: roomy).selected.isEmpty)
        #expect(selector.select(entries: entries, text: "テラー", options: roomy).selected.isEmpty)
        #expect(Set(preferred(selector.select(entries: entries, text: "テラ・ルナ", options: roomy))) == ["Terra", "Luna"])
    }

    // MARK: - Normalization

    @Test func foldsKatakanaWidthCaseAndWhitespace() {
        let entries = [
            DictionaryEntry(preferred: "Xcode", readings: ["えっくすこーど"]),
            DictionaryEntry(preferred: "合成株式会社", readings: ["ごうせい かぶしきがいしゃ"]),
            DictionaryEntry(preferred: "GitHub", readings: ["ぎっとはぶ"]),
        ]
        let full = selector.select(entries: entries, text: "エックスコードで ｇｉｔｈｕｂ と ギットハブ を使う", options: roomy)
        #expect(Set(preferred(full)) == ["Xcode", "GitHub"])
        let spaced = selector.select(entries: entries, text: "ごうせい　かぶしき がいしゃの件", options: roomy)
        #expect(preferred(spaced) == ["合成株式会社"])
    }

    @Test func preferredSpellingMatchesAfterFolding() {
        let entries = [DictionaryEntry(preferred: "ＡＰＩキー", readings: ["えーぴーあいきー"])]
        let selection = selector.select(entries: entries, text: "api キーを発行する", options: roomy)
        #expect(selection.selected.first?.matchKind == .preferred)
    }

    // MARK: - Short readings

    @Test func shortReadingNeedsClearBoundary() {
        let entries = [DictionaryEntry(preferred: "藍", readings: ["あい"])]
        // Inside a longer hiragana word: no match.
        #expect(selector.select(entries: entries, text: "ありがとうあいしてる", options: roomy).selected.isEmpty)
        // Whitespace, punctuation, text edge, or a script change are clear boundaries.
        #expect(preferred(selector.select(entries: entries, text: "田中 あい さん", options: roomy)) == ["藍"])
        #expect(preferred(selector.select(entries: entries, text: "それは、あい、です", options: roomy)) == ["藍"])
        #expect(preferred(selector.select(entries: entries, text: "あい", options: roomy)) == ["藍"])
        #expect(preferred(selector.select(entries: entries, text: "田中あい", options: roomy)) == ["藍"])
    }

    @Test func shortLatinReadingNeedsBoundary() {
        let entries = [DictionaryEntry(preferred: "AI", readings: ["ai"])]
        #expect(selector.select(entries: entries, text: "please send the mail", options: roomy).selected.isEmpty)
        #expect(preferred(selector.select(entries: entries, text: "AIを使う", options: roomy)) == ["AI"])
        #expect(preferred(selector.select(entries: entries, text: "use AI today", options: roomy)) == ["AI"])
    }

    @Test func longReadingMatchesInsideWords() {
        let entries = [DictionaryEntry(preferred: "社内規程", readings: ["しゃないきてい"])]
        #expect(preferred(selector.select(entries: entries, text: "これはしゃないきていです", options: roomy)) == ["社内規程"])
    }

    // MARK: - Ordering

    @Test func readingBeatsPreferred() {
        let entries = [
            DictionaryEntry(preferred: "山本商事", readings: ["やまもとしょうじ"]),   // only preferred appears
            DictionaryEntry(preferred: "田中工業", readings: ["たなかこうぎょう"]),   // reading appears
        ]
        let selection = selector.select(entries: entries, text: "山本商事とたなかこうぎょうの件", options: roomy)
        #expect(preferred(selection) == ["田中工業", "山本商事"])
        #expect(selection.selected.map(\.matchKind) == [.reading, .preferred])
    }

    @Test func longerMatchFirst() {
        let entries = [
            DictionaryEntry(preferred: "東京", readings: ["とうきょう"]),
            DictionaryEntry(preferred: "東京ドーム", readings: ["とうきょうどーむ"]),
            DictionaryEntry(preferred: "大阪城ホール", readings: ["おおさかじょうほーる"]),
        ]
        let selection = selector.select(entries: entries, text: "おおさかじょうほーると とうきょうどーむ", options: roomy)
        // "とうきょう" inside "とうきょうどーむ" is dropped; the longer reading ranks first.
        #expect(preferred(selection) == ["大阪城ホール", "東京ドーム"])
    }

    @Test func entriesWithoutReadingsAreLowPriorityAndNeedPreferredInText() {
        let entries = [
            DictionaryEntry(preferred: "ItJustTalks"),
            DictionaryEntry(preferred: "合成", readings: ["ごうせい"]),
            DictionaryEntry(preferred: "未使用語"),
        ]
        let selection = selector.select(entries: entries, text: "itjusttalksとごうせいの話", options: roomy)
        #expect(preferred(selection) == ["合成", "ItJustTalks"])
        #expect(selection.selected.last?.matchKind == .preferredWithoutReadings)
        #expect(selection.matchedCount == 2)
    }

    @Test func disabledAndEmptyEntriesAreIgnored() {
        let entries = [
            DictionaryEntry(preferred: "無効", readings: ["むこう"], isEnabled: false),
            DictionaryEntry(preferred: "", readings: ["くうはく"]),
            DictionaryEntry(preferred: "有効", readings: ["ゆうこう", ""]),
        ]
        let selection = selector.select(entries: entries, text: "むこうとくうはくとゆうこう", options: roomy)
        #expect(preferred(selection) == ["有効"])
    }

    @Test func duplicatePreferredIsPassedOnce() {
        let entries = [
            DictionaryEntry(preferred: "合成", readings: ["ごうせい"]),
            DictionaryEntry(preferred: "合成", readings: ["こうせい"]),
        ]
        #expect(selector.select(entries: entries, text: "ごうせいとこうせい", options: roomy).selected.count == 1)
    }

    // MARK: - Caps

    @Test func maxItemsCap() {
        let entries = (0..<20).map { DictionaryEntry(preferred: "語\($0)", readings: ["ことば\(String(format: "%02d", $0))"]) }
        let text = (0..<20).map { "ことば\(String(format: "%02d", $0))" }.joined(separator: " ")
        let selection = selector.select(entries: entries, text: text, options: roomy)
        #expect(selection.selected.count == 8)
        #expect(selection.matchedCount == 20)
        #expect(selection.omittedCount == 12)
        let three = selector.select(entries: entries, text: text, options: DictionarySelectionOptions(maxItems: 3, tokenBudget: 10_000))
        #expect(three.selected.count == 3)
    }

    @Test func tokenBudgetCap() {
        // Line "表記：語N（聞き取り例：ことばNN）" = 18 characters + 1 separator = 19 tokens.
        let entries = (0..<5).map { DictionaryEntry(preferred: "語\($0)", readings: ["ことば0\($0)"]) }
        let text = (0..<5).map { "ことば0\($0)" }.joined(separator: " ")
        let one = selector.select(entries: entries, text: text, options: DictionarySelectionOptions(maxItems: 8, tokenBudget: 19, includeMemo: false))
        #expect(one.selected.count == 1)
        #expect(one.totalTokens == 19)
        let three = selector.select(entries: entries, text: text, options: DictionarySelectionOptions(maxItems: 8, tokenBudget: 60, includeMemo: false))
        #expect(three.selected.count == 3)
        #expect(three.totalTokens <= 60)
        #expect(three.omittedCount == 2)
        let none = selector.select(entries: entries, text: text, options: DictionarySelectionOptions(maxItems: 8, tokenBudget: 5))
        #expect(none.selected.isEmpty)
        #expect(none.omittedCount == 5)
    }

    @Test func smallerEntryCanStillFitAfterALargeOneIsSkipped() {
        let entries = [
            DictionaryEntry(preferred: String(repeating: "長", count: 50), readings: ["ながいことば"]),
            DictionaryEntry(preferred: "短", readings: ["みじかい"]),
        ]
        let selection = selector.select(
            entries: entries, text: "ながいことばとみじかい",
            options: DictionarySelectionOptions(maxItems: 8, tokenBudget: 30, includeMemo: false)
        )
        #expect(preferred(selection) == ["短"])
        #expect(selection.omittedCount == 1)
    }

    // MARK: - Memo and readings

    @Test func memoIncludedOrExcludedByFlag() {
        let entries = [DictionaryEntry(preferred: "合成", readings: ["ごうせい"], memo: "社名。敬称は付けない")]
        let off = selector.select(entries: entries, text: "ごうせい", options: DictionarySelectionOptions(includeMemo: false))
        let on = selector.select(entries: entries, text: "ごうせい", options: DictionarySelectionOptions(includeMemo: true))
        #expect(off.hints.first?.memo == nil)
        #expect(on.hints.first?.memo == "社名。敬称は付けない")
        #expect(PromptAssembler.dictionaryLine(on.hints[0], language: .ja).contains("メモ：社名。敬称は付けない"))
        #expect(!PromptAssembler.dictionaryLine(off.hints[0], language: .ja).contains("メモ"))
        #expect(on.totalTokens > off.totalTokens)
    }

    @Test func memoIsDroppedBeforeTheEntryWhenOverBudget() {
        let entries = [DictionaryEntry(preferred: "合成", readings: ["ごうせい"], memo: String(repeating: "あ", count: 100))]
        let selection = selector.select(entries: entries, text: "ごうせい", options: DictionarySelectionOptions(tokenBudget: 40, includeMemo: true))
        #expect(selection.selected.count == 1)
        #expect(selection.hints[0].memo == nil)
    }

    @Test func matchedReadingComesFirstAndReadingsAreCapped() {
        let entries = [DictionaryEntry(preferred: "合成", readings: ["ごうせいa", "ごうせいb", "ごうせいc", "ごうせいd", "ごうせいe", "ごうせいf"])]
        let selection = selector.select(entries: entries, text: "ごうせいfです", options: roomy)
        let readings = selection.hints[0].readings
        #expect(readings.first == "ごうせいf")
        #expect(readings.count == 5)
    }

    @Test func emptyInputs() {
        #expect(selector.select(entries: [], text: "何か", options: roomy).selected.isEmpty)
        #expect(selector.select(entries: [DictionaryEntry(preferred: "a", readings: ["あ"])], text: "", options: roomy).selected.isEmpty)
    }

    // MARK: - Evaluation set sanity

    @Test func cleanupDictionaryCasesSelectTheirEntries() throws {
        // Every dictionary entry whose preferred spelling is expected in the output should be selected
        // when its reading appears in the transcript (the cases use a mis-recognized reading).
        var checked = 0
        var selectedCount = 0
        for row in try EvaluationCases.load("cleanup") {
            let input = row["input"] as! [String: Any]
            let dictionary = input["dictionary"] as! [[String: Any]]
            guard !dictionary.isEmpty else { continue }
            let entries = dictionary.map {
                DictionaryEntry(
                    preferred: $0["preferred"] as! String,
                    readings: $0["readings"] as! [String],
                    memo: $0["memo"] as? String
                )
            }
            let transcript = input["transcript"] as! String
            let selection = selector.select(entries: entries, text: transcript, options: DictionarySelectionOptions())
            let expect = row["expect"] as! [String: Any]
            let mustContain = expect["mustContain"] as! [String]
            for entry in entries where mustContain.contains(where: { $0.split(separator: "|").map(String.init).contains(entry.preferred) })
                && entry.readings.contains(where: { reading in TextFolding.fold(transcript).contains(TextFolding.fold(reading)) }) {
                checked += 1
                if selection.hints.contains(where: { $0.preferred == entry.preferred }) { selectedCount += 1 }
            }
        }
        print("[cleanup.jsonl] dictionary entries with reading present in transcript: selected \(selectedCount)/\(checked)")
        #expect(checked == 0 || selectedCount == checked)
    }
}
