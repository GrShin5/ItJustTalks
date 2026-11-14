import Testing
@testable import ItJustTalksAI

@Suite("English capitalization")
struct EnglishCapitalizationTests {
    @Test(arguments: [
        ("the paint is wet. we should wait.", "The paint is wet. We should wait."),
        ("i think i'll go, and i'm sure", "I think I'll go, and I'm sure"),
        ("can you come? yes, at noon", "Can you come? Yes, at noon"),
        ("got it", "Got it"),
        ("line one\nline two", "Line one\nLine two"),
        ("Already Fine.", "Already Fine."),
    ])
    func capitalizes(_ input: String, _ expected: String) {
        #expect(EnglishCapitalization.apply(input) == expected)
    }

    @Test(arguments: [
        "my iPhone is here. iPhone users agree",
        "see example.com for details",
        "write to a@example.com today",
        "meet at 3 p.m. tomorrow",
        "use e.g. the blue one",
        "the value is 3.5 now",
        "the U.S. market is open",
    ])
    func leavesIdentifiersAndAbbreviations(_ input: String) {
        let out = EnglishCapitalization.apply(input)
        #expect(out.dropFirst() == input.dropFirst())
    }

    @Test func idempotent() {
        let once = EnglishCapitalization.apply("so i said it. then i left")
        #expect(EnglishCapitalization.apply(once) == once)
    }
}
