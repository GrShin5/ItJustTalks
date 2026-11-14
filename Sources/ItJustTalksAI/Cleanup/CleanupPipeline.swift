import Foundation
import FoundationModels

/// One cleanup request (§3.1). Contains user text: never log instances.
public struct CleanupInput: Sendable {
    /// Final transcript, with the spoken output-language instruction already removed by the caller.
    public var transcript: String
    /// Active normal-mode custom instruction (hands-free: the snapshot taken at recording start).
    public var customInstruction: String?
    /// Enabled dictionary entries. The pipeline selects the relevant ones (`DictionarySelector`) against the
    /// transcript handed to the cleanup generation (after stage A).
    public var dictionaryEntries: [DictionaryEntry]
    /// Language of the fixed prompts (follows the STT language, G1).
    public var promptLanguage: PromptLanguage
    /// Output language resolved by the caller (nil: same as the transcript).
    public var outputLanguage: OutputLanguage?
    /// Hands-free: stricter validation (§3.4).
    public var handsFree: Bool

    public init(
        transcript: String,
        customInstruction: String? = nil,
        dictionaryEntries: [DictionaryEntry] = [],
        promptLanguage: PromptLanguage,
        outputLanguage: OutputLanguage? = nil,
        handsFree: Bool
    ) {
        self.transcript = transcript
        self.customInstruction = customInstruction
        self.dictionaryEntries = dictionaryEntries
        self.promptLanguage = promptLanguage
        self.outputLanguage = outputLanguage
        self.handsFree = handsFree
    }
}

/// Result state of a cleanup. Only `complete` may be inserted or sent automatically.
public enum CleanupStatus: Sendable, Hashable {
    case complete
    case needsReview([ValidationReason])
    case failed(AIFailureReason)
}

/// A request could not fit its context budget.
public enum CleanupBudgetStop: Sendable, Hashable {
    case needsChunking(maxBodyTokens: Int)
    case impossible(BudgetImpossibleReason)
}

/// One model call (no text).
public struct GenerationCallRecord: Sendable, Hashable {
    public enum Stage: String, Sendable, Hashable, CaseIterable {
        /// Stage A: self-correction spans.
        case selfCorrection
        /// Stage B: the cleanup generation.
        case cleanup
        /// AI command: the task classification (structured, sees the spoken instruction only).
        case taskClassification
        /// AI command: the task-specific body generation.
        case commandGeneration
        /// Custom-instruction optimization (including chunks, merge and length retry).
        case instructionOptimization
    }

    public var stage: Stage
    /// Model latency on success; elapsed time until the failure otherwise.
    public var latency: Duration
    public var usage: TokenUsage?
    public var isTruncated: Bool
    public var failure: AIFailure?

    public init(stage: Stage, latency: Duration, usage: TokenUsage?, isTruncated: Bool, failure: AIFailure?) {
        self.stage = stage
        self.latency = latency
        self.usage = usage
        self.isTruncated = isTruncated
        self.failure = failure
    }
}

/// Non-content diagnostics of one cleanup: codes, counts, token numbers and timings only — never transcript,
/// dictionary, instruction or output text.
public struct CleanupDiagnostics: Sendable, Hashable {
    /// Versioned prompt keys used (`self_correction@n/ja`, `cleanup@n/ja`).
    public var promptKeys: [String]
    public var variantName: String?
    public var contextSize: Int
    public var calls: [GenerationCallRecord]
    /// Numeric measures: `stageA.*`, `budget.*`, `stageB.latencyMs`.
    public var measures: [String: Double]
    public var dictionarySelected: Int
    public var dictionaryOmitted: Int
    public var budgetStop: CleanupBudgetStop?
    /// Generation or token-count failure that ended the cleanup.
    public var failure: AIFailure?
    /// Validator report of the generated text (nil when nothing was generated).
    public var validation: ValidationReport?

    public var totalLatency: Duration { calls.reduce(.zero) { $0 + $1.latency } }
    public var inputTokens: Int? {
        let usages = calls.compactMap(\.usage)
        return usages.isEmpty ? nil : usages.reduce(0) { $0 + $1.inputTokens }
    }
    public var outputTokens: Int? {
        let usages = calls.compactMap(\.usage)
        return usages.isEmpty ? nil : usages.reduce(0) { $0 + $1.outputTokens }
    }
}

public struct CleanupResult: Sendable {
    /// Generated text whenever the cleanup generation succeeded (also when validation failed, for review).
    /// Apply it only when `status == .complete`. User text: never log.
    public var text: String?
    public var status: CleanupStatus
    public var diagnostics: CleanupDiagnostics
    // Request-local context retained only to validate a joined chunk result. Never logged.
    var validationInput: ValidationInput? = nil
}

/// Stage A of the two-stage cleanup. Contains user text in `transcriptForCleanup`, `spans` and `proposals`.
public struct SelfCorrectionStageResult: Sendable {
    /// Transcript for the cleanup generation (the original one on any fallback).
    public var transcriptForCleanup: String
    /// Spans for `ValidationInput.selfCorrections` (nil when stage A did not run).
    public var spans: [SelfCorrectionSpan]?
    /// Stage-A proposals as generated (nil unless the stage-A generation succeeded).
    public var proposals: [SelfCorrectionPair]?
    public var promptKey: String?
    /// `stageA.*` measures (numbers only).
    public var measures: [String: Double]
    public var call: GenerationCallRecord?
    public var failure: AIFailure?

    public init(
        transcriptForCleanup: String,
        spans: [SelfCorrectionSpan]? = nil,
        proposals: [SelfCorrectionPair]? = nil,
        promptKey: String? = nil,
        measures: [String: Double] = [:],
        call: GenerationCallRecord? = nil,
        failure: AIFailure? = nil
    ) {
        self.transcriptForCleanup = transcriptForCleanup
        self.spans = spans
        self.proposals = proposals
        self.promptKey = promptKey
        self.measures = measures
        self.call = call
        self.failure = failure
    }

    /// Stage A did not run: the transcript goes to the cleanup unchanged.
    public static func notRun(transcript: String) -> SelfCorrectionStageResult {
        SelfCorrectionStageResult(transcriptForCleanup: transcript)
    }
}

/// The production cleanup flow (§3.1, §3.6), shared by the app and `afm-eval`:
/// cue-less restart collapse → stage A (spans, only when `SelfCorrection.hasCue` fires) → `SelfCorrection.apply` →
/// dictionary selection → budget (§5.1) → cleanup generation → `ResultValidator`.
///
/// Single-shot stage-A problems fall back to the cleanup of the original transcript, except `rateLimited`
/// (its single retry is used up), `timeout` and cancellation, which end the operation. A body that does not fit is
/// split into re-budgeted chunks; text is never dropped silently. Never logs.
public final class CleanupPipeline: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var budgeter: ContextBudgeter
        public var validator: ResultValidator
        /// Whether dictionary memos are rendered (plan default: on).
        public var includeDictionaryMemo: Bool
        /// Evaluation knob: force one guardrail mode instead of the per-task decision (`AITask.guardrails`).
        public var guardrailsOverride: GuardrailsMode?
        public var chunkReferenceContext: ChunkReferenceContext
        /// How the cleanup output is used for plain normal dictation (no style preferences, no
        /// translation, not hands-free): `.projected` keeps every spoken word and takes only the allowed
        /// edits (punctuation, fillers, restarts, dictionary spellings) from the model; `.off` is the
        /// previous free rewrite. The app enables `.projected` (`CleanupPipeline.product`).
        public var editProjection: EditProjectionMode

        public init(
            budgeter: ContextBudgeter = ContextBudgeter(),
            validator: ResultValidator = ResultValidator(),
            includeDictionaryMemo: Bool = true,
            guardrailsOverride: GuardrailsMode? = nil,
            chunkReferenceContext: ChunkReferenceContext = .none,
            editProjection: EditProjectionMode = .off
        ) {
            self.budgeter = budgeter
            self.validator = validator
            self.includeDictionaryMemo = includeDictionaryMemo
            self.guardrailsOverride = guardrailsOverride
            self.chunkReferenceContext = chunkReferenceContext
            self.editProjection = editProjection
        }
    }

    public enum EditProjectionMode: String, Sendable, Hashable, CaseIterable {
        case off
        case projected
    }

    public let configuration: Configuration
    private let selector = DictionarySelector()
    private let lock = NSLock()
    private var instructionTokenCache: [String: Int] = [:]
    private var schemaTokenCache: [String: Int] = [:]

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The configuration the app uses for dictation.
    public static func product() -> CleanupPipeline {
        CleanupPipeline(configuration: Configuration(editProjection: .projected))
    }

    // MARK: - Entry points

    /// Stage A then the cleanup stage.
    public func run(_ input: CleanupInput, using executor: some GenerationExecuting,
                    progress: (@Sendable (ChunkProgress) -> Void)? = nil) async -> CleanupResult {
        let result = await runCollapsed(input, using: executor, progress: progress)
        let final = projectedSafeText(
            await retryDistinctSpeechActs(preservingOriginalFidelity(result, input: input), input: input, using: executor),
            input: input
        )
        return final
    }

    /// Deterministic restart removal before generation: cue-less repeats everywhere, obvious cued
    /// restarts (「14枚いや19枚」) only for plain dictation with edit projection. Idempotent.
    func collapsingRestarts(_ input: CleanupInput) -> String {
        let collapsed = RestartCollapser.collapse(input.transcript)
        return projects(input) ? Self.projectedPreprocessing(collapsed, language: input.promptLanguage) : collapsed
    }

    /// Deterministic steps before the model on the projected path. Idempotent: the transcript passes
    /// through here more than once.
    static func projectedPreprocessing(_ text: String, language: PromptLanguage) -> String {
        switch language {
        case .ja: return PauseMarkRepair.repair(CuedRestart.collapse(JapaneseSpacing.normalize(text)))
        case .en: return EnglishCuedRestart.collapse(text)
        }
    }

    /// English plain dictation uses the word-level projector (case changes, fillers, no rewording).
    /// Set to false to return English to the previous rewrite path.
    static let projectsEnglish = true

    /// Plain normal dictation eligible for edit projection.
    func projects(_ input: CleanupInput) -> Bool {
        configuration.editProjection == .projected && !input.handsFree
            && (input.promptLanguage == .ja || (input.promptLanguage == .en && Self.projectsEnglish))
            && (input.customInstruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && !ResultValidator.isCrossLanguage(source: input.transcript, expected: input.outputLanguage?.code)
    }

    /// Entries the selector found in this text, with their normalized readings.
    private func projectionDictionary(_ input: CleanupInput, text: String) -> [(surface: String, readings: [String])] {
        let selection = selector.select(entries: input.dictionaryEntries, text: text,
            options: DictionarySelectionOptions(includeMemo: false, promptLanguage: input.promptLanguage))
        return selection.selected.compactMap { selected in
            guard input.dictionaryEntries.indices.contains(selected.entryIndex) else { return nil }
            let entry = input.dictionaryEntries[selected.entryIndex]
            guard entry.isEnabled else { return nil }
            return (surface: entry.preferred, readings: DictionaryEntry.normalizedReadings(entry.readings))
        }
    }

    /// A projected result the checks still question is not shown for review: the spoken words are
    /// inserted as they were, with only punctuation, fillers and dictionary spellings taken from the
    /// model (nothing is deleted or reworded, so nothing can be lost).
    private func projectedSafeText(_ result: CleanupResult, input: CleanupInput) -> CleanupResult {
        guard projects(input), let output = result.text else { return result }
        switch result.status {
        case .complete, .failed(.cancelled): return result
        case .needsReview, .failed(.validationFailed): break
        case .failed: return result
        }
        // Only a leftover restart was flagged: the projected text already keeps every other word, and the
        // safe text would keep the restart too, so the projected text is the better of the two.
        let reasons = result.diagnostics.validation?.outcome.reasons ?? []
        if case .needsReview = result.status, !reasons.isEmpty, reasons.allSatisfy({ $0 == .selfCorrectionKept }) {
            var result = result
            result.status = .complete
            result.diagnostics.measures["projection.keptRestartAccepted"] = 1
            return result
        }
        let source = deterministicFallbackText(for: input)
        // Very long text: the character diff is quadratic; keep the unformatted fallback path instead.
        guard source.count <= 4000 else { return result }
        let safe = EditProjector.project(.init(
            source: source, output: output, language: input.promptLanguage.rawValue,
            dictionary: projectionDictionary(input, text: source), allowsContentDeletions: false
        ))
        guard !safe.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }
        // An unrelated proposal (a refusal or an answer) gives no formatting: keep the "unformatted"
        // failure so the app inserts the fallback text with its notice instead of a review window.
        if safe.fellBack {
            var result = result
            result.status = .failed(.validationFailed)
            result.diagnostics.measures["projection.unformatted"] = 1
            return result
        }
        var result = result
        result.text = input.promptLanguage == .en ? EnglishCapitalization.apply(safe.text) : safe.text
        result.status = .complete
        result.diagnostics.measures["projection.safeText"] = 1
        return result
    }

    private func runCollapsed(_ input: CleanupInput, using executor: some GenerationExecuting,
                              progress: (@Sendable (ChunkProgress) -> Void)?) async -> CleanupResult {
        // Request-local copy for generation; retain the original for the final fidelity checks.
        var input = input
        input.transcript = collapsingRestarts(input)
        let preflight = await chunkBudget(input, reference: nil, using: executor)
        switch preflight {
        case .needsChunking(let target, _):
            await executor.extendOperationDeadlineForLongText()
            return await chunked(input, target: target, using: executor, progress: progress)
        case .tokenCountFailed(let failure):
            var diagnostics = CleanupDiagnostics(
                promptKeys: [PromptCatalog.template(.cleanup, language: input.promptLanguage).key],
                variantName: executor.generator.variantName, contextSize: executor.generator.contextSize,
                calls: [], measures: [:], dictionarySelected: 0, dictionaryOmitted: 0
            )
            diagnostics.failure = failure
            return CleanupResult(text: nil, status: .failed(AIFailureReason(failure)), diagnostics: diagnostics)
        case .fits, .impossible:
            break
        }
        let stageA = await selfCorrectionStage(input, using: executor)
        return await cleanupStage(input, after: stageA, reference: nil, allowChunking: true, using: executor, progress: progress)
    }

    /// Runs the cleanup as one interactive operation of `coordinator` (deadline `DeadlinePolicy.cleanup`).
    public func run(
        _ input: CleanupInput,
        operation: UUID,
        coordinator: GenerationCoordinator,
        deadline: DeadlinePolicy = .cleanup,
        progress: (@Sendable (ChunkProgress) -> Void)? = nil
    ) async -> CoordinatedOutcome<CleanupResult> {
        await coordinator.perform(operation: operation, priority: .interactive, deadline: deadline) { context in
            await self.run(input, using: context, progress: progress)
        }
    }

    /// Stage A: lists self-corrections (structured generation) and applies the verified ones.
    public func selfCorrectionStage(_ input: CleanupInput, using executor: some GenerationExecuting) async -> SelfCorrectionStageResult {
        // Public stage entry points apply the same idempotent pre-pass as `run` (afm-eval calls them directly).
        var input = input
        input.transcript = collapsingRestarts(input)
        var result = SelfCorrectionStageResult.notRun(transcript: input.transcript)
        guard SelfCorrection.hasCue(in: input.transcript) else { return result }
        result.measures["stageA.ran"] = 1

        let template = PromptCatalog.template(.selfCorrection, language: input.promptLanguage)
        result.promptKey = template.key
        let prompt = PromptAssembler.selfCorrectionPrompt(transcript: input.transcript, language: input.promptLanguage)
        let schemaTokens = (try? await schemaTokens(SelfCorrectionList.self, executor: executor)) ?? 0
        let budget = await budget(
            task: .selfCorrection, instructions: template.text, prompt: prompt, body: input.transcript,
            schemaTokens: schemaTokens, executor: executor
        )
        guard case .fits(let maxTokens, let inputTokens, _) = budget else {
            result.measures["stageA.skipped"] = 1
            // Out of time or cancelled while counting: stop the operation (no cleanup call after it).
            if case .tokenCountFailed(let failure) = budget, Self.endsOperation(failure) { result.failure = failure }
            return result
        }
        let request = makeRequest(task: .selfCorrection, instructions: template.text, prompt: prompt, maximumResponseTokens: maxTokens)
        let start = ContinuousClock.now
        let proposals: [SelfCorrectionPair]
        do {
            let generated = try await executor.generate(request, generating: SelfCorrectionList.self, inputTokens: inputTokens)
            record(GenerationCallRecord(
                stage: .selfCorrection, latency: generated.latency, usage: generated.usage,
                isTruncated: generated.isTruncated, failure: nil
            ), into: &result)
            if generated.isTruncated { result.measures["stageA.truncated"] = 1 }
            proposals = generated.value.corrections
            result.proposals = proposals
        } catch {
            record(GenerationCallRecord(
                stage: .selfCorrection, latency: ContinuousClock.now - start, usage: nil, isTruncated: false, failure: error
            ), into: &result)
            result.failure = error
            result.measures["stageA.failed"] = 1
            return result
        }

        result.measures["stageA.proposals"] = Double(proposals.count)
        let outcome = SelfCorrection.apply(proposals.map { ($0.retracted, $0.replacement) }, to: input.transcript)
        result.spans = outcome.spans
        result.measures["stageA.verifiedProposals"] = Double(outcome.verifiedProposals)
        result.measures["stageA.droppedProposals"] = Double(outcome.droppedProposals)
        if let corrected = outcome.corrected {
            result.transcriptForCleanup = corrected
            result.measures["stageA.applied"] = corrected == input.transcript ? 0 : 1
        } else {
            result.measures["stageA.fallback"] = 1
        }
        return result
    }

    /// Stage B: generate from `stageA.transcriptForCleanup`, validate against the source before stage A.
    /// Also check polarity against the original transcript before any cue-less restart removal.
    public func cleanupStage(
        _ input: CleanupInput,
        after stageA: SelfCorrectionStageResult,
        using executor: some GenerationExecuting
    ) async -> CleanupResult {
        var collapsed = input
        collapsed.transcript = collapsingRestarts(input)
        let result = await cleanupStage(collapsed, after: stageA, reference: nil, allowChunking: true, using: executor)
        let final = projectedSafeText(
            await retryDistinctSpeechActs(preservingOriginalFidelity(result, input: input), input: input, using: executor),
            input: input
        )
        return final
    }

    /// One bounded recovery round, using the same executor (and therefore the same deadline).
    /// Failed recovery retains the first result and its validation; only diagnostics gain call records.
    private func retryDistinctSpeechActs(
        _ initial: CleanupResult, input: CleanupInput, using executor: some GenerationExecuting
    ) async -> CleanupResult {
        // Hands-free never turns a failed result into a sendable one.
        guard !input.handsFree, initial.status != .complete, !Task.isCancelled,
              initial.diagnostics.failure == nil, initial.diagnostics.budgetStop == nil,
              Set(initial.diagnostics.validation?.outcome.reasons ?? []) == [.lowContentRetention],
              var whole = initial.validationInput, let output = initial.text,
              !ResultValidator.isCrossLanguage(source: input.transcript, expected: input.outputLanguage?.code)
        else { return initial }

        // Rebuild the normal validation source before restart collapse, including dictionary spellings.
        let selection = selector.select(entries: input.dictionaryEntries, text: input.transcript,
            options: DictionarySelectionOptions(includeMemo: configuration.includeDictionaryMemo,
                                                promptLanguage: input.promptLanguage))
        let substitution = DictionaryLiteralSubstitution(selection: selection, entries: input.dictionaryEntries)
        whole.source = substitution.apply(to: input.transcript, includeSound: false).text
        whole.languageSource = input.transcript
        whole.output = output
        let spans = whole.selfCorrections ?? []
        let validator = configuration.validator
        let report = validator.evaluate(whole)
        let retentionSource = validator.droppedSpanSource(whole)
        let overlap = input.handsFree ? validator.thresholds.cleanupOverlapHandsFree : validator.thresholds.cleanupOverlap
        guard Set(report.outcome.reasons) == [.lowContentRetention],
              // Independent retention failures must not trigger this recovery.
              !(report.metrics.contentRetention.map { $0 < overlap.minimumRetention } ?? false),
              !CleanupFidelity.dropsQualifier(source: retentionSource, output: output),
              !CleanupFidelity.dropsAuxiliary(source: whole.source, output: output, spans: spans),
              CleanupFidelity.dropsDistinctPredicate(source: input.transcript, output: output, spans: spans),
              let split = Self.speechActSplit(input.transcript, output: output)
        else { return initial }

        // A deleted repeated clause can also trip the contiguous-span detector. The split requires
        // identical predicate bodies with only different endings; validate the surviving clause to
        // distinguish that same deletion from any additional missing content.
        var surviving = whole
        surviving.source = substitution.apply(to: split.second, includeSound: false).text
        surviving.languageSource = split.second
        let survivingReport = validator.evaluate(surviving)
        guard survivingReport.outcome == .complete,
              survivingReport.metrics.contentRetention == 1 else { return initial }

        var fallback = initial
        fallback.diagnostics.measures["retry.speechActs"] = 1
        var parts: [CleanupResult] = []
        for source in [split.first, split.second] {
            if Task.isCancelled { return fallback }
            var local = input
            local.transcript = source
            // No stage A, chunking, or recursive recovery: exactly one cleanup request per part.
            let part = await cleanupStage(local, after: .notRun(transcript: source), reference: nil,
                                          allowChunking: false, using: executor)
            fallback.diagnostics.calls += part.diagnostics.calls
            guard part.status == .complete, part.diagnostics.failure == nil else { return fallback }
            parts.append(part)
        }
        guard !Task.isCancelled, let first = parts[0].text, let second = parts[1].text else { return fallback }
        // The separator belongs to the original transcript, rather than the model's first response.
        let separatorEndsSentence = split.separator.contains(where: { "。？！?!".contains($0) })
        let boundaryMarks = CharacterSet(charactersIn: separatorEndsSentence ? "。？！?!．." : "。．.")
            .union(.whitespacesAndNewlines)
        var firstBody = first
        while let last = firstBody.unicodeScalars.last, boundaryMarks.contains(last) {
            firstBody.unicodeScalars.removeLast()
        }
        // A question or exclamation the model kept already ends the first sentence.
        let keptMark = firstBody.last.map { "？！?!".contains($0) } ?? false
        let separator = keptMark && !separatorEndsSentence && split.separator == "。" ? "" : split.separator
        let joined = firstBody + separator + second
        let contexts = parts.compactMap(\.validationInput)
        guard contexts.count == 2 else { return fallback }
        whole.output = joined
        whole.allowedNewTerms = contexts.flatMap(\.allowedNewTerms)
        whole.reviewOnlyTerms = contexts.flatMap(\.reviewOnlyTerms)
        whole.selectedDictionary = contexts.flatMap(\.selectedDictionary)
        whole.languageIgnoringTerms = contexts.flatMap(\.languageIgnoringTerms)
        whole.isTruncated = contexts.contains(where: \.isTruncated)
        let joinedReport = validator.evaluate(whole)
        guard joinedReport.outcome == .complete else { return fallback }
        var recovered = fallback
        recovered.text = joined
        recovered.status = .complete
        recovered.validationInput = whole
        recovered.diagnostics.validation = joinedReport
        recovered.diagnostics.measures["retry.recovered"] = 1
        recovered = preservingOriginalFidelity(recovered, input: input)
        return recovered.status == .complete ? recovered : fallback
    }

    private static func speechActSplit(_ source: String, output: String)
        -> (first: String, separator: String, second: String)? {
        let separators = CharacterSet(charactersIn: "。？！?!").union(.whitespacesAndNewlines)
        func isSeparator(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy(separators.contains) }
        func predicateBody(_ text: String) -> String? {
            guard let ending = text.range(of: #"[ぁ-ゖ]+(?:下さい[ぁ-ゖ]*)?[。？！?!\s]*$"#, options: .regularExpression)
            else { return nil }
            return ResultValidator.normalizeForMatch(String(text[..<ending.lowerBound]))
        }
        func candidate(_ start: String.Index, _ end: String.Index)
            -> (first: String, separator: String, second: String)? {
            let first = String(source[..<start]), second = String(source[end...])
            guard !first.isEmpty, !second.isEmpty,
                  let firstBody = predicateBody(first), !firstBody.isEmpty,
                  firstBody == predicateBody(second),
                  CleanupFidelity.dropsDistinctPredicate(source: first + "。" + second, output: output),
                  CleanupFidelity.dropsDistinctPredicate(source: first + "。" + second, output: second),
                  !CleanupFidelity.dropsDistinctPredicate(source: first, output: output),
                  !CleanupFidelity.dropsDistinctPredicate(source: second, output: output) else { return nil }
            let separator = start == end ? "。" : String(source[start..<end])
            return (first, separator, second)
        }
        var index = source.startIndex
        while index < source.endIndex {
            if isSeparator(source[index]) {
                let start = index
                while index < source.endIndex, isSeparator(source[index]) { index = source.index(after: index) }
                if let split = candidate(start, index) { return split }
            } else { index = source.index(after: index) }
        }
        // No written boundary: find the beginning of a repeated stem, never split inside okurigana.
        for index in source.indices.dropFirst() {
            guard source[index].unicodeScalars.contains(where: PhoneticReading.isHan),
                  !source[source.index(before: index)].unicodeScalars.contains(where: PhoneticReading.isHan)
            else { continue }
            let suffix = source[index...]
            guard suffix.count >= 2, source[..<index].contains(String(suffix.prefix(2))) else { continue }
            if let split = candidate(index, index) { return split }
        }
        return nil
    }

    private func preservingOriginalFidelity(_ result: CleanupResult, input: CleanupInput) -> CleanupResult {
        guard !ResultValidator.isCrossLanguage(source: input.transcript, expected: input.outputLanguage?.code),
              let output = result.text else { return result }
        let spans = result.validationInput?.selfCorrections ?? []
        var originalReasons: [ValidationReason] = []
        if result.validationInput?.languageSource != input.transcript,
           CleanupFidelity.changesNegation(source: input.transcript, output: output, spans: spans) {
            originalReasons.append(.negationChanged)
        }
        if CleanupFidelity.dropsDistinctPredicate(source: input.transcript, output: output, spans: spans)
            || CleanupFidelity.dropsAuxiliary(source: input.transcript, output: output, spans: spans) {
            originalReasons.append(.lowContentRetention)
        }
        guard !originalReasons.isEmpty else { return result }
        var result = result
        var reasons = result.diagnostics.validation?.outcome.reasons ?? []
        for reason in originalReasons where !reasons.contains(reason) { reasons.append(reason) }
        let failed: Bool
        if case .failed = result.status { failed = true } else { failed = input.handsFree }
        let outcome: ValidationOutcome = failed ? .failed(reasons) : .needsReview(reasons)
        result.diagnostics.validation = ValidationReport(outcome: outcome,
            metrics: result.diagnostics.validation?.metrics ?? ValidationMetrics())
        result.status = failed ? .failed(.validationFailed) : .needsReview(reasons)
        return result
    }

    private func cleanupStage(
        _ input: CleanupInput, after stageA: SelfCorrectionStageResult, reference: String?,
        allowChunking: Bool, using executor: some GenerationExecuting,
        progress: (@Sendable (ChunkProgress) -> Void)? = nil
    ) async -> CleanupResult {
        let language = input.promptLanguage
        let template = PromptCatalog.template(.cleanup, language: language)
        let generator = executor.generator
        var diagnostics = CleanupDiagnostics(
            promptKeys: [template.key], variantName: generator.variantName, contextSize: generator.contextSize,
            calls: [], measures: [:], dictionarySelected: 0, dictionaryOmitted: 0
        )
        if let key = stageA.promptKey { diagnostics.promptKeys.insert(key, at: 0) }
        diagnostics.measures.merge(stageA.measures) { _, new in new }
        if let call = stageA.call { diagnostics.calls.append(call) }
        if stageA.failure == .cancelled || Task.isCancelled {
            diagnostics.failure = .cancelled
            return CleanupResult(text: nil, status: .failed(.cancelled), diagnostics: diagnostics)
        }
        // Stage A already used its single rateLimited retry or ran out of time: do not start the cleanup
        // call (and its own retry) on top of it.
        if let failure = stageA.failure, Self.endsOperation(failure) {
            diagnostics.failure = failure
            return CleanupResult(text: nil, status: .failed(AIFailureReason(failure)), diagnostics: diagnostics)
        }

        let selection = selector.select(
            entries: input.dictionaryEntries, text: stageA.transcriptForCleanup,
            options: DictionarySelectionOptions(includeMemo: configuration.includeDictionaryMemo, promptLanguage: language)
        )
        let substitution = DictionaryLiteralSubstitution(selection: selection, entries: input.dictionaryEntries)
        let outputSubstitution = DictionaryLiteralSubstitution(
            selection: selection, entries: input.dictionaryEntries, literalSource: stageA.transcriptForCleanup
        )
        let substituted = substitution.apply(to: stageA.transcriptForCleanup)
        let transcript = substituted.text
        let unresolvedHints = selector.select(
            entries: input.dictionaryEntries, text: transcript,
            options: DictionarySelectionOptions(includeMemo: configuration.includeDictionaryMemo, promptLanguage: language)
        ).unresolvedHints(in: transcript)
        diagnostics.measures["dictionary.substitutions"] = Double(substituted.count)
        diagnostics.dictionarySelected = selection.selected.count
        diagnostics.dictionaryOmitted = selection.omittedCount
        let prompt = PromptAssembler.cleanupPrompt(
            transcript: transcript, dictionaryHints: unresolvedHints, stylePreferences: input.customInstruction,
            outputLanguage: input.outputLanguage, language: language, referenceContext: reference
        )

        let budget = await budget(
            task: .cleanup, instructions: template.text, prompt: prompt, body: transcript,
            promptWithoutCustomInstruction: input.customInstruction == nil ? nil : PromptAssembler.cleanupPrompt(
                transcript: transcript, dictionaryHints: unresolvedHints, stylePreferences: nil,
                outputLanguage: input.outputLanguage, language: language, referenceContext: reference
            ), executor: executor
        )
        let maxTokens: Int
        let inputTokens: Int
        switch budget {
        case .fits(let maximum, let tokens, let measures):
            diagnostics.measures.merge(measures) { _, new in new }
            maxTokens = maximum
            inputTokens = tokens
        case .needsChunking(let maxBody, let measures):
            diagnostics.measures.merge(measures) { _, new in new }
            diagnostics.budgetStop = .needsChunking(maxBodyTokens: maxBody)
            if allowChunking {
                await executor.extendOperationDeadlineForLongText()
                return await chunked(input, target: maxBody, using: executor, progress: progress)
            }
            return CleanupResult(text: nil, status: .failed(.contextSizeExceeded), diagnostics: diagnostics)
        case .impossible(let reason, let measures):
            diagnostics.measures.merge(measures) { _, new in new }
            diagnostics.budgetStop = .impossible(reason)
            return CleanupResult(text: nil, status: .failed(reason == .customInstructionTooLong ? .customInstructionTooLong : .contextSizeExceeded), diagnostics: diagnostics)
        case .tokenCountFailed(let failure):
            diagnostics.failure = failure
            return CleanupResult(text: nil, status: .failed(AIFailureReason(failure)), diagnostics: diagnostics)
        }

        let request = makeRequest(task: .cleanup, instructions: template.text, prompt: prompt, maximumResponseTokens: maxTokens)
        let start = ContinuousClock.now
        let generated: GenerationResult
        do {
            generated = try await executor.generate(request, inputTokens: inputTokens)
        } catch {
            let call = GenerationCallRecord(
                stage: .cleanup, latency: ContinuousClock.now - start, usage: nil, isTruncated: false, failure: error
            )
            diagnostics.calls.append(call)
            diagnostics.measures["stageB.latencyMs"] = call.latency.milliseconds
            diagnostics.failure = error
            return CleanupResult(text: nil, status: .failed(AIFailureReason(error)), diagnostics: diagnostics)
        }
        diagnostics.calls.append(GenerationCallRecord(
            stage: .cleanup, latency: generated.latency, usage: generated.usage, isTruncated: generated.isTruncated, failure: nil
        ))
        diagnostics.measures["stageB.latencyMs"] = generated.latency.milliseconds

        // Hands-free: an entry found only by sound may be a homophone ("今度" for "近藤"), so its spelling
        // is never sent automatically; it is shown for review instead.
        let terms = DictionaryValidationTerms(selection, handsFree: input.handsFree)
        var output = Self.strippingShortPhraseFullStop(
            FillerStripper.strip(Self.trimmingTrailingLineWhitespace(outputSubstitution.apply(to: generated.text).text), source: input.transcript), transcript: input.transcript
        )
        // Projection: the model's text is a proposal. Only allowed edits reach the spoken words, so a
        // shortened or truncated proposal keeps the source text instead of losing it.
        var projectedTail = false
        if reference == nil, projects(input) {
            let projection = EditProjector.project(.init(
                source: transcript, output: output, language: language.rawValue,
                dictionary: projectionDictionary(input, text: stageA.transcriptForCleanup)
            ))
            // A proposal may put back a mid-utterance 「。」.
            output = language == .ja ? PauseMarkRepair.repair(projection.text) : EnglishCapitalization.apply(projection.text)
            projectedTail = !projection.fellBack
            diagnostics.measures["projection.applied"] = 1
            diagnostics.measures["projection.fellBack"] = projection.fellBack ? 1 : 0
            diagnostics.measures["projection.alignment"] = projection.alignment
            diagnostics.measures["projection.accepted"] = Double(projection.accepted.values.reduce(0, +))
            diagnostics.measures["projection.rejected"] = Double(projection.rejected.values.reduce(0, +))
        }
        let validationInput = ValidationInput(
            task: .cleanup, source: substitution.apply(to: input.transcript, includeSound: false).text,
            output: ChunkPlanner.bodyAfterReference(reference, output: output), isTruncated: generated.isTruncated && !projectedTail,
            protectedInstructions: [template.text],
            userSuppliedTexts: [],
            allowedNewTerms: terms.allowedNewTerms,
            reviewOnlyTerms: terms.reviewOnlyTerms,
            selectedDictionary: terms.selectedDictionary,
            expectedOutputLanguage: input.outputLanguage?.code, handsFree: input.handsFree,
            hasStylePreferences: !(input.customInstruction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            selfCorrections: substitution.validationSpans(stageA.spans),
            languageSource: input.transcript,
            languageIgnoringTerms: outputSubstitution.preferredSpellings
        )
        let report = configuration.validator.evaluate(validationInput)
        diagnostics.validation = report
        let status: CleanupStatus
        switch report.outcome {
        case .complete: status = .complete
        case .needsReview(let reasons): status = .needsReview(reasons)
        case .failed: status = .failed(.validationFailed)
        }
        return CleanupResult(text: output, status: status, diagnostics: diagnostics, validationInput: validationInput)
    }

    private func chunkBudget(_ input: CleanupInput, reference: String?, using executor: some GenerationExecuting) async -> StageBudget {
        let selection = selector.select(entries: input.dictionaryEntries, text: input.transcript,
            options: DictionarySelectionOptions(includeMemo: configuration.includeDictionaryMemo, promptLanguage: input.promptLanguage))
        let body = DictionaryLiteralSubstitution(selection: selection, entries: input.dictionaryEntries).apply(to: input.transcript).text
        let unresolvedHints = selector.select(entries: input.dictionaryEntries, text: body,
            options: DictionarySelectionOptions(includeMemo: configuration.includeDictionaryMemo, promptLanguage: input.promptLanguage)).unresolvedHints(in: body)
        let template = PromptCatalog.template(.cleanup, language: input.promptLanguage)
        return await budget(task: .cleanup, instructions: template.text,
            prompt: PromptAssembler.cleanupPrompt(transcript: body, dictionaryHints: unresolvedHints,
                stylePreferences: input.customInstruction, outputLanguage: input.outputLanguage,
                language: input.promptLanguage, referenceContext: reference), body: body,
            promptWithoutCustomInstruction: input.customInstruction == nil ? nil : PromptAssembler.cleanupPrompt(
                transcript: body, dictionaryHints: unresolvedHints, outputLanguage: input.outputLanguage,
                language: input.promptLanguage, referenceContext: reference), executor: executor)
    }

    private func chunked(_ input: CleanupInput, target: Int, using executor: some GenerationExecuting,
                         progress: (@Sendable (ChunkProgress) -> Void)?) async -> CleanupResult {
        var diagnostics = CleanupDiagnostics(promptKeys: [], variantName: executor.generator.variantName,
            contextSize: executor.generator.contextSize, calls: [], measures: [:], dictionarySelected: 0, dictionaryOmitted: 0)
        func failed(_ reason: AIFailureReason) -> CleanupResult {
            CleanupResult(text: nil, status: .failed(reason), diagnostics: diagnostics)
        }
        diagnostics.budgetStop = .needsChunking(maxBodyTokens: target)
        var pending: [PlannedChunk]
        do {
            guard case .chunks(let plan) = try await ChunkPlanner().plan(input.transcript, maxBodyTokens: target, balanced: true,
                maximumChunks: 8, using: executor), !plan.isEmpty else { return failed(.contextSizeExceeded) }
            pending = plan
            diagnostics.budgetStop = nil
        } catch { diagnostics.failure = error; return failed(AIFailureReason(error)) }
        var i = 0
        var previous: String?
        while i < pending.count {
            if Task.isCancelled { return failed(.cancelled) }
            let chunk = pending[i]
            var local = input
            local.transcript = chunk.source
            let reference = configuration.chunkReferenceContext == .previousSentence ? previous : nil
            let check = await chunkBudget(local, reference: reference, using: executor)
            switch check {
            case .needsChunking(let smaller, _):
                let minimum = configuration.budgeter.configuration.minimumChunkBodyTokens
                guard smaller >= minimum else { return failed(.contextSizeExceeded) }
                do {
                    let originalTokens = try await executor.tokenCount(for: .prompt(chunk.source))
                    let nextTarget = min(smaller, originalTokens - 1)
                    guard nextTarget >= minimum,
                          case .chunks(let pieces) = try await ChunkPlanner().plan(chunk.source,
                        maxBodyTokens: nextTarget, maximumChunks: 8 - pending.count + 1, using: executor),
                        pieces.count > 1 else { return failed(.contextSizeExceeded) }
                    pending.replaceSubrange(i...i, with: pieces.map {
                        PlannedChunk(source: $0.source, sourceRange: ($0.sourceRange.lowerBound + chunk.sourceRange.lowerBound)..<($0.sourceRange.upperBound + chunk.sourceRange.lowerBound))
                    })
                    continue
                } catch { diagnostics.failure = error; return failed(AIFailureReason(error)) }
            case .impossible(let reason, _):
                diagnostics.budgetStop = .impossible(reason)
                return failed(reason == .customInstructionTooLong ? .customInstructionTooLong : .contextSizeExceeded)
            case .tokenCountFailed(let failure):
                diagnostics.failure = failure
                return failed(AIFailureReason(failure))
            case .fits: break
            }
            previous = ChunkPlanner.lastSentence(chunk.source)
            i += 1
        }
        var results: [ChunkResult] = []
        var validationInputs: [ValidationInput] = []
        var referenceDuplicates: [ValidationReason] = []
        previous = nil
        i = 0
        diagnostics.measures.merge(ChunkingSummary(chunkCount: pending.count, mergeStages: 0,
            referenceContext: configuration.chunkReferenceContext).measures) { _, new in new }
        progress?(ChunkProgress(completed: 0, total: pending.count))
        while i < pending.count {
            if Task.isCancelled { return failed(.cancelled) }
            let chunk = pending[i]
            var local = input
            local.transcript = chunk.source
            let reference = configuration.chunkReferenceContext == .previousSentence ? previous : nil
            // Same stage-A rules as single-shot: fall back to single-stage cleanup of this chunk, except
            // cancellation / timeout / rateLimited, which `cleanupStage` turns into a failure of the operation.
            let stageA = await selfCorrectionStage(local, using: executor)
            let result = await cleanupStage(local, after: stageA, reference: reference, allowChunking: false, using: executor)
            diagnostics.calls += result.diagnostics.calls
            diagnostics.promptKeys += result.diagnostics.promptKeys
            diagnostics.measures.merge(result.diagnostics.measures) { _, new in new }
            diagnostics.dictionarySelected += result.diagnostics.dictionarySelected
            diagnostics.dictionaryOmitted += result.diagnostics.dictionaryOmitted
            diagnostics.failure = result.diagnostics.failure
            diagnostics.budgetStop = result.diagnostics.budgetStop
            // Dictionary selection after stage A may increase the budget; re-plan this chunk only.
            if case .needsChunking(let smaller)? = result.diagnostics.budgetStop {
                do {
                    let originalTokens = try await executor.tokenCount(for: .prompt(chunk.source))
                    let nextTarget = min(smaller, originalTokens - 1)
                    guard nextTarget >= configuration.budgeter.configuration.minimumChunkBodyTokens,
                          case .chunks(let pieces) = try await ChunkPlanner().plan(chunk.source, maxBodyTokens: nextTarget,
                            maximumChunks: 8 - pending.count + 1, using: executor), pieces.count > 1 else {
                        return failed(.contextSizeExceeded)
                    }
                    pending.replaceSubrange(i...i, with: pieces.map {
                        PlannedChunk(source: $0.source, sourceRange: ($0.sourceRange.lowerBound + chunk.sourceRange.lowerBound)..<($0.sourceRange.upperBound + chunk.sourceRange.lowerBound))
                    })
                    diagnostics.measures["chunk.count"] = Double(pending.count)
                    progress?(ChunkProgress(completed: i, total: pending.count))
                    continue
                } catch { diagnostics.failure = error; return failed(AIFailureReason(error)) }
            }
            guard let output = result.text else {
                if result.diagnostics.calls.contains(where: { $0.stage == .cleanup }) {
                    progress?(ChunkProgress(completed: i + 1, total: pending.count))
                }
                if case .failed(let reason) = result.status { return failed(reason) }
                return failed(.generationError)
            }
            var outcome = result.diagnostics.validation?.outcome ?? .failed([.invalidInput])
            let referenceMatch = reference.map(ResultValidator.normalizeForMatch) ?? ""
            if !referenceMatch.isEmpty, ResultValidator.normalizeForMatch(output).hasPrefix(referenceMatch) {
                referenceDuplicates.append(.chunkBoundaryDuplicate(index: i))
                if case .failed = outcome {} else {
                    outcome = .needsReview(outcome.reasons + [.chunkBoundaryDuplicate(index: i)])
                }
            }
            results.append(ChunkResult(index: i, sourceRange: chunk.sourceRange, source: chunk.source, output: output, outcome: outcome))
            if let context = result.validationInput { validationInputs.append(context) }
            previous = ChunkPlanner.lastSentence(chunk.source)
            i += 1
            progress?(ChunkProgress(completed: i, total: pending.count))
            if case .failed = outcome {
                diagnostics.validation = ValidationReport(outcome: .failed([.chunkFailed(index: i - 1)] + outcome.reasons), metrics: ValidationMetrics())
                return CleanupResult(text: ChunkPlanner.joined(results), status: .failed(.validationFailed), diagnostics: diagnostics)
            }
        }
        diagnostics.measures.merge(ChunkingSummary(chunkCount: results.count, mergeStages: 0,
            referenceContext: configuration.chunkReferenceContext).measures) { _, new in new }
        var outcome = ChunkValidator(thresholds: configuration.validator.thresholds).validate(results, sourceLength: input.transcript.count)
        if !referenceDuplicates.isEmpty {
            if case .failed = outcome {} else { outcome = .needsReview(outcome.reasons + referenceDuplicates) }
        }
        var joinedValidationInput: ValidationInput?
        if var whole = validationInputs.first {
            // The per-chunk validation sources (after dictionary substitution) tile the transcript.
            whole.source = validationInputs.map(\.source).joined()
            whole.languageSource = input.transcript
            whole.output = ChunkPlanner.joined(results)
            whole.allowedNewTerms = validationInputs.flatMap(\.allowedNewTerms)
            whole.reviewOnlyTerms = validationInputs.flatMap(\.reviewOnlyTerms)
            whole.selectedDictionary = validationInputs.flatMap(\.selectedDictionary)
            whole.selfCorrections = validationInputs.flatMap { $0.selfCorrections ?? [] }
            whole.languageIgnoringTerms = validationInputs.flatMap(\.languageIgnoringTerms)
            joinedValidationInput = whole
            let reasons = configuration.validator.joinedNumberReasons(whole)
            if !reasons.isEmpty {
                if input.handsFree { outcome = .failed(outcome.reasons + reasons) }
                else if case .failed = outcome {} else { outcome = .needsReview(outcome.reasons + reasons) }
            }
        }
        diagnostics.validation = ValidationReport(outcome: outcome, metrics: ValidationMetrics())
        let status: CleanupStatus
        switch outcome {
        case .complete: status = .complete
        case .needsReview(let reasons): status = .needsReview(reasons)
        case .failed: status = .failed(.validationFailed)
        }
        return CleanupResult(text: ChunkPlanner.joined(results), status: status, diagnostics: diagnostics,
                             validationInput: joinedValidationInput)
    }

    // MARK: - Helpers

    /// A single word or short phrase ("了解", "Thanks") is inserted without a final full stop (user decision
    /// 2026-10-16), whatever the recognizer or the model added. Only `。` / `．` / one `.`; `？`/`！`/`...` are kept.
    static func strippingShortPhraseFullStop(_ output: String, transcript: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, "。．.".contains(last), !trimmed.hasSuffix(".."),
              isShortPhrase(transcript), isShortPhrase(String(trimmed.dropLast())) else { return output }
        return String(trimmed.dropLast())
    }

    /// One line, no sentence or comma punctuation inside, ≤ 8 characters (≤ 2 words for Latin text).
    /// Both the transcript and the output must be short: a short dictionary reading that expands to a full
    /// sentence keeps its full stop.
    static func isShortPhrase(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。．.!?！？"))
        guard !body.isEmpty, !body.contains(where: { $0.isNewline || "。．.!?！？、，,".contains($0) }) else { return false }
        let letters = body.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let latin = !letters.isEmpty && letters.allSatisfy { $0.isASCII }
        return latin ? body.split(whereSeparator: \.isWhitespace).count <= 2 : body.count <= 8
    }

    /// Remove Markdown hard-break spaces and trailing tabs without changing line breaks or inner spaces.
    static func trimmingTrailingLineWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \t]+(?=\r\n|[\r\n]|$)", with: "", options: .regularExpression)
    }

    private func makeRequest(task: AITask, instructions: String, prompt: String, maximumResponseTokens: Int) -> GenerationRequest {
        GenerationRequest(
            instructions: instructions, prompt: prompt, maximumResponseTokens: maximumResponseTokens,
            greedy: true, guardrails: configuration.guardrailsOverride ?? task.guardrails
        )
    }

    private func record(_ call: GenerationCallRecord, into result: inout SelfCorrectionStageResult) {
        result.call = call
        result.measures["stageA.latencyMs"] = call.latency.milliseconds
        if let usage = call.usage {
            result.measures["stageA.inputTokens"] = Double(usage.inputTokens)
            result.measures["stageA.outputTokens"] = Double(usage.outputTokens)
        }
    }

    private enum StageBudget {
        case fits(maximumResponseTokens: Int, inputTokens: Int, measures: [String: Double])
        case needsChunking(maxBodyTokens: Int, measures: [String: Double])
        case impossible(BudgetImpossibleReason, measures: [String: Double])
        case tokenCountFailed(AIFailure)
    }

    /// Stage-A failures after which the cleanup call is not started (m1): its retry was used or time is up.
    private static func endsOperation(_ failure: AIFailure) -> Bool {
        switch failure {
        case .rateLimited, .timeout, .cancelled: return true
        default: return false
        }
    }

    private func instructionTokens(_ text: String, executor: some GenerationExecuting) async throws(AIFailure) -> Int {
        if let cached = lock.withLock({ instructionTokenCache[text] }) { return cached }
        let count = try await executor.tokenCount(for: .instructions(text))
        lock.withLock { instructionTokenCache[text] = count }
        return count
    }

    private func schemaTokens<Output: Generable>(_ type: Output.Type, executor: some GenerationExecuting) async throws(AIFailure) -> Int {
        let key = String(describing: type)
        if let cached = lock.withLock({ schemaTokenCache[key] }) { return cached }
        let count = try await executor.schemaTokenCount(for: type)
        lock.withLock { schemaTokenCache[key] = count }
        return count
    }

    /// §5.1 budget with the measures `afm-eval` records (`budget.*`).
    private func budget(
        task: AITask, instructions: String, prompt: String, body: String, schemaTokens: Int = 0,
        promptWithoutCustomInstruction: String? = nil,
        executor: some GenerationExecuting
    ) async -> StageBudget {
        let generator = executor.generator
        let fixed: Int
        let promptTokens: Int
        let bodyTokens: Int
        do {
            fixed = try await instructionTokens(instructions, executor: executor)
            promptTokens = try await executor.tokenCount(for: .prompt(prompt))
            bodyTokens = body.isEmpty ? 0 : min(try await executor.tokenCount(for: .prompt(body)), promptTokens)
        } catch {
            return .tokenCountFailed(error)
        }
        let contextSize = generator.contextSize
        let input = BudgetInput(
            task: task, contextSize: contextSize, fixedInstructionTokens: fixed,
            promptTokens: promptTokens, bodyTokens: bodyTokens, schemaTokens: schemaTokens
        )
        var measures: [String: Double] = [
            "budget.contextSize": Double(contextSize),
            "budget.fixedInstructionTokens": Double(fixed),
            "budget.promptTokens": Double(promptTokens),
            "budget.bodyTokens": Double(bodyTokens),
            "budget.schemaTokens": Double(schemaTokens),
        ]
        switch configuration.budgeter.decide(input) {
        case .fits(let maximum):
            measures["budget.maxResponseTokens"] = Double(maximum)
            return .fits(maximumResponseTokens: maximum, inputTokens: fixed + promptTokens + schemaTokens, measures: measures)
        case .needsChunking(let maxBody):
            measures["budget.maxBodyTokens"] = Double(maxBody)
            return .needsChunking(maxBodyTokens: maxBody, measures: measures)
        case .impossible(let reason):
            if reason != .invalidInput, reason != .unknownTask,
               let stripped = promptWithoutCustomInstruction {
                do {
                    let count = try await executor.tokenCount(for: .prompt(stripped))
                    if configuration.budgeter.customInstructionPreventsMinimumBody(input, promptTokensWithoutInstruction: count) {
                        return .impossible(.customInstructionTooLong, measures: measures)
                    }
                } catch { return .tokenCountFailed(error) }
            }
            return .impossible(reason, measures: measures)
        }
    }
}

