import Foundation
import Testing
@testable import ItJustTalksAI

@Suite("Chunked cleanup")
struct ChunkedCleanupTests {
    private let bodies = [String(repeating: "a", count: 32), String(repeating: "b", count: 32), String(repeating: "c", count: 32)]
    private var pipeline: CleanupPipeline { CleanupPipeline(configuration: .init(budgeter: chunkTestBudgeter())) }

    @Test func joinsAIOnlyAndReportsProgress() async {
        let fake = FakeGenerator(script: bodies.map { chunkTestText($0) },
            contextSize: chunkTestContext(task: .cleanup, capacity: 32), charactersPerToken: 1)
        let recorder = ChunkProgressRecorder()
        let result = await pipeline.run(CleanupInput(transcript: bodies.joined(), promptLanguage: .en, handsFree: false),
            using: ChunkTestExecutor(generator: fake), progress: { recorder.append($0) })
        // Latin source split without whitespace: joined exactly as written (no inserted space).
        #expect(result.text == bodies.joined())
        #expect(result.status == .complete)
        #expect(result.diagnostics.measures["chunk.count"] == 3)
        #expect(fake.receivedRequests.count == 3)
        #expect(recorder.recorded == (0...3).map { ChunkProgress(completed: $0, total: 3) })
    }

    @Test(arguments: [AIFailure.guardrailViolation, .cancelled, .timeout])
    func secondChunkFailureStopsImmediately(_ failure: AIFailure) async {
        let fake = FakeGenerator(script: [chunkTestText(bodies[0]), .init(.failure(failure)), chunkTestText(bodies[2])],
            contextSize: chunkTestContext(task: .cleanup, capacity: 32), charactersPerToken: 1)
        let result = await pipeline.run(CleanupInput(transcript: bodies.joined(), promptLanguage: .en, handsFree: true),
            using: ChunkTestExecutor(generator: fake))
        #expect(result.status == .failed(AIFailureReason(failure)))
        #expect(result.text == nil)
        #expect(fake.receivedRequests.count == 2)
    }

    @Test func reviewInHandsFreeRetainsOnlyJoinedAIText() async {
        let originals = ["The meeting will start tomorrow.", String(repeating: "あ", count: 32), "The report will arrive tomorrow."]
        let outputs = [originals[0], "The schedule remains unchanged.", originals[2]]
        let language = OutputLanguage(code: "en", name: "English")
        let extra = PromptAssembler.cleanupPrompt(transcript: "", outputLanguage: language, language: .en).count
            - PromptAssembler.cleanupPrompt(transcript: "", language: .en).count
        let fake = FakeGenerator(script: outputs.map { chunkTestText($0) },
            contextSize: chunkTestContext(task: .cleanup, capacity: 32) + extra, charactersPerToken: 1)
        let result = await pipeline.run(CleanupInput(transcript: originals.joined(), promptLanguage: .en,
            outputLanguage: language, handsFree: true), using: ChunkTestExecutor(generator: fake))
        #expect(result.text == outputs.joined(separator: " "))
        guard case .needsReview(let reasons) = result.status else { Issue.record("Expected review"); return }
        #expect(reasons.contains(.chunkNeedsReview(index: 1)))
        #expect(fake.receivedRequests.count == 3)
    }

    @Test func failedValidationKeepsGeneratedText() async {
        let outputs = [bodies[0], "", bodies[2]]
        let fake = FakeGenerator(script: outputs.map { chunkTestText($0) },
            contextSize: chunkTestContext(task: .cleanup, capacity: 32), charactersPerToken: 1)
        let result = await pipeline.run(CleanupInput(transcript: bodies.joined(), promptLanguage: .en, handsFree: false),
            using: ChunkTestExecutor(generator: fake))
        #expect(result.status == .failed(.validationFailed))
        #expect(result.text == bodies[0])
        #expect(fake.receivedRequests.count == 2)
    }

    @Test func sourceLineSeparatorsSurviveJoining() async {
        let originals = [String(repeating: "a", count: 30) + "\r\n", String(repeating: "b", count: 30) + "\n\n", "end"]
        let outputs = originals.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let fake = FakeGenerator(script: outputs.map { chunkTestText($0) },
            contextSize: chunkTestContext(task: .cleanup, capacity: 32), charactersPerToken: 1)
        let result = await pipeline.run(CleanupInput(transcript: originals.joined(), promptLanguage: .en, handsFree: false),
            using: ChunkTestExecutor(generator: fake))
        #expect(result.text == originals.joined())
    }

    @Test(arguments: [127, 128, 129])
    func singleRequestThreshold(_ count: Int) async {
        let source = String(repeating: "a", count: count)
        let fake = FakeGenerator(fallback: chunkTestText(source),
            contextSize: chunkTestContext(task: .cleanup, capacity: 128), charactersPerToken: 1)
        let recorder = ChunkProgressRecorder()
        let result = await pipeline.run(CleanupInput(transcript: source, promptLanguage: .en, handsFree: false),
            using: ChunkTestExecutor(generator: fake), progress: { recorder.append($0) })
        if count <= 128 {
            #expect(fake.receivedRequests.count == 1)
            #expect(fake.receivedRequests.first?.prompt == PromptAssembler.cleanupPrompt(transcript: source, language: .en))
            #expect(result.diagnostics.measures["chunk.count"] == nil)
            #expect(recorder.recorded.isEmpty)
        } else {
            #expect(result.diagnostics.measures["chunk.count"] == 2)
            // The scripted reply repeats the whole source, so chunk 1 fails validation and the run stops there.
            #expect(fake.receivedRequests.count == 1)
            #expect(result.status == .failed(.validationFailed))
        }
    }

    @Test func runtimeContextSizeChoosesChunkingAndRejectsInvalidSizes() async {
        let source = String(repeating: "あ", count: 6000)
        for context in [0, -1, 4096, 8192] {
            let fake = FakeGenerator(fallback: chunkTestText("あ"), contextSize: context)
            let result = await CleanupPipeline().run(CleanupInput(transcript: source, promptLanguage: .ja, handsFree: false),
                using: ChunkTestExecutor(generator: fake))
            if context <= 0 {
                #expect(result.status == .failed(.contextSizeExceeded))
                #expect(fake.receivedRequests.isEmpty)
            } else if context == 4096 {
                #expect((result.diagnostics.measures["chunk.count"] ?? 0) > 1)
            } else {
                #expect(fake.receivedRequests.count == 1)
                #expect(result.diagnostics.measures["chunk.count"] == nil)
            }
        }
    }

    @Test func previousSentenceIsReferenceOnlyAndDuplicatesNeedReview() async {
        let originals = [String(repeating: "a", count: 210) + ". Tail.\n",
                         String(repeating: "b", count: 210) + ". Next.\n",
                         String(repeating: "c", count: 210) + ". End."]
        let outputs = [originals[0], "ＴＡＩＬ！ " + originals[1], originals[2]]
        let fake = FakeGenerator(script: outputs.map { chunkTestText($0) },
            contextSize: chunkTestContext(task: .cleanup, capacity: 360), charactersPerToken: 1)
        let configured = CleanupPipeline(configuration: .init(budgeter: chunkTestBudgeter(), chunkReferenceContext: .previousSentence))
        let result = await configured.run(CleanupInput(transcript: originals.joined(), promptLanguage: .en, handsFree: true),
            using: ChunkTestExecutor(generator: fake))
        let heading = PromptSection.precedingText.title(.en)
        #expect(fake.receivedRequests.count == 3)
        #expect(fake.receivedRequests.first?.prompt.contains(heading) == false)
        #expect(fake.receivedRequests.dropFirst().allSatisfy { $0.prompt.contains(heading) })
        #expect(result.diagnostics.measures["chunk.referenceContext"] == 1)
        guard case .needsReview(let reasons) = result.status else { Issue.record("Expected review"); return }
        #expect(reasons.contains(.chunkNeedsReview(index: 1)))
        #expect(reasons.contains(.chunkBoundaryDuplicate(index: 1)))
    }

    @Test func referenceOverheadRebudgetsOnlyFollowingChunks() async throws {
        let source = ["a", "b", "c"].map { String(repeating: $0, count: 88) + ". Tail.\n" }.joined()
        let fake = FakeGenerator(fallback: chunkTestText("AI"),
            contextSize: chunkTestContext(task: .cleanup, capacity: 160), charactersPerToken: 1)
        let configured = CleanupPipeline(configuration: .init(budgeter: chunkTestBudgeter(), chunkReferenceContext: .previousSentence))
        let result = await configured.run(CleanupInput(transcript: source, promptLanguage: .en, handsFree: false),
            using: ChunkTestExecutor(generator: fake))
        #expect((result.diagnostics.measures["chunk.count"] ?? 0) > 3)
        #expect(result.text != nil)
        #expect(fake.receivedRequests.first?.prompt.contains(String(repeating: "a", count: 88)) == true)
        for request in fake.receivedRequests {
            let fixed = try await fake.tokenCount(for: .instructions(request.instructions))
            let prompt = try await fake.tokenCount(for: .prompt(request.prompt))
            #expect(fixed + prompt + (request.maximumResponseTokens ?? 0) <= fake.contextSize)
        }
    }

    @Test func taskCancellationDuringSecondChunkStopsThird() async throws {
        let fake = FakeGenerator(script: [chunkTestText(bodies[0]),
            .init(.text(bodies[1]), delay: .seconds(10)), chunkTestText(bodies[2])],
            contextSize: chunkTestContext(task: .cleanup, capacity: 32), charactersPerToken: 1)
        let configured = pipeline
        let input = CleanupInput(transcript: bodies.joined(), promptLanguage: .en, handsFree: false)
        let work = Task { await configured.run(input, using: ChunkTestExecutor(generator: fake)) }
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

    @Test func crossChunkCueNeedsReviewAndStageAFailureFallsBackLikeSingleShot() async {
        let originals = [String(repeating: "a", count: 30) + ".\n", "actually, " + String(repeating: "b", count: 20) + "."]
        let fake = FakeGenerator(script: [chunkTestText(originals[0]), chunkTestText("{\"corrections\": []}"), chunkTestText(originals[1])],
            contextSize: chunkTestContext(task: .cleanup, capacity: 32), charactersPerToken: 1)
        let result = await pipeline.run(CleanupInput(transcript: originals.joined(), promptLanguage: .en, handsFree: true),
            using: ChunkTestExecutor(generator: fake, schemaTokens: 1))
        guard case .needsReview(let reasons) = result.status else { Issue.record("Expected review"); return }
        #expect(reasons.contains(.crossChunkCorrection(index: 1)))
        // A stage-A refusal falls back to the single-stage cleanup of that chunk (as in single-shot); the
        // cross-chunk cue still keeps the whole result out of automatic insertion.
        let fallback = FakeGenerator(script: [chunkTestText(originals[0]), .init(.failure(.guardrailViolation)), chunkTestText(originals[1])],
            contextSize: chunkTestContext(task: .cleanup, capacity: 32), charactersPerToken: 1)
        let reviewed = await pipeline.run(CleanupInput(transcript: originals.joined(), promptLanguage: .en, handsFree: false),
            using: ChunkTestExecutor(generator: fallback, schemaTokens: 1))
        guard case .needsReview = reviewed.status else { Issue.record("Expected review"); return }
        #expect(reviewed.diagnostics.measures["stageA.failed"] == 1)
        #expect(fallback.receivedRequests.count == 3)
        // A stage-A timeout ends the whole operation without partial text.
        let timedOut = FakeGenerator(script: [chunkTestText(originals[0]), .init(.failure(.timeout))],
            contextSize: chunkTestContext(task: .cleanup, capacity: 32), charactersPerToken: 1)
        let stopped = await pipeline.run(CleanupInput(transcript: originals.joined(), promptLanguage: .en, handsFree: false),
            using: ChunkTestExecutor(generator: timedOut, schemaTokens: 1))
        #expect(stopped.status == .failed(.timeout))
        #expect(stopped.text == nil)
        #expect(timedOut.receivedRequests.count == 2)
    }
}
