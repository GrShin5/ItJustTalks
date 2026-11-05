import Testing
@testable import ItJustTalksAI

@Suite("ContextBudgeter")
struct ContextBudgeterTests {
    let budgeter = ContextBudgeter()

    // Provisional default: H = 32 + ceil(0.03 × C); cleanup O = ceil(1.1 × body) + 32 (min 64).
    @Test func overheadMatchesConfiguration() {
        #expect(budgeter.overhead(contextSize: 4096) == 155)
        #expect(budgeter.overhead(contextSize: 8192) == 278)
    }

    @Test func cleanupReservation() {
        let policy = BudgetConfiguration.provisionalDefault.profiles[.cleanup]!.reservation
        #expect(policy.reservation(forBodyTokens: 1000) == 1132)
        #expect(policy.reservation(forBodyTokens: 2000) == 2232)
        #expect(policy.reservation(forBodyTokens: 999) == 1131)
        #expect(policy.reservation(forBodyTokens: 0) == 64) // minimum
    }

    /// Tf + Td + Ts + O + H == C exactly for the given Tf.
    @Test(arguments: [
        (contextSize: 4096, body: 1000, equalTf: 1709, maxBodyWhenOver: 999),
        (contextSize: 8192, body: 2000, equalTf: 3582, maxBodyWhenOver: 1999),
    ])
    func boundaries(_ c: (contextSize: Int, body: Int, equalTf: Int, maxBodyWhenOver: Int)) {
        func input(tf: Int) -> BudgetInput {
            BudgetInput(task: .cleanup, contextSize: c.contextSize, fixedInstructionTokens: tf,
                        promptTokens: c.body + 100, bodyTokens: c.body)
        }
        let expectedO = BudgetConfiguration.provisionalDefault.profiles[.cleanup]!.reservation
            .reservation(forBodyTokens: c.body)
        // Just under and equal: fits, maximumResponseTokens = O.
        #expect(budgeter.decide(input(tf: c.equalTf - 1)) == .fits(maximumResponseTokens: expectedO))
        #expect(budgeter.decide(input(tf: c.equalTf)) == .fits(maximumResponseTokens: expectedO))
        // One over: chunk.
        #expect(budgeter.decide(input(tf: c.equalTf + 1)) == .needsChunking(maxBodyTokens: c.maxBodyWhenOver))
    }

    @Test func chunkSizeLeavesRoomForReservation() {
        let input = BudgetInput(task: .cleanup, contextSize: 4096, fixedInstructionTokens: 300,
                                promptTokens: 3100, bodyTokens: 3000)
        guard case .needsChunking(let maxBody) = budgeter.decide(input) else {
            Issue.record("expected chunking"); return
        }
        let policy = BudgetConfiguration.provisionalDefault.profiles[.cleanup]!.reservation
        let chunk = BudgetInput(task: .cleanup, contextSize: 4096, fixedInstructionTokens: 300,
                                promptTokens: maxBody + 100, bodyTokens: maxBody)
        #expect(budgeter.decide(chunk) == .fits(maximumResponseTokens: policy.reservation(forBodyTokens: maxBody)))
        let bigger = BudgetInput(task: .cleanup, contextSize: 4096, fixedInstructionTokens: 300,
                                 promptTokens: maxBody + 101, bodyTokens: maxBody + 1)
        if case .fits = budgeter.decide(bigger) { Issue.record("maxBody + 1 must not fit") }
    }

    @Test func impossibleWhenFixedPartsFillContext() {
        // Long custom instructions (non-body prompt) leave no room for a minimal chunk.
        let input = BudgetInput(task: .cleanup, contextSize: 4096, fixedInstructionTokens: 300,
                                promptTokens: 3700, bodyTokens: 200)
        #expect(budgeter.decide(input) == .impossible(.fixedOverheadTooLarge))
    }

    @Test func nonChunkableTaskThatDoesNotFit() {
        let input = BudgetInput(task: .answerQuestion, contextSize: 4096, fixedInstructionTokens: 200,
                                promptTokens: 3900, bodyTokens: 3800)
        #expect(budgeter.decide(input) == .impossible(.chunkingNotAllowed))
        let classifier = BudgetInput(task: .taskClassification, contextSize: 4096, fixedInstructionTokens: 300,
                                     promptTokens: 3800, bodyTokens: 0, schemaTokens: 100)
        #expect(budgeter.decide(classifier) == .impossible(.fixedOverheadTooLarge))
    }

    @Test func schemaTokensCount() {
        let base = BudgetInput(task: .taskClassification, contextSize: 4096, fixedInstructionTokens: 300,
                               promptTokens: 100, bodyTokens: 0, schemaTokens: 0)
        #expect(budgeter.decide(base) == .fits(maximumResponseTokens: 48))
        // Tf + Td + Ts + O + H = 300 + 100 + Ts + 48 + 155 ≤ 4096 → Ts ≤ 3493.
        var atLimit = base; atLimit.schemaTokens = 3493
        #expect(budgeter.decide(atLimit) == .fits(maximumResponseTokens: 48))
        var over = base; over.schemaTokens = 3494
        #expect(budgeter.decide(over) == .impossible(.fixedOverheadTooLarge))
    }

    @Test func reservationClampsToMaximum() {
        let input = BudgetInput(task: .summarize, contextSize: 8192, fixedInstructionTokens: 300,
                                promptTokens: 5100, bodyTokens: 5000)
        #expect(budgeter.decide(input) == .fits(maximumResponseTokens: 1024))
    }

    @Test func invalidInputs() {
        #expect(budgeter.decide(BudgetInput(task: .cleanup, contextSize: 0, fixedInstructionTokens: 1,
                                            promptTokens: 1, bodyTokens: 1)) == .impossible(.invalidInput))
        #expect(budgeter.decide(BudgetInput(task: .cleanup, contextSize: 4096, fixedInstructionTokens: 1,
                                            promptTokens: 10, bodyTokens: 11)) == .impossible(.invalidInput))
    }

    @Test func negativeTokenInputsAreInvalid() {
        let base = BudgetInput(task: .cleanup, contextSize: 4096, fixedInstructionTokens: 300, promptTokens: 200, bodyTokens: 100)
        var tf = base; tf.fixedInstructionTokens = -1
        var td = base; td.promptTokens = -1
        var ts = base; ts.schemaTokens = -5
        var body = base; body.bodyTokens = -1
        var c = base; c.contextSize = -4096
        for input in [tf, td, ts, body, c] {
            #expect(budgeter.decide(input) == .impossible(.invalidInput))
        }
    }

    @Test func hugeTokenInputsDoNotTrap() {
        let huge = BudgetInput(task: .cleanup, contextSize: Int.max, fixedInstructionTokens: Int.max,
                               promptTokens: Int.max, bodyTokens: Int.max, schemaTokens: Int.max)
        #expect(budgeter.decide(huge) == .impossible(.invalidInput))
        let bigBody = BudgetInput(task: .cleanup, contextSize: 8192, fixedInstructionTokens: 300,
                                  promptTokens: 1 << 39, bodyTokens: 1 << 39)
        if case .fits = budgeter.decide(bigBody) { Issue.record("an oversized body must not fit") }
    }

    /// m1: invalid configurations never report `.fits` (negative H could make `.fits` exceed C).
    @Test func invalidConfigurationsAreRejected() {
        let input = BudgetInput(task: .cleanup, contextSize: 4096, fixedInstructionTokens: 300, promptTokens: 1100, bodyTokens: 1000)
        var negativeMargin = BudgetConfiguration.provisionalDefault
        negativeMargin.marginRatio = -0.5
        var negativeOverhead = BudgetConfiguration.provisionalDefault
        negativeOverhead.hiddenOverheadTokens = -10_000
        var nanMargin = BudgetConfiguration.provisionalDefault
        nanMargin.marginRatio = .nan
        var infiniteCoefficient = BudgetConfiguration.provisionalDefault
        infiniteCoefficient.profiles[.cleanup] = .init(reservation: .init(coefficient: .infinity, constant: 32), allowsChunking: true)
        var nanCoefficient = BudgetConfiguration.provisionalDefault
        nanCoefficient.profiles[.cleanup] = .init(reservation: .init(coefficient: .nan, constant: 32), allowsChunking: true)
        for config in [negativeMargin, negativeOverhead, nanMargin, infiniteCoefficient, nanCoefficient] {
            #expect(ContextBudgeter(configuration: config).decide(input) == .impossible(.invalidInput))
        }
        // Reservation itself saturates instead of trapping.
        #expect(OutputReservationPolicy(coefficient: .infinity, constant: 0).reservation(forBodyTokens: 10) > 0)
    }

    @Test func zeroReservationIsRejected() {
        // `.fits(maximumResponseTokens: 0)` would disable truncation detection.
        var config = BudgetConfiguration.provisionalDefault
        config.profiles[.taskClassification] = .init(reservation: .init(coefficient: 0, constant: 0), allowsChunking: false)
        let input = BudgetInput(task: .taskClassification, contextSize: 4096, fixedInstructionTokens: 300,
                                promptTokens: 100, bodyTokens: 0)
        #expect(ContextBudgeter(configuration: config).decide(input) == .impossible(.invalidInput))
    }

    @Test func chunkingAt8192() {
        // H = 32 + ceil(0.03 × 8192) = 278. Non-body = 400 + 100 + 278 = 778 → available 7414.
        let input = BudgetInput(task: .cleanup, contextSize: 8192, fixedInstructionTokens: 400,
                                promptTokens: 6100, bodyTokens: 6000)
        guard case .needsChunking(let maxBody) = budgeter.decide(input) else {
            Issue.record("expected chunking"); return
        }
        let policy = BudgetConfiguration.provisionalDefault.profiles[.cleanup]!.reservation
        // b + ceil(1.1 b) + 32 ≤ 7414 → b = 3515.
        #expect(maxBody == 3515)
        let chunk = BudgetInput(task: .cleanup, contextSize: 8192, fixedInstructionTokens: 400,
                                promptTokens: maxBody + 100, bodyTokens: maxBody)
        #expect(budgeter.decide(chunk) == .fits(maximumResponseTokens: policy.reservation(forBodyTokens: maxBody)))
        let bigger = BudgetInput(task: .cleanup, contextSize: 8192, fixedInstructionTokens: 400,
                                 promptTokens: maxBody + 101, bodyTokens: maxBody + 1)
        if case .fits = budgeter.decide(bigger) { Issue.record("maxBody + 1 must not fit") }
    }

    @Test func coefficientsAreConfigurable() {
        var config = BudgetConfiguration.provisionalDefault
        config.profiles[.translate] = BudgetTaskProfile(
            reservation: OutputReservationPolicy(coefficient: 2.0, constant: 0), allowsChunking: true)
        config.hiddenOverheadTokens = 0
        config.marginRatio = 0
        let b = ContextBudgeter(configuration: config)
        // 100 + 1000 + 2000 = 3100 + 996 Tf = 4096.
        let input = BudgetInput(task: .translate, contextSize: 4096, fixedInstructionTokens: 996,
                                promptTokens: 1100, bodyTokens: 1000)
        #expect(b.decide(input) == .fits(maximumResponseTokens: 2000))
    }
}
