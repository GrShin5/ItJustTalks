import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("Dropped numbers (P6)")
struct DroppedNumberTests {
    private func rewrite(_ source: String, _ output: String) -> ValidationOutcome {
        V.validator.validate(ValidationInput(
            task: .proofreadRewrite, source: source, output: output, isTruncated: false,
            protectedInstructions: [V.commandInstructions], userSuppliedTexts: ["丁寧にして"], handsFree: false
        ))
    }

    @Test func droppedSentenceWithNumberIsReviewedOrFailedHandsFree() {
        let source = "予算は761,000円です。会議は3時からです。資料を送ります。"
        let output = "会議は3時からです。資料を送ります。"
        #expect(V.cleanup(source, output).reasons.contains(.numbersDropped(count: 1)))
        guard case .needsReview = V.cleanup(source, output) else { Issue.record("expected review"); return }
        guard case .failed = V.cleanup(source, output, handsFree: true) else { Issue.record("expected failure"); return }
        #expect(rewrite(source, "会議は3時からです。資料をお送りします。").reasons.contains(.numbersDropped(count: 1)))
    }

    @Test func repetitionsAndRetractionsAreNotDrops() {
        #expect(V.cleanup("会議は3時、3時からです", "会議は3時からです。") == .complete)
        #expect(V.cleanup("資料を5部、いや3部印刷してください", "資料を3部印刷してください。") == .complete)
        #expect(V.cleanup("Book a table for six, no wait, eight people", "Book a table for eight people.") == .complete)
    }

    @Test func compoundTimeCorrectionKeptIsCaught() {
        let source = "架空の第1会議は1時41分から、いや、13時51分からです。"
        #expect(V.cleanup(source, "架空の第1会議は13時51分からです。") == .complete)
        guard case .failed = V.cleanup(source, "架空の第1会議は1時41分から13時51分からです。") else {
            Issue.record("kept retracted compound time must fail"); return
        }
        guard case .failed = V.cleanup(source, "架空の第1会議は1時41分から、13時51分からです。", handsFree: true) else {
            Issue.record("kept retracted compound time must fail (hands-free)"); return
        }
    }

    @Test func valueRangesAreNotJoinedIntoOneCompoundValue() {
        // Only 15 is taken back: "〜" separates the two values, so 10 is not part of a compound value.
        #expect(V.cleanup("休憩は10〜15分、いや20分です", "休憩は10〜20分です。") == .complete)
        #expect(V.cleanup("作業は2・3時間です、いや4時間です", "作業は2・4時間です。") == .complete)
    }

    @Test func summariesAreNotChecked() {
        let outcome = V.validator.validate(ValidationInput(
            task: .summarize, source: "予算は761,000円です。会議は3時からです。", output: "会議は3時からです。",
            isTruncated: false, protectedInstructions: [V.commandInstructions], userSuppliedTexts: ["要約して"], handsFree: false
        ))
        #expect(!outcome.reasons.contains(where: { if case .numbersDropped = $0 { true } else { false } }))
    }
}

@Suite("Balanced chunk plan (P6)")
struct BalancedChunkPlanTests {
    @Test func balancedChunksStayUnderThePreferredSize() async throws {
        let sentence = String(repeating: "x", count: 99) + "。"
        let body = String(repeating: sentence, count: 30) // 3,000 tokens at 1 char/token
        let fake = FakeGenerator(contextSize: 8192, charactersPerToken: 1)
        let executor = ChunkTestExecutor(generator: fake)
        guard case .chunks(let filled) = try await ChunkPlanner().plan(body, maxBodyTokens: 3_500, maximumChunks: 8, using: executor),
              case .chunks(let even) = try await ChunkPlanner().plan(body, maxBodyTokens: 3_500, balanced: true,
                                                                       maximumChunks: 8, using: executor) else {
            Issue.record("expected chunks"); return
        }
        #expect(filled.count == 1)
        let expected = (3_000 + ChunkPlanner.preferredChunkBodyTokens - 1) / ChunkPlanner.preferredChunkBodyTokens
        #expect(even.count == expected)
        #expect(even.map(\.source).joined() == body)
        #expect(even.allSatisfy { $0.source.count <= ChunkPlanner.preferredChunkBodyTokens + 100 })
    }

    @Test func balancingNeverExceedsTheChunkLimit() async throws {
        let sentence = String(repeating: "y", count: 99) + "。"
        let body = String(repeating: sentence, count: 60) // 6,000 tokens: 4 preferred chunks, limit 2
        let fake = FakeGenerator(contextSize: 8192, charactersPerToken: 1)
        guard case .chunks(let chunks) = try await ChunkPlanner().plan(body, maxBodyTokens: 3_500, balanced: true,
                                                                        maximumChunks: 2, using: ChunkTestExecutor(generator: fake)) else {
            Issue.record("expected chunks"); return
        }
        #expect(chunks.count == 2)
        #expect(chunks.map(\.source).joined() == body)
    }
}

@Suite("Short phrase full stop (2026-10-16)")
struct ShortPhraseFullStopTests {
    @Test(arguments: [("了解。", "了解。", "了解"), ("はい", "はい。", "はい"), ("Thanks.", "Thanks.", "Thanks"),
                      ("sounds good", "Sounds good.", "Sounds good"), ("東京駅", "東京駅．", "東京駅")])
    func shortPhraseLosesTheFullStop(_ c: (String, String, String)) {
        #expect(CleanupPipeline.strippingShortPhraseFullStop(c.1, transcript: c.0) == c.2)
    }

    @Test(arguments: [("本当ですか", "本当ですか？"), ("wait", "Wait..."),
                      ("明日の会議は十時からです", "明日の会議は10時からです。"),
                      ("please send the report today", "Please send the report today."),
                      ("了解。資料を送ります。", "了解。資料を送ります。"),
                      ("定型説明", "あの件はいやだとは言っていません。"), ("ありがとうございます", "ありがとうございます。")])
    func sentencesAndOtherMarksAreKept(_ c: (String, String)) {
        #expect(CleanupPipeline.strippingShortPhraseFullStop(c.1, transcript: c.0) == c.1)
    }
}
