import Testing
@testable import ItJustTalksAI

@Suite("English cued restarts")
struct EnglishCuedRestartTests {
    @Test(arguments: [
        ("prepare 14, no wait, 19 envelopes", "prepare 19 envelopes"),
        ("meet at 3, no wait, 4 pm", "meet at 4 pm"),
        ("meet at 10, actually, 9 am", "meet at 9 am"),
        ("120, scratch that, 80 people", "80 people"),
        ("5000, make that, 20000 dollars", "20000 dollars"),
        ("3.5, or rather, 4 kilos", "4 kilos"),
        ("send it to Mark, sorry, Martin", "send it to Martin"),
        ("about 20, I mean, 25 people", "about 25 people"),
        ("meet at 3:30, actually, 4:15", "meet at 4:15"),
        ("1,000, sorry, 2,000 units", "2,000 units"),
        ("at 3, NO WAIT, 4 pm", "at 4 pm"),
        ("14, sorry, 19 then 20, I mean, 25", "19 then 25"),
        ("3, sorry, 4, actually, 5", "5"),
    ])
    func removes(_ example: (String, String)) {
        let result = EnglishCuedRestart.collapse(example.0)
        #expect(result == example.1)
        #expect(EnglishCuedRestart.collapse(result) == result)
    }

    @Test(arguments: ["", "not A but B", "A, not B", "not 3, sorry, 4 but 5",
                      "3, sorry, 4, not 5", "at 3, sorry, Martin", "to Mark, sorry, 4",
                      "I am sorry, 10 minutes late", "actually this is fine", "3. Sorry, 4",
                      "3,\nno wait, 4", "3, sorry,\n4", "x3, sorry, 4", "3, sorry, 4th",
                      "-3, sorry, 4", "3, sorry, -4", "Monday, actually, Tuesday",
                      "Budget, actually, Scope", "mark, sorry, martin",
                      "3 no wait 4", "3, sorry, 3"])
    func keeps(_ text: String) {
        #expect(EnglishCuedRestart.collapse(text) == text)
    }

    @Test(arguments: [
        "Tell Sarah, sorry Sam can't make it.",
        "I talked to Maria, actually Marcus joined as well.",
        "We have 3, actually 4 would be better.",
    ])
    func needsACommaAfterTheCue(_ text: String) {
        #expect(EnglishCuedRestart.collapse(text) == text)
    }
}
