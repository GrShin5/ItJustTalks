import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("Cooperative dictionary cancellation")
struct DictionaryCancellationTests {
    @Test func cancelledLargeFallbackAndSubstitutionReturnPromptly() async {
        let entries = [DictionaryEntry(preferred: "ExampleApp", readings: ["エクザンプルアプリ"])]
        let text = String(repeating: "エクザンプルアプリを確認します。", count: 20_000)
        let input = CleanupInput(transcript: text, dictionaryEntries: entries, promptLanguage: .ja, handsFree: false)
        let empty = DictionarySelection(selected: [], matchedCount: 0, omittedCount: 0, totalTokens: 0)
        let substitution = DictionaryLiteralSubstitution(selection: empty, entries: entries)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            let start = ContinuousClock.now
            let selection = DictionarySelector().select(entries: entries, text: text)
            let result = substitution.apply(to: text)
            let fallback = CleanupPipeline().deterministicFallbackText(for: input)
            return (ContinuousClock.now - start, selection.selected.count, result.count,
                    result.text == text && fallback == text)
        }
        let (elapsed, selected, substitutions, keptOriginal) = await task.value
        #expect(elapsed < .seconds(2))
        #expect(selected == 0)
        #expect(substitutions == 0)
        #expect(keptOriginal)
    }

    @Test func cancellingRunningSubstitutionReturnsPromptly() async {
        let entries = [DictionaryEntry(preferred: "ExampleApp", readings: ["エクザンプルアプリ"])]
        let text = String(repeating: "エクザンプルアプリを確認します。", count: 20_000)
        let empty = DictionarySelection(selected: [], matchedCount: 0, omittedCount: 0, totalTokens: 0)
        let substitution = DictionaryLiteralSubstitution(selection: empty, entries: entries)
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let task = Task.detached {
            continuation.yield(())
            continuation.finish()
            let result = substitution.apply(to: text)
            return result.count == 0 && result.text == text
        }
        for await _ in started { break }
        let start = ContinuousClock.now
        task.cancel()
        let keptOriginal = await task.value
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(keptOriginal)
    }

    @Test func cancellationDuringSelectionDiscardsPartialHints() async {
        let entries = (0..<32).map { DictionaryEntry(preferred: "Preferred\($0)", readings: ["term\($0)"]) }
        let text = (0..<32).map { "term\($0)" }.joined(separator: " ")
        let task = Task.detached {
            let selector = DictionarySelector(tokenCounter: { _ in
                // Deterministically cancel after matching, during hint construction, without sleeps.
                withUnsafeCurrentTask { $0?.cancel() }
                return 1
            })
            let result = selector.select(entries: entries, text: text)
            return result.selected.count
        }
        #expect(await task.value == 0)
    }

    @Test func checkpointDetectsCancellationWithinOneBatch() async {
        let task = Task.detached {
            var checkpoint = DictionaryCancellationCheckpoint()
            for _ in 0..<100 {
                if checkpoint.isCancelled() { return false }
            }
            withUnsafeCurrentTask { $0?.cancel() }
            for _ in 0..<256 {
                if checkpoint.isCancelled() { return true }
            }
            return false
        }
        #expect(await task.value)
    }

    @Test func uncancelledFallbackKeepsExactBytes() {
        let input = CleanupInput(transcript: "エクザンプルアプリを確認し、エクザンプルアプリを確認してください。\n",
            dictionaryEntries: [DictionaryEntry(preferred: "ExampleApp", readings: ["エクザンプルアプリ"])],
            promptLanguage: .ja, handsFree: false)
        let expected = "ExampleAppを確認し、ExampleAppを確認してください。\n"
        let matches = CleanupPipeline().deterministicFallbackText(for: input).utf8.elementsEqual(expected.utf8)
        #expect(matches)
    }
}
