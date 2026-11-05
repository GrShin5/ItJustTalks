import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("TranslationIntent")
struct TranslationIntentTests {
    @Test(arguments: ["英語にして", "英語に訳して", "英語に翻訳して", "英語訳して", "英訳して",
                      "これ英語にして", "これを英語にしてください", "この文章を英語にしてくれる",
                      "この文を英語にしてもらえる", "全部英語にしてお願い", "選択した文を英語にしてください。",
                      "in English", "into English", "translate this into English", "translate it to English",
                      "translate to English", "translate into English", "Please translate this to English please."])
    func english(_ instruction: String) {
        #expect(TranslationIntent.parse(instruction) == .pureTranslation(OutputLanguage(code: "en", name: "英語")))
    }

    @Test(arguments: [("和訳して", "ja"), ("日本語にして", "ja"), ("中国語に訳して", "zh"),
                      ("韓国語に翻訳して", "ko"), ("translate to Japanese", "ja"),
                      ("translate it into Chinese", "zh"), ("in Korean", "ko")])
    func otherLanguages(_ pair: (String, String)) {
        guard case .pureTranslation(let language) = TranslationIntent.parse(pair.0) else {
            Issue.record("Expected pure translation"); return
        }
        #expect(language.code == pair.1)
    }

    @Test(arguments: ["英語にしないで", "英語にしなくていい", "英語にできる？", "英語にできますか",
                      "英語にして?", "「英語にして」と書いて", "『英語にして』", "校正して",
                      "don't translate to English", "do not translate to English", "Can you translate to English?",
                      "write 'in English'", "“translate to English”", "英語にして日本語にして"])
    func rejects(_ instruction: String) {
        #expect(TranslationIntent.parse(instruction) == nil)
    }

    @Test(arguments: ["英語にして要約して", "要約して英語にして", "translate to English and summarize",
                      "write the words in English"])
    func compound(_ instruction: String) {
        #expect(TranslationIntent.parse(instruction) == .mentionsTranslation(OutputLanguage(code: "en", name: "英語")))
    }
}
