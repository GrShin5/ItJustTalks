import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("Chunked commands")
struct ChunkedCommandTests {
    private let bodies = [String(repeating: "a", count: 32), String(repeating: "b", count: 32), String(repeating: "c", count: 32)]
    private var pipeline: CommandPipeline { CommandPipeline(configuration: .init(budgeter: chunkTestBudgeter())) }
    private func input(_ body: String) -> CommandInput {
        CommandInput(spokenInstruction: "Edit", target: body, promptLanguage: .en)
    }

    @Test(arguments: [AITask.proofreadRewrite, .transform, .translate])
    func transformationsJoinInOrder(_ task: AITask) async {
        // Identical translation chunks must exhaust one retry and remain review-only.
        let outputs = task == .translate ? bodies.flatMap { [$0, $0] } : bodies
        let fake = FakeGenerator(script: outputs.map { chunkTestText($0) },
            contextSize: chunkTestContext(task: task, capacity: 32), charactersPerToken: 1)
        let recorder = ChunkProgressRecorder()
        let result = await pipeline.generate(task, input(bodies.joined()), using: ChunkTestExecutor(generator: fake),
            progress: { recorder.append($0) })
        #expect(result.text == bodies.joined())
        #expect(result.chunking == ChunkingSummary(chunkCount: 3, mergeStages: 0))
        #expect(fake.receivedRequests.count == (task == .translate ? 6 : 3))
        if task == .translate {
            guard case .needsReview = result.status else { Issue.record("Unchanged translation must require review"); return }
        }
        #expect(recorder.recorded == (0...3).map { ChunkProgress(completed: $0, total: 3) })
    }

    @Test(arguments: [AIFailure.guardrailViolation, .cancelled, .timeout])
    func failureInSecondChunkHasNoPartialOutput(_ failure: AIFailure) async {
        let fake = FakeGenerator(script: [chunkTestText(bodies[0]), .init(.failure(failure)), chunkTestText(bodies[2])],
            contextSize: chunkTestContext(task: .proofreadRewrite, capacity: 32), charactersPerToken: 1)
        let result = await pipeline.generate(.proofreadRewrite, input(bodies.joined()), using: ChunkTestExecutor(generator: fake))
        #expect(result.status == .failed(AIFailureReason(failure)))
        #expect(result.text == nil)
        #expect(fake.receivedRequests.count == 2)
    }

    @Test func reviewPropagatesAndValidationFailureKeepsAIText() async {
        for empty in [false, true] {
            let outputs = [bodies[0], empty ? "" : "changed", bodies[2]]
            let fake = FakeGenerator(script: outputs.enumerated().map { chunkTestText($0.element, truncated: !empty && $0.offset == 1) },
                contextSize: chunkTestContext(task: .proofreadRewrite, capacity: 32), charactersPerToken: 1)
            let result = await pipeline.generate(.proofreadRewrite, input(bodies.joined()), using: ChunkTestExecutor(generator: fake))
            // Review (truncated) continues to the end; a failed chunk 2 (empty) stops the run there. Neither is applied.
            #expect(result.text == (empty ? outputs.prefix(2).joined() : outputs.joined()))
            #expect(fake.receivedRequests.count == (empty ? 2 : 3))
            if empty { #expect(result.status == .failed(.validationFailed)) }
            else {
                guard case .needsReview = result.status else { Issue.record("Expected review"); continue }
            }
        }
    }

    @Test(arguments: [AITask.summarize, .explainAnalyze])
    func mergeIsOneAdditionalCallAndProgressIncludesIt(_ task: AITask) async {
        let fake = FakeGenerator(script: [chunkTestText("alpha"), chunkTestText("beta"), chunkTestText("gamma"), chunkTestText("combined")],
            contextSize: chunkTestContext(task: task, capacity: 32), charactersPerToken: 1)
        let recorder = ChunkProgressRecorder()
        let result = await pipeline.generate(task, input(bodies.joined()), using: ChunkTestExecutor(generator: fake),
            progress: { recorder.append($0) })
        #expect(result.text == "combined")
        #expect(result.chunking == ChunkingSummary(chunkCount: 3, mergeStages: 1))
        #expect(fake.receivedRequests.count == 4)
        #expect(fake.receivedRequests.last?.prompt == PromptAssembler.taskPrompt(spokenInstruction: "Edit",
            target: "alpha\nbeta\ngamma", language: .en))
        #expect(recorder.recorded == (0...4).map { ChunkProgress(completed: $0, total: 4) })
    }

    @Test func summaryChunkReviewSurvivesSuccessfulMerge() async {
        let fake = FakeGenerator(script: [chunkTestText("alpha", truncated: true), chunkTestText("beta"),
            chunkTestText("gamma"), chunkTestText("combined")],
            contextSize: chunkTestContext(task: .summarize, capacity: 32), charactersPerToken: 1)
        let result = await pipeline.generate(.summarize, input(bodies.joined()), using: ChunkTestExecutor(generator: fake))
        guard case .needsReview = result.status else { Issue.record("Expected review"); return }
        #expect(result.text == "combined")
        #expect(fake.receivedRequests.count == 4)
    }

    @Test func summaryMergeCannotRecurseOrReturnPartialText() async {
        let fake = FakeGenerator(script: bodies.map { chunkTestText($0) },
            contextSize: chunkTestContext(task: .summarize, capacity: 32), charactersPerToken: 1)
        let result = await pipeline.generate(.summarize, input(bodies.joined()), using: ChunkTestExecutor(generator: fake))
        #expect(result.status == .failed(.contextSizeExceeded))
        #expect(result.text == nil)
        #expect(fake.receivedRequests.count == 3)
    }

    @Test func mergeFailureDoesNotExposeChunkSummaries() async {
        let fake = FakeGenerator(script: [chunkTestText("a"), chunkTestText("b"), chunkTestText("c"), .init(.failure(.timeout))],
            contextSize: chunkTestContext(task: .summarize, capacity: 32), charactersPerToken: 1)
        let result = await pipeline.generate(.summarize, input(bodies.joined()), using: ChunkTestExecutor(generator: fake))
        #expect(result.status == .failed(.timeout))
        #expect(result.text == nil)
        #expect(fake.receivedRequests.count == 4)
    }

    @Test func extractionDedupePreservesFirstLineAndOrder() {
        let outputs = ["- Alpha\n・Ｂｅｔａ", "1. Alpha\n* Gamma", "• Beta\n2) Delta"]
        let chunks = outputs.enumerated().map {
            ChunkResult(index: $0.offset, sourceRange: $0.offset..<($0.offset + 1), source: "s", output: $0.element, outcome: .complete)
        }
        let merged = CommandPipeline.mergeExtractions(chunks)
        #expect(merged.map(\.text).joined(separator: "\n") == "- Alpha\n・Ｂｅｔａ\n* Gamma\n2) Delta")
        #expect(merged.map(\.chunkIndex) == [0, 0, 1, 2])
    }

    @Test func syntheticClassifierAllowsProgressBeforeGenerationTimeout() async {
        let fake = FakeGenerator(script: [.init(.text(
            "{\"taskType\":\"proofread_rewrite\",\"isReplacementArtifact\":false}"))],
            fallback: .init(.failure(.timeout)), contextSize: 8192, charactersPerToken: 1)
        let recorder = ChunkProgressRecorder()
        let result = await pipeline.run(input(String(repeating: "a", count: 20_000)),
            using: ChunkTestExecutor(generator: fake), progress: { recorder.append($0) })
        #expect(recorder.recorded.first?.completed == 0)
        #expect((recorder.recorded.first?.total ?? 0) > 1)
        #expect(result.status == .failed(.timeout))
        #expect(fake.receivedRequests.count == 2)
    }

    @Test func chunkTranslationRetryUsesOnlyChunkAndRephrasesInstruction() async {
        let spoken = "Please translate the provided target text carefully and preserve every detail."
        let language = OutputLanguage(code: "en", name: "English")
        let template = PromptCatalog.template(.translate, language: .en)
        let empty = PromptAssembler.taskPrompt(spokenInstruction: spoken, target: "", outputLanguage: language, language: .en)
        let chunk = String(repeating: "あ", count: 64)
        let source = chunk + chunk + chunk
        // Distinct sentences avoid the independent cross-chunk duplicate check.
        let fake = FakeGenerator(script: [chunkTestText(chunk), chunkTestText("The blue box is here."),
            chunkTestText("The green box is here."), chunkTestText("The red box is here.")],
            contextSize: template.text.count + empty.count + 16 + 64, charactersPerToken: 1)
        let result = await pipeline.generate(.translate,
            CommandInput(spokenInstruction: spoken, target: source, promptLanguage: .en, outputLanguage: language),
            using: ChunkTestExecutor(generator: fake))
        #expect(result.status == .complete)
        #expect(result.chunking?.chunkCount == 3)
        #expect(fake.receivedRequests.count == 4)
        #expect(fake.receivedRequests.dropFirst().first?.prompt == PromptAssembler.taskPrompt(
            spokenInstruction: "Translate the Target text into English.", target: chunk,
            outputLanguage: language, language: .en))
        #expect(fake.receivedRequests.allSatisfy { !$0.prompt.contains(source) })
    }

    @Test func oversizedChunkRetryStopsBeforeSecondGeneration() async {
        let language = OutputLanguage(code: "en", name: "English")
        let template = PromptCatalog.template(.translate, language: .en)
        let empty = PromptAssembler.taskPrompt(spokenInstruction: "Edit", target: "", outputLanguage: language, language: .en)
        let chunk = String(repeating: "あ", count: 64)
        let fake = FakeGenerator(script: [chunkTestText(chunk)], fallback: chunkTestText("Translated sentence."),
            contextSize: template.text.count + empty.count + 16 + 64, charactersPerToken: 1)
        let result = await pipeline.generate(.translate,
            CommandInput(spokenInstruction: "Edit", target: chunk + chunk + chunk, promptLanguage: .en, outputLanguage: language),
            using: ChunkTestExecutor(generator: fake))
        #expect(result.status == .failed(.contextSizeExceeded))
        #expect(fake.receivedRequests.count == 1)
    }

    @Test func translationUsesWholeInputDictionarySelectionEverywhere() async {
        let entry = DictionaryEntry(preferred: "AlphaBrand", readings: ["aliasbrand"])
        let hint = DictionaryHint(preferred: "AlphaBrand", readings: ["aliasbrand"])
        let source = "aliasbrand " + String(repeating: "a", count: 85)
        let fake = FakeGenerator(fallback: chunkTestText("translated"),
            contextSize: chunkTestContext(task: .translate, capacity: 32, hints: [hint]), charactersPerToken: 1)
        var request = input(source)
        request.dictionaryEntries = [entry]
        let result = await pipeline.generate(.translate, request, using: ChunkTestExecutor(generator: fake))
        #expect((result.chunking?.chunkCount ?? 0) > 1)
        #expect(fake.receivedRequests.allSatisfy {
            $0.prompt.contains(PromptAssembler.dictionaryLine(hint, language: .en))
        })
    }

    @Test(arguments: [AITask.answerQuestion, .composeReply])
    func unsupportedTasksRemainSingleRequestOnly(_ task: AITask) async {
        let fake = FakeGenerator(contextSize: chunkTestContext(task: task, capacity: 32), charactersPerToken: 1)
        let recorder = ChunkProgressRecorder()
        let result = await pipeline.generate(task, input(bodies.joined()), using: ChunkTestExecutor(generator: fake),
            progress: { recorder.append($0) })
        #expect(result.status == .failed(.contextSizeExceeded))
        #expect(result.chunking == nil)
        #expect(fake.receivedRequests.isEmpty)
        #expect(recorder.recorded.isEmpty)
    }

    @Test(arguments: [31, 32, 33])
    func singleShotThresholdAndPrompts(_ count: Int) async {
        let source = String(repeating: "a", count: count)
        let fake = FakeGenerator(fallback: chunkTestText(source),
            contextSize: chunkTestContext(task: .transform, capacity: 32), charactersPerToken: 1)
        let result = await pipeline.generate(.transform, input(source), using: ChunkTestExecutor(generator: fake))
        if count <= 32 {
            #expect(result.chunking == nil)
            #expect(fake.receivedRequests.count == 1)
            #expect(fake.receivedRequests.first?.prompt == PromptAssembler.taskPrompt(spokenInstruction: "Edit", target: source, language: .en))
            #expect(fake.receivedRequests.first?.instructions == PromptCatalog.template(.transform, language: .en).text)
        } else { #expect(result.chunking?.chunkCount == 2) }
    }

    @Test func completePromptRebudgetSplitsOnlyAffectedChunk() async throws {
        let fake = FakeGenerator(fallback: chunkTestText("AI"),
            contextSize: chunkTestContext(task: .transform, capacity: 32), charactersPerToken: 1)
        let executor = ChunkTestExecutor(generator: fake, chunkPromptPenalty: 20)
        let result = await pipeline.generate(.transform, input(bodies.joined()), using: executor)
        #expect(result.chunking?.chunkCount == 5)
        #expect(fake.receivedRequests.count == 5)
        #expect(fake.receivedRequests.first?.prompt.contains(bodies[0]) == true)
        #expect(fake.receivedRequests.last?.prompt.contains(bodies[2]) == true)
        for request in fake.receivedRequests {
            let fixed = try await executor.tokenCount(for: .instructions(request.instructions))
            let prompt = try await executor.tokenCount(for: .prompt(request.prompt))
            #expect(fixed + prompt + (request.maximumResponseTokens ?? 0) <= fake.contextSize)
        }
    }

    @Test func mergeCallCountsTowardSixteenCallCap() async {
        let fake = FakeGenerator(contextSize: chunkTestContext(task: .summarize, capacity: 32), charactersPerToken: 1)
        let result = await pipeline.generate(.summarize, input(String(repeating: "a", count: 512)),
            using: ChunkTestExecutor(generator: fake))
        #expect(result.status == .failed(.contextSizeExceeded))
        #expect(result.text == nil)
        #expect(fake.receivedRequests.isEmpty)
    }

    @Test func taskCancellationDuringSecondChunkStopsThird() async throws {
        let fake = FakeGenerator(script: [chunkTestText(bodies[0]),
            .init(.text(bodies[1]), delay: .seconds(10)), chunkTestText(bodies[2])],
            contextSize: chunkTestContext(task: .transform, capacity: 32), charactersPerToken: 1)
        let pipeline = self.pipeline
        let request = input(bodies.joined())
        let work = Task { await pipeline.generate(.transform, request, using: ChunkTestExecutor(generator: fake)) }
        for _ in 0..<1000 {
            if fake.receivedRequests.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        work.cancel()
        let result = await work.value
        #expect(result.status == .failed(.cancelled))
        #expect(result.text == nil)
        #expect(fake.receivedRequests.count == 2)
    }

    @Test func runExposesChunkingSummaryAfterRouting() async {
        let classification = chunkTestText("{\"taskType\": \"transform\", \"isReplacementArtifact\": true}")
        let fake = FakeGenerator(script: [classification], fallback: chunkTestText("result"), contextSize: 4096)
        let result = await CommandPipeline().run(input(String(repeating: "あ", count: 8000)), using: ChunkTestExecutor(generator: fake))
        #expect((result.chunking?.chunkCount ?? 0) > 1)
        // "result" fails validation against chunk 1, so the run stops after classification + one chunk call.
        #expect(result.status == .failed(.validationFailed))
        #expect(result.diagnostics.calls.count == 2)
    }
}
