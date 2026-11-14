import Foundation

/// Removes only isolated horizontal spaces at Japanese/ASCII boundaries.
enum JapaneseSpacing {
    static func normalize(_ text: String) -> String {
        let japanese = #"[\p{Hiragana}\p{Katakana}\p{Han}、。「」『』（）【】！？・ー]"#
        // Spaced capitals (「H T M L」) are joined only when the model proposes it (EditProjector):
        // 「A B C の3つ」 lists separate items.
        let result = text
        // Lookarounds allow both spaces in "日 A 日" to be removed in one pass. A katakana word and a
        // Latin word keep their space: either may become a Latin dictionary spelling ("クロードコード Tool").
        let kanaFree = #"[\p{Hiragana}\p{Han}、。「」『』（）【】！？・]"#
        return result.replacingOccurrences(
            of: "(?<=\(kanaFree))[ 　](?=[A-Za-z0-9])|(?<=[A-Za-z0-9])[ 　](?=\(kanaFree))"
                + "|(?<=\(japanese))[ 　](?=[0-9])|(?<=[0-9])[ 　](?=\(japanese))",
            with: "", options: .regularExpression)
    }
}
