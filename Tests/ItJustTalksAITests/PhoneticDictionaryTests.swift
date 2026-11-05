import Foundation
import Testing
@testable import ItJustTalksAI

// All texts below are synthetic.

@Suite("PhoneticReading")
struct PhoneticReadingTests {
    private func key(_ text: String) -> String? { PhoneticReading.key(of: text)?.key }

    @Test func kanaTableCoversHiraganaBlock() {
        #expect(PhoneticReading.hiraganaRomaji.count == 0x3096 - 0x3041 + 1)
    }

    @Test(arguments: [
        ("さいとう", "斉藤"),               // kanji word read by the tokenizer
        ("あいてぃーじぇー", "アイティージェイ"),  // small kana, ー vs イ after e
        ("けーえむえす", "ケイエムエス"),
        ("こんふぃぐ", "コンフィグ"),
        ("みどりせいき", "緑精機"),
        ("かんの", "管野"),
        ("がっこう", "ガッコー"),           // おう vs ー
        ("おおの", "おうの"),               // おお vs おう
    ])
    func sameReadingSameKey(_ pair: (String, String)) {
        #expect(key(pair.0) != nil)
        #expect(key(pair.0) == key(pair.1), "\(pair.0) / \(pair.1)")
    }

    /// Vowel length is kept: only true homophones collide.
    @Test(arguments: [
        ("こんどう", "今度"), ("さいとう", "サイト"), ("おおの", "小野"), ("てくのーら", "テクノラ"),
        ("ごとう", "ごと"), ("さいとう", "さとう"), ("みなみでんき", "南口電気"),
    ])
    func differentReadingDifferentKey(_ pair: (String, String)) {
        #expect(key(pair.0) != key(pair.1), "\(pair.0) / \(pair.1)")
    }

    @Test func sokuonBeforeYoon() {
        #expect(key("いっしょ") == "issho")
        #expect(key("ちょっちゅう") == "chotchu:")
        #expect(key("きゃく") == "kyaku")
    }

    @Test func moraCountsOnTheFoldedKey() {
        #expect(PhoneticReading.key(of: "かれ")?.morae == 2)
        #expect(PhoneticReading.key(of: "きょう")?.morae == 2)
        #expect(PhoneticReading.key(of: "かんの")?.morae == 3)
        #expect(PhoneticReading.key(of: "さいとう")?.morae == 4)
        #expect(PhoneticReading.key(of: "がっこう")?.morae == 4)
    }

    @Test func edgeCases() {
        #expect(PhoneticReading.key(of: "") == nil)
        #expect(PhoneticReading.key(of: "ー") == nil)
        #expect(PhoneticReading.key(of: "っ") == nil)
        #expect(PhoneticReading.key(of: "ーっ、") == nil)
        #expect(PhoneticReading.units("😀渡辺さん").first?.romaji == Array("watanabe".utf8))
        #expect(PhoneticReading.units("𠮷野さん").isEmpty == false)
        #expect(PhoneticReading.units("渡辺\n部長").count == 2)
    }

    @Test func katakanaAndAcronymsSpokenInHiragana() {
        #expect(PhoneticReading.wordsSpokenInHiragana(["テンプレート", "レスポンス"], source: "てんぷれーとをかくにんします")
                    == ["テンプレート"])
        #expect(PhoneticReading.wordsSpokenInHiragana(["api", "abc"], source: "えーぴーあい を使います") == ["api"])
        // Katakana or kanji in the source is not hiragana evidence.
        #expect(PhoneticReading.wordsSpokenInHiragana(["テンプレート"], source: "テンプレを確認").isEmpty)
        #expect(PhoneticReading.wordsSpokenInHiragana(["サイトウ"], source: "斉藤さん").isEmpty)
        // Latin words are licensed only when spelled out letter by letter, never by romaji.
        #expect(PhoneticReading.wordsSpokenInHiragana(["sushi"], source: "すしを食べます").isEmpty)
    }

    /// Hiragana evidence must be whole words: no run across a word boundary.
    @Test(arguments: [
        ("メール", "メールをやめるときは連絡します"),      // や|める
        ("ノート", "そのときは連絡します"),             // その|とき
        ("サイト", "見積もりを送ってくださいとお願いしました"),  // くだ|さいと
        ("セール", "できるだけ早くさせるようにします"),     // さ|せる
        ("メル", "やめるときは連絡します"),             // two morae only
        ("ハート", "それはあとで話します"),              // は|あと: starts with a particle
        ("ノート", "かぜのおとがきこえます"),            // の|おと
    ])
    func hiraganaEvidenceIsWordAligned(_ pair: (String, String)) {
        #expect(PhoneticReading.wordsSpokenInHiragana([pair.0], source: pair.1).isEmpty, "\(pair.0)")
    }
}

@Suite("DictionarySelector phonetic")
struct DictionarySelectorPhoneticTests {
    let selector = DictionarySelector(tokenCounter: { $0.count })
    let roomy = DictionarySelectionOptions(maxItems: 8, tokenBudget: 10_000, includeMemo: false)

    private func preferred(_ selection: DictionarySelection) -> [String] { selection.hints.map(\.preferred) }

    @Test func kanjiMisrecognitionIsSelectedWithoutTheTranscriptSpan() {
        let entries = [DictionaryEntry(preferred: "渡邉", readings: ["わたなべ"])]
        let selection = selector.select(entries: entries, text: "渡辺部長に確認をお願いします", options: roomy)
        #expect(preferred(selection) == ["渡邉"])
        #expect(selection.selected.first?.matchKind == .phonetic)
        #expect(selection.hints.first?.readings == ["わたなべ"])
    }

    @Test func compoundOfKanjiWordsIsSelected() {
        let entries = [DictionaryEntry(preferred: "ミドリ精機", readings: ["みどりせいき"])]
        let selection = selector.select(entries: entries, text: "緑精機の担当者から連絡がありました", options: roomy)
        #expect(preferred(selection) == ["ミドリ精機"])
    }

    @Test func katakanaVariantIsSelected() {
        let entries = [
            DictionaryEntry(preferred: "ITJ", readings: ["あいてぃーじぇー"]),
            DictionaryEntry(preferred: "KMS", readings: ["けーえむえす"]),
        ]
        let selection = selector.select(entries: entries, text: "アイティージェイとケイエムエスの資料", options: roomy)
        #expect(Set(preferred(selection)) == ["ITJ", "KMS"])
        #expect(selection.selected.allSatisfy { $0.matchKind == .phonetic })
    }

    /// Homophones that differ only in vowel length are not matched (近藤 for 今度, 齋藤 for サイト).
    @Test(arguments: [
        ("近藤", "こんどう", "今度の打ち合わせは金曜の午後に会議室で行います"),
        ("齋藤", "さいとう", "サイトの更新をお願いします"),
        ("大野", "おおの", "小野さんに連絡します"),
        ("テクノーラ", "てくのーら", "テクノラの新製品"),
    ])
    func vowelLengthMustMatch(_ entry: (String, String, String)) {
        let entries = [DictionaryEntry(preferred: entry.0, readings: [entry.1])]
        #expect(selector.select(entries: entries, text: entry.2, options: roomy).selected.isEmpty, "\(entry.0)")
    }

    /// Kana matches must start and end at word boundaries.
    @Test(arguments: [
        ("伊藤", "いとう", "確認しないと分かりません"),
        ("後藤", "ごとう", "1時間ごとに休憩します"),
        ("齋藤", "さいとう", "見積もりを送ってくださいとお願いしました"),
        ("内藤", "ないと", "確認しないとだめです"),
    ])
    func kanaMatchesAreWordAligned(_ entry: (String, String, String)) {
        let entries = [DictionaryEntry(preferred: entry.0, readings: [entry.1])]
        let selection = selector.select(entries: entries, text: entry.2, options: roomy)
        #expect(selection.selected.allSatisfy { $0.matchKind != .phonetic }, "\(entry.0)")
    }

    @Test func kanjiNumeralsNeverMatchBySound() {
        let entries = [DictionaryEntry(preferred: "サンジ", readings: ["さんじ"])]
        #expect(selector.select(entries: entries, text: "三時に集合してください", options: roomy).selected.isEmpty)
        #expect(selector.select(entries: entries, text: "3時に集合してください", options: roomy).selected.isEmpty)
    }

    @Test func readingKeysAreCachedPerDictionaryVersion() {
        let first = PhoneticReading.cachedKeys(of: ["さいとう", "わたなべ"])
        #expect(first["さいとう"] == PhoneticReading.key(of: "さいとう"))
        let second = PhoneticReading.cachedKeys(of: ["わたなべ", "かんの"])
        #expect(second.keys.sorted() == ["かんの", "わたなべ"])
        #expect(second["わたなべ"] == first["わたなべ"])
    }

    @Test func latinNeverMatchesBySound() {
        // A Latin reading does not match by sound, and Latin text does not match a kana reading by sound.
        let boot = [DictionaryEntry(preferred: "Boot Camp", readings: ["boot"])]
        #expect(selector.select(entries: boot, text: "the bot replied", options: roomy).selected.isEmpty)
        let saito = [DictionaryEntry(preferred: "齋藤", readings: ["さいとう"])]
        #expect(selector.select(entries: saito, text: "please ask saitou about it", options: roomy).selected.isEmpty)
    }

    @Test func literalMatchesRankFirst() {
        let entries = [
            DictionaryEntry(preferred: "齋藤", readings: ["さいとう"]),       // by sound only (斉藤)
            DictionaryEntry(preferred: "合成", readings: ["ごうせい"]),       // literal reading
            DictionaryEntry(preferred: "ItJustTalks"),                     // literal preferred, no readings
        ]
        let selection = selector.select(entries: entries, text: "斉藤さんとごうせいとitjusttalks", options: roomy)
        #expect(preferred(selection) == ["合成", "ItJustTalks", "齋藤"])
        #expect(selection.selected.map(\.matchKind) == [.reading, .preferredWithoutReadings, .phonetic])
        let both = selector.select(entries: [entries[0]], text: "さいとうさんと斉藤さん", options: roomy)
        #expect(both.selected.first?.matchKind == .reading)
    }

    @Test func soundMatchDoesNotHideLiteralMatch() {
        let entries = [
            DictionaryEntry(preferred: "ミドリ精機", readings: ["みどりせいき"]),
            DictionaryEntry(preferred: "翠", readings: ["みどり"]),
        ]
        let selection = selector.select(entries: entries, text: "緑精機と、みどりの件", options: roomy)
        #expect(Set(preferred(selection)) == ["ミドリ精機", "翠"])
    }

    @Test func shortReadingsDoNotMatchBySound() {
        let entries = [DictionaryEntry(preferred: "カレ", readings: ["かれ"])]
        #expect(selector.select(entries: entries, text: "彼に聞いてください", options: roomy).selected.isEmpty)
        let off = DictionarySelectionOptions(maxItems: 8, tokenBudget: 10_000, includeMemo: false, phoneticMinimumMorae: 0)
        let three = [DictionaryEntry(preferred: "渡邉", readings: ["わたなべ"])]
        #expect(selector.select(entries: three, text: "渡辺さん", options: off).selected.isEmpty)
    }

    @Test func kanjiWordsAreNotSplitForSound() {
        let entries = [DictionaryEntry(preferred: "ミナミ電機", readings: ["みなみでんき"])]
        #expect(selector.select(entries: entries, text: "南口の電気屋さんで待ち合わせ", options: roomy).selected.isEmpty)
        let other = [DictionaryEntry(preferred: "齋藤", readings: ["さいとう"])]
        #expect(selector.select(entries: other, text: "佐藤さんに連絡", options: roomy).selected.isEmpty)
    }

    @Test func edgeTexts() {
        let entries = [DictionaryEntry(preferred: "渡邉", readings: ["わたなべ"])]
        for text in ["", "ー", "っ", "ーっ", "😀", "𠮷野さん", "最、塔"] {
            #expect(selector.select(entries: entries, text: text, options: roomy).selected.isEmpty, "\(text)")
        }
        #expect(preferred(selector.select(entries: entries, text: "😀渡辺さん", options: roomy)) == ["渡邉"])
        #expect(preferred(selector.select(entries: entries, text: "了解です\n渡辺部長", options: roomy)) == ["渡邉"])
    }

    @Test func linesAreSingleLineAndKeepCasing() {
        let entries = [DictionaryEntry(preferred: "ItJust\nTalks", readings: ["いっと\nじゃすと"], memo: "社内\nツール")]
        let options = DictionarySelectionOptions(maxItems: 8, tokenBudget: 10_000, includeMemo: true)
        let hint = selector.select(entries: entries, text: "いっとじゃすとの件", options: options).hints.first
        #expect(hint?.preferred == "ItJust Talks")
        #expect(hint?.readings == ["いっと じゃすと"])
        #expect(hint?.memo == "社内 ツール")
    }

    @Test func capsStillApply() {
        let entries = (0..<12).map { DictionaryEntry(preferred: "語\($0)", readings: ["さいとう"]) }
        let selection = selector.select(entries: entries, text: "斉藤さん", options: roomy)
        #expect(selection.selected.count == 8)
        #expect(selection.matchedCount == 12)
        let tight = DictionarySelectionOptions(maxItems: 8, tokenBudget: 20, includeMemo: false)
        let budget = selector.select(entries: entries, text: "斉藤さん", options: tight)
        #expect(budget.totalTokens <= 20)
        #expect(budget.omittedCount == 12 - budget.selected.count)
    }

    @Test func deterministic() {
        let entries = [
            DictionaryEntry(preferred: "渡邉", readings: ["わたなべ"]),
            DictionaryEntry(preferred: "ITJ", readings: ["あいてぃーじぇー"]),
            DictionaryEntry(preferred: "ミドリ精機", readings: ["みどりせいき"]),
        ]
        let text = "渡辺さんがアイティージェイの件で緑精機へ"
        let first = selector.select(entries: entries, text: text, options: roomy)
        #expect(first.selected.count == 3)
        for _ in 0..<5 { #expect(selector.select(entries: entries, text: text, options: roomy) == first) }
    }

    @Test func longTextWithManyEntriesIsFast() {
        let paragraph = "渡辺さんと今度の打ち合わせについて、資料をまとめてから連絡します。アイティージェイの件も確認しないといけません。"
        var text = ""
        while text.count < 12_000 { text += paragraph }
        let kana = Array("あいうえおかきくけこさしすせそたちつてとなにぬねのまみむめもやゆよらりるれろわ")
        let entries = (0..<1_000).map { index -> DictionaryEntry in
            let reading = String([kana[index % kana.count], kana[(index / kana.count) % kana.count], kana[(index * 7) % kana.count], "う"])
            return DictionaryEntry(preferred: "語\(index)", readings: [reading, "読み\(index)"])
        }
        let start = ContinuousClock.now
        _ = selector.select(entries: entries, text: text, options: DictionarySelectionOptions())
        let elapsed = ContinuousClock.now - start
        // Debug builds are several times slower than release; the bound is deliberately generous.
        #expect(elapsed < .seconds(5), "\(elapsed)")
    }
}

@Suite("ResultValidator dictionary and loanwords")
struct ResultValidatorDictionaryTests {
    private func cleanup(
        _ source: String, _ output: String, handsFree: Bool, allowed: [String] = [], reviewOnly: [String] = [],
        spans: [SelfCorrectionSpan]? = nil
    ) -> ValidationOutcome {
        V.validator.validate(ValidationInput(
            task: .cleanup, source: source, output: output, isTruncated: false,
            protectedInstructions: [V.cleanupInstructionsJA, V.cleanupInstructionsEN],
            allowedNewTerms: allowed, reviewOnlyTerms: reviewOnly, handsFree: handsFree, selfCorrections: spans
        ))
    }

    @Test func loanwordsSpokenInHiraganaAreNotNewContent() {
        #expect(V.cleanup("のーしょんのてんぷれーとを共有します", "Notionのテンプレートを共有します",
                          allowedNewTerms: ["Notion"]) == .complete)
        #expect(V.cleanup("えーぴーあい を使います", "APIを使います") == .complete)
        #expect(V.cleanup("ぱいそんのすくりぷとでこんふぃぐをよみこみます", "ぱいそんのスクリプトでコンフィグを読み込みます") == .complete)
    }

    /// Hands-free never relaxes for loanwords: an unpunctuated retraction is invisible to the cue rules.
    @Test func handsFreeHasNoLoanwordRelaxation() {
        #expect(!V.cleanup("のーしょんのてんぷれーとを共有します", "Notionのテンプレートを共有します",
                           handsFree: true, allowedNewTerms: ["Notion"]).isComplete)
        #expect(!V.sendable("ぱいそんのすくりぷとでこんふぃぐをよみこみます", "ぱいそんのスクリプトでコンフィグを読み込みます"))
        #expect(!V.sendable("てんぷれーといやふぉーまっとを使ってください", "テンプレートを使ってください"))
        #expect(!cleanup("てんぷれーといやふぉーまっとを使ってください", "テンプレートを使ってください", handsFree: true,
                         spans: [SelfCorrectionSpan(retracted: "てんぷれーと", replacement: "ふぉーまっと")]).isComplete)
    }

    /// Stage-A spans are removed by a folded key, whatever script they were copied in.
    @Test func retractedSpanIsRemovedByFoldedKey() {
        let evidence = CleanupFidelity.removingRetractions(
            from: "てんぷれーといやふぉーまっとを使ってください",
            spans: [SelfCorrectionSpan(retracted: "テンプレート", replacement: "フォーマット")]
        )
        #expect(!evidence.contains("てんぷれーと"))
        #expect(evidence.contains("ふぉーまっと"))
        #expect(!cleanup("てんぷれーといやふぉーまっとを使ってください", "テンプレートを使ってください", handsFree: false,
                         spans: [SelfCorrectionSpan(retracted: "テンプレート", replacement: "フォーマット")]).isComplete)
        // A replacement repeating the retracted words keeps them.
        let kept = CleanupFidelity.removingRetractions(
            from: "てんぷれーと、いや、てんぷれーとふぁいるを使って",
            spans: [SelfCorrectionSpan(retracted: "てんぷれーと", replacement: "てんぷれーとふぁいる")]
        )
        #expect(kept.contains("てんぷれーとふぁいる"))
    }

    /// Hands-free: a dictionary spelling (or a word of it) used more often than the transcript supports
    /// is reviewed, whether the entry matched by sound or literally elsewhere.
    @Test func dictionaryUseBeyondEvidenceIsReviewedInHandsFree() {
        // Route 1: only a part of a sound-matched spelling.
        let sato = DictionaryHint(preferred: "佐藤部長", readings: ["さとう"])
        let route1 = V.validator.validate(ValidationInput(
            task: .cleanup, source: "コーヒーに砂糖を入れてください", output: "コーヒーに佐藤を入れてください", isTruncated: false,
            protectedInstructions: [V.cleanupInstructionsJA], reviewOnlyTerms: ["佐藤部長"], selectedDictionary: [sato],
            handsFree: true
        ))
        #expect(!route1.isComplete)
        #expect(route1.reasons.contains(.unverifiedDictionaryReplacement))
        let midori = DictionaryHint(preferred: "ミドリ精機株式会社", readings: ["みどりせいきかぶしきがいしゃ"])
        let partial = V.validator.validate(ValidationInput(
            task: .cleanup, source: "緑精機株式会社の方と会います", output: "ミドリ精機の方と会います", isTruncated: false,
            protectedInstructions: [V.cleanupInstructionsJA], reviewOnlyTerms: ["ミドリ精機株式会社"],
            selectedDictionary: [midori], handsFree: true
        ))
        #expect(!partial.isComplete)
        #expect(partial.reasons.contains(.unverifiedDictionaryReplacement))
        // Route 2: the entry also matched literally, but the homophone was rewritten too.
        let satoSan = DictionaryHint(preferred: "佐藤", readings: ["さとう"])
        func route2(_ output: String) -> ValidationOutcome {
            V.validator.validate(ValidationInput(
                task: .cleanup, source: "さとうさんに砂糖を渡してください", output: output, isTruncated: false,
                protectedInstructions: [V.cleanupInstructionsJA], allowedNewTerms: ["佐藤"], selectedDictionary: [satoSan],
                handsFree: true
            ))
        }
        #expect(route2("佐藤さんに佐藤を渡してください") == .needsReview([.unverifiedDictionaryReplacement]))
        #expect(route2("佐藤さんに砂糖を渡してください") == .complete)
    }

    /// Retracted speech is no evidence for a dictionary spelling (selection ran on the corrected transcript).
    @Test func retractedSpeechDoesNotLicenseDictionarySpelling() {
        let sato = DictionaryHint(preferred: "佐藤", readings: ["さとう"])
        for spans in [nil, [SelfCorrectionSpan(retracted: "佐藤さん", replacement: "加藤さん")]] as [[SelfCorrectionSpan]?] {
            let outcome = V.validator.validate(ValidationInput(
                task: .cleanup, source: "佐藤さん、いや、加藤さんに砂糖を渡してください",
                output: "加藤さんに佐藤を渡してください", isTruncated: false,
                protectedInstructions: [V.cleanupInstructionsJA], reviewOnlyTerms: ["佐藤"], selectedDictionary: [sato],
                handsFree: true, selfCorrections: spans
            ))
            #expect(!outcome.isComplete)
            #expect(outcome.reasons.contains(.unverifiedDictionaryReplacement))
        }
    }

    /// A number inside a sound-matched spelling: reviewed, not failed (licensed where the whole term appears).
    @Test func reviewOnlyTermWithNumberIsReviewedNotFailed() {
        let outcome = V.validator.validate(ValidationInput(
            task: .cleanup, source: "だいにえいぎょうぶの資料を送ります", output: "第2営業部の資料を送ります", isTruncated: false,
            protectedInstructions: [V.cleanupInstructionsJA], reviewOnlyTerms: ["第2営業部"], handsFree: true
        ))
        #expect(outcome == .needsReview([.unverifiedDictionaryReplacement]))
    }

    @Test func dictionarySpellingIsAllowedOnlyWhenSelected() {
        #expect(!V.cleanup("のーしょんを開いてください", "Notionを開いてください").isComplete)
        #expect(V.cleanup("のーしょんを開いてください", "Notionを開いてください", allowedNewTerms: ["Notion"]) == .complete)
        #expect(!V.sendable("るもーらの設定を開いてください", "Lumoraの設定を開いてください"))
        #expect(V.cleanup("るもーらの設定を開いてください", "Lumoraの設定を開いてください", handsFree: true,
                          allowedNewTerms: ["Lumora"]) == .complete)
        // Kana → kanji with the same reading was already licensed by reading (unchanged).
        #expect(V.cleanup("さいとう部長に渡してください", "齋藤部長に渡してください", handsFree: true) == .complete)
    }

    @Test func singleCharacterOfALicensedSpellingIsNotLicensedAlone() {
        let result = V.validator.contentOverlap(source: "資料を送ります", output: "都の資料を送ります", allowedNewTerms: ["東京都"])
        #expect(result.isNew("都"))
        #expect(!result.isNew("東京都"))
        #expect(!result.isNew("東京"))
    }

    /// Hands-free: a spelling found only by sound may be a homophone, so it is never sent (needsReview).
    @Test func soundOnlyReplacementIsReviewedInHandsFree() {
        let source = "今度の打ち合わせは金曜の午後に会議室で行います"
        let output = "近藤の打ち合わせは金曜の午後に会議室で行います"
        #expect(cleanup(source, output, handsFree: true, reviewOnly: ["近藤"]) == .needsReview([.unverifiedDictionaryReplacement]))
        #expect(cleanup("渡辺部長に確認をお願いします", "渡邉部長に確認をお願いします", handsFree: true, reviewOnly: ["渡邉"])
                    == .needsReview([.unverifiedDictionaryReplacement]))
        // The spelling already in the transcript, or not used, changes nothing.
        #expect(cleanup("渡邉部長に確認をお願いします", "渡邉部長に確認をお願いします", handsFree: true, reviewOnly: ["渡邉"]) == .complete)
        #expect(cleanup("渡辺部長に確認をお願いします", "渡辺部長に確認をお願いします", handsFree: true, reviewOnly: ["渡邉"]) == .complete)
    }

    @Test func unspokenKatakanaIsStillNewContent() {
        #expect(!V.cleanup("資料を共有します", "テンプレートの資料を共有します").isComplete)
        #expect(!V.sendable("てんぷれを共有します", "テンプレートを共有します"))
        #expect(!V.cleanup("あしたのてんきは", "明日の天気はサニーです").isComplete)
        #expect(!V.cleanup("のーしょんを共有します", "Notionのテンプレートを共有します", allowedNewTerms: ["Notion"]).isComplete)
        // Hiragana inside other words is no evidence.
        #expect(!V.sendable("メールをやめるときは連絡します", "メールを止める時はメール連絡します"))
        #expect(!V.cleanup("そのときは連絡します", "そのノートは連絡します").isComplete)
    }

    /// Retracted speech never licenses a katakana rendering.
    @Test func retractedSpeechIsNoEvidence() {
        let source = "てんぷれーと、いや、ふぉーまっとを使ってください"
        let output = "テンプレートを使ってください"
        let spans = [SelfCorrectionSpan(retracted: "てんぷれーと", replacement: "ふぉーまっと")]
        for handsFree in [false, true] {
            #expect(!cleanup(source, output, handsFree: handsFree).isComplete, "handsFree \(handsFree)")
            #expect(!cleanup(source, output, handsFree: handsFree, spans: spans).isComplete, "handsFree \(handsFree) spans")
        }
        // The corrected word is fine (normal mode; hands-free has no loanword relaxation).
        #expect(cleanup(source, "フォーマットを使ってください", handsFree: false, spans: spans) == .complete)
    }
}
