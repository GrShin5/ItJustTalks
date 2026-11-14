import Testing
@testable import ItJustTalksAI

@Suite("English v3.1 repairs")
struct EnglishV31Tests {
    private func project(_ source: String, _ output: String) -> String {
        EditProjector.projectEnglish(.init(source: source, output: output, language: "en")).text
    }

    @Test(arguments: [
        ("Order 6 boxes. No, wait. 8 boxes.", "Order 8 boxes.", "6 boxes", "8 boxes"),
        ("The call is on Monday. No, Friday.", "The call is on Friday.", "Monday", "Friday"),
        ("We fly out in March. Actually, we fly out in April.", "We fly out in April.", "March", "April"),
    ])
    func sentenceCorrections(_ e: (String, String, String, String)) {
        #expect(EnglishCuedRestart.collapse(e.0) == e.1)
        #expect(SelfCorrection.apply([(e.2, e.3)], to: e.0).corrected == e.1)
        #expect(SelfCorrection.apply([(e.3, e.2)], to: e.0).corrected == e.1)
    }

    @Test(arguments: [
        "Is it ready? No, Friday is better.", "No.", "No, thanks.",
        "Actually, I agree.", "Order 6 boxes. No, thanks.",
        "The call is not on Monday. No, Friday.", "Order 6. No, Friday.",
        "We fly out in March. Actually, we agree in April.",
        "We fly out in March. No, I don't think so.",
        "The call is on Monday. No, Friday is better.",
    ])
    func preservesSentences(_ text: String) {
        #expect(EnglishCuedRestart.collapse(text) == text)
        #expect(SelfCorrection.apply([("March", "April")], to: text).corrected == nil)
    }

    @Test(arguments: [
        ("we need we need a new plan", "we need a new plan"),
        ("meet at the at the station", "meet at the station"),
        ("we need a new we need a new plan", "we need a new plan"),
    ])
    func adjacentPhrases(_ e: (String, String)) {
        #expect(project(e.0, e.1) == e.1)
    }

    @Test(arguments: [
        ("had had a plan", "had a plan"), ("that that works", "that works"),
        ("we need 2 we need 2 boxes", "we need 2 boxes"),
        ("meet with Alice meet with Alice today", "meet with Alice today"),
        ("we need. we need a plan", "we need a plan"),
    ])
    func preservesRepetitions(_ e: (String, String)) {
        // The repeated words stay (a removed sentence period alone may still be taken).
        #expect(project(e.0, e.1) != e.1)
    }

    @Test(arguments: [
        ("Pack the tent, stove, lamp, and rope.", "Pack the tent stove lamp and rope."),
        ("Pack tent, stove, lamp.", "Pack tent stove lamp."),
        ("Pack tent, stove, or lamp.", "Pack tent stove or lamp."),
    ])
    func listCommas(_ e: (String, String)) {
        #expect(project(e.0, e.1) == e.0)
    }

    @Test func ordinaryComma() {
        #expect(project("short, but useful", "short but useful") == "short but useful")
    }

    @Test(arguments: ["We don't need 6 boxes. No, 8 boxes.", "The call isn't on Monday. No, Friday.",
                      "You asked if it's Monday. No, Friday.", "We never fly in March. Actually, we never fly in April."])
    func negationAndReportedSpeechStay(_ text: String) {
        #expect(EnglishCuedRestart.collapse(text) == text)
    }

    @Test func keepsWordCaseAfterRemovingTheFirstSentence() {
        #expect(EnglishCuedRestart.collapse("iOS is on 16. Actually, iOS is on 17.") == "iOS is on 17.")
        #expect(SelfCorrection.apply([("Samsung", "iPhone")], to: "Samsung, no wait, iPhone 15 ships today.").corrected
                == "iPhone 15 ships today.")
    }

    @Test func clausesWithCommasAreNotLists() {
        #expect(project("We compared, Nova, Delta, and Vega today.", "We compared Nova, Delta, and Vega today.")
                == "We compared Nova, Delta, and Vega today.")
        #expect(project("We compared, Nova, Delta, and Vega today.", "We compared Nova Delta and Vega today.")
                == "We compared Nova, Delta, and Vega today.")
        #expect(project("I think, we should, go now", "I think we should go now") == "I think we should go now")
        #expect(project("After lunch, if possible, call me", "After lunch if possible call me") == "After lunch if possible call me")
    }

    @Test(arguments: [
        ("what we have we have to keep", "what we have to keep"),
        ("again and again and again", "again and again"),
        ("one two one two go", "one two go"),
    ])
    func grammaticalDoublesStay(_ e: (String, String)) {
        #expect(project(e.0, e.1) != e.1)
    }

    @Test func acronymsAndQuotedSentenceStarts() {
        #expect(project("ask the it team", "ask the IT team") == "ask the IT team")
        #expect(project("that's ok", "that's OK") == "that's OK")
        #expect(project("use plan a", "use plan A") == "use plan A")
        #expect(project("he said, \"well, it works\"", "he said, \"Well, it works\"") == "he said, \"Well, it works\"")
    }

    @Test func capitalization() {
        #expect(project("Well, honestly, it works.", "Well, Honestly, it works.") == "Well, honestly, it works.")
        #expect(project("we meet on monday in april.", "We meet on Monday in April.") == "We meet on Monday in April.")
        #expect(project("then i'm ready.", "then I'm ready.") == "then I'm ready.")
        #expect(project("Well, Honestly, it works.", "Well, honestly, it works.") == "Well, honestly, it works.")
        // Names may still be capitalized mid-sentence.
        #expect(project("i met sam today", "I met Sam today") == "I met Sam today")
        let input = EditProjector.Input(source: "use lumora today", output: "use Lumora today", language: "en",
                                        dictionary: [(surface: "Lumora", readings: [])])
        #expect(EditProjector.projectEnglish(input).text == "use Lumora today")
    }
}
