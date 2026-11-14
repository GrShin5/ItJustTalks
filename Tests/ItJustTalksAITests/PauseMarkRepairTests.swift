import Testing
@testable import ItJustTalksAI

@Suite("Pause mark repair")
struct PauseMarkRepairTests {
    @Test(arguments: [
        ("こちらは。参考に", "こちらは、参考に"), ("資料が。必要です", "資料が、必要です"),
        ("資料を。確認", "資料を、確認"), ("確認して。次に", "確認して、次に"),
        ("読んで。確認", "読んで、確認"), ("確認したり。調べたり", "確認したり、調べたり"),
        ("ただし。途中で", "ただし、途中で"), ("なので。次に", "なので、次に"),
        ("つまり。必要です", "つまり、必要です"),
        ("こちらは。確認して。次に", "こちらは、確認して、次に"),
    ])
    func repairs(_ example: (String, String)) {
        let result = PauseMarkRepair.repair(example.0)
        #expect(result == example.1)
        #expect(PauseMarkRepair.repair(result) == result)
    }

    @Test(arguments: ["", "こちらは。", "確認して。\n次に", "確認して。 \r\n次に", "確認して。  ",
                      "必要です。次は", "した。が", "いろは。次に", "すべて。次に", "かえで。次に",
                      "あたり。次に", "そして。次に", "必要なので。次に", "確認して。！？"])
    func preserves(_ text: String) {
        #expect(PauseMarkRepair.repair(text) == text)
    }

    @Test func listingFormsBecomeCommas() {
        #expect(PauseMarkRepair.repair("映画であったり。小説であったりします") == "映画であったり、小説であったりします")
        #expect(PauseMarkRepair.repair("本を読んだり。走ったりする") == "本を読んだり、走ったりする")
        #expect(PauseMarkRepair.repair("このあたり。次の駅です") == "このあたり。次の駅です")
    }

    @Test func listingFormsAreNarrow() {
        #expect(PauseMarkRepair.repair("川で遊んだり。山に登ったりする") == "川で遊んだり、山に登ったりする")
        #expect(PauseMarkRepair.repair("サイズがぴったり。次はこれ") == "サイズがぴったり。次はこれ")
        #expect(PauseMarkRepair.repair("庭のおんどり。次は") == "庭のおんどり。次は")
    }
}
