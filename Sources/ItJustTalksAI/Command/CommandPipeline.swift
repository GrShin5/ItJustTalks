import Foundation
import FoundationModels

/// One AI-command request (§3.2). Contains user text: never log instances.
public struct CommandInput: Sendable {
    /// Spoken instruction, with the spoken output-language directive already removed by the caller.
    public var spokenInstruction: String
    /// Target text fixed at recording start (selection or clipboard). `nil`: a general request.
    public var target: String?
    /// AI-command custom instruction. Passed as a style reference only; it never decides the task,
    /// the destination or permissions.
    public var customInstruction: String?
    /// Enabled dictionary entries. The pipeline selects the relevant ones (`DictionarySelector`).
    public var dictionaryEntries: [DictionaryEntry]
    /// Language of the fixed prompts (follows the STT language, G1).
    public var promptLanguage: PromptLanguage
    /// Output language the speaker asked for in this request. Always applied.
    public var outputLanguage: OutputLanguage?
    /// Output language from the saved setting. Applied except for translation, whose target language is the
    /// one named in the spoken instruction.
    public var settingsOutputLanguage: OutputLanguage?

    public init(
        spokenInstruction: String,
        target: String?,
        customInstruction: String? = nil,
        dictionaryEntries: [DictionaryEntry] = [],
        promptLanguage: PromptLanguage,
        outputLanguage: OutputLanguage? = nil,
        settingsOutputLanguage: OutputLanguage? = nil
    ) {
        self.spokenInstruction = spokenInstruction
        self.target = target
        self.customInstruction = customInstruction
        self.dictionaryEntries = dictionaryEntries
        self.promptLanguage = promptLanguage
        self.outputLanguage = outputLanguage
        self.settingsOutputLanguage = settingsOutputLanguage
    }

    public var hasTarget: Bool { target != nil }
}

/// Deterministic and classified routing of one AI command (§3.2 steps 1–3 and 5). No text.
public struct CommandRouting: Sendable, Hashable {
    /// Step 2: from the spoken instruction only.
    public var outputIntent: CommandOutputIntent
    /// Step 1: the Web pre-check fired (no classification call was made).
    public var requiresWebPrecheck: Bool
    public var hasTarget: Bool
    /// Task type before the deterministic override: the classifier's answer, `.requires_web` when the pre-check
    /// fired, `.translate` for a pure translation instruction (no classifier call), `.answer_question` on the
    /// parse fallback. `nil` when the classification did not complete.
    public var classifiedTaskType: ClassifiedTaskType?
    /// The classifier's `isReplacementArtifact`, or true for a deterministic pure translation.
    /// Recorded only; the kind does not trust it.
    public var classifierReplacement: Bool?
    /// The classification could not be parsed and fell back to a plain answer (§6.4).
    public var classifierFallback: Bool
    /// Task type after `CommandRouter.adjustedTaskType`.
    public var taskType: ClassifiedTaskType?
    /// Step 5 (`CommandRouter.deriveKind`). `nil` when the routing did not complete.
    public var kind: CommandKind?

    public init(outputIntent: CommandOutputIntent, requiresWebPrecheck: Bool, hasTarget: Bool) {
        self.outputIntent = outputIntent
        self.requiresWebPrecheck = requiresWebPrecheck
        self.hasTarget = hasTarget
        self.classifierFallback = false
    }
}

/// Result state of an AI command. Only `complete` may be routed automatically (replacement or insertion);
/// everything else is shown in the result window and never touches the selection (CMD-09).
public enum CommandStatus: Sendable, Hashable {
    /// For `.content` / `.answer` the text is generated and validated. For `.clarification`, `.refusal` and
    /// `.requiresWeb` nothing is generated (`text == nil`): the app shows its fixed message.
    case complete
    case needsReview([ValidationReason])
    case failed(AIFailureReason)
}

/// Non-content diagnostics of one AI command: codes, counts, token numbers and timings only.
public struct CommandDiagnostics: Sendable, Hashable {
    public var promptKeys: [String]
    public var variantName: String?
    public var contextSize: Int
    public var calls: [GenerationCallRecord]
    /// Numeric measures (`budget.*`; in `CommandResult`, the classification's are prefixed `classification.`).
    public var measures: [String: Double]
    public var dictionarySelected: Int
    public var dictionaryOmitted: Int
    /// A request could not fit its context budget.
    public var budgetStop: CleanupBudgetStop?
    /// Generation or token-count failure that ended the stage.
    public var failure: AIFailure?
    /// Validator report of the generated text (nil when nothing was generated).
    public var validation: ValidationReport?

    init(generator: any TextGenerating) {
        promptKeys = []
        variantName = generator.variantName
        contextSize = generator.contextSize
        calls = []
        measures = [:]
        dictionarySelected = 0
        dictionaryOmitted = 0
    }
}

public struct CommandRoutingStage: Sendable {
    public var routing: CommandRouting
    public var diagnostics: CommandDiagnostics
}

public struct CommandGenerationStage: Sendable {
    public var task: AITask
    /// Generated text whenever the generation succeeded (also when validation failed). User text: never log.
    public var text: String?
    public var status: CommandStatus
    public var diagnostics: CommandDiagnostics
    public var chunking: ChunkingSummary? = nil
}

public struct CommandResult: Sendable {
    public var routing: CommandRouting
    /// Generated text (see `CommandStatus`). Route it automatically only when `status == .complete`.
    public var text: String?
    public var status: CommandStatus
    public var diagnostics: CommandDiagnostics
    public var chunking: ChunkingSummary? = nil
}

/// The production AI-command flow (§3.2), shared by the app and `afm-eval`:
/// Web pre-check and output intent (deterministic, spoken instruction only) → task classification (small
/// structured generation that sees the spoken instruction and whether a target exists, never the target) →
/// deterministic task-type override and kind → task-specific plain generation (target passed as data) →
/// `ResultValidator`.
///
/// Clarification, refusal and Web-required kinds are not generated. Requests exceeding the chunking limits
/// fail with `.contextSizeExceeded` (no partial output). Never logs.
public final class CommandPipeline: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var budgeter: ContextBudgeter
        public var validator: ResultValidator
        /// Whether dictionary memos are rendered (plan default: on).
        public var includeDictionaryMemo: Bool
        /// Evaluation knob: force one guardrail mode instead of the per-task decision (`AITask.guardrails`).
        public var guardrailsOverride: GuardrailsMode?

        public init(
            budgeter: ContextBudgeter = ContextBudgeter(),
            validator: ResultValidator = ResultValidator(),
            includeDictionaryMemo: Bool = true,
            guardrailsOverride: GuardrailsMode? = nil
        ) {
            self.budgeter = budgeter
            self.validator = validator
            self.includeDictionaryMemo = includeDictionaryMemo
            self.guardrailsOverride = guardrailsOverride
        }
    }

    public let configuration: Configuration
    private let selector = DictionarySelector()
    private let tokens: StageTokenBudget

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.tokens = StageTokenBudget(budgeter: configuration.budgeter)
    }

    // MARK: - Entry points

    /// Runs the command as one interactive operation of `coordinator` (deadline `DeadlinePolicy.aiCommand`).
    public func run(
        _ input: CommandInput,
        operation: UUID,
        coordinator: GenerationCoordinator,
        deadline: DeadlinePolicy = .aiCommand,
        progress: (@Sendable (ChunkProgress) -> Void)? = nil
    ) async -> CoordinatedOutcome<CommandResult> {
        await coordinator.perform(operation: operation, priority: .interactive, deadline: deadline) { context in
            await self.run(input, using: context, progress: progress)
        }
    }

    /// Routing, then (for `.content` / `.answer`) the task-specific generation.
    public func run(_ input: CommandInput, using executor: some GenerationExecuting,
                    progress: (@Sendable (ChunkProgress) -> Void)? = nil) async -> CommandResult {
        let routingStage = await route(input, using: executor)
        let routing = routingStage.routing
        var diagnostics = routingStage.diagnostics
        diagnostics.measures = Dictionary(uniqueKeysWithValues: diagnostics.measures.map { ("classification.\($0.key)", $0.value) })

        func failed(_ reason: AIFailureReason) -> CommandResult {
            CommandResult(routing: routing, text: nil, status: .failed(reason), diagnostics: diagnostics)
        }
        if routingStage.diagnostics.budgetStop != nil { return failed(.contextSizeExceeded) }
        if let failure = routingStage.diagnostics.failure { return failed(AIFailureReason(failure)) }
        guard let kind = routing.kind, let taskType = routing.taskType else { return failed(.generationError) }
        switch kind {
        case .clarification, .refusal, .requiresWeb:
            return CommandResult(routing: routing, text: nil, status: .complete, diagnostics: diagnostics)
        case .content, .answer:
            break
        }
        guard let task = taskType.generationTask else { return failed(.generationError) }
        if Task.isCancelled { return failed(.cancelled) }

        let generation = await generate(task, input, using: executor, progress: progress)
        let stage = generation.diagnostics
        diagnostics.promptKeys += stage.promptKeys
        diagnostics.calls += stage.calls
        diagnostics.measures.merge(stage.measures) { _, new in new }
        diagnostics.dictionarySelected = stage.dictionarySelected
        diagnostics.dictionaryOmitted = stage.dictionaryOmitted
        diagnostics.budgetStop = stage.budgetStop
        diagnostics.failure = stage.failure
        diagnostics.validation = stage.validation
        return CommandResult(routing: routing, text: generation.text, status: generation.status, diagnostics: diagnostics, chunking: generation.chunking)
    }

    /// Steps 1, 2, 3 and 5: Web pre-check, output intent, classification, override and kind.
    public func route(_ input: CommandInput, using executor: some GenerationExecuting) async -> CommandRoutingStage {
        let instruction = input.spokenInstruction
        let hasTarget = input.hasTarget
        var routing = CommandRouting(
            outputIntent: CommandRouter.outputIntent(spokenInstruction: instruction),
            requiresWebPrecheck: CommandRouter.requiresWeb(spokenInstruction: instruction, hasTarget: hasTarget),
            hasTarget: hasTarget
        )
        var diagnostics = CommandDiagnostics(generator: executor.generator)

        let classified: ClassifiedTaskType
        if hasTarget, case .pureTranslation = TranslationIntent.parse(instruction) {
            classified = .translate
            routing.classifierReplacement = true
        } else if routing.requiresWebPrecheck {
            classified = .requires_web
        } else {
            let language = input.promptLanguage
            let template = PromptCatalog.template(.taskClassifier, language: language)
            diagnostics.promptKeys.append(template.key)
            let prompt = PromptAssembler.taskClassifierPrompt(spokenInstruction: instruction, hasTarget: hasTarget, language: language)
            let schemaTokens = (try? await tokens.schemaTokens(TaskClassification.self, executor: executor)) ?? 0
            let budget = await tokens.budget(
                task: .taskClassification, instructions: template.text, prompt: prompt, body: "",
                schemaTokens: schemaTokens, executor: executor
            )
            guard let (maxTokens, inputTokens) = Self.accept(budget, into: &diagnostics) else {
                return CommandRoutingStage(routing: routing, diagnostics: diagnostics)
            }
            let request = makeRequest(task: .taskClassification, instructions: template.text, prompt: prompt, maximumResponseTokens: maxTokens)
            let start = ContinuousClock.now
            do {
                let generated = try await executor.generate(request, generating: TaskClassification.self, inputTokens: inputTokens)
                diagnostics.calls.append(GenerationCallRecord(
                    stage: .taskClassification, latency: generated.latency, usage: generated.usage,
                    isTruncated: generated.isTruncated, failure: nil
                ))
                guard !generated.isTruncated else {
                    diagnostics.failure = .other(code: "classificationTruncated")
                    return CommandRoutingStage(routing: routing, diagnostics: diagnostics)
                }
                classified = generated.value.taskType
                routing.classifierReplacement = generated.value.isReplacementArtifact
            } catch .structuredParsingFailed {
                diagnostics.calls.append(GenerationCallRecord(
                    stage: .taskClassification, latency: ContinuousClock.now - start, usage: nil, isTruncated: false,
                    failure: .structuredParsingFailed
                ))
                // §6.4: an unparseable classification falls back to a plain answer (shown, never replacing).
                routing.classifierFallback = true
                routing.classifierReplacement = false
                classified = .answer_question
            } catch {
                diagnostics.calls.append(GenerationCallRecord(
                    stage: .taskClassification, latency: ContinuousClock.now - start, usage: nil, isTruncated: false,
                    failure: error
                ))
                diagnostics.failure = error
                return CommandRoutingStage(routing: routing, diagnostics: diagnostics)
            }
        }
        routing.classifiedTaskType = classified
        // The classifier's isReplacementArtifact is only recorded; the kind table does not trust it.
        let type = CommandRouter.adjustedTaskType(classified, spokenInstruction: instruction, hasTarget: hasTarget)
        routing.taskType = type
        routing.kind = CommandRouter.deriveKind(taskType: type, hasTarget: hasTarget, spokenInstruction: instruction)
        return CommandRoutingStage(routing: routing, diagnostics: diagnostics)
    }

    /// Step 4: the task-specific plain generation of one executable task, then the validator.
    public func generate(_ task: AITask, _ input: CommandInput, using executor: some GenerationExecuting,
                         progress: (@Sendable (ChunkProgress) -> Void)? = nil) async -> CommandGenerationStage {
        let language = input.promptLanguage
        let template = PromptCatalog.template(PromptID(task: task), language: language)
        var diagnostics = CommandDiagnostics(generator: executor.generator)
        diagnostics.promptKeys = [template.key]
        func stage(_ text: String?, _ status: CommandStatus) -> CommandGenerationStage {
            CommandGenerationStage(task: task, text: text, status: status, diagnostics: diagnostics)
        }

        let source = input.target ?? ""
        let outputLanguage = resolvedOutputLanguage(task, input)
        // Names may be mis-recognized in the spoken instruction or written differently in the target.
        let selection = selector.select(
            entries: input.dictionaryEntries,
            text: [input.spokenInstruction, input.target].compactMap { $0 }.joined(separator: "\n"),
            options: DictionarySelectionOptions(includeMemo: configuration.includeDictionaryMemo, promptLanguage: language)
        )
        diagnostics.dictionarySelected = selection.selected.count
        diagnostics.dictionaryOmitted = selection.omittedCount
        let style = input.customInstruction?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = PromptAssembler.taskPrompt(
            spokenInstruction: input.spokenInstruction, target: input.target, dictionaryHints: selection.hints,
            stylePreferences: (style?.isEmpty ?? true) ? nil : style, outputLanguage: outputLanguage, language: language
        )

        let budget = await tokens.budget(
            task: task, instructions: template.text, prompt: prompt, body: source,
            promptWithoutCustomInstruction: (style?.isEmpty ?? true) ? nil : PromptAssembler.taskPrompt(
                spokenInstruction: input.spokenInstruction, target: input.target, dictionaryHints: selection.hints,
                stylePreferences: nil, outputLanguage: outputLanguage, language: language
            ), executor: executor
        )
        if case .needsChunking(let target, _) = budget {
            switch task {
            case .proofreadRewrite, .transform, .translate, .summarize, .extract, .explainAnalyze: break
            default: return stage(nil, .failed(.contextSizeExceeded))
            }
            await executor.extendOperationDeadlineForLongText()
            return await chunked(task, input, selection: selection, target: target, using: executor, progress: progress)
        }
        guard let (maxTokens, inputTokens) = Self.accept(budget, into: &diagnostics) else {
            if diagnostics.budgetStop == .impossible(.customInstructionTooLong) {
                return stage(nil, .failed(.customInstructionTooLong))
            }
            if diagnostics.budgetStop != nil { return stage(nil, .failed(.contextSizeExceeded)) }
            return stage(nil, .failed(AIFailureReason(diagnostics.failure ?? .other(code: "budget"))))
        }

        let request = makeRequest(task: task, instructions: template.text, prompt: prompt, maximumResponseTokens: maxTokens)
        // A translate retry rephrases the request explicitly in the target's prompt language: the on-device model
        // answers an identical request identically, so repeating it cannot fix an untranslated echo.
        let retry = task == .translate ? translationRetry(input, selection: selection, style: style,
            outputLanguage: outputLanguage, maximumResponseTokens: maxTokens) : nil
        let protectedInstructions = [template.text] + (retry.map { [$0.instructions] } ?? [])
        let terms = DictionaryValidationTerms(selection, handsFree: false)
        let generated: GenerationResult
        let report: ValidationReport
        do {
            (generated, report) = try await generateValidated(request, retryRequest: retry?.request, task: task,
                inputTokens: inputTokens, using: executor, diagnostics: &diagnostics) { output in
                configuration.validator.evaluate(ValidationInput(
                    task: task, source: source, output: output.text, isTruncated: output.isTruncated,
                    protectedInstructions: protectedInstructions, userSuppliedTexts: [input.spokenInstruction],
                    allowedNewTerms: terms.allowedNewTerms, reviewOnlyTerms: terms.reviewOnlyTerms,
                    selectedDictionary: terms.selectedDictionary,
                    expectedOutputLanguage: outputLanguage?.code, handsFree: false))
            }
        } catch {
            diagnostics.failure = error
            return stage(nil, .failed(AIFailureReason(error)))
        }
        diagnostics.validation = report
        switch report.outcome {
        case .complete: return stage(generated.text, .complete)
        case .needsReview(let reasons): return stage(generated.text, .needsReview(reasons))
        case .failed: return stage(generated.text, .failed(.validationFailed))
        }
    }

    private func resolvedOutputLanguage(_ task: AITask, _ input: CommandInput) -> OutputLanguage? {
        if task == .translate, let intent = TranslationIntent.parse(input.spokenInstruction) {
            return intent.language
        }
        return input.outputLanguage ?? (task == .translate ? nil : input.settingsOutputLanguage)
    }

    /// One extra attempt for an unchanged/wrong-language translation; same budget and operation deadline.
    /// The explicit second attempt for an untranslated or wrong-language translate result.
    private func translationRetry(
        _ input: CommandInput, selection: DictionarySelection, style: String?,
        outputLanguage: OutputLanguage?, maximumResponseTokens: Int, target: String? = nil
    ) -> (request: GenerationRequest, instructions: String)? {
        guard let outputLanguage else { return nil }
        let code = outputLanguage.code.lowercased()
        let language: PromptLanguage = code.hasPrefix("en") ? .en : (code.hasPrefix("ja") ? .ja : input.promptLanguage)
        let name: String
        let instruction: String
        switch (language, code.prefix(2)) {
        case (.en, "en"): name = "English"; instruction = "Translate the Target text into English."
        case (.ja, "ja"): name = "日本語"; instruction = "対象本文を日本語に翻訳してください。"
        case (.en, _): name = outputLanguage.name; instruction = "Translate the Target text into \(outputLanguage.name)."
        case (.ja, _): name = outputLanguage.name; instruction = "対象本文を\(outputLanguage.name)に翻訳してください。"
        }
        let template = PromptCatalog.template(PromptID(task: .translate), language: language)
        let prompt = PromptAssembler.taskPrompt(
            spokenInstruction: instruction, target: target ?? input.target, dictionaryHints: selection.hints,
            stylePreferences: (style?.isEmpty ?? true) ? nil : style,
            outputLanguage: OutputLanguage(code: outputLanguage.code, name: name), language: language
        )
        return (makeRequest(task: .translate, instructions: template.text, prompt: prompt,
                            maximumResponseTokens: maximumResponseTokens), template.text)
    }

    private func generateValidated(
        _ request: GenerationRequest, retryRequest: GenerationRequest? = nil, task: AITask, inputTokens: Int,
        using executor: some GenerationExecuting,
        diagnostics: inout CommandDiagnostics,
        validate: (GenerationResult) -> ValidationReport
    ) async throws(AIFailure) -> (GenerationResult, ValidationReport) {
        for attempt in 0...1 {
            let start = ContinuousClock.now
            let generated: GenerationResult
            do throws(AIFailure) {
                let activeRequest = attempt == 0 ? request : (retryRequest ?? request)
                var activeTokens = inputTokens
                if attempt > 0, retryRequest != nil {
                    let fixed = try await executor.tokenCount(for: .instructions(activeRequest.instructions))
                    let prompt = try await executor.tokenCount(for: .prompt(activeRequest.prompt))
                    let context = executor.generator.contextSize
                    guard fixed + prompt + (activeRequest.maximumResponseTokens ?? 0) + configuration.budgeter.overhead(contextSize: context) <= context else {
                        throw AIFailure.contextSizeExceeded(contextSize: context, tokenCount: fixed + prompt)
                    }
                    activeTokens = fixed + prompt
                }
                generated = try await executor.generate(activeRequest, inputTokens: activeTokens)
            } catch {
                diagnostics.calls.append(GenerationCallRecord(stage: .commandGeneration,
                    latency: ContinuousClock.now - start, usage: nil, isTruncated: false, failure: error))
                throw error
            }
            diagnostics.calls.append(GenerationCallRecord(stage: .commandGeneration, latency: generated.latency,
                usage: generated.usage, isTruncated: generated.isTruncated, failure: nil))
            let report = validate(generated)
            diagnostics.validation = report
            let retry = task == .translate && report.outcome.reasons.contains {
                switch $0 {
                case .translationUnchanged, .languageMismatch: return true
                default: return false
                }
            }
            if attempt == 1 || !retry { return (generated, report) }
            if Task.isCancelled { throw .cancelled }
        }
        throw .other(code: "translationRetry")
    }

    private func chunked(_ task: AITask, _ input: CommandInput, selection: DictionarySelection,
                         target: Int, using executor: some GenerationExecuting,
                         progress: (@Sendable (ChunkProgress) -> Void)?) async -> CommandGenerationStage {
        let source = input.target ?? ""
        let template = PromptCatalog.template(PromptID(task: task), language: input.promptLanguage)
        let outputLanguage = resolvedOutputLanguage(task, input)
        let style = input.customInstruction?.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = DictionaryValidationTerms(selection, handsFree: false)
        let mergeStages = (task == .summarize || task == .explainAnalyze) ? 1 : 0
        var diagnostics = CommandDiagnostics(generator: executor.generator)
        diagnostics.promptKeys = [template.key]
        diagnostics.dictionarySelected = selection.selected.count
        diagnostics.dictionaryOmitted = selection.omittedCount
        var summary = ChunkingSummary(chunkCount: 0, mergeStages: mergeStages)
        func stage(_ text: String?, _ status: CommandStatus) -> CommandGenerationStage {
            var recorded = diagnostics
            recorded.measures.merge(summary.measures) { _, new in new }
            return CommandGenerationStage(task: task, text: text, status: status, diagnostics: recorded, chunking: summary)
        }
        func prompt(_ body: String, withoutStyle: Bool = false) -> String {
            PromptAssembler.taskPrompt(spokenInstruction: input.spokenInstruction, target: body,
                dictionaryHints: selection.hints, stylePreferences: withoutStyle ? nil : style,
                outputLanguage: outputLanguage, language: input.promptLanguage)
        }
        func check(_ body: String) async -> StageTokenBudget.Decision {
            await tokens.budget(task: task, instructions: template.text, prompt: prompt(body), body: body,
                promptWithoutCustomInstruction: (style?.isEmpty ?? true) ? nil : prompt(body, withoutStyle: true), executor: executor)
        }
        func validationInput(_ output: String, source: String, isTruncated: Bool = false) -> ValidationInput {
            ValidationInput(task: task, source: source, output: output,
                isTruncated: isTruncated, protectedInstructions: [template.text] +
                    (translationRetry(input, selection: selection, style: style, outputLanguage: outputLanguage,
                        maximumResponseTokens: 1, target: source).map { [$0.instructions] } ?? []),
                userSuppliedTexts: [input.spokenInstruction], allowedNewTerms: terms.allowedNewTerms,
                reviewOnlyTerms: terms.reviewOnlyTerms, selectedDictionary: terms.selectedDictionary,
                expectedOutputLanguage: outputLanguage?.code, handsFree: false)
        }
        func validate(_ output: GenerationResult, source: String) -> ValidationReport {
            configuration.validator.evaluate(validationInput(output.text, source: source, isTruncated: output.isTruncated))
        }
        diagnostics.budgetStop = .needsChunking(maxBodyTokens: target)
        var pending: [PlannedChunk]
        do {
            guard case .chunks(let plan) = try await ChunkPlanner().plan(source, maxBodyTokens: target, balanced: true,
                maximumChunks: 16 - mergeStages, using: executor), !plan.isEmpty else { return stage(nil, .failed(.contextSizeExceeded)) }
            pending = plan
            diagnostics.budgetStop = nil
        } catch { diagnostics.failure = error; return stage(nil, .failed(AIFailureReason(error))) }
        // Resolve every complete prompt before announcing the fixed progress total.
        var budgets: [(Int, Int)] = []
        var i = 0
        while i < pending.count {
            if Task.isCancelled { return stage(nil, .failed(.cancelled)) }
            let chunk = pending[i]
            let decision = await check(chunk.source)
            switch decision {
            case .fits(let maximum, let count, let measures):
                diagnostics.measures.merge(measures) { _, new in new }
                budgets.append((maximum, count))
                i += 1
            case .needsChunking(let smaller, _):
                guard smaller >= configuration.budgeter.configuration.minimumChunkBodyTokens else { return stage(nil, .failed(.contextSizeExceeded)) }
                do {
                    guard case .chunks(let pieces) = try await ChunkPlanner().plan(chunk.source, maxBodyTokens: smaller,
                        maximumChunks: 16 - mergeStages - pending.count + 1, using: executor), pieces.count > 1 else {
                        return stage(nil, .failed(.contextSizeExceeded))
                    }
                    pending.replaceSubrange(i...i, with: pieces.map {
                        PlannedChunk(source: $0.source, sourceRange: ($0.sourceRange.lowerBound + chunk.sourceRange.lowerBound)..<($0.sourceRange.upperBound + chunk.sourceRange.lowerBound))
                    })
                } catch { diagnostics.failure = error; return stage(nil, .failed(AIFailureReason(error))) }
            case .impossible(let reason, _):
                diagnostics.budgetStop = .impossible(reason)
                return stage(nil, .failed(reason == .customInstructionTooLong ? .customInstructionTooLong : .contextSizeExceeded))
            case .tokenCountFailed(let failure): diagnostics.failure = failure; return stage(nil, .failed(AIFailureReason(failure)))
            }
        }
        summary.chunkCount = pending.count
        let total = pending.count + mergeStages
        progress?(ChunkProgress(completed: 0, total: total))
        var chunks: [ChunkResult] = []
        for (index, chunk) in pending.enumerated() {
            if Task.isCancelled { return stage(nil, .failed(.cancelled)) }
            let generated: GenerationResult
            let report: ValidationReport
            do {
                (generated, report) = try await generateValidated(makeRequest(task: task, instructions: template.text,
                    prompt: prompt(chunk.source), maximumResponseTokens: budgets[index].0),
                    retryRequest: task == .translate ? translationRetry(input, selection: selection, style: style,
                        outputLanguage: outputLanguage, maximumResponseTokens: budgets[index].0, target: chunk.source)?.request : nil,
                    task: task, inputTokens: budgets[index].1, using: executor, diagnostics: &diagnostics) {
                    validate($0, source: chunk.source)
                }
            } catch {
                diagnostics.failure = error
                progress?(ChunkProgress(completed: index + 1, total: total))
                return stage(nil, .failed(AIFailureReason(error)))
            }
            chunks.append(ChunkResult(index: index, sourceRange: chunk.sourceRange, source: chunk.source,
                output: generated.text, outcome: report.outcome))
            progress?(ChunkProgress(completed: index + 1, total: total))
            if case .failed = report.outcome {
                diagnostics.validation = ValidationReport(outcome: .failed([.chunkFailed(index: index)] + report.outcome.reasons), metrics: report.metrics)
                return stage(ChunkPlanner.joined(chunks), .failed(.validationFailed))
            }
        }
        var outcome = ChunkValidator(thresholds: configuration.validator.thresholds).validate(chunks, sourceLength: source.count, spokenCorrections: false)
        var output = ChunkPlanner.joined(chunks)
        if [.proofreadRewrite, .translate, .transform].contains(task) {
            let reasons = configuration.validator.joinedNumberReasons(validationInput(output, source: source))
            if !reasons.isEmpty {
                if case .failed = outcome {} else { outcome = .needsReview(outcome.reasons + reasons) }
            }
        }
        if task == .extract {
            let merged = Self.mergeExtractions(chunks)
            output = merged.map(\.text).joined(separator: "\n")
            diagnostics.measures["chunk.extractionLines"] = Double(merged.count)
            for index in pending.indices {
                diagnostics.measures["chunk.extractionLines.\(index)"] = Double(merged.filter { $0.chunkIndex == index }.count)
            }
        }
        if mergeStages == 1 {
            let mergeBody = chunks.map(\.output).joined(separator: "\n")
            let decision = await check(mergeBody)
            guard let (maximum, count) = Self.accept(decision, into: &diagnostics) else {
                if let failure = diagnostics.failure { return stage(nil, .failed(AIFailureReason(failure))) }
                return stage(nil, .failed(.contextSizeExceeded))
            }
            if Task.isCancelled { return stage(nil, .failed(.cancelled)) }
            let start = ContinuousClock.now
            let generated: GenerationResult
            do {
                generated = try await executor.generate(makeRequest(task: task, instructions: template.text,
                    prompt: prompt(mergeBody), maximumResponseTokens: maximum), inputTokens: count)
            } catch {
                diagnostics.calls.append(GenerationCallRecord(stage: .commandGeneration, latency: ContinuousClock.now - start,
                    usage: nil, isTruncated: false, failure: error))
                diagnostics.failure = error
                progress?(ChunkProgress(completed: total, total: total))
                return stage(nil, .failed(AIFailureReason(error)))
            }
            diagnostics.calls.append(GenerationCallRecord(stage: .commandGeneration, latency: generated.latency,
                usage: generated.usage, isTruncated: generated.isTruncated, failure: nil))
            output = generated.text
            let merged = validate(generated, source: source).outcome
            switch (outcome, merged) {
            case (.failed, _), (_, .failed): outcome = .failed(outcome.reasons + merged.reasons)
            case (.needsReview, _), (_, .needsReview): outcome = .needsReview(outcome.reasons + merged.reasons)
            default: break
            }
            progress?(ChunkProgress(completed: total, total: total))
        }
        diagnostics.validation = ValidationReport(outcome: outcome, metrics: ValidationMetrics())
        switch outcome {
        case .complete: return stage(output, .complete)
        case .needsReview(let reasons): return stage(output, .needsReview(reasons))
        case .failed: return stage(output, .failed(.validationFailed))
        }
    }

    struct ExtractionLine {
        var text: String
        var chunkIndex: Int
    }

    /// Merges per-chunk extractions. An item is an unindented bullet/number line with every following line up to the
    /// next one (indented sub-items and attribute lines stay with their item); without such markers, blank-line
    /// separated blocks (or single lines) are items. Only items repeated from an EARLIER chunk are removed, so
    /// nothing a single chunk listed is dropped.
    static func mergeExtractions(_ chunks: [ChunkResult]) -> [ExtractionLine] {
        let itemStart = #"^(?:[-・*•]+|[0-9０-９]+[.)、．）])\s*"#
        let anyMarker = #"^\s*(?:[-・*•]+|[0-9０-９]+[.)、．）])\s*"#
        func normalized(_ item: String) -> String {
            item.precomposedStringWithCompatibilityMapping.components(separatedBy: .newlines).map {
                $0.replacingOccurrences(of: anyMarker, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }
        var seenEarlier: Set<String> = []
        var items: [ExtractionLine] = []
        for chunk in chunks {
            let lines = chunk.output.components(separatedBy: .newlines)
            let hasItemStarts = lines.contains { $0.range(of: itemStart, options: .regularExpression) != nil }
            let hasBlankSeparators = lines.contains(where: isBlank)
            var grouped: [String] = []
            var open = false
            for line in lines {
                if isBlank(line) {
                    if !hasItemStarts { open = false }
                    continue
                }
                let starts = hasItemStarts ? line.range(of: itemStart, options: .regularExpression) != nil : !(hasBlankSeparators && open)
                if starts || grouped.isEmpty {
                    grouped.append(line)
                } else {
                    grouped[grouped.count - 1] += "\n" + line
                }
                open = true
            }
            var seenHere: Set<String> = []
            for item in grouped {
                let key = normalized(item)
                guard !key.isEmpty, !seenEarlier.contains(key) else { continue }
                seenHere.insert(key)
                items.append(ExtractionLine(text: item, chunkIndex: chunk.index))
            }
            seenEarlier.formUnion(seenHere)
        }
        let emptyItems: Set<String> = ["該当なし", "なし", "none", "n/a"]
        if items.contains(where: { !emptyItems.contains(normalized($0.text).lowercased()) }) {
            items.removeAll { emptyItems.contains(normalized($0.text).lowercased()) }
        }
        return items
    }

    // MARK: - Helpers

    private func makeRequest(task: AITask, instructions: String, prompt: String, maximumResponseTokens: Int) -> GenerationRequest {
        GenerationRequest(
            instructions: instructions, prompt: prompt, maximumResponseTokens: maximumResponseTokens,
            greedy: true, guardrails: configuration.guardrailsOverride ?? task.guardrails
        )
    }

    /// Records the budget's measures and stop/failure; returns the response cap and input tokens when it fits.
    private static func accept(_ budget: StageTokenBudget.Decision, into diagnostics: inout CommandDiagnostics) -> (Int, Int)? {
        switch budget {
        case .fits(let maximum, let inputTokens, let measures):
            diagnostics.measures.merge(measures) { _, new in new }
            return (maximum, inputTokens)
        case .needsChunking(let maxBody, let measures):
            diagnostics.measures.merge(measures) { _, new in new }
            diagnostics.budgetStop = .needsChunking(maxBodyTokens: maxBody)
            return nil
        case .impossible(let reason, let measures):
            diagnostics.measures.merge(measures) { _, new in new }
            diagnostics.budgetStop = .impossible(reason)
            return nil
        case .tokenCountFailed(let failure):
            diagnostics.failure = failure
            return nil
        }
    }
}

/// §5.1 budget of one model call with the measures `afm-eval` records (`budget.*`), with cached instruction
/// and schema token counts.
final class StageTokenBudget: @unchecked Sendable {
    enum Decision {
        case fits(maximumResponseTokens: Int, inputTokens: Int, measures: [String: Double])
        case needsChunking(maxBodyTokens: Int, measures: [String: Double])
        case impossible(BudgetImpossibleReason, measures: [String: Double])
        case tokenCountFailed(AIFailure)
    }

    private let budgeter: ContextBudgeter
    private let lock = NSLock()
    private var instructionTokenCache: [String: Int] = [:]
    private var schemaTokenCache: [String: Int] = [:]

    init(budgeter: ContextBudgeter) {
        self.budgeter = budgeter
    }

    func schemaTokens<Output: Generable>(_ type: Output.Type, executor: some GenerationExecuting) async throws(AIFailure) -> Int {
        let key = String(describing: type)
        if let cached = lock.withLock({ schemaTokenCache[key] }) { return cached }
        let count = try await executor.schemaTokenCount(for: type)
        lock.withLock { schemaTokenCache[key] = count }
        return count
    }

    private func instructionTokens(_ text: String, executor: some GenerationExecuting) async throws(AIFailure) -> Int {
        if let cached = lock.withLock({ instructionTokenCache[text] }) { return cached }
        let count = try await executor.tokenCount(for: .instructions(text))
        lock.withLock { instructionTokenCache[text] = count }
        return count
    }

    func budget(
        task: AITask, instructions: String, prompt: String, body: String, schemaTokens: Int = 0,
        promptWithoutCustomInstruction: String? = nil,
        executor: some GenerationExecuting
    ) async -> Decision {
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
        let contextSize = executor.generator.contextSize
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
        switch budgeter.decide(input) {
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
                    if budgeter.customInstructionPreventsMinimumBody(input, promptTokensWithoutInstruction: count) {
                        return .impossible(.customInstructionTooLong, measures: measures)
                    }
                } catch { return .tokenCountFailed(error) }
            }
            return .impossible(reason, measures: measures)
        }
    }
}
