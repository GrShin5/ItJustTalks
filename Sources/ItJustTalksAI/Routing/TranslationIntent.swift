import Foundation

/// Conservative instruction-only parsing. Never inspect target text or log an instruction.
public enum TranslationIntent: Sendable, Hashable {
    case pureTranslation(OutputLanguage)
    case mentionsTranslation(OutputLanguage)

    public var language: OutputLanguage {
        switch self {
        case .pureTranslation(let language), .mentionsTranslation(let language): return language
        }
    }

    public static func parse(_ instruction: String) -> TranslationIntent? {
        let text = instruction.precomposedStringWithCompatibilityMapping.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Quoted/literal commands, negation and questions cannot authorize replacement.
        guard text.range(of: #"[「」『』“”\"`‘’«»‹›《》]|'[^']+'|[?？]|しない|しなく|してほしくない|できますか|できる(?:か|$)|don't|don’t|do\s+not|can\s+you|could\s+you"#,
                         options: .regularExpression) == nil else { return nil }
        // The app's output settings support ja/en; zh/ko also occur in its command vocabulary.
        let languages: [(String, String, String, String?)] = [
            ("ja", "日本語", "japanese", "和訳して"),
            ("en", "英語", "english", "英訳して"),
            ("zh", "中国語", "chinese", nil),
            ("ko", "韓国語", "korean", nil),
        ]
        var found: TranslationIntent?
        for (code, name, english, shorthand) in languages {
            let japanese = name + #"(?:に翻訳して|に訳して|訳して|にして)"#
            let phrase = "(?:" + japanese + (shorthand.map { "|" + $0 } ?? "")
                + #"|\b(?:translate\s+(?:(?:this|it)\s+)?(?:into|to)|in|into)\s+"# + english + #"\b)"#
            guard text.range(of: phrase, options: .regularExpression) != nil else { continue }
            // Conflicting target languages are left to the model; no guessed expected language.
            guard found == nil else { return nil }
            let pure = #"^(?:please\s+)?(?:(?:これを|これ|この文章を|この文を|全部|選択した文を)\s*)?"#
                + phrase + #"\s*(?:(?:ください|くれる|もらえる|お願い)(?:します)?|please)?[\s。.!！、,]*$"#
            let language = OutputLanguage(code: code, name: name)
            found = text.range(of: pure, options: .regularExpression) != nil
                ? .pureTranslation(language) : .mentionsTranslation(language)
        }
        return found
    }
}
