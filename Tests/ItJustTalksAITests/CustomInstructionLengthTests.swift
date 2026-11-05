import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("Custom instruction length and budget attribution")
struct CustomInstructionLengthTests {
    @Test func levelsUseContextRatiosWithoutRejectingText() {
        #expect(CustomInstructionLength(tokens: 99, contextSize: 1000).level == .appropriate)
        #expect(CustomInstructionLength(tokens: 100, contextSize: 1000).level == .long)
        #expect(CustomInstructionLength(tokens: 249, contextSize: 1000).level == .long)
        #expect(CustomInstructionLength(tokens: 250, contextSize: 1000).level == .unprocessable)
        #expect(CustomInstructionLength(tokens: 20_000, contextSize: 1000).tokens == 20_000)
    }

    @Test func measuredTokensAndUnavailableFallback() async {
        let text = "合成のカスタム指示です。"
        let available = FakeGenerator(charactersPerToken: 1)
        let measured = await CustomInstructionLength.measure(text, using: available)
        #expect(measured.tokens == text.count)
        #expect(!measured.estimated)
        let unavailable = FakeGenerator(availability: .unavailable(.modelNotReady))
        let fallback = await CustomInstructionLength.measure(text, using: unavailable)
        #expect(fallback.tokens == DictionarySelector.estimatedTokens(text))
        #expect(fallback.estimated)
        #expect(available.receivedRequests.isEmpty && unavailable.receivedRequests.isEmpty)
    }

    @Test func customInstructionMustCauseMinimumBodyFailure() {
        let budgeter = ContextBudgeter()
        for task in [AITask.cleanup, .proofreadRewrite, .answerQuestion, .composeReply] {
            let input = BudgetInput(task: task, contextSize: 4096, fixedInstructionTokens: 300,
                                    promptTokens: 8000, bodyTokens: 100)
            #expect(budgeter.customInstructionPreventsMinimumBody(input, promptTokensWithoutInstruction: 200))
            // The body itself may need chunking; attribute only loss of MINIMUM body capacity.
            #expect(!budgeter.customInstructionPreventsMinimumBody(input, promptTokensWithoutInstruction: 7900))
            #expect(!budgeter.customInstructionPreventsMinimumBody(input, promptTokensWithoutInstruction: 8000))
        }
        let fitting = BudgetInput(task: .cleanup, contextSize: 4096, fixedInstructionTokens: 300,
                                  promptTokens: 200, bodyTokens: 100)
        #expect(!budgeter.customInstructionPreventsMinimumBody(fitting, promptTokensWithoutInstruction: 100))
    }
}
