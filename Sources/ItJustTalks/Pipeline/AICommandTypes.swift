import Foundation

/// 「AIに指示」の結果の意味。出力経路は `AICommandOutputRoutingPolicy` が決める。
enum AICommandOutcomeKind: String, Codable {
    case content
    case answer
    case clarification
    case refusal
    case requiresWeb = "requires_web"
}

enum AICommandDestinationIntent: String, Codable {
    case automatic
    case insertAtCapturedTarget = "insert_at_captured_target"
    case showResult = "show_result"
}

/// 現在のブラウザページやURL本文はAIに指示へ渡していないため、モデルやWeb検索へ渡す前に
/// 明確に対象不足を返す。本文を音声で続けた依頼は、ここでは遮断しない。
enum AICommandInputPreflight {
    static let pageContentUnavailable = "このページの内容は取得できません。何を要約しますか？要約する文章を選択するか、内容を音声で続けてください。"
    static let urlContentUnavailable = "URLの内容は取得できません。何を要約しますか？要約する文章を選択するか、内容を音声で続けてください。"

    static func pageContentUnavailable(for language: AppLanguage) -> String {
        switch language {
        case .japanese:
            return pageContentUnavailable
        case .english:
            return "This page's content is not available. What would you like summarized? Select the text or continue by speaking its contents."
        }
    }

    /// 選択文章がURLだけで、要約・翻訳等の本文操作ではない依頼（「これ何？」等）。
    /// このアプリはページを取得しないため、AIへ渡さず、取得していないことを明示する（QA-22）。
    static let urlTargetUnavailable = "URLの先のページは取得できません（このアプリはWeb検索やページの取得を行いません）。必要な文章を選択するか、内容を音声で続けてください。"

    static func urlTargetUnavailable(for language: AppLanguage) -> String {
        switch language {
        case .japanese:
            return urlTargetUnavailable
        case .english:
            return "The page behind this URL is not available (this app does not search the Web or fetch pages). Select the text you need or continue by speaking its contents."
        }
    }

    static func urlContentUnavailable(for language: AppLanguage) -> String {
        switch language {
        case .japanese:
            return urlContentUnavailable
        case .english:
            return "This URL's content is not available. What would you like summarized? Select the text or continue by speaking its contents."
        }
    }

    private static let pageReferenceTerms = [
        "このページ", "このサイト", "この画面", "この記事", "このURL", "このurl", "このリンク", "このウェブページ",
    ]
    private static let contentActionTerms = [
        "要約", "まとめ", "翻訳", "訳", "抽出", "書き換", "校正", "説明", "解説",
    ]
    private static let englishPageReferenceTerms = [
        "thispage", "thissite", "thisscreen", "thisarticle", "thisurl", "thislink", "thiswebpage",
    ]
    private static let englishContentActionTerms = [
        "summarize", "summary", "translate", "extract", "rewrite", "edit", "proofread", "explain",
    ]
    /// 対象本文を続けた発話は残るよう、単独のページ参照＋操作だけを取り除く。
    private static let standaloneCommandFragments = [
        "について", "してください", "して下さい", "してほしい", "して欲しい", "お願い致します", "お願いします",
        "要約して", "まとめて", "翻訳して", "訳して", "抽出して", "書き換えて", "校正して", "説明して", "解説して",
        "要約", "まとめ", "翻訳", "抽出", "書き換え", "校正", "説明", "解説",
        "を", "の", "は", "に", "。", "、", "!", "！", "?", "？",
    ]
    private static let englishStandaloneCommandFragments = [
        "please", "couldyou", "canyou", "wouldyou", "summarize", "summary", "translate", "extract",
        "rewrite", "edit", "proofread", "explain", "it", "this", "the", ".", ",", "!", "?",
    ]

    static func localClarification(
        spokenInstruction: String,
        selectedText: String?,
        language: AppLanguage = .japanese
    ) -> String? {
        let normalizedInstruction = normalize(spokenInstruction)
        let asksContentAction = containsContentAction(normalizedInstruction, language: language)

        // URLだけの選択は、どの依頼でもページの本文を渡せない。AIに推測させない（QA-22）。
        if let selectedText,
           isOnlyURL(selectedText) {
            return asksContentAction ? urlContentUnavailable(for: language) : urlTargetUnavailable(for: language)
        }
        guard asksContentAction else { return nil }

        guard selectedText == nil else { return nil }
        if containsURL(normalizedInstruction) {
            return urlContentUnavailable(for: language)
        }
        let references = language == .english ? englishPageReferenceTerms : pageReferenceTerms
        guard references.contains(where: { normalizedInstruction.contains($0.lowercased()) }) else {
            return nil
        }
        return isStandalonePageContentRequest(normalizedInstruction, language: language)
            ? pageContentUnavailable(for: language)
            : nil
    }

    private static func isStandalonePageContentRequest(
        _ normalizedInstruction: String,
        language: AppLanguage
    ) -> Bool {
        var remainder = normalizedInstruction
        let references = language == .english ? englishPageReferenceTerms : pageReferenceTerms.map { $0.lowercased() }
        let fragments = language == .english ? englishStandaloneCommandFragments : standaloneCommandFragments
        for fragment in (references + fragments)
            .sorted(by: { $0.count > $1.count }) {
            remainder = remainder.replacingOccurrences(of: fragment.lowercased(), with: "")
        }
        return remainder.isEmpty
    }

    private static func containsContentAction(_ text: String, language: AppLanguage) -> Bool {
        let terms = language == .english ? englishContentActionTerms : contentActionTerms
        return terms.contains { text.contains($0) }
    }

    private static func isOnlyURL(_ text: String) -> Bool {
        let normalized = normalize(text)
        return normalized.range(
            of: #"^(?:https?://|www\.)[^\s]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsURL(_ text: String) -> Bool {
        text.range(of: #"(?:https?://|www\.)[^\s]+"#, options: .regularExpression) != nil
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
