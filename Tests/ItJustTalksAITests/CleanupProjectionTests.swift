import Foundation
import Testing
@testable import ItJustTalksAI

private func runProduct(_ input: CleanupInput, replies: [String]) async -> CleanupResult? {
    let fake = FakeGenerator(script: replies.map { .init(.text($0, usage: TokenUsage(inputTokens: 100, outputTokens: 20))) })
    let coordinator = GenerationCoordinator(generator: fake, configuration: fastConfiguration)
    let outcome = await CleanupPipeline.product().run(input, operation: UUID(), coordinator: coordinator, deadline: roomyDeadline)
    guard case .delivered(let result) = outcome else { return nil }
    return result
}

@Suite("Cleanup with edit projection")
struct CleanupProjectionTests {
    @Test func droppedWordsAndParaphraseAreRestored() async {
        let input = CleanupInput(transcript: "えーと、資料を確認しておいてほしいです", promptLanguage: .ja, handsFree: false)
        let result = await runProduct(input, replies: ["資料を確認してください。"])
        #expect(result?.status == .complete)
        #expect(result?.text == "資料を確認しておいてほしいです。")
        #expect(result?.diagnostics.measures["projection.applied"] == 1)
    }

    @Test func unfinishedSentenceIsNotCompleted() async {
        let input = CleanupInput(transcript: "その件は来週話すので", promptLanguage: .ja, handsFree: false)
        let result = await runProduct(input, replies: ["その件は来週話します。"])
        #expect(result?.status == .complete)
        #expect(result?.text == "その件は来週話すので")
    }

    @Test func questionedProposalBecomesSafeSpokenText() async {
        // The model drops a negation; the checks question it, so the spoken words are inserted instead
        // of a review window, with only punctuation taken from the proposal.
        let input = CleanupInput(transcript: "明日は行けないと思います来週なら大丈夫です", promptLanguage: .ja, handsFree: false)
        let result = await runProduct(input, replies: ["明日は行けると思います。来週なら大丈夫です。"])
        #expect(result?.status == .complete)
        #expect(result?.text?.contains("行けない") == true)
    }

    @Test func handsFreeAndStylePreferencesKeepTheReviewPath() async {
        for (handsFree, custom) in [(true, nil), (false, "です・ます調にする")] as [(Bool, String?)] {
            let input = CleanupInput(transcript: "資料を確認しておいてほしい", customInstruction: custom, promptLanguage: .ja, handsFree: handsFree)
            let result = await runProduct(input, replies: ["資料を確認してください。"])
            #expect(result?.diagnostics.measures["projection.applied"] == nil)
            #expect(result?.diagnostics.measures["projection.safeText"] == nil)
        }
    }
}
