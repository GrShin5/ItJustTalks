import Foundation
import FoundationModels
import Testing
@testable import ItJustTalksAI

/// Synthetic subjects are retained only in this test spy; production diagnostics remain content-free.
private final class OptimizerTokenMeasurements: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ subject: TokenCountSubject) {
        if case .prompt(let text) = subject { lock.withLock { counts[text, default: 0] += 1 } }
    }

    func count(_ text: String) -> Int { lock.withLock { counts[text, default: 0] } }
}

/// Exercise the pipeline's own cancellation/status contract without coordinator delivery filtering.
private struct OptimizerExecutor: GenerationExecuting {
    let generator: any TextGenerating
    var cancelAfterGeneration = false
    var failSchemaCount = false
    var tokenMeasurements: OptimizerTokenMeasurements?

    func tokenCount(for subject: TokenCountSubject) async throws(AIFailure) -> Int {
        tokenMeasurements?.record(subject)
        return try await generator.tokenCount(for: subject)
    }

    func schemaTokenCount<Output: Generable>(for type: Output.Type) async throws(AIFailure) -> Int {
        if failSchemaCount { throw .unsupportedCapability }
        return try await generator.schemaTokenCount(for: type)
    }

    func generate(_ request: GenerationRequest, inputTokens: Int) async throws(AIFailure) -> GenerationResult {
        try await generator.generate(request)
    }

    func generate<Output: Generable & Sendable>(
        _ request: GenerationRequest, generating type: Output.Type, inputTokens: Int
    ) async throws(AIFailure) -> StructuredGenerationResult<Output> {
        let result = try await generator.generate(request, generating: type)
        if cancelAfterGeneration { withUnsafeCurrentTask { $0?.cancel() } }
        return result
    }
}

private func optimizerReply(_ items: [String], delay: Duration = .zero) -> FakeGenerator.Step {
    let data = try! JSONEncoder().encode(["items": items])
    return .init(.text(String(decoding: data, as: UTF8.self), usage: TokenUsage(inputTokens: 100, outputTokens: 20)), delay: delay)
}

private let optimizerInput = InstructionOptimizationInput(
    draft: "丁寧で簡潔な文章にしてください。", kind: .cleanup, promptLanguage: .ja
)
private let optimizerSix = ["丁寧に書く。", "簡潔に書く。", "短文にする。", "敬語を使う。", "箇条書きにする。", "結論から書く。"]

private func optimize(
    _ fake: FakeGenerator, input: InstructionOptimizationInput = optimizerInput,
    pipeline: InstructionOptimizerPipeline = InstructionOptimizerPipeline()
) async -> InstructionOptimizationResult {
    await pipeline.run(input, using: OptimizerExecutor(generator: fake))
}

/// Enough room for one line and its full prompt/schema/reservation, but not two lines.
private func chunkSetup(
    line: String, replies: [FakeGenerator.Step]
) async throws -> (FakeGenerator, InstructionOptimizerPipeline) {
    let probe = FakeGenerator()
    let template = PromptCatalog.template(.instructionOptimizer, language: .ja)
    let prompt = PromptAssembler.instructionOptimizerPrompt(draft: line, kind: .cleanup, language: .ja)
    let fixed = try await probe.tokenCount(for: .instructions(template.text))
    let schema = try await probe.schemaTokenCount(for: OptimizedInstructionItems.self)
    let promptTokens = try await probe.tokenCount(for: .prompt(prompt))
    let configuration = BudgetConfiguration(
        profiles: [.instructionOptimization: .init(reservation: .init(coefficient: 0, constant: 320), allowsChunking: true)],
        hiddenOverheadTokens: 0, marginRatio: 0, minimumChunkBodyTokens: 1
    )
    let fake = FakeGenerator(script: replies, contextSize: fixed + schema + promptTokens + 325)
    return (fake, InstructionOptimizerPipeline(configuration: .init(budgeter: ContextBudgeter(configuration: configuration))))
}

@Suite("InstructionOptimizerPipeline")
struct InstructionOptimizerPipelineTests {
    @Test func warningThresholdFitsOptimizerWithDictionaryAndSchema() async throws {
        for language in PromptLanguage.allCases {
            for kind in CustomInstructionKind.allCases {
                let fake = FakeGenerator(script: [optimizerReply(["丁寧に書く。"])])
                let tokens = Int(Double(fake.contextSize) * CustomInstructionLength.unprocessableRatio)
                let draft = String(repeating: "あ", count: tokens * 2)
                #expect(await CustomInstructionLength.measure(draft, using: fake).level == .unprocessable)
                let hints = (0..<8).map { DictionaryHint(preferred: "Example\($0)", readings: ["あ"], memo: nil) }
                for retry in [false, true] {
                    let prompt = PromptAssembler.instructionOptimizerPrompt(
                        draft: draft, kind: kind, mentionedDictionaryHints: hints,
                        shortenPreviousResult: retry, language: language
                    )
                    let budget = BudgetInput(
                        task: .instructionOptimization, contextSize: fake.contextSize,
                        fixedInstructionTokens: try await fake.tokenCount(for: .instructions(PromptCatalog.template(.instructionOptimizer, language: language).text)),
                        promptTokens: try await fake.tokenCount(for: .prompt(prompt)), bodyTokens: tokens,
                        schemaTokens: try await fake.schemaTokenCount(for: OptimizedInstructionItems.self)
                    )
                    // Strict headroom: the warning threshold is BELOW the actual input limit.
                    if case .fits = ContextBudgeter().decide(budget) {} else { Issue.record("Warning threshold must fit optimizer") }
                    var larger = budget
                    larger.promptTokens += 1
                    larger.bodyTokens += 1
                    if case .fits = ContextBudgeter().decide(larger) {} else { Issue.record("Warning needs strict headroom") }
                }
            }
        }
    }

    @Test func thousandEntriesAndTwentyThousandCharactersRemainIntact() async {
        let start = ContinuousClock.now
        let entries = (0..<1000).map {
            DictionaryEntry(preferred: "Product\($0)", readings: ["alias\($0), ＡＬＩＡＳ\($0)、alias\($0)"], memo: "Synthetic memo")
        }
        let draft = "alias999 " + String(repeating: "あ", count: 19_991)
        #expect(draft.count == 20_000)
        let input = InstructionOptimizationInput(draft: draft, kind: .cleanup, dictionaryEntries: entries, promptLanguage: .ja)
        let selected = DictionarySelector().select(entries: entries, text: draft, options: .init(includeMemo: false))
        #expect(selected.selected.contains { $0.hint.preferred == "Product999" })
        let fake = FakeGenerator(fallback: optimizerReply(["丁寧に書く。"]), contextSize: 4096)
        let result = await optimize(fake, input: input)
        guard case .complete = result.status else { Issue.record("Large input failed: \(result.status)"); return }
        #expect((result.diagnostics.measures["chunkCount"] ?? 0) > 1)
        // Derive the envelope from the assembler, then recover exactly what each request received.
        // Synthetic data contains neither quotes nor headings, so no unescaping is needed.
        let envelope = PromptAssembler.instructionOptimizerPrompt(
            draft: "P5BoundarySentinel", kind: .cleanup, mentionedDictionaryHints: selected.hints, language: .ja
        ).components(separatedBy: "P5BoundarySentinel")
        let chunks = Int(result.diagnostics.measures["chunkCount"] ?? 0)
        var recovered = ""
        for request in fake.receivedRequests.prefix(chunks) {
            #expect(request.prompt.hasPrefix(envelope[0]))
            #expect(request.prompt.hasSuffix(envelope[1]))
            recovered += String(request.prompt.dropFirst(envelope[0].count).dropLast(envelope[1].count))
        }
        #expect(recovered == draft)
        #expect(input.draft == draft && input.dictionaryEntries == entries)
        #expect(ContinuousClock.now - start < .seconds(60))
    }

    @Test func splitCachesUnitsAndOnlyMeasuresFinalPromptCandidates() async throws {
        let line = String(repeating: "あ", count: 220) + "\n"
        let (fake, pipeline) = try await chunkSetup(
            line: line, replies: Array(repeating: optimizerReply(["丁寧に書く。"]), count: 7)
        )
        var input = optimizerInput
        input.draft = String(repeating: line, count: 6)
        let measurements = OptimizerTokenMeasurements()
        let result = await pipeline.run(input, using: OptimizerExecutor(generator: fake, tokenMeasurements: measurements))
        #expect(result.status == .complete(items: ["丁寧に書く。"]))
        #expect(result.diagnostics.measures["chunkCount"] == 6)
        #expect(measurements.count(line) == 1)
        let envelope = PromptAssembler.instructionOptimizerPrompt(draft: "", kind: .cleanup, language: .ja)
        #expect(measurements.count(envelope) == 1)
        let failedPackingCandidate = PromptAssembler.instructionOptimizerPrompt(draft: line + line, kind: .cleanup, language: .ja)
        #expect(measurements.count(failedPackingCandidate) == 0)
    }

    @Test func sixLargePartResultsMergeIteratively() async throws {
        let line = String(repeating: "あ", count: 1200) + "\n"
        let items = (0..<5).map { _ in String(repeating: "い", count: 95) }
        let replies = Array(repeating: optimizerReply(items), count: 30)
        let (fake, pipeline) = try await chunkSetup(line: line, replies: replies)
        var input = optimizerInput
        input.draft = String(repeating: line, count: 6)
        let result = await optimize(fake, input: input, pipeline: pipeline)
        #expect(result.status == .complete(items: items))
        #expect(result.diagnostics.measures["chunkCount"] == 6)
        #expect((result.diagnostics.measures["mergeCount"] ?? 0) > 1)
        #expect((result.diagnostics.measures["mergeCount"] ?? 0) <= 4)
        #expect(fake.receivedRequests.count > 7)
    }

    @Test func mergeRoundsAreBoundedWithoutExposingPartialItems() async throws {
        let line = String(repeating: "あ", count: 220) + "\n"
        // Each valid response expands the combined input; it never fits a final global pass.
        let items = (0..<5).map { _ in String(repeating: "い", count: 95) }
        let (fake, pipeline) = try await chunkSetup(line: line, replies: Array(repeating: optimizerReply(items), count: 500))
        var input = optimizerInput
        input.draft = line + line
        let result = await optimize(fake, input: input, pipeline: pipeline)
        #expect(result.status == .draftTooLong)
        #expect(result.diagnostics.measures["mergeCount"] == 4)
        #expect(result.permissionFlaggedIndices.isEmpty)
    }

    @Test func retrySentenceIsProtectedFromEchoing() async {
        for language in PromptLanguage.allCases {
            let retry = language == .ja ? PromptTextsJA.optimizerRetry : PromptTextsEN.optimizerRetry
            // Only the sentence: a section heading would also trigger the generic scaffold check.
            let sentence = retry.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            let fake = FakeGenerator(script: [optimizerReply(optimizerSix), optimizerReply([sentence])])
            var input = optimizerInput
            input.promptLanguage = language
            let result = await optimize(fake, input: input)
            #expect(result.status == .failed(.validationFailed))
            #expect(result.diagnostics.validation?.outcome.reasons.contains(.promptLeakage) == true)
            #expect(fake.receivedRequests.count == 2)
        }
    }

    @Test func fittingDraftPreservesPrototypeRequestForBothKindsAndLanguages() async {
        for kind in CustomInstructionKind.allCases {
            for language in PromptLanguage.allCases {
                let fake = FakeGenerator(script: [optimizerReply([" 丁寧に書く。 ", "", "\n", "簡潔に書く。"])])
                var input = optimizerInput
                input.kind = kind
                input.promptLanguage = language
                let result = await optimize(fake, input: input)
                #expect(result.status == .complete(items: ["丁寧に書く。", "簡潔に書く。"]))
                #expect(result.diagnostics.measures["retryCount"] == 0)
                #expect(result.diagnostics.measures["chunkCount"] == 0)
                let request = fake.receivedRequests.first
                #expect(request?.instructions == PromptCatalog.template(.instructionOptimizer, language: language).text)
                #expect(request?.prompt == PromptAssembler.instructionOptimizerPrompt(draft: input.draft, kind: kind, language: language))
                #expect(request?.greedy == true)
                #expect(request?.guardrails == AITask.instructionOptimization.guardrails)
                #expect(request?.maximumResponseTokens == 320)
                #expect((result.diagnostics.measures["budget.schemaTokens"] ?? 0) > 0)
            }
        }
    }

    @Test func fiveItemsComplete() async {
        let items = Array(optimizerSix.prefix(5))
        let result = await optimize(FakeGenerator(script: [optimizerReply(items)]))
        #expect(result.status == .complete(items: items))
    }

    @Test func sixItemsRetryOnceThenComplete() async {
        for language in PromptLanguage.allCases {
            var input = optimizerInput
            input.promptLanguage = language
            let fake = FakeGenerator(script: [optimizerReply(optimizerSix), optimizerReply(["丁寧で簡潔に書く。"])])
            let result = await optimize(fake, input: input)
            #expect(result.status == .complete(items: ["丁寧で簡潔に書く。"]))
            #expect(result.diagnostics.measures["retryCount"] == 1)
            #expect(fake.receivedRequests.count == 2)
            let retry = PromptAssembler.instructionOptimizerPrompt(
                draft: input.draft, kind: input.kind, shortenPreviousResult: true, language: language
            )
            #expect(fake.receivedRequests.last?.prompt == retry)
            #expect(fake.receivedRequests.first?.instructions == fake.receivedRequests.last?.instructions)
        }
    }

    @Test func sixItemsTwiceNeverExposeAnApplicableCandidate() async {
        let fake = FakeGenerator(script: [optimizerReply(optimizerSix), optimizerReply(optimizerSix)])
        let result = await optimize(fake)
        #expect(result.status == .tooLong)
        #expect(result.permissionFlaggedIndices.isEmpty)
        #expect(fake.receivedRequests.count == 2)
    }

    @Test func lengthIncludesNewlinesAndCountsExtendedGraphemes() async {
        // Two 250-Character items plus the separator = 501; emoji scalars must not inflate the count.
        let item = String(repeating: "あ", count: 249) + "👨‍👩‍👧‍👦"
        #expect(item.count == 250)
        let fake = FakeGenerator(script: [optimizerReply([item, item]), optimizerReply(["簡潔に書く。"])])
        let result = await optimize(fake)
        #expect(result.status == .complete(items: ["簡潔に書く。"]))
        #expect(result.diagnostics.measures["retryCount"] == 1)
        let tooLong = await optimize(FakeGenerator(script: [optimizerReply([item, item]), optimizerReply([item, item])]))
        #expect(tooLong.status == .tooLong)
        let exactly500 = String(repeating: "あ", count: 499) + "👨‍👩‍👧‍👦"
        #expect(await optimize(FakeGenerator(script: [optimizerReply([exactly500])])).status == .complete(items: [exactly500]))
    }

    @Test func emptyItemsFailWithoutRetry() async {
        let fake = FakeGenerator(script: [optimizerReply(["", " \n "])])
        let result = await optimize(fake)
        #expect(result.status == .failed(.validationFailed))
        #expect(result.diagnostics.validation?.outcome.reasons.contains(.emptyOutput) == true)
        #expect(fake.receivedRequests.count == 1)
    }

    @Test func onlyDraftMentionedDictionaryEntriesAndNoMemos() async {
        var input = optimizerInput
        input.draft = "アクメは正しい表記にしてください。"
        input.dictionaryEntries = [
            DictionaryEntry(preferred: "Acme", readings: ["アクメ"], memo: "secretMemoSentinel"),
            DictionaryEntry(preferred: "UnmentionedSentinel", readings: ["ノースウィンド"]),
        ]
        let fake = FakeGenerator(script: [optimizerReply(optimizerSix), optimizerReply(["Acmeと書く。"])])
        let result = await optimize(fake, input: input)
        #expect(result.status == .complete(items: ["Acmeと書く。"]))
        #expect(result.diagnostics.dictionarySelected == 1)
        for request in fake.receivedRequests {
            #expect(request.prompt.contains("表記：Acme"))
            #expect(!request.prompt.contains("UnmentionedSentinel"))
            #expect(!request.prompt.contains("secretMemoSentinel"))
        }
    }

    @Test func chunkAllLinesThenMergeOnce() async throws {
        let first = String(repeating: "丁寧な説明を希望します。", count: 20) + "\n"
        let second = String(repeating: "簡潔な文章を希望します。", count: 20) + "\n"
        let partial = Array(optimizerSix.prefix(3))
        let merged = ["丁寧で簡潔な短文にする。"]
        let (fake, pipeline) = try await chunkSetup(
            line: first, replies: [optimizerReply(partial), optimizerReply(partial), optimizerReply(merged)]
        )
        var input = optimizerInput
        input.draft = first + second
        let result = await optimize(fake, input: input, pipeline: pipeline)
        #expect(result.status == .complete(items: merged))
        #expect(result.diagnostics.measures["chunkCount"] == 2)
        #expect(result.diagnostics.measures["mergeCount"] == 1)
        #expect(fake.receivedRequests.count == 3)
        #expect(fake.receivedRequests.first?.prompt == PromptAssembler.instructionOptimizerPrompt(draft: first, kind: .cleanup, language: .ja))
        #expect(fake.receivedRequests.dropFirst().first?.prompt == PromptAssembler.instructionOptimizerPrompt(draft: second, kind: .cleanup, language: .ja))
        #expect(fake.receivedRequests.last?.prompt == PromptAssembler.instructionOptimizerPrompt(
            draft: (partial + partial).joined(separator: "\n"), kind: .cleanup, language: .ja
        ))
    }

    @Test func oversizedLineSplitsAtSentenceBoundaries() async throws {
        for delimiter in ["。", ". ", "！", "？"] {
            let sentence = String(repeating: "あ", count: 220) + delimiter
            let (fake, pipeline) = try await chunkSetup(line: sentence, replies: [optimizerReply(["丁寧に書く。"]), optimizerReply(["簡潔に書く。"]), optimizerReply(["丁寧で簡潔に書く。"])])
            var input = optimizerInput
            input.draft = sentence + sentence
            let result = await optimize(fake, input: input, pipeline: pipeline)
            #expect(result.status == .complete(items: ["丁寧で簡潔に書く。"]))
            #expect(result.diagnostics.measures["chunkCount"] == 2)
            #expect(result.diagnostics.measures["mergeCount"] == 1)
            #expect(fake.receivedRequests.count == 3)
        }
    }

    @Test func shortDuplicatePartResultsStillGetGlobalMerge() async throws {
        let line = String(repeating: "あ", count: 220) + "\n"
        let item = "丁寧に書く。"
        let (fake, pipeline) = try await chunkSetup(line: line, replies: [
            optimizerReply([item]), optimizerReply([item]), optimizerReply([item]),
        ])
        var input = optimizerInput
        input.draft = line + line
        let result = await optimize(fake, input: input, pipeline: pipeline)
        #expect(result.status == .complete(items: [item]))
        #expect(result.diagnostics.measures["mergeCount"] == 1)
        #expect(fake.receivedRequests.count == 3)
        #expect(fake.receivedRequests.last?.prompt == PromptAssembler.instructionOptimizerPrompt(
            draft: item + "\n" + item, kind: .cleanup, language: .ja
        ))
    }

    @Test func mergeHasItsOwnSingleLimitRetry() async throws {
        for mergeSucceeds in [true, false] {
            let line = String(repeating: "あ", count: 220) + "\n"
            let partial = Array(optimizerSix.prefix(3))
            let final = ["丁寧で簡潔に書く。"]
            let (fake, pipeline) = try await chunkSetup(line: line, replies: [
                optimizerReply(partial), optimizerReply(partial), optimizerReply(optimizerSix),
                optimizerReply(mergeSucceeds ? final : optimizerSix),
            ])
            var input = optimizerInput
            input.draft = line + line
            let result = await optimize(fake, input: input, pipeline: pipeline)
            #expect(result.status == (mergeSucceeds ? .complete(items: final) : .tooLong))
            #expect(result.diagnostics.measures["chunkCount"] == 2)
            #expect(result.diagnostics.measures["mergeCount"] == 1)
            #expect(result.diagnostics.measures["retryCount"] == 1)
            #expect(fake.receivedRequests.count == 4)
        }
    }

    @Test func combinedLengthAloneTriggersMerge() async throws {
        let line = String(repeating: "あ", count: 700) + "\n"
        let partial = String(repeating: "い", count: 300)
        let (fake, pipeline) = try await chunkSetup(line: line, replies: [
            optimizerReply([partial]), optimizerReply([partial]), optimizerReply(["丁寧に書く。"]),
        ])
        var input = optimizerInput
        input.draft = line + line
        let result = await optimize(fake, input: input, pipeline: pipeline)
        #expect(result.status == .complete(items: ["丁寧に書く。"]))
        #expect(result.diagnostics.measures["mergeCount"] == 1)
        #expect(fake.receivedRequests.count == 3)
    }

    @Test func unbrokenLineSplitsWithoutDroppingCharacters() async throws {
        let line = String(repeating: "あ", count: 220)
        let (fake, pipeline) = try await chunkSetup(line: line, replies: [
            optimizerReply(["丁寧に書く。"]), optimizerReply(["簡潔に書く。"]), optimizerReply(["丁寧で簡潔に書く。"]),
        ])
        var input = optimizerInput
        input.draft = line + line
        let result = await optimize(fake, input: input, pipeline: pipeline)
        #expect(result.status == .complete(items: ["丁寧で簡潔に書く。"]))
        #expect(result.diagnostics.measures["chunkCount"] == 2)
        #expect(result.diagnostics.measures["mergeCount"] == 1)
        #expect(fake.receivedRequests.prefix(2).map(\.prompt) == [
            PromptAssembler.instructionOptimizerPrompt(draft: line, kind: .cleanup, language: .ja),
            PromptAssembler.instructionOptimizerPrompt(draft: line, kind: .cleanup, language: .ja),
        ])
    }

    @Test func failureInLaterChunkDoesNotReturnEarlierItems() async throws {
        let line = String(repeating: "あ", count: 220) + "\n"
        let (fake, pipeline) = try await chunkSetup(
            line: line, replies: [optimizerReply(["丁寧に書く。"]), .init(.failure(.refusal))]
        )
        var input = optimizerInput
        input.draft = line + line
        let result = await optimize(fake, input: input, pipeline: pipeline)
        #expect(result.status == .failed(.guardrail))
        #expect(result.permissionFlaggedIndices.isEmpty)
        #expect(fake.receivedRequests.count == 2)
    }

    @Test func permissionNoticesKeepAllItemsAndUseFinalIndices() async {
        let keywords = [
            "Web", "ウェブ", "ネット", "インターネット", "検索", "URL", "リンク", "送信", "送って", "メール", "保存",
            "アップロード", "ダウンロード", "外部", "共有", "投稿", "send", "email", "save", "upload", "download",
            "web", "internet", "search", "browse", "share", "post",
        ]
        for keyword in keywords {
            let flagged = "\(keyword.uppercased()) を含む説明にする。"
            let fake = FakeGenerator(script: [optimizerReply(["", "丁寧に書く。", flagged])])
            let result = await optimize(fake)
            #expect(result.status == .complete(items: ["丁寧に書く。", flagged]))
            #expect(result.permissionFlaggedIndices == [1])
        }
    }

    @Test func cancellationDuringGenerationReturnsNoPartialCandidate() async {
        let fake = FakeGenerator(script: [optimizerReply(["送信する。"], delay: .seconds(5))])
        let task = Task { await optimize(fake) }
        await eventually { !fake.receivedRequests.isEmpty }
        task.cancel()
        let result = await task.value
        #expect(result.status == .failed(.cancelled))
        #expect(result.permissionFlaggedIndices.isEmpty)
        #expect(fake.receivedRequests.count == 1)
    }

    @Test func cancellationAfterReplyPreventsRetryOrNextChunk() async throws {
        let line = String(repeating: "あ", count: 220) + "\n"
        let (fake, pipeline) = try await chunkSetup(line: line, replies: [optimizerReply(["送信する。"])])
        var input = optimizerInput
        input.draft = line + line
        let chunkInput = input
        let task = Task {
            await pipeline.run(chunkInput, using: OptimizerExecutor(generator: fake, cancelAfterGeneration: true))
        }
        let result = await task.value
        #expect(result.status == .failed(.cancelled))
        #expect(result.permissionFlaggedIndices.isEmpty)
        #expect(fake.receivedRequests.count == 1)
        let retryFake = FakeGenerator(script: [optimizerReply(optimizerSix)])
        let retryTask = Task {
            await InstructionOptimizerPipeline().run(optimizerInput, using: OptimizerExecutor(generator: retryFake, cancelAfterGeneration: true))
        }
        #expect(await retryTask.value.status == .failed(.cancelled))
        #expect(retryFake.receivedRequests.count == 1)
    }

    @Test func schemaCountFailureStopsRatherThanUnderbudgeting() async {
        let fake = FakeGenerator()
        let result = await InstructionOptimizerPipeline().run(
            optimizerInput, using: OptimizerExecutor(generator: fake, failSchemaCount: true)
        )
        #expect(result.status == .failed(.generationError))
        #expect(result.diagnostics.failure == .unsupportedCapability)
        #expect(fake.receivedRequests.isEmpty)
    }

    @Test func alreadyCancelledTaskMakesNoCalls() async {
        let fake = FakeGenerator()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await optimize(fake)
        }
        #expect(await task.value.status == .failed(.cancelled))
        #expect(fake.receivedRequests.isEmpty)
    }

    @Test func validationFailureAndGenerationFailureDoNotRetry() async {
        let truncated = FakeGenerator(script: [.init(.text("{\"items\":[\"丁寧に書く。\"]}", usage: TokenUsage(inputTokens: 100, outputTokens: 320)))])
        #expect(await optimize(truncated).status == .failed(.validationFailed))
        #expect(truncated.receivedRequests.count == 1)
        let failure = FakeGenerator(script: [.init(.failure(.unsupportedLanguageOrLocale(languageCode: nil)))])
        #expect(await optimize(failure).status == .failed(.unsupportedLanguage))
        #expect(failure.receivedRequests.count == 1)
    }

    @Test func diagnosticsContainNoUserText() async {
        var input = optimizerInput
        input.draft = "draftPrivateSentinel の表記は保つ。"
        input.dictionaryEntries = [DictionaryEntry(preferred: "draftPrivateSentinel", memo: "memoPrivateSentinel")]
        let result = await optimize(FakeGenerator(script: [optimizerReply(["outputPrivateSentinel を使う。"])]), input: input)
        let dump = String(describing: result.diagnostics)
        #expect(!dump.contains("draftPrivateSentinel"))
        #expect(!dump.contains("memoPrivateSentinel"))
        #expect(!dump.contains("outputPrivateSentinel"))
    }
}
