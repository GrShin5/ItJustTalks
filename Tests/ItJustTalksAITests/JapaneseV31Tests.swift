import Testing
@testable import ItJustTalksAI

@Suite("Japanese v3.1 cleanup")
struct JapaneseV31Tests {
    @Test(arguments: [
        ("資料を送りましたが。返事はまだありません。", "資料を送りましたが、返事はまだありません。"),
        ("雨が降ってきたので。今日は中止にします。", "雨が降ってきたので、今日は中止にします。"),
        ("行きたいんですけど。時間がありません。", "行きたいんですけど、時間がありません。"),
        ("行くんですが。時間がありません。", "行くんですが、時間がありません。"),
        ("難しいけれど。試します。", "難しいけれど、試します。"),
        ("終わったけれども。確認します。", "終わったけれども、確認します。"),
        ("時間がないのに。待ちます。", "時間がないのに、待ちます。"),
    ])
    func repairsPredicateConnectives(_ example: (String, String)) {
        #expect(PauseMarkRepair.repair(example.0) == example.1)
        #expect(PauseMarkRepair.repair(example.1) == example.1)
    }

    @Test(arguments: ["送りましたが。", "なので。", "みかんが。次です。",
                      "送りましたが。\n次です。", "送りましたが。 \r\n次です。"])
    func preservesConnectiveBoundaries(_ text: String) {
        #expect(PauseMarkRepair.repair(text) == text)
    }

    @Test(arguments: [
        ("持ち物、タオル、水筒、帽子、地図", "持ち物タオル水筒帽子地図"),
        ("タオル、水筒、帽子", "タオル水筒帽子"),
        ("りんご、みかん、バナナ", "りんごみかんバナナ"),
        ("うどん、ごはん、とけい", "うどんごはんとけい"),
        ("タオル、水筒、帽子。", "タオル、水筒帽子。"),
        ("タオル、水筒、帽子、確認します", "タオル水筒帽子、確認します"),
        ("持ち物、タオル、水筒、帽子、地図", "持ち物、タオル水筒、帽子地図"),
    ])
    func preservesEnumerationCommas(_ example: (String, String)) {
        let result = EditProjector.project(.init(source: example.0, output: example.1, language: "ja"))
        #expect(result.text == example.0)
        #expect(result.rejected[.punctuation, default: 0] > 0)
    }

    @Test(arguments: [
        ("タオル、水筒", "タオル水筒"),
        ("確認します、送ります、待ちます", "確認します送ります待ちます"),
        ("資料は、机に、置きます", "資料は机に置きます"),
        ("タオル、水筒、帽子、", "タオル、水筒、帽子"),
        ("あの、資料です。", "資料です。"),
        ("タオル。水筒、帽子", "タオル。水筒帽子"),
        ("タオル、水筒、帽子、確認します", "タオル、水筒、帽子確認します"),
        ("折り畳み式携帯タオル、水筒、帽子", "折り畳み式携帯タオル水筒帽子"),
        ("タオル\n水筒、帽子", "タオル\n水筒帽子"),
        ("stagingじゃなくて production", "stagingじゃなくて production"),
    ])
    func preservesOtherPunctuationBehavior(_ example: (String, String)) {
        let result = EditProjector.project(.init(source: example.0, output: example.1, language: "ja"))
        #expect(result.text == example.1)
    }
}
