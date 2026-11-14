import Foundation

/// Repairs only strongly evidenced pauses; no morphological analysis or model calls.
enum PauseMarkRepair {
    static func repair(_ text: String) -> String {
        var characters = Array(text)
        for i in characters.indices where characters[i] == "。" {
            guard i + 1 < characters.count else { continue }
            // Spaces before a newline/end are also treated as an utterance boundary.
            var next = i + 1
            while next < characters.count, characters[next] == " " || characters[next] == "　" { next += 1 }
            guard next < characters.count, !characters[next].isNewline,
                  characters[next].isLetter || characters[next].isNumber else { continue }
            let prefix = String(characters[..<i])
            if hasRepairableEnding(prefix) { characters[i] = "、" }
        }
        return String(characters)
    }

    private static func hasRepairableEnding(_ prefix: String) -> Bool {
        // Bare kana suffixes are ambiguous (いろは, すべて, かえで, あたり).
        // Prefer missing repairs: particles require a kanji/katakana boundary or a
        // known demonstrative; connective forms use a small explicit vocabulary.
        let particle = #"(?:[\p{Han}\p{Katakana}][はがを]|(?:こちら|これ|それ|あれ|ここ|そこ|どれ|私たち)[はがを])$"#
        if prefix.range(of: particle, options: .regularExpression) != nil { return true }
        // A predicate followed by a conjunctive particle (「送りましたが。」「降ってきたので。」) continues.
        let connective = #"(?:ました|ます|です|でした|だった|た|だ|る|い|ない)(?:が|けど|けれど|けれども|ので|のに)$"#
        if prefix.range(of: connective, options: .regularExpression) != nil { return true }
        if prefix.range(of: #"\p{Han}し(?:て|たり)$"#, options: .regularExpression) != nil { return true }
        // Listing forms after a small tsu or a voiced stem (あったり, 読んだり, 泳いだり); bare あたり is a noun.
        if prefix.range(of: #"(?:(?:\p{Han}|あ)ったり|\p{Han}[んい]だり)$"#, options: .regularExpression) != nil { return true }
        let endings = ["食べて", "読んで", "飲んで", "行って", "見て", "書いて", "歩いて",
                       "待って", "使って", "送って", "調べて", "遊んで", "働いて", "閉じて",
                       "食べたり", "読んだり", "行ったり", "見たり"]
        if endings.contains(where: { prefix.hasSuffix($0) }) { return true }
        // Conjunctions must be complete tokens, not a suffix of an ordinary phrase.
        return prefix.range(of: #"(?:^|[\s、。！？])(ただし|なので|つまり)$"#,
                            options: .regularExpression) != nil
    }
}
