import Foundation
import ItJustTalksAI

/// What one case produced: the record plus optional output text for human review.
struct CaseOutcome: Sendable {
    var record: EvalRecord
    var output: String?
    var stageA: String? = nil
    var items: [String]? = nil
}

/// Per-category pipelines. They use the library only: PromptAssembler, ContextBudgeter (via `Harness`),
/// the generator, ResultValidator, CommandRouter and DictionarySelector. Cleanup and the AI-command routing and
/// generation run through the product pipelines (`CleanupPipeline`, `CommandPipeline`).
final class Pipelines: @unchecked Sendable {
    let harness: Harness
    let validator = ResultValidator()
    let selector = DictionarySelector()
    let commandMethod: CommandMethod
    let memo: Bool
    /// Cleanup runs through the product code: `CleanupPipeline` under a `GenerationCoordinator`.
    let evalGenerator: EvalGenerator
    let coordinator: GenerationCoordinator
    let cleanupPipeline: CleanupPipeline
    /// AI-command routing and generation run through the product code: `CommandPipeline`.
    let commandPipeline: CommandPipeline
    let optimizerPipeline: InstructionOptimizerPipeline

    init(harness: Harness) {
        self.harness = harness
        self.commandMethod = harness.options.commandMethod
        self.memo = harness.options.dictionaryMemo
        self.evalGenerator = EvalGenerator(harness: harness)
        self.coordinator = GenerationCoordinator(generator: evalGenerator)
        let guardrails = harness.options.guardrails
        self.cleanupPipeline = CleanupPipeline(configuration: .init(
            includeDictionaryMemo: harness.options.dictionaryMemo,
            guardrailsOverride: guardrails == .auto ? nil : guardrails.mode(for: .cleanup),
            editProjection: harness.options.projection
        ))
        self.commandPipeline = CommandPipeline(configuration: .init(
            includeDictionaryMemo: harness.options.dictionaryMemo,
            guardrailsOverride: guardrails == .auto ? nil : guardrails.mode(for: .cleanup)
        ))
        self.optimizerPipeline = InstructionOptimizerPipeline(configuration: .init(
            guardrailsOverride: guardrails == .auto ? nil : guardrails.mode(for: .instructionOptimization)
        ))
    }

    // MARK: - Shared helpers

    /// Prompt language for one case (`--prompt-lang auto`: the case language stands in for the STT setting).
    private func language(_ meta: CaseMeta) -> PromptLanguage {
        harness.options.promptLanguage.resolve(caseLang: meta.lang)
    }

    private func baseRecord(_ meta: CaseMeta, run: Int, prompts: [PromptTemplate]) -> EvalRecord {
        EvalRecord(
            id: meta.id, category: meta.category.rawValue, lang: meta.lang, critical: meta.critical, run: run,
            settings: harness.settings, model: harness.model, outcome: "ok", failureCode: nil,
            validator: nil, judge: nil, latencyMs: nil, cold: nil, inputTokens: nil, outputTokens: nil,
            truncated: false, promptKeys: prompts.map(\.key), routing: nil, measures: [:],
            dictionarySelected: nil, dictionaryOmitted: nil
        )
    }

    private func apply(_ accumulator: CallAccumulator, to record: inout EvalRecord) {
        guard accumulator.calls > 0 else { return }
        record.latencyMs = accumulator.latencyMs
        record.cold = accumulator.cold
        if accumulator.sawUsage {
            record.inputTokens = accumulator.inputTokens
            record.outputTokens = accumulator.outputTokens
        }
        record.truncated = accumulator.truncated
    }

    private static func reasonName(_ reason: ValidationReason) -> String {
        let text = String(describing: reason)
        if let index = text.firstIndex(of: "(") { return String(text[..<index]) }
        return text
    }

    private static func status(_ outcome: ValidationOutcome) -> String {
        switch outcome {
        case .complete: return "complete"
        case .needsReview: return "needsReview"
        case .failed: return "failed"
        }
    }

    private func validatorRecord(_ report: ValidationReport, into record: inout EvalRecord) {
        record.validator = ValidatorRecord(
            status: Self.status(report.outcome), reasons: report.outcome.reasons.map(Self.reasonName)
        )
        let metrics = report.metrics
        if let value = metrics.lengthRatio { record.measures["validator.lengthRatio"] = value }
        if let value = metrics.contentRetention { record.measures["validator.contentRetention"] = value }
        if let value = metrics.newContentRatio { record.measures["validator.newContentRatio"] = value }
        record.measures["validator.newNumberCount"] = Double(metrics.newNumberCount)
    }

    private func recordFailure(_ failure: AIFailure, into record: inout EvalRecord) {
        record.outcome = "failure"
        record.failureCode = failure.code
        let report = validator.validate(failure: failure)
        record.validator = ValidatorRecord(status: Self.status(report), reasons: report.reasons.map(Self.reasonName))
        record.judge = JudgeRecord(pass: false, failedChecks: ["generationFailed:\(failure.code)"])
    }

    private func recordBudgetStop(_ result: BudgetResult, into record: inout EvalRecord) -> Bool {
        switch result {
        case .fits(_, let measures):
            record.measures.merge(measures) { _, new in new }
            return false
        case .needsChunking(_, let measures):
            record.measures.merge(measures) { _, new in new }
            record.outcome = "needsChunking"
            return true
        case .impossible(let reason, let measures):
            record.measures.merge(measures) { _, new in new }
            record.outcome = "budgetImpossible"
            record.failureCode = reason
            record.judge = JudgeRecord(pass: false, failedChecks: ["budgetImpossible:\(reason)"])
            return true
        case .tokenCountFailed(let failure):
            recordFailure(failure, into: &record)
            return true
        }
    }

    private func outputLanguage(_ code: String, _ language: PromptLanguage) -> OutputLanguage? {
        switch (code, language) {
        case ("ja", .ja): return OutputLanguage(code: "ja", name: "日本語")
        case ("ja", .en): return OutputLanguage(code: "ja", name: "Japanese")
        case ("en", .ja): return OutputLanguage(code: "en", name: "英語")
        case ("en", .en): return OutputLanguage(code: "en", name: "English")
        default: return nil
        }
    }

    private func selectDictionary(
        _ entries: [DictionaryCaseEntry], text: String, language: PromptLanguage, into record: inout EvalRecord
    ) -> DictionarySelection {
        let selection = selector.select(
            entries: entries.map { DictionaryEntry(preferred: $0.preferred, readings: $0.readings, memo: $0.memo) },
            text: text,
            options: DictionarySelectionOptions(includeMemo: memo, promptLanguage: language)
        )
        record.dictionarySelected = selection.selected.count
        record.dictionaryOmitted = selection.omittedCount
        return selection
    }

    // MARK: - cleanup

    func cleanup(_ item: CleanupCase, run: Int) async -> CaseOutcome {
        let language = language(item.meta)
        let template = PromptCatalog.template(.cleanup, language: language)
        var record = baseRecord(item.meta, run: run, prompts: [template])
        let target = outputLanguage(item.outputLanguage, language)
        let input = CleanupInput(
            transcript: item.transcript, customInstruction: item.customInstruction,
            dictionaryEntries: item.dictionary.map { DictionaryEntry(preferred: $0.preferred, readings: $0.readings, memo: $0.memo) },
            promptLanguage: language, outputLanguage: target, handsFree: item.handsFree
        )
        // Stage A (self-corrections) when a cue is present; stage B is the normal cleanup of its result.
        evalGenerator.beginCase(structured: .json(Self.fakeStageAJSON(item)), text: .text(item.transcript))
        let outcome = await coordinator.perform(operation: UUID(), priority: .interactive, deadline: .cleanup) { context in
            let stage = await self.stageA(item, input: input, language: language, context: context)
            self.evalGenerator.setTextPlan(.text(stage.result.transcriptForCleanup))
            let result = await self.cleanupPipeline.cleanupStage(input, after: stage.result, using: context)
            return (stage.review, result)
        }
        guard case .delivered(let (review, result)) = outcome else {
            recordFailure(.cancelled, into: &record)
            return CaseOutcome(record: record, output: nil)
        }
        let diagnostics = result.diagnostics
        record.promptKeys = diagnostics.promptKeys
        record.measures.merge(diagnostics.measures) { _, new in new }
        record.dictionarySelected = diagnostics.dictionarySelected
        record.dictionaryOmitted = diagnostics.dictionaryOmitted
        var accumulator = CallAccumulator()
        let cold = evalGenerator.caseCold
        for call in diagnostics.calls {
            // Stage-A truncation is recorded in its measures only, not as the case's truncation.
            accumulator.add(
                latencyMs: harness.milliseconds(call.latency), usage: call.usage,
                truncated: call.stage == .cleanup && call.isTruncated, cold: cold
            )
        }

        switch diagnostics.budgetStop {
        case .needsChunking:
            record.outcome = "needsChunking"
            return CaseOutcome(record: record, output: nil)
        case .impossible(let reason):
            let code = String(describing: reason)
            record.outcome = "budgetImpossible"
            record.failureCode = code
            record.judge = JudgeRecord(pass: false, failedChecks: ["budgetImpossible:\(code)"])
            return CaseOutcome(record: record, output: nil)
        case nil:
            break
        }
        if let failure = diagnostics.failure {
            // A token-count failure stops before the cleanup call (no latency recorded, as before).
            if diagnostics.calls.contains(where: { $0.stage == .cleanup }) { apply(accumulator, to: &record) }
            recordFailure(failure, into: &record)
            return CaseOutcome(record: record, output: nil)
        }
        apply(accumulator, to: &record)
        guard let output = result.text, let report = diagnostics.validation else {
            recordFailure(.other(code: "missingOutput"), into: &record)
            return CaseOutcome(record: record, output: nil)
        }
        validatorRecord(report, into: &record)

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        record.judge = Judge.cleanup(item, output: trimmed)
        return CaseOutcome(record: record, output: output, stageA: review)
    }

    // MARK: - routing

    private static func classifiedToString(_ type: ClassifiedTaskType) -> String { type.rawValue }

    private static func intentString(_ intent: UnifiedOutputIntent) -> String {
        switch intent {
        case .automatic: return CommandOutputIntent.automatic.rawValue
        case .show_result: return CommandOutputIntent.showResult.rawValue
        case .insert_at_captured_target: return CommandOutputIntent.insertAtTarget.rawValue
        }
    }

    private static func unifiedIntentJSON(_ expected: String) -> String {
        switch expected {
        case "show_result": return "show_result"
        case "insert_at_target": return "insert_at_captured_target"
        default: return "automatic"
        }
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }

    func routing(_ item: RoutingCase, run: Int) async -> CaseOutcome {
        if commandMethod == .unified { return await unifiedRouting(item, run: run) }
        let hasTarget = item.target != nil
        let language = language(item.meta)
        let classifierTemplate = PromptCatalog.template(.taskClassifier, language: language)
        var record = baseRecord(item.meta, run: run, prompts: [classifierTemplate])

        // The product routing (`CommandPipeline.route`): Web pre-check, output intent, classification,
        // task-type override, then the kind table.
        let input = CommandInput(spokenInstruction: item.instruction, target: item.target, promptLanguage: language)
        let isContent = item.expectedKind == CommandKind.content.rawValue
        let fakeJSON = "{\"taskType\": \"\(item.expectedTaskType)\", \"isReplacementArtifact\": \(isContent)}"
        evalGenerator.beginCase(structured: .json(fakeJSON), text: .text(""))
        let outcome = await coordinator.perform(operation: UUID(), priority: .interactive, deadline: .aiCommand) { context in
            await self.commandPipeline.route(input, using: context)
        }
        guard case .delivered(let stage) = outcome else {
            recordFailure(.cancelled, into: &record)
            return CaseOutcome(record: record, output: nil)
        }
        let routing = stage.routing
        let diagnostics = stage.diagnostics
        let webPrecheck = routing.requiresWebPrecheck
        let predictedIntent: String? = routing.outputIntent.rawValue
        var accumulator = CallAccumulator()
        let cold = evalGenerator.caseCold
        for call in diagnostics.calls {
            accumulator.add(latencyMs: harness.milliseconds(call.latency), usage: call.usage, truncated: call.isTruncated, cold: cold)
        }
        record.measures.merge(diagnostics.measures) { _, new in new }
        if let stop = diagnostics.budgetStop {
            switch stop {
            case .needsChunking:
                record.outcome = "needsChunking"
            case .impossible(let reason):
                let code = String(describing: reason)
                record.outcome = "budgetImpossible"
                record.failureCode = code
                record.judge = JudgeRecord(pass: false, failedChecks: ["budgetImpossible:\(code)"])
            }
            record.routing = routingRecord(item, hasTarget, predictedIntent, nil, nil, webPrecheck, false)
            return CaseOutcome(record: record, output: nil)
        }
        if let failure = diagnostics.failure {
            // A token-count failure stops before the classification call (no latency recorded, as before).
            if !diagnostics.calls.isEmpty { apply(accumulator, to: &record) }
            recordFailure(failure, into: &record)
            record.routing = routingRecord(item, hasTarget, predictedIntent, nil, nil, webPrecheck, false)
            return CaseOutcome(record: record, output: nil)
        }
        apply(accumulator, to: &record)

        let predictedTask = routing.taskType?.rawValue
        let predictedKind = routing.kind?.rawValue
        var detail = webPrecheck ? "" : (routing.classifierFallback ? "fallback" : "separated")
        if let classified = routing.classifiedTaskType, let type = routing.taskType, type != classified { detail += " override" }
        record.routing = routingRecord(
            item, hasTarget, predictedIntent, predictedTask, predictedKind, webPrecheck, routing.classifierFallback
        )
        record.routing?.classifierTaskType = routing.classifiedTaskType?.rawValue
        record.routing?.classifierReplacement = routing.classifierReplacement
        return judgeRouting(item, record: record, intent: predictedIntent, task: predictedTask, kind: predictedKind, web: webPrecheck, detail: detail)
    }

    private func judgeRouting(
        _ item: RoutingCase, record: EvalRecord, intent: String?, task: String?, kind: String?, web: Bool, detail: String
    ) -> CaseOutcome {
        var record = record
        record.judge = Judge.routing(item, intent: intent, task: task, kind: kind)
        let summary = "intent=\(intent ?? "-") taskType=\(task ?? "-") kind=\(kind ?? "-") web=\(web) \(detail)"
        return CaseOutcome(record: record, output: summary)
    }

    /// V-07 comparison only (`--command-method unified`): one structured generation decides task, destination and
    /// body. Not a product path.
    private func unifiedRouting(_ item: RoutingCase, run: Int) async -> CaseOutcome {
        let hasTarget = item.target != nil
        let language = language(item.meta)
        let unifiedTemplate = PromptCatalog.template(.unifiedCommand, language: language)
        var record = baseRecord(item.meta, run: run, prompts: [unifiedTemplate])

        let webPrecheck = CommandRouter.requiresWeb(spokenInstruction: item.instruction, hasTarget: hasTarget)
        var predictedIntent: String? = CommandRouter.outputIntent(spokenInstruction: item.instruction).rawValue
        var predictedTask: String?
        var accumulator = CallAccumulator()
        var detail = ""

        if webPrecheck {
            predictedTask = ClassifiedTaskType.requires_web.rawValue
        } else {
            let prompt = PromptAssembler.taskPrompt(spokenInstruction: item.instruction, target: item.target, language: language)
            var schemaTokens = 0
            if case .success(let value) = await harness.schemaTokens(UnifiedCommandResult.self) { schemaTokens = value }
            let budget = await harness.budget(
                task: .unifiedCommand, instructions: unifiedTemplate.text, prompt: prompt, body: item.target ?? "", schemaTokens: schemaTokens
            )
            if recordBudgetStop(budget, into: &record) {
                record.routing = routingRecord(item, hasTarget, nil, nil, nil, webPrecheck, false)
                return CaseOutcome(record: record, output: nil)
            }
            guard case .fits(let maxTokens, _) = budget else { return CaseOutcome(record: record, output: nil) }
            let request = harness.makeRequest(task: .unifiedCommand, instructions: unifiedTemplate.text, prompt: prompt, maximumResponseTokens: maxTokens)
            let fakeJSON = "{\"taskType\": \"\(item.expectedTaskType)\", \"outputIntent\": \"\(Self.unifiedIntentJSON(item.expectedIntent))\", \"body\": \"\"}"
            let result = await harness.structured(request, as: UnifiedCommandResult.self, fake: .json(fakeJSON), into: &accumulator)
            switch result {
            case .success(let generated):
                predictedTask = generated.value.taskType.rawValue
                // The single generation decides the destination in this variant (V-07).
                predictedIntent = Self.intentString(generated.value.outputIntent)
                detail = "unified"
            case .failure(let failure):
                apply(accumulator, to: &record)
                recordFailure(failure, into: &record)
                record.routing = routingRecord(item, hasTarget, predictedIntent, nil, nil, webPrecheck, false)
                return CaseOutcome(record: record, output: nil)
            }
        }
        apply(accumulator, to: &record)

        let classifierTaskType = predictedTask
        var predictedKind: String?
        if let raw = predictedTask, let classified = ClassifiedTaskType(rawValue: raw) {
            let type = CommandRouter.adjustedTaskType(classified, spokenInstruction: item.instruction, hasTarget: hasTarget)
            predictedTask = type.rawValue
            predictedKind = CommandRouter.deriveKind(
                taskType: type, hasTarget: hasTarget, spokenInstruction: item.instruction
            ).rawValue
            if type != classified { detail += " override" }
        }
        record.routing = routingRecord(item, hasTarget, predictedIntent, predictedTask, predictedKind, webPrecheck, false)
        record.routing?.classifierTaskType = classifierTaskType
        record.routing?.classifierReplacement = nil
        return judgeRouting(item, record: record, intent: predictedIntent, task: predictedTask, kind: predictedKind, web: webPrecheck, detail: detail)
    }

    private func routingRecord(
        _ item: RoutingCase, _ hasTarget: Bool, _ intent: String?, _ task: String?, _ kind: String?,
        _ web: Bool, _ fallback: Bool
    ) -> RoutingRecord {
        let wrong = kind == CommandKind.content.rawValue && intent == CommandOutputIntent.automatic.rawValue && hasTarget
            && !(item.expectedKind == CommandKind.content.rawValue && item.expectedIntent == CommandOutputIntent.automatic.rawValue)
        return RoutingRecord(
            hasTarget: hasTarget, injection: item.injection, expectedIntent: item.expectedIntent, predictedIntent: intent,
            expectedTaskType: item.expectedTaskType, predictedTaskType: task, expectedKind: item.expectedKind,
            predictedKind: kind, webPrecheck: web, classifierFallback: fallback, wrongAutoReplace: wrong
        )
    }

    // MARK: - generation

    func generation(_ item: GenerationCase, run: Int) async -> CaseOutcome {
        guard let task = AITask(rawValue: item.taskType) else {
            var record = baseRecord(item.meta, run: run, prompts: [])
            record.outcome = "failure"
            record.failureCode = "unknownTaskType"
            record.judge = JudgeRecord(pass: false, failedChecks: ["unknownTaskType"])
            return CaseOutcome(record: record, output: nil)
        }
        let language = language(item.meta)
        let template = PromptCatalog.template(PromptID(task: task), language: language)
        var record = baseRecord(item.meta, run: run, prompts: [template])
        let target = outputLanguage(item.outputLanguage, language)
        let source = item.target ?? ""

        record.generationPath = harness.options.generationPath.rawValue
        let input = CommandInput(
            spokenInstruction: item.instruction, target: item.target, promptLanguage: language, outputLanguage: target
        )
        let fakeJSON = "{\"taskType\": \(Self.jsonString(item.taskType)), \"isReplacementArtifact\": true}"
        evalGenerator.beginCase(structured: .json(fakeJSON), text: .text(item.target ?? item.instruction))
        let e2e = harness.options.generationPath == .e2e
        let outcome = await coordinator.perform(operation: UUID(), priority: .interactive, deadline: .aiCommand) { context in
            if e2e {
                let result = await self.commandPipeline.run(input, using: context)
                return (result.diagnostics, result.text, Optional(result.routing))
            }
            let result = await self.commandPipeline.generate(task, input, using: context)
            return (result.diagnostics, result.text, Optional<CommandRouting>.none)
        }
        guard case .delivered(let (diagnostics, generatedText, routing)) = outcome else {
            recordFailure(.cancelled, into: &record)
            return CaseOutcome(record: record, output: nil)
        }
        record.promptKeys = diagnostics.promptKeys
        if let routing {
            record.routing = RoutingRecord(hasTarget: input.hasTarget, injection: false,
                expectedIntent: "unscored", predictedIntent: routing.outputIntent.rawValue,
                expectedTaskType: item.taskType, predictedTaskType: routing.taskType?.rawValue,
                expectedKind: "unscored", predictedKind: routing.kind?.rawValue,
                webPrecheck: routing.requiresWebPrecheck, classifierFallback: routing.classifierFallback,
                wrongAutoReplace: false, classifierTaskType: routing.classifiedTaskType?.rawValue,
                classifierReplacement: routing.classifierReplacement)
        }
        var accumulator = CallAccumulator()
        let cold = evalGenerator.caseCold
        for call in diagnostics.calls {
            accumulator.add(latencyMs: harness.milliseconds(call.latency), usage: call.usage, truncated: call.isTruncated, cold: cold)
        }
        record.measures.merge(diagnostics.measures) { _, new in new }
        if let stop = diagnostics.budgetStop {
            switch stop {
            case .needsChunking:
                record.outcome = "needsChunking"
            case .impossible(let reason):
                let code = String(describing: reason)
                record.outcome = "budgetImpossible"
                record.failureCode = code
                record.judge = JudgeRecord(pass: false, failedChecks: ["budgetImpossible:\(code)"])
            }
            return CaseOutcome(record: record, output: nil)
        }
        if let failure = diagnostics.failure {
            // A token-count failure stops before the generation call (no latency recorded, as before).
            if !diagnostics.calls.isEmpty { apply(accumulator, to: &record) }
            recordFailure(failure, into: &record)
            return CaseOutcome(record: record, output: nil)
        }
        apply(accumulator, to: &record)
        guard let output = generatedText, let report = diagnostics.validation else {
            recordFailure(.other(code: "missingOutput"), into: &record)
            return CaseOutcome(record: record, output: nil)
        }
        validatorRecord(report, into: &record)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if Judge.visibleLength(source) > 0 {
            record.measures["lengthRatio"] = Double(Judge.visibleLength(trimmed)) / Double(Judge.visibleLength(source))
        }
        record.judge = Judge.generation(item, output: trimmed, path: record.generationPath, predictedTask: record.routing?.predictedTaskType)
        return CaseOutcome(record: record, output: output)
    }

    // MARK: - optimization

    func optimization(_ item: OptimizationCase, run: Int) async -> CaseOutcome {
        let language = language(item.meta)
        let template = PromptCatalog.template(.instructionOptimizer, language: language)
        var record = baseRecord(item.meta, run: run, prompts: [template])
        record.optimizationMode = item.mode.rawValue
        let input = InstructionOptimizationInput(
            draft: item.draft, kind: item.mode,
            dictionaryEntries: item.dictionary.map { DictionaryEntry(preferred: $0.preferred, readings: $0.readings, memo: $0.memo) },
            promptLanguage: language
        )
        let fakeItems = item.mustPreserve.compactMap { Judge.alternatives($0).first }.prefix(item.maxItems)
        let fakeJSON = "{\"items\": [\(fakeItems.map { Self.jsonString($0) }.joined(separator: ", "))]}"
        evalGenerator.beginCase(structured: .json(fakeJSON), text: .text(""))
        let outcome = await coordinator.perform(
            operation: UUID(), priority: .optimization, deadline: DeadlinePolicy(cap: DeadlineConstants.longTextCap)
        ) { context in
            await self.optimizerPipeline.run(input, using: context)
        }
        guard case .delivered(let result) = outcome else {
            recordFailure(.cancelled, into: &record)
            return CaseOutcome(record: record, output: nil)
        }
        let diagnostics = result.diagnostics
        record.promptKeys = diagnostics.promptKeys
        record.measures.merge(diagnostics.measures) { _, new in new }
        record.dictionarySelected = diagnostics.dictionarySelected
        record.dictionaryOmitted = diagnostics.dictionaryOmitted
        var accumulator = CallAccumulator()
        for call in diagnostics.calls {
            accumulator.add(
                latencyMs: harness.milliseconds(call.latency), usage: call.usage,
                truncated: call.isTruncated, cold: evalGenerator.caseCold
            )
        }
        if !diagnostics.calls.isEmpty { apply(accumulator, to: &record) }
        if let failure = diagnostics.failure {
            recordFailure(failure, into: &record)
            return CaseOutcome(record: record, output: nil)
        }
        if let report = diagnostics.validation { validatorRecord(report, into: &record) }
        record.permissionFlaggedIndices = result.permissionFlaggedIndices
        switch result.status {
        case .complete(let items):
            let joined = items.joined(separator: "\n")
            // Keep the evaluation field's historical meaning (item characters, excluding separators).
            let graphemes = Judge.graphemes(items)
            record.measures["graphemes"] = Double(graphemes)
            record.judge = Judge.optimization(item, items: items, flags: result.permissionFlaggedIndices)
            return CaseOutcome(record: record, output: joined, items: items)
        case .tooLong:
            record.outcome = "tooLong"
            record.judge = JudgeRecord(pass: false, failedChecks: ["optimizerTooLong"])
        case .draftTooLong:
            if case .impossible(let reason) = diagnostics.budgetStop {
                record.outcome = "budgetImpossible"
                record.failureCode = String(describing: reason)
                record.judge = JudgeRecord(pass: false, failedChecks: ["budgetImpossible:\(reason)"])
            } else {
                record.outcome = "draftTooLong"
                record.judge = JudgeRecord(pass: false, failedChecks: ["draftTooLong"])
            }
        case .failed(let reason):
            record.outcome = "failure"
            record.failureCode = reason.rawValue
            record.judge = JudgeRecord(pass: false, failedChecks: [reason.rawValue])
        }
        return CaseOutcome(record: record, output: nil)
    }

    // MARK: - long

    func long(_ item: LongCase, run: Int) async -> CaseOutcome {
        let task: AITask = Judge.longTask(item)
        let language = language(item.meta)
        let template = PromptCatalog.template(PromptID(task: task), language: language)
        var record = baseRecord(item.meta, run: run, prompts: [template])
        record.measures["textCharacters"] = Double(item.text.count)
        // Single-shot is represented as one chunk; product diagnostics overwrite this when split.
        record.measures["chunk.count"] = 1
        record.measures["chunk.mergeStages"] = 0
        record.measures["chunk.referenceContext"] = 0
        let start = ContinuousClock.now
        evalGenerator.beginCase(structured: .json("{\"corrections\":[]}"), text: .text(item.text))

        let output: String?
        let calls: [GenerationCallRecord]
        let report: ValidationReport?
        let failure: AIFailure?
        if item.isTranscript {
            // Same configuration as cleanup; only long evaluation enables reference context.
            let guardrails = harness.options.guardrails
            let pipeline = CleanupPipeline(configuration: .init(
                includeDictionaryMemo: harness.options.dictionaryMemo,
                guardrailsOverride: guardrails == .auto ? nil : guardrails.mode(for: .cleanup),
                chunkReferenceContext: harness.options.chunkContext.referenceContext,
                editProjection: harness.options.projection
            ))
            let input = CleanupInput(transcript: item.text, promptLanguage: language,
                                     outputLanguage: outputLanguage(item.language, language), handsFree: item.handsFree)
            let outcome = await pipeline.run(input, operation: UUID(), coordinator: coordinator, deadline: .cleanup)
            guard case .delivered(let result) = outcome else {
                return longCancelled(record, start: start)
            }
            output = result.text
            calls = result.diagnostics.calls
            report = result.diagnostics.validation
            failure = result.diagnostics.failure
            record.promptKeys = result.diagnostics.promptKeys
            record.measures.merge(result.diagnostics.measures) { _, new in new }
            switch result.status {
            case .complete: record.outcome = "complete"
            case .needsReview: record.outcome = "needsReview"
            case .failed(let reason): record.outcome = "failed"; record.failureCode = reason.rawValue
            }
        } else {
            let input = CommandInput(spokenInstruction: item.instruction ?? "", target: item.text,
                                     promptLanguage: language, outputLanguage: outputLanguage(item.language, language))
            let outcome = await coordinator.perform(operation: UUID(), priority: .interactive, deadline: .aiCommand) { context in
                await self.commandPipeline.generate(task, input, using: context)
            }
            guard case .delivered(let result) = outcome else {
                return longCancelled(record, start: start)
            }
            output = result.text
            calls = result.diagnostics.calls
            report = result.diagnostics.validation
            failure = result.diagnostics.failure
            record.promptKeys = result.diagnostics.promptKeys
            record.measures.merge(result.diagnostics.measures) { _, new in new }
            if let chunking = result.chunking {
                record.measures["chunk.count"] = Double(chunking.chunkCount)
                record.measures["chunk.mergeStages"] = Double(chunking.mergeStages)
                record.measures["chunk.referenceContext"] = Double(chunking.referenceContext.rawValue)
            }
            switch result.status {
            case .complete: record.outcome = "complete"
            case .needsReview: record.outcome = "needsReview"
            case .failed(let reason): record.outcome = "failed"; record.failureCode = reason.rawValue
            }
        }
        record.totalLatencyMs = harness.milliseconds(ContinuousClock.now - start)
        record.calls = calls.map { call in
            EvalCallRecord(stage: call.stage.rawValue, latencyMs: harness.milliseconds(call.latency),
                           inputTokens: call.usage?.inputTokens, outputTokens: call.usage?.outputTokens,
                           truncated: call.isTruncated, failureCode: call.failure?.code)
        }
        var accumulator = CallAccumulator()
        for call in calls {
            accumulator.add(latencyMs: harness.milliseconds(call.latency), usage: call.usage,
                            truncated: call.isTruncated, cold: evalGenerator.caseCold)
        }
        apply(accumulator, to: &record)
        if let report { validatorRecord(report, into: &record) }
        if let failure { record.failureCode = failure.code }
        let trimmed = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let survived = item.checkpoints.filter { Judge.satisfied($0, in: trimmed) }.count
        record.measures["checkpointsSurvived"] = Double(survived)
        record.measures["checkpointsTotal"] = Double(item.checkpoints.count)
        record.measures["checkpointSurvival"] = Double(survived) / Double(max(1, item.checkpoints.count))
        let failed = Judge.checkLong(item, task: task, outcome: record.outcome, output: trimmed)
        record.judge = JudgeRecord(pass: failed.isEmpty, failedChecks: failed)
        return CaseOutcome(record: record, output: output)
    }

    private func longCancelled(_ original: EvalRecord, start: ContinuousClock.Instant) -> CaseOutcome {
        var record = original
        record.outcome = "failed"
        record.failureCode = "cancelled"
        record.validator = ValidatorRecord(status: "failed", reasons: ["cancelled"])
        record.judge = JudgeRecord(pass: false, failedChecks: ["generationFailed:cancelled"])
        record.totalLatencyMs = harness.milliseconds(ContinuousClock.now - start)
        return CaseOutcome(record: record, output: nil)
    }
}
