import Foundation

/// Where an AI-command result should go, decided from the SPOKEN instruction only (§3.2 step 2).
/// Target text and custom instructions are never inspected.
public enum CommandOutputIntent: String, Sendable, Hashable, CaseIterable {
    case automatic
    case showResult = "show_result"
    case insertAtTarget = "insert_at_target"
}

/// Result kind of an AI command (§3.2 kind table). Raw values match the evaluation labels.
public enum CommandKind: String, Sendable, Hashable, CaseIterable {
    case content
    case answer
    case clarification
    case refusal
    case requiresWeb = "requires_web"
}

/// Deterministic pre-checks and kind derivation for AI commands (§3.2 steps 1, 2 and 5).
///
/// All functions are pure. The vocabulary is a closed Japanese/English list; it is intentionally small and
/// conservative: anything conflicting or ambiguous resolves to `.showResult`, and an unsure kind is `.answer`.
public enum CommandRouter {
    // MARK: - Output intent (step 2)

    public static func outputIntent(spokenInstruction: String) -> CommandOutputIntent {
        let compact = TextFolding.compact(spokenInstruction)
        var words = TextFolding.asciiWords(spokenInstruction)

        // 1. Negated insertion ("貼らないで", "don't paste it") means show only. Remove those phrases so
        //    the affirmative insert vocabulary cannot match inside them.
        var remaining = compact
        var wantsShow = false
        for phrase in vocabulary.negatedInsertJA where remaining.contains(phrase) {
            wantsShow = true
            remaining = remaining.replacingOccurrences(of: phrase, with: "")
        }
        // Structural form: an insert verb followed (through okurigana/particles only) by a negation
        // ("入力はしないで", "貼り付けは不要", "入れずに") or a hedge ("入れてもいいよ"). Negated → show only;
        // hedged → ambiguous → show. The clause is then removed from the affirmative matching.
        var vagueByHedge = false
        for clause in clauses(spokenInstruction) {
            switch insertModality(TextFolding.compact(clause)) {
            case .negated:
                wantsShow = true
                remaining = remaining.replacingOccurrences(of: TextFolding.compact(clause), with: "|")
            case .hedged:
                vagueByHedge = true
            case .none:
                break
            }
        }
        let (maskedWords, negatedEnglish) = maskNegated(words, verbs: vocabulary.insertVerbsEN)
        words = maskedWords
        if negatedEnglish { wantsShow = true }

        // 2. Affirmative vocabulary.
        let padded = " " + words.joined(separator: " ") + " "
        if vocabulary.showJA.contains(where: { remaining.contains($0) })
            || vocabulary.showEN.contains(where: { padded.contains($0) }) {
            wantsShow = true
        }
        let wantsInsert = vocabulary.insertJA.contains(where: { remaining.contains($0) })
            || vocabulary.insertEN.contains(where: { padded.contains($0) })
        let vague = vagueByHedge
            || vocabulary.vagueJA.contains(where: { remaining.contains($0) })
            || vocabulary.vagueEN.contains(where: { padded.contains($0) })

        // 3. Conflicting or ambiguous → show.
        if vague { return .showResult }
        switch (wantsShow, wantsInsert) {
        case (true, _): return .showResult
        case (false, true): return .insertAtTarget
        case (false, false): return .automatic
        }
    }

    enum InsertModality { case none, negated, hedged }

    /// Negated or hedged insert verb inside one compact (folded, punctuation-free) clause. Between the verb
    /// stem and the marker only hiragana (okurigana, particles: "はしないで", "らずに") may appear.
    static func insertModality(_ clause: String) -> InsertModality {
        let chars = Array(clause)
        var result = InsertModality.none
        for stem in vocabulary.insertStemsJA {
            let stemChars = Array(stem)
            var index = 0
            while index + stemChars.count <= chars.count {
                defer { index += 1 }
                guard Array(chars[index..<(index + stemChars.count)]) == stemChars else { continue }
                let rest = Array(chars[(index + stemChars.count)...])
                for gap in 0...min(4, rest.count) {
                    if gap > 0, !isHiragana(rest[gap - 1]) { break }
                    let tail = String(rest[gap...])
                    if vocabulary.negationMarkersJA.contains(where: { tail.hasPrefix($0) }) { return .negated }
                    if vocabulary.hedgeMarkersJA.contains(where: { tail.hasPrefix($0) }) { result = .hedged }
                }
            }
        }
        return result
    }

    private static func isHiragana(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
    }

    /// Folded clauses split at punctuation (and the question mark), with whether each ended with "?".
    static func clauses(_ text: String) -> [String] {
        clausesWithQuestionMark(text).map(\.text)
    }

    static func clausesWithQuestionMark(_ text: String) -> [(text: String, question: Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        for character in TextFolding.fold(text) {
            if "、。,.!?！？;；\n".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append((trimmed, character == "?" || character == "？")) }
                current = ""
            } else {
                current.append(character)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append((trimmed, false)) }
        return result
    }

    /// Replaces "<negator> … <verb>" (up to three words apart) with blanks. Returns whether one was found.
    private static func maskNegated(_ words: [String], verbs: Set<String>) -> ([String], Bool) {
        var result = words
        var found = false
        var index = 0
        while index < result.count {
            if vocabulary.negators.contains(result[index]) {
                let limit = min(result.count - 1, index + 4)
                if index + 1 <= limit {
                    for lookahead in (index + 1)...limit where verbs.contains(result[lookahead]) {
                        for masked in index...lookahead { result[masked] = "" }
                        found = true
                        break
                    }
                }
            }
            index += 1
        }
        return (result.filter { !$0.isEmpty }, found)
    }

    // MARK: - Web-required pre-check (step 1)

    /// True when the request needs live external information the app cannot provide (no web search).
    ///
    /// When a target text is provided and the instruction operates on it (summarize, translate, proofread …),
    /// the request is a text task and this never fires ("今日届いたメールを要約して").
    public static func requiresWeb(spokenInstruction: String, hasTarget: Bool) -> Bool {
        let compact = TextFolding.compact(spokenInstruction)
        let words = TextFolding.asciiWords(spokenInstruction)
        let padded = " " + words.joined(separator: " ") + " "

        if hasTarget && operatesOnText(compact: compact, padded: padded) { return false }

        if vocabulary.searchJA.contains(where: { compact.contains($0) })
            || vocabulary.searchEN.contains(where: { padded.contains($0) }) {
            return true
        }

        let hasMarker = vocabulary.liveMarkerJA.contains(where: { compact.contains($0) })
            || words.contains(where: { word in
                vocabulary.liveMarkerEN.contains(word) || word.hasPrefix("today")
            })
            || vocabulary.liveMarkerPhraseEN.contains(where: { padded.contains($0) })
        let hasNoun = vocabulary.liveNounJA.contains(where: { compact.contains($0) })
            || words.contains(where: { vocabulary.liveNounEN.contains($0) })
        if hasMarker && hasNoun { return true }
        // "最新" / "latest" alone asks for current information.
        if vocabulary.latestJA.contains(where: { compact.contains($0) }) || words.contains("latest") { return true }

        // Strong live nouns (news, weather, stock price …) unless the request is conceptual or a writing task.
        let strong = vocabulary.strongNounJA.contains(where: { compact.contains($0) })
            || vocabulary.strongNounEN.contains(where: { padded.contains($0) })
        if strong {
            let exempt = vocabulary.conceptualJA.contains(where: { compact.contains($0) })
                || vocabulary.conceptualEN.contains(where: { padded.contains($0) })
            return !exempt
        }
        return false
    }

    private static func operatesOnText(compact: String, padded: String) -> Bool {
        vocabulary.textOperationJA.contains(where: { compact.contains($0) })
            || vocabulary.textOperationEN.contains(where: { padded.contains($0) })
    }

    // MARK: - Task type override (step 4)

    /// Deterministic override of the classifier's task type. An instruction that both edits the target and
    /// asks to be told something ("校正して、おかしいところも教えて", "fix the grammar and tell me what was
    /// wrong") wants an explanation shown to the user, not a replacement → `.explain_analyze`.
    /// Other types are returned unchanged.
    ///
    /// Structural rule (P1 round 2): when a target exists and the instruction also asks a question or an
    /// opinion about it — a question mark, "か/かな/かどうか/と思う", "か教えて", "whether", "do you think",
    /// an auxiliary-first clause ("is it …") — the request wants an answer shown, not a replacement:
    /// `.explain_analyze` when it names an explanation ("説明して", "explain") or asks a wh-question about the
    /// edit ("どこが違ったか教えて"), `.answer_question` for a yes/no or opinion question.
    /// A request phrased as a question ("校正してくれる？", "Could you proofread this?") is not a question
    /// element.
    public static func adjustedTaskType(
        _ type: ClassifiedTaskType, spokenInstruction: String, hasTarget: Bool = true
    ) -> ClassifiedTaskType {
        if hasTarget, case .pureTranslation = TranslationIntent.parse(spokenInstruction) { return .translate }
        // "…と丁寧に返信して" / "Reply politely …": a reply to the target, even when a tone word made the
        // classifier pick an edit ("この返信を丁寧にして" ends differently and stays an edit).
        if hasTarget, type == .proofread_rewrite || type == .transform, asksForReply(spokenInstruction),
           !mentionsEdit(spokenInstruction) {
            return .compose_reply
        }
        switch type {
        case .proofread_rewrite, .translate, .transform, .summarize, .extract:
            if hasTarget {
                // "説明して" / a wh-question about the edit ("どこが違ったか教えて") → explanation;
                // a yes/no or opinion question ("失礼じゃないか教えて", "do you think …") → answer.
                let question = questionElement(spokenInstruction)
                if namesExplanation(spokenInstruction) || question == .wh { return .explain_analyze }
                if question == .yesNoOrOpinion { return .answer_question }
            }
            return isEditPlusQuestion(spokenInstruction) ? .explain_analyze : type
        case .explain_analyze, .answer_question, .compose_reply, .insufficient_target, .not_executable, .requires_web:
            return type
        }
    }

    static func asksForReply(_ spokenInstruction: String) -> Bool {
        let compact = TextFolding.compact(spokenInstruction)
        if vocabulary.replyEndingsJA.contains(where: { compact.hasSuffix($0) }) { return true }
        // English: the request must start with the reply verb ("Reply politely…", "Please write a reply…").
        var words = TextFolding.asciiWords(spokenInstruction)
        if words.first == "please" { words.removeFirst() }
        let padded = " " + words.joined(separator: " ") + " "
        return ["reply", "respond"].contains(words.first ?? "")
            || vocabulary.replyRequestsEN.contains(where: { padded.hasPrefix($0) })
    }

    /// "下書きを直して返信して": the user's own draft is edited, not answered.
    static func mentionsEdit(_ spokenInstruction: String) -> Bool {
        let compact = TextFolding.compact(spokenInstruction)
        let padded = " " + TextFolding.asciiWords(spokenInstruction).joined(separator: " ") + " "
        return vocabulary.editJA.contains(where: { compact.contains($0) })
            || vocabulary.editEN.contains(where: { padded.contains($0) })
    }

    static func isEditPlusQuestion(_ spokenInstruction: String) -> Bool {
        let compact = TextFolding.compact(spokenInstruction)
        let padded = " " + TextFolding.asciiWords(spokenInstruction).joined(separator: " ") + " "
        let edits = vocabulary.editJA.contains(where: { compact.contains($0) })
            || vocabulary.editEN.contains(where: { padded.contains($0) })
        let asks = vocabulary.askJA.contains(where: { compact.contains($0) })
            || vocabulary.askEN.contains(where: { padded.contains($0) })
        return edits && asks
    }

    enum QuestionKind { case yesNoOrOpinion, wh }

    static func hasQuestionElement(_ spokenInstruction: String) -> Bool {
        questionElement(spokenInstruction) != nil
    }

    /// The question or opinion request in the instruction, if any (see `adjustedTaskType`).
    static func questionElement(_ spokenInstruction: String) -> QuestionKind? {
        for (clause, questionMark) in clausesWithQuestionMark(spokenInstruction) {
            let compact = TextFolding.compact(clause)
            let words = TextFolding.asciiWords(clause)
            let padded = " " + words.joined(separator: " ") + " "
            func kind() -> QuestionKind {
                let wh = vocabulary.interrogativesJA.contains(where: { compact.contains($0) })
                    || words.contains(where: { vocabulary.interrogativesEN.contains($0) })
                return wh ? .wh : .yesNoOrOpinion
            }
            // Opinion / yes-no questions, even inside a polite request ("whether", "かどうか", "どう思う").
            if vocabulary.embeddedQuestionJA.contains(where: { compact.contains($0) })
                || vocabulary.embeddedQuestionEN.contains(where: { padded.contains($0) }) {
                return .yesNoOrOpinion
            }
            if compact.range(of: "(か|かな|かしら)(も|を)?(教えて|おしえて|知りたい|知らせて|聞きたい|聞かせて|判断して|確認して|みて|見て|ちぇっくして|評価して)", options: .regularExpression) != nil {
                return kind()
            }
            // A clause that is itself a request ("校正してくれる？", "could you fix this?") is not a question.
            let isRequestQuestion = vocabulary.requestQuestionEndingsJA.contains(where: { compact.hasSuffix($0) })
                || vocabulary.requestQuestionStartsEN.contains(where: { padded.hasPrefix($0) })
            if isRequestQuestion { continue }
            if questionMark || vocabulary.questionEndingsJA.contains(where: { compact.hasSuffix($0) }) { return kind() }
            if let first = words.first, vocabulary.auxiliaryStartsEN.contains(first), words.count >= 3,
               ["it", "this", "that", "these", "those", "the", "my", "there", "i", "we", "they", "he", "she"].contains(words[1]) {
                return .yesNoOrOpinion
            }
        }
        return nil
    }

    static func namesExplanation(_ spokenInstruction: String) -> Bool {
        let compact = TextFolding.compact(spokenInstruction)
        let padded = " " + TextFolding.asciiWords(spokenInstruction).joined(separator: " ") + " "
        return vocabulary.explainJA.contains(where: { compact.contains($0) })
            || vocabulary.explainEN.contains(where: { padded.contains($0) })
    }

    /// The spoken instruction explicitly asks to replace / rewrite the target ("要約に書き換えて",
    /// "三行に直して", "replace it with a summary", "rewrite it as a summary"). Negated forms
    /// ("置き換えないで", "don't replace") do not count.
    public static func asksToReplaceTarget(spokenInstruction: String) -> Bool {
        var compact = TextFolding.compact(spokenInstruction)
        for phrase in vocabulary.negatedReplaceJA { compact = compact.replacingOccurrences(of: phrase, with: "|") }
        if vocabulary.replaceJA.contains(where: { compact.contains($0) }) { return true }
        let (words, _) = maskNegated(TextFolding.asciiWords(spokenInstruction), verbs: vocabulary.replaceVerbsEN)
        let padded = " " + words.joined(separator: " ") + " "
        return vocabulary.replaceEN.contains(where: { padded.contains($0) })
    }

    // MARK: - Kind (step 5)

    /// §3.2 kind table with the deterministic replacement rule (P1 evaluation fix): a summary or extraction
    /// is a replacement artifact (`.content`) only when the spoken instruction explicitly asks to
    /// replace/rewrite the target; otherwise it is shown as an `.answer`. The classifier's
    /// `isReplacementArtifact` is not trusted for this decision. When unsure the result is `.answer`.
    /// Pass the task type after `adjustedTaskType(_:spokenInstruction:)`.
    public static func deriveKind(
        taskType: ClassifiedTaskType,
        hasTarget: Bool,
        spokenInstruction: String
    ) -> CommandKind {
        switch taskType {
        case .insufficient_target: return .clarification
        case .not_executable: return .refusal
        case .requires_web: return .requiresWeb
        case .proofread_rewrite, .translate, .transform:
            return hasTarget ? .content : .answer
        case .summarize, .extract:
            return hasTarget && asksToReplaceTarget(spokenInstruction: spokenInstruction) ? .content : .answer
        case .explain_analyze, .answer_question, .compose_reply:
            return .answer
        }
    }

    // MARK: - Vocabulary

    /// Phrases are folded with `TextFolding` (NFKC, lower case, katakana → hiragana, separators removed for
    /// Japanese; space-separated lower-case words for English) at first use.
    private static let vocabulary = Vocabulary()

    private struct Vocabulary {
        // Show only. Stems cover the verb forms ("見せて", "見せるだけ", "表示させて", "画面に出すだけ").
        let showJA = fold([
            "表示", "見せ", "見るだけ", "確認だけ", "読むだけ", "画面に出", "出すだけ", "結果ウィンドウ",
        ])
        let showEN = words([
            "show me only", "show only", "show it only", "show me the result", "show the result",
            "just show", "only show", "display only", "just display", "only display", "show me the output",
            "display it", "display the result",
        ])
        // Insert verb stems for the structural negation / hedge check (folded: katakana → hiragana).
        let insertStemsJA = fold([
            "貼り付け", "貼りつけ", "貼付け", "貼", "入力", "入れ", "挿入", "ペースト", "打ち込", "書き込", "置き換え",
            "置きかえ", "置換", "上書き", "差し替え", "差しかえ", "反映", "書き換え", "書きかえ",
        ])
        let negationMarkersJA = fold([
            "ないで", "なくて", "ないよう", "ない", "ずに", "ず", "せず", "ません", "不要", "いらない", "要らない",
            "やめて", "止めて", "禁止", "なしで", "無しで", "だめ", "ダメ",
        ])
        let hedgeMarkersJA = fold([
            "てもいい", "てもよい", "ても良い", "てもかまわ", "ても構わ", "でもいい", "でもよい", "てもok", "てもオッケー",
        ])
        // Questions / opinion requests about the target.
        let embeddedQuestionJA = fold(["かどうか", "と思う", "と思います", "と思いますか", "どう思う", "どうかな", "大丈夫かな"])
        let embeddedQuestionEN = words([
            "whether", "tell me if", "let me know if", "do you think", "what do you think", "does it sound",
            "does this sound", "is it okay", "is it ok", "is this okay", "is this ok", "is it correct", "is this correct",
            "is it right", "is this right", "how does it sound", "how does this sound",
        ])
        let questionEndingsJA = fold([
            "ですか", "ますか", "でしょうか", "だろうか", "かな", "かしら", "っけ", "のか", "ないか", "るか", "たか",
        ])
        let requestQuestionEndingsJA = fold([
            "てくれる", "でくれる", "てくれない", "でくれない", "てもらえる", "でもらえる", "てもらえない", "でもらえない",
            "てくれますか", "でくれますか", "てもらえますか", "でもらえますか", "ていただけますか", "でいただけますか",
            "ていただけませんか", "でいただけませんか", "てくれませんか", "でくれませんか", "てもらえませんか",
            "でもらえませんか", "てくれるかな", "でくれるかな", "てもらえるかな", "でもらえるかな", "てほしい", "でほしい",
            "てくれるか", "でくれるか", "てもらえるか", "でもらえるか", "できる", "できますか", "できるかな", "できない",
            "できませんか", "お願いできる", "お願いできますか", "頼める",
        ])
        let requestQuestionStartsEN = words([
            "can you", "could you", "would you", "will you", "can u", "could u", "please", "would you mind",
            "can i get", "could i get", "may i have",
        ])
        let auxiliaryStartsEN: Set<String> = [
            "is", "are", "was", "were", "does", "did", "should", "would", "will", "can", "could",
        ]
        let interrogativesJA = fold([
            "どこ", "なぜ", "なんで", "何", "なに", "どう", "どれ", "どの", "どんな", "いつ", "だれ", "誰", "どちら", "どっち",
        ])
        let interrogativesEN: Set<String> = ["what", "why", "where", "how", "which", "who", "when"]
        // Verb forms only: "説明" is also a noun ("PRの説明を要約して").
        let explainJA = fold(["説明して", "解説して", "分析して", "説明も", "解説も", "説明お願", "解説お願"])
        let explainEN = words(["explain", "analyze", "analyse"])
        // "Do not insert/paste" – forms handled before the affirmative vocabulary.
        let negatedInsertJA = fold([
            "貼らないで", "貼り付けないで", "貼りつけないで", "貼らず", "入れないで", "入力しないで", "挿入しないで",
            "置き換えないで", "置換しないで", "書き換えないで", "上書きしないで", "ペーストしないで", "反映しないで",
        ])
        let negators = Set([
            "dont", "don't", "not", "never", "without", "no", "doesn't", "shouldn't", "instead", "rather", "avoid", "skip",
        ])
        let insertVerbsEN = Set([
            "paste", "pasting", "insert", "inserting", "type", "typing", "put", "putting", "replace", "replacing",
            "overwrite", "overwriting", "enter",
        ])
        // Insert at the captured target.
        let insertJA = fold([
            "ここに入れて", "ここに入力して", "ここに貼り付けて", "ここに貼りつけて", "ここに貼って", "ここに挿入して",
            "ここに書いて", "ここに書き込んで", "ここにペーストして", "入れて", "入力して", "貼り付けて", "貼りつけて",
            "貼って", "挿入して", "ペーストして", "書き込んで", "打ち込んで",
        ])
        let insertEN = words([
            "insert it", "insert here", "insert this", "insert into", "insert the result",
            "paste it", "paste here", "paste this", "paste into", "paste the result",
            "put it here", "type it here", "type it in", "enter it here", "write it here",
        ])
        // Vague destinations → ambiguous → show.
        let vagueJA = fold([
            "どこかに", "どこかへ", "どっかに", "どこか適当", "適当な場所", "どっちでも", "どちらでも", "お任せ", "おまかせ", "任せる",
        ])
        let vagueEN = words(["somewhere", "anywhere", "wherever", "if you want", "if you like", "either way", "up to you", "whichever"])

        // Web: explicit search.
        let searchJA = fold([
            "検索して", "ググって", "ぐぐって", "ウェブ検索", "web検索", "ネット検索", "ネットで調べ", "ウェブで調べ",
            "webで調べ", "インターネットで調べ", "ネットで探", "ネットで検索",
        ])
        let searchEN = words([
            "search the web", "search online", "search the internet", "search the net", "web search",
            "google it", "google that", "look it up online", "look up online", "browse the web",
        ])
        // Web: live information.
        let latestJA = fold(["最新"])
        let liveMarkerJA = fold([
            "今日", "本日", "今の", "現在", "明日", "明後日", "今週", "今月", "来週", "直近", "リアルタイム", "速報", "昨日",
        ])
        let liveMarkerEN = Set(["now", "current", "currently", "tonight", "tomorrow", "live", "breaking", "recent", "recently"])
        let liveMarkerPhraseEN = words(["right now", "this week", "this month", "this morning", "this evening"])
        let liveNounJA = fold([
            "ニュース", "為替", "株価", "株式", "天気", "天候", "気温", "相場", "レート", "日経平均", "ドル円", "ビットコイン",
            "仮想通貨", "運行情報", "渋滞", "試合結果", "スコア", "話題", "トレンド", "情報", "出来事", "価格", "値段",
        ])
        let liveNounEN = Set([
            "news", "headline", "headlines", "weather", "forecast", "stock", "stocks", "rate", "rates", "price", "prices",
            "score", "scores", "traffic", "bitcoin", "crypto", "events", "update", "updates",
        ])
        let strongNounJA = fold([
            "ニュース", "為替レート", "為替相場", "株価", "天気", "日経平均", "ドル円", "円相場",
        ])
        let strongNounEN = words([
            "news", "headlines", "weather", "exchange rate", "exchange rates", "stock price", "stock prices",
            "share price",
        ])
        // Strong nouns do not fire for conceptual questions or writing tasks.
        let conceptualJA = fold([
            "仕組み", "しくみ", "とは", "書き方", "作り方", "意味", "違い", "歴史", "原理", "について教えて", "書いて", "作って", "作成して",
            "下書き", "例文",
        ])
        let conceptualEN = words([
            "how to", "how does", "how do", "how is", "how are", "explain", "history of", "definition", "meaning of", "write",
            "draft", "compose",
        ])
        // The instruction operates on the provided text.
        let textOperationJA = fold([
            "要約", "翻訳", "訳して", "英語に", "日本語に", "中国語に", "韓国語に", "語にして", "校正", "添削", "直して",
            "書き換", "書きかえ", "言い換", "言いかえ", "整形", "箇条書き", "抜き出", "抽出", "説明", "解説", "分析",
            "返信", "返事", "短く", "長く", "丁寧", "敬語", "カジュアル", "まとめて", "読みやすく", "手直し", "清書",
            "整えて", "リライト", "文章を", "本文を", "メールを", "文面", "要点", "表にして", "リストにして", "にして",
        ])
        // Explicit replacement of the target (summaries / extractions become content only with these).
        let replaceJA = fold([
            "書き換えて", "書きかえて", "書き換えに", "置き換えて", "置きかえて", "差し替えて", "差しかえて", "置換して",
            "上書きして", "に直して", "になおして", "に書き直して",
        ])
        let negatedReplaceJA = fold([
            "書き換えないで", "書きかえないで", "置き換えないで", "置きかえないで", "差し替えないで", "差しかえないで",
            "置換しないで", "上書きしないで", "直さないで", "書き換えず", "置き換えず", "差し替えず",
        ])
        let replaceVerbsEN = Set(["replace", "replacing", "overwrite", "overwriting", "rewrite", "rewriting"])
        let replaceEN = words([
            "replace", "replacing", "overwrite", "rewrite as", "rewrite it as", "rewrite this as", "rewrite into",
            "rewrite it into", "rewrite this into", "rewrite the text as",
        ])
        // The instruction ends by asking for a reply to the target.
        let replyEndingsJA = fold([
            "返信して", "返信してください", "返信をして", "返事して", "返事をして", "返事してください",
            "返信を書いて", "返事を書いて", "返信文を書いて", "返信を作って", "返信案を作って", "返信案を書いて",
        ])
        let replyRequestsEN = words([
            "write a reply", "draft a reply", "write a response", "draft a response",
        ])
        // Mixed "edit + tell me" instructions want an explanation.
        let editJA = fold([
            "校正", "添削", "直して", "なおして", "手直し", "修正して", "書き換", "書きかえ", "言い換", "言いかえ",
            "リライト", "清書",
        ])
        let editEN = words([
            "proofread", "fix", "correct", "edit", "rewrite", "reword", "rephrase", "polish",
        ])
        let askJA = fold([
            "教えて", "おしえて", "説明して", "解説して", "指摘して", "知らせて", "理由も", "どこが", "なぜ", "どうして",
        ])
        let askEN = words([
            "tell me", "explain", "let me know", "point out", "why", "what was wrong", "what's wrong",
            "what you changed",
        ])
        let textOperationEN = words([
            "proofread", "translate", "summarize", "summarise", "summary", "rewrite", "reword", "rephrase", "shorten",
            "fix", "edit", "extract", "explain", "analyze", "analyse", "reply", "format", "polish", "simplify",
            "bullet", "tidy", "make this", "make it", "turn this", "turn it", "convert",
        ])

        private static func fold(_ phrases: [String]) -> [String] {
            phrases.map { TextFolding.compact($0) }
        }

        private static func words(_ phrases: [String]) -> [String] {
            phrases.map { " " + TextFolding.asciiWords($0).joined(separator: " ") + " " }
        }
    }
}
