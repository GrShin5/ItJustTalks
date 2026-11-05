import Foundation

/// Contains user text. Never log this input or the applicable items in the result.
public struct InstructionOptimizationInput: Sendable {
    public var draft: String
    public var kind: CustomInstructionKind
    public var dictionaryEntries: [DictionaryEntry]
    public var promptLanguage: PromptLanguage

    public init(
        draft: String, kind: CustomInstructionKind, dictionaryEntries: [DictionaryEntry] = [],
        promptLanguage: PromptLanguage
    ) {
        self.draft = draft
        self.kind = kind
        self.dictionaryEntries = dictionaryEntries
        self.promptLanguage = promptLanguage
    }
}

public enum InstructionOptimizationStatus: Sendable, Equatable {
    /// Only this case contains applicable items; no partial or over-limit candidate is exposed.
    case complete(items: [String])
    case tooLong
    /// A draft segment (or the combined preferences) cannot fit without discarding text.
    case draftTooLong
    case failed(AIFailureReason)
}

/// Codes, counts and timings only. Neither drafts nor generated items are retained here.
public struct InstructionOptimizationDiagnostics: Sendable {
    public var promptKeys: [String]
    public var calls: [GenerationCallRecord] = []
    public var measures: [String: Double] = ["retryCount": 0, "chunkCount": 0, "mergeCount": 0]
    public var dictionarySelected: Int
    public var dictionaryOmitted: Int
    public var validation: ValidationReport?
    public var failure: AIFailure?
    public var budgetStop: BudgetDecision?
}

public struct InstructionOptimizationResult: Sendable {
    public var status: InstructionOptimizationStatus
    /// Zero-based indices in the final, trimmed items (OPT-07). A notice never removes an item.
    public var permissionFlaggedIndices: [Int]
    public var diagnostics: InstructionOptimizationDiagnostics
}

/// On-device optimizer shared by the app and afm-eval (§3.5). No persistence or logging.
public final class InstructionOptimizerPipeline: Sendable {
    public struct Configuration: Sendable {
        public var budgeter: ContextBudgeter
        public var validator: ResultValidator
        public var guardrailsOverride: GuardrailsMode?

        public init(
            budgeter: ContextBudgeter = ContextBudgeter(), validator: ResultValidator = ResultValidator(),
            guardrailsOverride: GuardrailsMode? = nil
        ) {
            self.budgeter = budgeter
            self.validator = validator
            self.guardrailsOverride = guardrailsOverride
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func run(
        _ input: InstructionOptimizationInput, using executor: some GenerationExecuting
    ) async -> InstructionOptimizationResult {
        let template = PromptCatalog.template(.instructionOptimizer, language: input.promptLanguage)
        // Selection is anchored to the ORIGINAL draft, including during merge/retry. Model output
        // cannot cause unrelated dictionary entries or memos to be added to later calls.
        let selection = DictionarySelector().select(
            entries: input.dictionaryEntries, text: input.draft,
            options: DictionarySelectionOptions(includeMemo: false, promptLanguage: input.promptLanguage)
        )
        var diagnostics = InstructionOptimizationDiagnostics(
            promptKeys: [template.key], dictionarySelected: selection.selected.count,
            dictionaryOmitted: selection.omittedCount
        )
        let status: InstructionOptimizationStatus
        do {
            try Self.checkCancellation()
            let fixed = try await executor.tokenCount(for: .instructions(template.text))
            try Self.checkCancellation()
            let schema = try await executor.schemaTokenCount(for: OptimizedInstructionItems.self)
            try Self.checkCancellation()
            let terms = DictionaryValidationTerms(selection, handsFree: false)
            let context = Context(input: input, instructions: template.text, hints: selection.hints, terms: terms, fixed: fixed, schema: schema)
            let initial = try await prepare(input.draft, retry: false, context: context, executor: executor, diagnostics: &diagnostics)
            let items: [String]
            switch initial.decision {
            case .fits:
                items = try await optimize(input.draft, prepared: initial, context: context, executor: executor, diagnostics: &diagnostics)
            case .needsChunking:
                let parts = try await split(input.draft, context: context, executor: executor, diagnostics: &diagnostics)
                diagnostics.measures["chunkCount"] = Double(parts.count)
                var combined: [String] = []
                for part in parts {
                    try Self.checkCancellation()
                    combined += try await optimize(part.draft, prepared: part.prepared, context: context, executor: executor, diagnostics: &diagnostics)
                }
                // Even a short concatenation needs a global pass to reconcile duplicates/conflicts.
                if parts.count >= 2 || Self.exceedsLimits(combined) {
                    items = try await merge(combined, context: context, executor: executor, diagnostics: &diagnostics)
                } else {
                    items = combined
                }
            case .impossible:
                diagnostics.budgetStop = initial.decision
                throw Stop.draftTooLong
            }
            try Self.checkCancellation()
            // Validate the final combination too: individually valid chunks do not prove that their
            // joined result is valid against the original draft (e.g. leakage across item boundaries).
            if diagnostics.measures["chunkCount", default: 0] > 0 {
                let report = configuration.validator.evaluate(ValidationInput(
                    task: .instructionOptimization, source: input.draft, output: items.joined(separator: "\n"),
                    isTruncated: false, protectedInstructions: [template.text] +
                        (diagnostics.measures["retryCount", default: 0] > 0 ? [Self.retryInstruction(input.promptLanguage)] : []),
                    userSuppliedTexts: [],
                    allowedNewTerms: terms.allowedNewTerms, reviewOnlyTerms: terms.reviewOnlyTerms,
                    selectedDictionary: terms.selectedDictionary, handsFree: false
                ))
                diagnostics.validation = report
                if case .failed = report.outcome { throw Stop.validationFailed }
            }
            diagnostics.measures["itemCount"] = Double(items.count)
            diagnostics.measures["graphemes"] = Double(items.joined(separator: "\n").count)
            status = .complete(items: items)
        } catch let stop as Stop {
            switch stop {
            case .tooLong: status = .tooLong
            case .draftTooLong: status = .draftTooLong
            case .validationFailed: status = .failed(.validationFailed)
            }
        } catch let failure as AIFailure {
            diagnostics.failure = failure
            status = .failed(AIFailureReason(failure))
        } catch {
            // Never retain arbitrary error descriptions, which may contain prompt content.
            diagnostics.failure = .other(code: "InstructionOptimizerPipeline.unexpected")
            status = .failed(.generationError)
        }
        // Cancellation wins even if an executor returned a successful response after cancellation.
        if Task.isCancelled {
            diagnostics.failure = .cancelled
            return InstructionOptimizationResult(status: .failed(.cancelled), permissionFlaggedIndices: [], diagnostics: diagnostics)
        }
        let flags: [Int]
        if case .complete(let items) = status {
            flags = items.indices.filter { index in
                let text = items[index].lowercased()
                return Self.permissionKeywords.contains { text.contains($0) }
            }
        } else {
            flags = []
        }
        return InstructionOptimizationResult(status: status, permissionFlaggedIndices: flags, diagnostics: diagnostics)
    }

    private enum Stop: Error { case tooLong, draftTooLong, validationFailed }

    private struct Context {
        var input: InstructionOptimizationInput
        var instructions: String
        var hints: [DictionaryHint]
        var terms: DictionaryValidationTerms
        var fixed: Int
        var schema: Int
    }

    private struct Prepared {
        var prompt: String
        var decision: BudgetDecision
        var inputTokens: Int
        var retry: Bool
    }

    private struct Part {
        var draft: String
        var prepared: Prepared
    }

    private func prepare(
        _ draft: String, retry: Bool, knownBodyTokens: Int? = nil, context: Context, executor: some GenerationExecuting,
        diagnostics: inout InstructionOptimizationDiagnostics
    ) async throws -> Prepared {
        try Self.checkCancellation()
        let prompt = PromptAssembler.instructionOptimizerPrompt(
            draft: draft, kind: context.input.kind, mentionedDictionaryHints: context.hints,
            shortenPreviousResult: retry, language: context.input.promptLanguage
        )
        let promptTokens = try await executor.tokenCount(for: .prompt(prompt))
        try Self.checkCancellation()
        let measuredBody: Int
        if let knownBodyTokens { measuredBody = knownBodyTokens }
        else if draft.isEmpty { measuredBody = 0 }
        else { measuredBody = try await executor.tokenCount(for: .prompt(draft)) }
        let bodyTokens = min(measuredBody, promptTokens)
        try Self.checkCancellation()
        let budget = BudgetInput(
            task: .instructionOptimization, contextSize: executor.generator.contextSize,
            fixedInstructionTokens: context.fixed, promptTokens: promptTokens, bodyTokens: bodyTokens,
            schemaTokens: context.schema
        )
        let decision = configuration.budgeter.decide(budget)
        diagnostics.measures.merge([
            "budget.contextSize": Double(budget.contextSize), "budget.fixedInstructionTokens": Double(context.fixed),
            "budget.promptTokens": Double(promptTokens), "budget.bodyTokens": Double(bodyTokens),
            "budget.schemaTokens": Double(context.schema),
        ]) { _, new in new }
        if case .fits(let maximum) = decision { diagnostics.measures["budget.maxResponseTokens"] = Double(maximum) }
        if case .needsChunking(let maximum) = decision { diagnostics.measures["budget.maxBodyTokens"] = Double(maximum) }
        return Prepared(prompt: prompt, decision: decision, inputTokens: context.fixed + promptTokens + context.schema, retry: retry)
    }

    /// One candidate plus at most one limit retry. A retry uses the same draft, never a truncated one.
    private func optimize(
        _ draft: String, prepared: Prepared, context: Context, executor: some GenerationExecuting,
        diagnostics: inout InstructionOptimizationDiagnostics
    ) async throws -> [String] {
        var prepared = prepared
        for attempt in 0...1 {
            try Self.checkCancellation()
            guard case .fits(let maximum) = prepared.decision else {
                diagnostics.budgetStop = prepared.decision
                throw Stop.draftTooLong
            }
            let request = GenerationRequest(
                instructions: context.instructions, prompt: prepared.prompt, maximumResponseTokens: maximum,
                greedy: true, guardrails: configuration.guardrailsOverride ?? AITask.instructionOptimization.guardrails
            )
            let start = ContinuousClock.now
            let generated: StructuredGenerationResult<OptimizedInstructionItems>
            do {
                generated = try await executor.generate(request, generating: OptimizedInstructionItems.self, inputTokens: prepared.inputTokens)
                diagnostics.calls.append(GenerationCallRecord(
                    stage: .instructionOptimization, latency: generated.latency, usage: generated.usage,
                    isTruncated: generated.isTruncated, failure: nil
                ))
            } catch {
                diagnostics.calls.append(GenerationCallRecord(
                    stage: .instructionOptimization, latency: ContinuousClock.now - start, usage: nil,
                    isTruncated: false, failure: error
                ))
                throw error
            }
            try Self.checkCancellation()
            let items = generated.value.items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let joined = items.joined(separator: "\n")
            diagnostics.measures["itemCount"] = Double(items.count)
            diagnostics.measures["graphemes"] = Double(joined.count)
            let report = configuration.validator.evaluate(ValidationInput(
                task: .instructionOptimization, source: draft, output: joined, isTruncated: generated.isTruncated,
                protectedInstructions: [context.instructions] + (prepared.retry ? [Self.retryInstruction(context.input.promptLanguage)] : []),
                userSuppliedTexts: [],
                allowedNewTerms: context.terms.allowedNewTerms, reviewOnlyTerms: context.terms.reviewOnlyTerms,
                selectedDictionary: context.terms.selectedDictionary, handsFree: false
            ))
            diagnostics.validation = report
            if Self.exceedsLimits(items) {
                guard attempt == 0 else { throw Stop.tooLong }
                diagnostics.measures["retryCount", default: 0] += 1
                prepared = try await prepare(draft, retry: true, context: context, executor: executor, diagnostics: &diagnostics)
                continue
            }
            guard !items.isEmpty else { throw Stop.validationFailed }
            if case .failed = report.outcome { throw Stop.validationFailed }
            return items
        }
        throw Stop.tooLong
    }

    /// Up to four merge rounds; only a final global pass can expose applicable items.
    private func merge(
        _ items: [String], context: Context, executor: some GenerationExecuting,
        diagnostics: inout InstructionOptimizationDiagnostics
    ) async throws -> [String] {
        var combined = items
        for round in 1...4 {
            try Self.checkCancellation()
            diagnostics.measures["mergeCount"] = Double(round)
            let draft = combined.joined(separator: "\n")
            let prepared = try await prepare(draft, retry: false, context: context, executor: executor, diagnostics: &diagnostics)
            switch prepared.decision {
            case .fits:
                return try await optimize(draft, prepared: prepared, context: context, executor: executor, diagnostics: &diagnostics)
            case .needsChunking where round < 4:
                let parts = try await split(draft, context: context, executor: executor, diagnostics: &diagnostics)
                combined = []
                for part in parts {
                    combined += try await optimize(part.draft, prepared: part.prepared, context: context, executor: executor, diagnostics: &diagnostics)
                }
            default:
                diagnostics.budgetStop = prepared.decision
                throw Stop.draftTooLong
            }
        }
        throw Stop.draftTooLong
    }

    private static func retryInstruction(_ language: PromptLanguage) -> String {
        language == .ja ? PromptTextsJA.optimizerRetry : PromptTextsEN.optimizerRetry
    }

    /// Count the invariant prompt envelope once and each distinct unit once. Packing uses additive
    /// token estimates; only finalized chunks are re-verified with the actual assembled prompt.
    /// Tokenization is not additive, so an oversized verified chunk is split again without dropping text.
    private func split(
        _ draft: String, context: Context, executor: some GenerationExecuting,
        diagnostics: inout InstructionOptimizationDiagnostics
    ) async throws -> [Part] {
        var cache: [String: Int] = [:]
        let envelope = PromptAssembler.instructionOptimizerPrompt(
            draft: "", kind: context.input.kind, mentionedDictionaryHints: context.hints,
            language: context.input.promptLanguage
        )
        let overhead = try await executor.tokenCount(for: .prompt(envelope))
        var lines: [String] = []
        var buffer = ""
        for character in draft {
            if character == "•", !buffer.isEmpty { lines.append(buffer); buffer = "" }
            buffer.append(character)
            if character.isNewline { lines.append(buffer); buffer = "" }
        }
        if !buffer.isEmpty { lines.append(buffer) }
        var units: [String] = []
        for line in lines {
            let count = try await unitTokens(line, executor: executor, cache: &cache)
            if case .fits = splitDecision(bodyTokens: count, overhead: overhead, context: context, executor: executor) {
                units.append(line)
            } else {
                var sentence = ""
                var previous: Character?
                for character in line {
                    sentence.append(character)
                    if "。！？".contains(character) || (previous == "." && character == " ") {
                        units.append(sentence)
                        sentence = ""
                    }
                    previous = character
                }
                if !sentence.isEmpty { units.append(sentence) }
            }
        }
        var fitting: [(String, Int)] = []
        var pending = Array(units.reversed())
        while let unit = pending.popLast() {
            let count = try await unitTokens(unit, executor: executor, cache: &cache)
            if case .fits = splitDecision(bodyTokens: count, overhead: overhead, context: context, executor: executor) {
                fitting.append((unit, count))
            } else if unit.count > 1 {
                let middle = unit.index(unit.startIndex, offsetBy: unit.count / 2)
                pending.append(String(unit[middle...]))
                pending.append(String(unit[..<middle]))
            } else {
                // Final verification below, rather than the additive estimate, decides whether
                // even a single grapheme is impossible.
                fitting.append((unit, count))
            }
        }
        var chunks: [String] = []
        buffer = ""
        var bodyTokens = 0
        for (unit, count) in fitting {
            let decision = splitDecision(bodyTokens: bodyTokens + count, overhead: overhead, context: context, executor: executor)
            if case .fits = decision {
                buffer += unit
                bodyTokens += count
            } else {
                if !buffer.isEmpty { chunks.append(buffer) }
                buffer = unit
                bodyTokens = count
            }
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        var parts: [Part] = []
        for chunk in chunks {
            parts += try await verifyChunk(chunk, context: context, executor: executor, cache: &cache, diagnostics: &diagnostics)
        }
        guard !parts.isEmpty, parts.map(\.draft).joined() == draft else { throw Stop.draftTooLong }
        return parts
    }

    private func unitTokens(
        _ text: String, executor: some GenerationExecuting, cache: inout [String: Int]
    ) async throws -> Int {
        try Self.checkCancellation()
        if let count = cache[text] { return count }
        let count = try await executor.tokenCount(for: .prompt(text))
        cache[text] = count
        return count
    }

    private func splitDecision(
        bodyTokens: Int, overhead: Int, context: Context, executor: some GenerationExecuting
    ) -> BudgetDecision {
        configuration.budgeter.decide(BudgetInput(
            task: .instructionOptimization, contextSize: executor.generator.contextSize,
            fixedInstructionTokens: context.fixed, promptTokens: overhead + bodyTokens,
            bodyTokens: bodyTokens, schemaTokens: context.schema
        ))
    }

    /// Reuse the verified request at generation time; do not count the finalized chunk again.
    private func verifyChunk(
        _ draft: String, context: Context, executor: some GenerationExecuting,
        cache: inout [String: Int], diagnostics: inout InstructionOptimizationDiagnostics
    ) async throws -> [Part] {
        let count = try await unitTokens(draft, executor: executor, cache: &cache)
        let prepared = try await prepare(draft, retry: false, knownBodyTokens: count, context: context, executor: executor, diagnostics: &diagnostics)
        if case .fits = prepared.decision { return [Part(draft: draft, prepared: prepared)] }
        guard draft.count > 1 else {
            diagnostics.budgetStop = prepared.decision
            throw Stop.draftTooLong
        }
        let middle = draft.index(draft.startIndex, offsetBy: draft.count / 2)
        let first = try await verifyChunk(String(draft[..<middle]), context: context, executor: executor, cache: &cache, diagnostics: &diagnostics)
        let last = try await verifyChunk(String(draft[middle...]), context: context, executor: executor, cache: &cache, diagnostics: &diagnostics)
        return first + last
    }

    private static func exceedsLimits(_ items: [String]) -> Bool {
        items.count > 5 || items.joined(separator: "\n").count > 500
    }

    private static func checkCancellation() throws(AIFailure) {
        if Task.isCancelled { throw .cancelled }
    }

    private static let permissionKeywords = [
        "web", "ウェブ", "ネット", "インターネット", "検索", "url", "リンク", "送信", "送って", "メール", "保存",
        "アップロード", "ダウンロード", "外部", "共有", "投稿", "send", "email", "save", "upload", "download",
        "internet", "search", "browse", "share", "post",
    ]
}
