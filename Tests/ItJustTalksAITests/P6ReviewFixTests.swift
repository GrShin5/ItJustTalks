import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("P6 independent review fixes")
struct P6ReviewFixTests {
    private func chunk(_ index: Int, _ source: String, _ output: String) -> ChunkResult {
        ChunkResult(index: index, sourceRange: index..<(index + source.count), source: source,
                    output: output, outcome: .complete)
    }

    @Test(arguments: ["3.14", "1,500", "example.com", "v2.1", "３．１４", "１，５００"])
    func punctuationInsideTokensIsNotABoundary(_ token: String) {
        let chars = Array(token)
        for level in [1, 2] {
            #expect(ChunkPlanner.ranges(chars, within: 0..<chars.count, level: level) == [0..<chars.count])
        }
    }

    @Test(arguments: ["End. Next", "End.\nNext", "End.」Next", "終わり.次", "終わり．次"])
    func sentenceEndStillSplits(_ text: String) {
        #expect(ChunkPlanner.ranges(Array(text), within: 0..<text.count, level: 1).count == 2)
    }

    @Test func commaBetweenWordsStillSplits() {
        let text = "alpha,beta"
        #expect(ChunkPlanner.ranges(Array(text), within: 0..<text.count, level: 2).count == 2)
    }

    @Test func hardSplitPrefersBoundaryOutsideDigitRun() async throws {
        let executor = ChunkTestExecutor(generator: FakeGenerator(charactersPerToken: 1))
        guard case .chunks(let chunks) = try await ChunkPlanner().plan("abc12345", maxBodyTokens: 5,
            maximumChunks: 3, using: executor) else { Issue.record("Expected plan"); return }
        #expect(chunks.map(\.source) == ["abc", "12345"])
    }

    @Test func balancedOverflowRetriesAtOriginalLimit() async throws {
        let sentence = String(repeating: "a", count: 1698) + ". "
        let source = String(repeating: sentence, count: 3) + String(repeating: "b", count: 898) + ". "
        let executor = ChunkTestExecutor(generator: FakeGenerator(charactersPerToken: 1))
        guard case .chunks(let chunks) = try await ChunkPlanner().plan(source, maxBodyTokens: 3500,
            balanced: true, maximumChunks: 2, using: executor) else { Issue.record("Expected fallback plan"); return }
        #expect(chunks.count == 2)
        #expect(chunks.map(\.source).joined() == source)
        #expect(chunks.allSatisfy { $0.source.count <= 3500 })
    }

    @Test func joinsLatinOutputsWithOneSpaceAndCJKDirectly() {
        for tail in ["Hello", "3", ".", ",", ";", ":", "!", "?", ")"] {
            #expect(ChunkPlanner.joined([chunk(0, "原文。", tail), chunk(1, "次。", "Next")]) == tail + " Next")
        }
        #expect(ChunkPlanner.joined([chunk(0, "原文。", "日本語。"), chunk(1, "次。", "続き。")]) == "日本語。続き。")
        #expect(ChunkPlanner.joined([chunk(0, "原文。\n", "Hello"), chunk(1, "次。", "Next")]) == "Hello\nNext")
        #expect(ChunkPlanner.joined([chunk(0, "原文。", "Hello "), chunk(1, "次。", "Next")]) == "Hello Next")
    }

    @Test func listEnumeratorsOnSourceAreNotDroppedNumbers() {
        let source = "1. 準備\n2. 実行"
        let validator = ResultValidator()
        let input = ValidationInput(task: .proofreadRewrite, source: source, output: source,
            isTruncated: false, protectedInstructions: ["Proofread"], handsFree: false)
        #expect(validator.validate(input) == .complete)
        #expect(validator.droppedNumberCount(input: input, output: source) == 0)
        var withFact = input
        withFact.source += "\n予算は761円です。"
        #expect(validator.droppedNumberCount(input: withFact, output: source) == 1)
    }

    @Test func extractionKeepsContinuationLinesAndDistinctFullItems() {
        let chunks = [chunk(0, "a", "- Alpha\n  detail A\n- Beta\ndetail B"),
                      chunk(1, "b", "1. Ａｌｐｈａ\ndetail A\n2. Alpha\ndetail C"),
                      chunk(2, "c", "Plain item\nOther item")]
        let merged = CommandPipeline.mergeExtractions(chunks)
        #expect(merged.map(\.text) == ["- Alpha\n  detail A", "- Beta\ndetail B", "2. Alpha\ndetail C", "Plain item", "Other item"])
        #expect(merged.map(\.chunkIndex) == [0, 0, 1, 2, 2])
    }

    @Test(arguments: ["該当なし", "なし", "None", "N/A", "- None", "・該当なし"])
    func extractionDropsEmptySentinelsOnlyWhenOtherItemsExist(_ sentinel: String) {
        #expect(CommandPipeline.mergeExtractions([chunk(0, "a", sentinel)]).map(\.text) == [sentinel])
        #expect(CommandPipeline.mergeExtractions([chunk(0, "a", sentinel), chunk(1, "b", "- Alpha")]).map(\.text) == ["- Alpha"])
    }

    @Test(arguments: ["never mind", "なしにして", "取りやめ"])
    func distantRetractionsKeepWholeTextForReview(_ cue: String) {
        let validator = ChunkValidator()
        #expect(validator.correctionCueChunkIndices(["先の文。", "通常の文章です。" + cue]) == [1])
        #expect(validator.correctionCueChunkIndices(["先の文。", "使いやすい。ではなくという語の説明です。"]).isEmpty)
    }

    // A digit run longer than a chunk cannot be preserved by any local number check alone.
    private let digits = "12345678901234567890123456789012"

    // A digit run longer than a chunk must be hard-split inside the run; the joined output keeps it intact
    // (Latin sources are joined without inserted spaces) and is complete. Join-level number checks themselves are
    // covered by `joinedNumberChecksHonorDictionaryAndCombinedRetractions`.
    @Test(arguments: [AITask.proofreadRewrite, .translate, .transform])
    func commandKeepsDigitRunSplitAcrossChunks(_ task: AITask) async {
        let parts = [String(digits.prefix(16)), String(digits.suffix(16))]
        let fake = FakeGenerator(script: parts.map { chunkTestText($0) },
            contextSize: chunkTestContext(task: task, capacity: 16), charactersPerToken: 1)
        let pipeline = CommandPipeline(configuration: .init(budgeter: chunkTestBudgeter()))
        let result = await pipeline.generate(task, CommandInput(spokenInstruction: "Edit", target: digits, promptLanguage: .en),
            using: ChunkTestExecutor(generator: fake))
        #expect(fake.receivedRequests.count == 2)
        #expect(result.text == digits)
        #expect(result.status == .complete)
    }

    @Test(arguments: [false, true])
    func cleanupKeepsDigitRunSplitAcrossChunks(_ handsFree: Bool) async {
        let parts = [String(digits.prefix(16)), String(digits.suffix(16))]
        let fake = FakeGenerator(script: parts.map { chunkTestText($0) },
            contextSize: chunkTestContext(task: .cleanup, capacity: 16), charactersPerToken: 1)
        let pipeline = CleanupPipeline(configuration: .init(budgeter: chunkTestBudgeter()))
        let result = await pipeline.run(CleanupInput(transcript: digits, promptLanguage: .en, handsFree: handsFree),
            using: ChunkTestExecutor(generator: fake))
        #expect(fake.receivedRequests.count == 2)
        #expect(result.text == digits)
        #expect(result.status == .complete)
    }

    @Test func joinedNumberChecksHonorDictionaryAndCombinedRetractions() {
        let validator = ResultValidator()
        let input = ValidationInput(task: .cleanup,
            source: "予算は761円。台数は42台。資料を送ります。", output: "Device 17とTool 28の資料を送ります。",
            isTruncated: false, protectedInstructions: ["Clean up"],
            allowedNewTerms: ["Device 17", "Tool 28"], handsFree: false,
            selfCorrections: [SelfCorrectionSpan(retracted: "予算は761円", replacement: nil),
                              SelfCorrectionSpan(retracted: "台数は42台", replacement: nil)])
        #expect(validator.joinedNumberReasons(input).isEmpty)
        var command = input
        command.task = .translate
        command.source = "資料を送ります。"
        command.selfCorrections = nil
        #expect(validator.joinedNumberReasons(command).isEmpty)
        command.task = .transform
        command.source = "予算は761円です。"
        command.output = "資料を送ります。"
        #expect(validator.joinedNumberReasons(command).isEmpty)
    }

    @Test(arguments: [false, true])
    func failedCleanupValidationStopsWithGeneratedTextSoFar(_ handsFree: Bool) async {
        let parts = [String(repeating: "a", count: 32), String(repeating: "b", count: 32), String(repeating: "c", count: 32)]
        let fake = FakeGenerator(script: [chunkTestText(parts[0]), chunkTestText(parts[1], truncated: true), chunkTestText(parts[2])],
            contextSize: chunkTestContext(task: .cleanup, capacity: 32), charactersPerToken: 1)
        let result = await CleanupPipeline(configuration: .init(budgeter: chunkTestBudgeter())).run(
            CleanupInput(transcript: parts.joined(), promptLanguage: .en, handsFree: handsFree),
            using: ChunkTestExecutor(generator: fake))
        #expect(result.status == .failed(.validationFailed))
        #expect(result.text == parts.prefix(2).joined())
        #expect(fake.receivedRequests.count == 2)
        #expect(result.diagnostics.validation?.outcome.reasons.contains(.truncated) == true)
    }

    @Test(arguments: [AITask.summarize, .explainAnalyze, .extract, .proofreadRewrite])
    func failedCommandChunkStopsLaterChunksAndMerge(_ task: AITask) async {
        let parts = [String(repeating: "a", count: 32), String(repeating: "b", count: 32), String(repeating: "c", count: 32)]
        let fake = FakeGenerator(script: [chunkTestText("alpha"), chunkTestText(""), chunkTestText("later")],
            contextSize: chunkTestContext(task: task, capacity: 32), charactersPerToken: 1)
        let result = await CommandPipeline(configuration: .init(budgeter: chunkTestBudgeter())).generate(task,
            CommandInput(spokenInstruction: "Edit", target: parts.joined(), promptLanguage: .en),
            using: ChunkTestExecutor(generator: fake))
        #expect(result.status == .failed(.validationFailed))
        #expect(result.text == "alpha")
        #expect(fake.receivedRequests.count == 2)
        #expect(result.diagnostics.validation?.outcome.reasons.contains(.chunkFailed(index: 1)) == true)
    }

    @Test func extractionKeepsNestedAttributesAndWithinChunkRepeats() {
        let nested = CommandPipeline.mergeExtractions([chunk(0, "a", "- 会議A\n  - 担当: 田中"), chunk(1, "b", "- 会議B\n  - 担当: 田中")])
        #expect(nested.map(\.text) == ["- 会議A\n  - 担当: 田中", "- 会議B\n  - 担当: 田中"])
        let blocks = CommandPipeline.mergeExtractions([chunk(0, "a", "会議A\n担当: 田中\n\n会議B\n担当: 田中")])
        #expect(blocks.map(\.text) == ["会議A\n担当: 田中", "会議B\n担当: 田中"])
        let lines = CommandPipeline.mergeExtractions([chunk(0, "a", "担当: 田中\n担当: 田中"), chunk(1, "b", "担当: 田中\n期限: 金曜")])
        #expect(lines.map(\.text) == ["担当: 田中", "担当: 田中", "期限: 金曜"])
    }

    @Test func joinedAddsSpaceOnlyAfterNonLatinSource() {
        #expect(ChunkPlanner.joined([chunk(0, "今日です。", "It is today."), chunk(1, "明日です。", "Tomorrow.")]) == "It is today. Tomorrow.")
        #expect(ChunkPlanner.joined([chunk(0, "alpha,", "alpha,"), chunk(1, "beta", "beta")]) == "alpha,beta")
        #expect(ChunkPlanner.joined([chunk(0, "今日です。", "今日です。"), chunk(1, "明日です。", "明日です。")]) == "今日です。明日です。")
    }

    // End to end: a dictionary term with digits in a chunked hands-free cleanup stays complete (the whole-text
    // number check uses the substituted sources, like the per-chunk checks).
    @Test func chunkedHandsFreeCleanupWithDigitDictionaryTermCompletes() async {
        let sentences = ["Bring the Zentrix 17 kit today. ", "The review starts at 3 tomorrow. ", "Please send the notes."]
        let transcript = ["Bring the zentrix seventeen kit today. ", sentences[1], sentences[2]].joined()
        let entry = DictionaryEntry(preferred: "Zentrix 17", readings: ["zentrix seventeen"])
        let fake = FakeGenerator(script: sentences.map { chunkTestText($0.trimmingCharacters(in: .whitespaces)) },
            // Resolved literal spellings are not repeated as prompt hints (cleanup@6).
            contextSize: chunkTestContext(task: .cleanup, capacity: 40, hints: []),
            charactersPerToken: 1)
        let pipeline = CleanupPipeline(configuration: .init(budgeter: chunkTestBudgeter()))
        let result = await pipeline.run(CleanupInput(transcript: transcript, dictionaryEntries: [entry], promptLanguage: .en, handsFree: true),
            using: ChunkTestExecutor(generator: fake))
        #expect((result.diagnostics.measures["chunk.count"] ?? 0) > 1)
        #expect(result.status == .complete)
        #expect(result.text == sentences.joined())
    }
}
