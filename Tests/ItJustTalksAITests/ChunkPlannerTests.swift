import Foundation
import FoundationModels
import Testing
@testable import ItJustTalksAI

struct ChunkTestExecutor: GenerationExecuting {
    let generator: any TextGenerating
    var schemaTokens: Int? = nil
    var chunkPromptPenalty: Int = 0
    func tokenCount(for subject: TokenCountSubject) async throws(AIFailure) -> Int {
        let count = try await generator.tokenCount(for: subject)
        if case .prompt(let text) = subject, text.contains("### Target text"),
           text.contains("bbbb"), !text.contains("aaaa"), !text.contains("cccc") {
            return count + chunkPromptPenalty
        }
        return count
    }
    func schemaTokenCount<Output: Generable>(for type: Output.Type) async throws(AIFailure) -> Int {
        if let schemaTokens { return schemaTokens }
        return try await generator.schemaTokenCount(for: type)
    }
    func generate(_ request: GenerationRequest, inputTokens: Int) async throws(AIFailure) -> GenerationResult {
        try await generator.generate(request)
    }
    func generate<Output: Generable & Sendable>(_ request: GenerationRequest, generating type: Output.Type,
                                               inputTokens: Int) async throws(AIFailure) -> StructuredGenerationResult<Output> {
        try await generator.generate(request, generating: type)
    }
}

final class ChunkProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ChunkProgress] = []
    func append(_ value: ChunkProgress) { lock.withLock { values.append(value) } }
    var recorded: [ChunkProgress] { lock.withLock { values } }
}

func chunkTestText(_ text: String, truncated: Bool = false) -> FakeGenerator.Step {
    .init(.text(text, usage: TokenUsage(inputTokens: 1, outputTokens: truncated ? 16 : 1)))
}

func chunkTestBudgeter() -> ContextBudgeter {
    var configuration = BudgetConfiguration.provisionalDefault
    configuration.hiddenOverheadTokens = 0
    configuration.marginRatio = 0
    configuration.minimumChunkBodyTokens = 8
    for task in AITask.allCases {
        configuration.profiles[task]?.reservation = OutputReservationPolicy(coefficient: 0, constant: 16)
    }
    return ContextBudgeter(configuration: configuration)
}

func chunkTestContext(task: AITask, capacity: Int, hints: [DictionaryHint] = [], style: String? = nil) -> Int {
    let template = PromptCatalog.template(PromptID(task: task), language: .en)
    let empty = task == .cleanup
        ? PromptAssembler.cleanupPrompt(transcript: "", dictionaryHints: hints, stylePreferences: style, language: .en)
        : PromptAssembler.taskPrompt(spokenInstruction: "Edit", target: "", dictionaryHints: hints, stylePreferences: style, language: .en)
    return template.text.count + empty.count + 16 + capacity
}

@Suite("ChunkPlanner")
struct ChunkPlannerTests {
    @Test(arguments: ["日本語です。次の文です。\n\n段落です。", "First sentence. Second sentence! Third?",
                      "日本語。English! 👨‍👩‍👧‍👦 é🇯🇵\n終わり。", String(repeating: "👨‍👩‍👧‍👦", count: 80),
                      String(repeating: "a", count: 300), String(repeating: "\n", count: 100),
                      String(repeating: "長い文章", count: 200) + "。"])
    func losslessAndBounded(_ source: String) async throws {
        let executor = ChunkTestExecutor(generator: FakeGenerator(charactersPerToken: 1))
        let plan = try await ChunkPlanner().plan(source, maxBodyTokens: 17, maximumChunks: 100, using: executor)
        guard case .chunks(let chunks) = plan else { Issue.record("Expected a plan"); return }
        #expect(chunks.map(\.source).joined() == source)
        #expect(chunks.map(\.source).joined().utf8.elementsEqual(source.utf8))
        var end = 0
        for chunk in chunks {
            #expect(chunk.sourceRange.lowerBound == end)
            #expect(chunk.sourceRange.count == chunk.source.count)
            #expect(try await executor.tokenCount(for: .prompt(chunk.source)) <= 17)
            end = chunk.sourceRange.upperBound
        }
        #expect(end == source.count)
    }

    @Test func overflowAndUnsplittableAreExplicit() async throws {
        let executor = ChunkTestExecutor(generator: FakeGenerator(charactersPerToken: 1))
        #expect(try await ChunkPlanner().plan(String(repeating: "a", count: 30), maxBodyTokens: 10,
            maximumChunks: 2, using: executor) == .maximumChunkCountExceeded)
        #expect(try await ChunkPlanner().plan("a", maxBodyTokens: 0, maximumChunks: 2, using: executor) == .unsplittable)
        let largeGrapheme = ChunkTestExecutor(generator: FakeGenerator(charactersPerToken: 0.1))
        #expect(try await ChunkPlanner().plan("👨‍👩‍👧‍👦", maxBodyTokens: 1, maximumChunks: 2,
            using: largeGrapheme) == .unsplittable)
    }

    @Test func boundaryPreferenceAndClosingQuotes() async throws {
        let executor = ChunkTestExecutor(generator: FakeGenerator(charactersPerToken: 1))
        let source = "First.\nSecond!\nThird?"
        guard case .chunks(let chunks) = try await ChunkPlanner().plan(source, maxBodyTokens: 14,
            maximumChunks: 8, using: executor) else { Issue.record("Expected chunks"); return }
        #expect(chunks.first?.source == "First.\n")
        let quoted = "「一文です。」 次です。"
        guard case .chunks(let quotes) = try await ChunkPlanner().plan(quoted, maxBodyTokens: 9,
            maximumChunks: 8, using: executor) else { Issue.record("Expected chunks"); return }
        #expect(quotes.first?.source == "「一文です。」 ")
    }

    @Test func correctionKeepsPreviousSentenceWhenHalfTargetRemains() async throws {
        let executor = ChunkTestExecutor(generator: FakeGenerator(charactersPerToken: 1))
        let source = "AAAAAAAAAAAA. BBBBB. Actually, CCCC."
        guard case .chunks(let chunks) = try await ChunkPlanner().plan(source, maxBodyTokens: 25,
            maximumChunks: 8, using: executor) else { Issue.record("Expected chunks"); return }
        #expect(chunks.first?.source == "AAAAAAAAAAAA. ")
        #expect(chunks.count == 2)
        #expect(chunks.last?.source == "BBBBB. Actually, CCCC.")
        #expect(chunks.map(\.source).joined() == source)
    }

    @Test func operationDeadlineExtendsOnceAndCopiesShareIt() async {
        let coordinator = GenerationCoordinator(generator: FakeGenerator())
        let outcome = await coordinator.perform(operation: UUID(), priority: .interactive, deadline: .cleanup) { context in
            let copy = context
            let original = context.operationDeadline
            await context.extendOperationDeadlineForLongText()
            let extended = copy.operationDeadline
            await copy.extendOperationDeadlineForLongText()
            return original == context.requestedAt + DeadlineConstants.cleanupCap
                && extended == context.requestedAt + DeadlineConstants.longTextCap
                && context.operationDeadline == extended
        }
        guard case .delivered(let valid) = outcome else { Issue.record("Not delivered"); return }
        #expect(valid)
    }

    @Test func tokenCountsUseExtendedDeadlineAfterOriginalDeadlinePasses() async {
        let coordinator = GenerationCoordinator(generator: FakeGenerator())
        let outcome = await coordinator.perform(operation: UUID(), priority: .interactive,
            deadline: DeadlinePolicy(cap: .milliseconds(1))) { context in
            await context.extendOperationDeadlineForLongText()
            do {
                try await Task.sleep(for: .milliseconds(10))
                return try await context.tokenCount(for: .prompt("synthetic")) > 0
            } catch { return false }
        }
        guard case .delivered(let valid) = outcome else { Issue.record("Not delivered"); return }
        #expect(valid)
    }

    @Test func deadlineExtensionNeverShortensLongerDeadline() async {
        let coordinator = GenerationCoordinator(generator: FakeGenerator())
        let outcome = await coordinator.perform(operation: UUID(), priority: .interactive,
            deadline: DeadlinePolicy(cap: .seconds(400))) { context in
            let original = context.operationDeadline
            await context.extendOperationDeadlineForLongText()
            return context.operationDeadline == original
        }
        guard case .delivered(let valid) = outcome else { Issue.record("Not delivered"); return }
        #expect(valid)
    }
}
