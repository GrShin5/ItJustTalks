import Foundation
import Testing
@testable import ItJustTalks

@Suite("Recognizer contextual strings")
struct RecognizerContextualStringsTests {
    @Test func trimsDedupesAndKeepsFirstOccurrenceOrder() {
        let result = TranscriptionEngine.recognizerContextualStrings(
            from: ["Codex", " Claude Code ", "", "  ", "Codex", "Gemini", "Claude Code\n"]
        )
        #expect(result == ["Codex", "Claude Code", "Gemini"])
    }

    @Test func capsAfterDedupe() {
        let spellings = (0..<150).map { "Word\($0 % 120)" }
        let result = TranscriptionEngine.recognizerContextualStrings(from: spellings)
        #expect(result.count == TranscriptionEngine.maxRecognizerContextualStrings)
        #expect(result.first == "Word0")
        #expect(result.last == "Word99")
        #expect(TranscriptionEngine.recognizerContextualStrings(from: ["A", "B", "C"], limit: 2) == ["A", "B"])
        #expect(TranscriptionEngine.recognizerContextualStrings(from: []).isEmpty)
    }

    @Test func newestEntriesComeFirstSoTheCapKeepsThem() {
        let base = Date(timeIntervalSince1970: 1_000)
        let entries = (0..<120).map {
            PersonalDictionaryEntry(preferredForm: "Word\($0)", updatedAt: base.addingTimeInterval(Double($0)))
        } + [PersonalDictionaryEntry(preferredForm: "Tie", updatedAt: base.addingTimeInterval(119))]
        let spellings = TranscriptionEngine.newestFirstPreferredSpellings(entries)
        #expect(Array(spellings.prefix(3)) == ["Word119", "Tie", "Word118"])
        let capped = TranscriptionEngine.recognizerContextualStrings(from: spellings)
        #expect(capped.count == TranscriptionEngine.maxRecognizerContextualStrings)
        #expect(!capped.contains("Word0"))
        #expect(capped.contains("Word119"))
    }
}
