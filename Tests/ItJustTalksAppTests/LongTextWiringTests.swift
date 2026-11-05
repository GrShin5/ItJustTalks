import Foundation
import Testing
@testable import ItJustTalksAI
@testable import ItJustTalks

private let longText = String(repeating: "a", count: 20_000)
private let wiringConfiguration = GenerationCoordinator.Configuration(
    minimumRequestSpacing: .zero, rateLimitDefaultWait: .milliseconds(10), cancelDrainLimit: .seconds(2)
)

private func wiringBudgeter() -> ContextBudgeter {
    var configuration = BudgetConfiguration.provisionalDefault
    configuration.hiddenOverheadTokens = 0
    configuration.marginRatio = 0
    configuration.minimumChunkBodyTokens = 8
    for task in AITask.allCases {
        configuration.profiles[task]?.reservation = OutputReservationPolicy(coefficient: 0, constant: 16)
    }
    return ContextBudgeter(configuration: configuration)
}

@MainActor
private final class ProgressLog {
    var values: [ChunkProgress] = []
    func append(_ value: ChunkProgress) { values.append(value) }
    func waitForFirst() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while values.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(!values.isEmpty)
    }
}

@Suite("Long-text HUD")
@MainActor
struct LongTextHUDTests {
    @Test func progressClampsAndLocalizes() {
        #expect(HUDChunkProgress.display(completed: 0, total: 5) == "1/5")
        #expect(HUDChunkProgress.display(completed: 1, total: 5) == "2/5")
        #expect(HUDChunkProgress.display(completed: 5, total: 5) == "5/5")
        #expect(HUDChunkProgress.display(completed: Int.max, total: 5) == "5/5")
        #expect(HUDChunkProgress.display(completed: -5, total: 5) == "1/5")
        #expect(HUDChunkProgress.display(completed: 0, total: 0) == nil)
        #expect(HUDChunkProgress.label(completed: 1, total: 5, language: .japanese)
            == "文章を分けて処理しています（2/5）。すべて完了してから入力します。")
        #expect(HUDChunkProgress.label(completed: 1, total: 5, language: .english)
            == "Processing the text in parts (2/5). It will be entered after all parts are done.")
    }

    @Test func onlyProcessingAppearancesShowProgress() {
        let state = AppState()
        state.setPhase(.cleaning)
        var view = RecordingHUDView(appState: state, chunkProgress: (1, 5))
        #expect(view.visibleChunkProgress != nil)
        for appearance in [HandsFreeSendHUDState.processing, .triggerConfirmedProcessing] {
            view.handsFreeSendState = appearance
            #expect(view.accessibilityLabel == HUDChunkProgress.label(completed: 1, total: 5, language: .japanese))
        }
        view.handsFreeSendState = .sendArmed
        #expect(view.visibleChunkProgress == nil)
        view.aiCommandState = .processing
        #expect(view.visibleChunkProgress != nil)
        view.aiCommandState = .recording
        #expect(view.visibleChunkProgress == nil)
        view.aiCommandState = nil
        view.handsFreeSendState = nil
        state.setPhase(.recording)
        #expect(view.visibleChunkProgress == nil)
    }

    @Test func clearingAbsentProgressPreservesBusyFlash() {
        let hud = RecordingHUDController(appState: AppState(), onCancelRecording: {}, onFinishRecording: {})
        hud.flashBusy(durationSeconds: 60)
        guard let view = hud.hostingView else { Issue.record("Expected rendered HUD"); return }
        #expect(view.rootView.overridePhase == .cleaning)
        hud.clearChunkProgress()
        #expect(view.rootView.overridePhase == .cleaning)
        hud.showChunkProgress(completed: 1, total: 2)
        hud.clearChunkProgress()
        #expect(hud.chunkProgress == nil)
        #expect(view.rootView.overridePhase == nil)
        hud.hide()
    }

    @Test func hideAndExistingClearsRemoveProgress() {
        let hud = RecordingHUDController(appState: AppState(), onCancelRecording: {}, onFinishRecording: {})
        hud.showChunkProgress(completed: 1, total: 5)
        #expect(hud.chunkProgress?.completed == 1)
        hud.hide()
        #expect(hud.chunkProgress == nil)
        hud.showChunkProgress(completed: 1, total: 5)
        hud.clearAICommandState()
        #expect(hud.chunkProgress == nil)
        hud.showChunkProgress(completed: 1, total: 5)
        hud.clearHandsFreeSendState()
        #expect(hud.chunkProgress == nil)
        hud.showChunkProgress(completed: 1, total: 5)
        hud.clearChunkProgress()
        #expect(hud.chunkProgress == nil)
    }
}

@Suite("Long-text service progress")
@MainActor
struct LongTextServiceProgressTests {
    @Test func singleShotDoesNotReportChunkProgress() async {
        let text = "This is a synthetic sentence."
        let body = FakeGenerator.Step(.text(text, usage: TokenUsage(inputTokens: 1, outputTokens: 1)))
        let fake = FakeGenerator(fallback: body, contextSize: 8192)
        let cleanup = DictationCleanupService(generator: fake, coordinatorConfiguration: wiringConfiguration)
        let log = ProgressLog()
        let cleanupRequest = DictationCleanupRequest(transcript: text, customInstruction: "", dictionaryEntries: [],
            sttLanguage: .english, outputLanguage: .automatic(.english), handsFree: false)
        #expect(await cleanup.cleanup(cleanupRequest, operation: UUID(), progress: { log.append($0) }) == .complete(text))
        let commandFake = FakeGenerator(script: [.init(.text("{\"taskType\":\"proofread_rewrite\",\"isReplacementArtifact\":false}")), body])
        let coordinator = GenerationCoordinator(generator: commandFake, configuration: wiringConfiguration)
        let command = AICommandService(coordinator: { coordinator })
        let commandRequest = AICommandServiceRequest(spokenInstruction: "Proofread", targetText: text,
            customInstruction: "", dictionaryEntries: [], sttLanguage: .english,
            outputLanguage: .automatic(.english), outputLanguageWasSpoken: false)
        #expect(await command.execute(commandRequest, operation: UUID(), progress: { log.append($0) })
            == .completed(kind: .content, intent: .automatic, text: text))
        for _ in 0..<10 { await Task.yield() }
        #expect(log.values.isEmpty)
    }

    @Test func commandForwardsIntermediateProgressOnMainActor() async {
        let fake = FakeGenerator(script: [.init(.text("{\"taskType\":\"proofread_rewrite\",\"isReplacementArtifact\":false}"))],
            fallback: .init(.text("Synthetic output", usage: TokenUsage(inputTokens: 1, outputTokens: 1)),
                delay: .milliseconds(30)), contextSize: 8192, charactersPerToken: 1)
        let coordinator = GenerationCoordinator(generator: fake, configuration: wiringConfiguration)
        let service = AICommandService(coordinator: { coordinator },
            pipeline: CommandPipeline(configuration: .init(budgeter: wiringBudgeter())))
        let log = ProgressLog()
        let request = AICommandServiceRequest(spokenInstruction: "Proofread", targetText: longText,
            customInstruction: "", dictionaryEntries: [], sttLanguage: .english,
            outputLanguage: .automatic(.english), outputLanguageWasSpoken: false)
        _ = await service.execute(request, operation: UUID(), progress: { log.append($0) })
        let total = log.values.first?.total ?? 0
        #expect(total > 1)
        #expect(log.values.map(\.completed).starts(with: Array(0..<max(0, total))))
        #expect(log.values.allSatisfy { $0.total == total })
    }

    // 0: another operation is cancelled; 1: this operation; 2: the caller's Task.
    @Test(arguments: [0, 1, 2])
    func cleanupProgressBelongsToOperation(cancellation: Int) async {
        // Long delay when cancelling, so a loaded test run cannot time out before the cancel arrives.
        let fake = FakeGenerator(fallback: .init(.failure(.timeout), delay: cancellation == 0 ? .milliseconds(300) : .seconds(10)),
            contextSize: 8192, charactersPerToken: 1)
        let service = DictationCleanupService(generator: fake,
            pipeline: CleanupPipeline(configuration: .init(budgeter: wiringBudgeter())),
            coordinatorConfiguration: wiringConfiguration)
        let operation = UUID()
        let log = ProgressLog()
        let request = DictationCleanupRequest(transcript: longText, customInstruction: "", dictionaryEntries: [],
            sttLanguage: .english, outputLanguage: .automatic(.english), handsFree: false)
        let task = Task { await service.cleanup(request, operation: operation, progress: { log.append($0) }) }
        await log.waitForFirst()
        #expect(log.values.first?.completed == 0)
        #expect((log.values.first?.total ?? 0) > 1)
        if cancellation == 2 { task.cancel() }
        else { service.cancel(operation: cancellation == 1 ? operation : UUID()) }
        let count = log.values.count
        let outcome = await task.value
        #expect(outcome == (cancellation == 0 ? .failed(.timeout) : .cancelled))
        if cancellation != 0 { #expect(log.values.count == count) }
        let finalCount = log.values.count
        for _ in 0..<10 { await Task.yield() }
        #expect(log.values.count == finalCount)
        #expect(!service.hasOperationInFlight)
        service.cancel(operation: operation)
        #expect(await service.cleanup(request, operation: operation, progress: { log.append($0) }) == .cancelled)
        #expect(log.values.count == finalCount)
    }

    @Test(arguments: [false, true])
    func cleanupDispositionsMatchSingleShot(handsFree: Bool) async {
        // Real sentences: the validator rejects letter runs as content-free output.
        let bodies = ["Send the report by Monday noon. ", "Call the client on Tuesday too. ",
                      "Book a room for Friday morning."]
        let source = bodies.joined()
        let template = PromptCatalog.template(.cleanup, language: .en)
        let overhead = template.text.count + PromptAssembler.cleanupPrompt(transcript: "", language: .en).count + 16
        let request = DictationCleanupRequest(transcript: source, customInstruction: "", dictionaryEntries: [],
            sttLanguage: .english, outputLanguage: .automatic(.english), handsFree: handsFree)
        for mode in 0...2 {
            var outcomes: [DictationCleanupOutcome] = []
            for chunked in [false, true] {
                let outputs = chunked ? bodies : [source]
                let steps: [FakeGenerator.Step] = mode == 2 ? [.init(.failure(.timeout))] : outputs.map {
                    .init(.text($0, usage: TokenUsage(inputTokens: 1, outputTokens: mode == 1 ? 16 : 1)))
                }
                let fake = FakeGenerator(script: steps, contextSize: chunked ? overhead + 32 : 8192,
                    charactersPerToken: 1)
                let service = DictationCleanupService(generator: fake,
                    pipeline: CleanupPipeline(configuration: .init(budgeter: wiringBudgeter())),
                    coordinatorConfiguration: wiringConfiguration)
                outcomes.append(await service.cleanup(request, operation: UUID()))
                // A chunk that fails validation (mode 1: truncated) stops the run before the next chunk.
                #expect(fake.receivedRequests.count == (chunked && mode == 0 ? 3 : 1))
            }
            let expected: DictationCleanupDisposition
            switch mode {
            case 0: expected = .insert(source)
            // A truncated output fails validation in both paths (it is never shown as a reviewable result).
            case 1:
                expected = handsFree ? .showResult(source, notice: .aiFailed(.validationFailed))
                    : .insertUnformatted(source, reason: .validationFailed)
            default:
                expected = handsFree ? .showResult(source, notice: .aiFailed(.timeout))
                    : .insertUnformatted(source, reason: .timeout)
            }
            for outcome in outcomes {
                #expect(DictationCleanupDispositionPolicy.disposition(for: outcome, original: source,
                    handsFree: handsFree) == expected)
            }
        }
    }

    @Test(arguments: [0, 1, 2])
    func commandProgressBelongsToOperation(cancellation: Int) async {
        let fake = FakeGenerator(script: [.init(.text("{\"taskType\":\"proofread_rewrite\",\"isReplacementArtifact\":false}"))],
            // Long delay when cancelling, so a loaded test run cannot time out before the cancel arrives.
            fallback: .init(.failure(.timeout), delay: cancellation == 0 ? .milliseconds(300) : .seconds(10)),
            contextSize: 8192, charactersPerToken: 1)
        let coordinator = GenerationCoordinator(generator: fake, configuration: wiringConfiguration)
        let service = AICommandService(coordinator: { coordinator },
            pipeline: CommandPipeline(configuration: .init(budgeter: wiringBudgeter())))
        let operation = UUID()
        let log = ProgressLog()
        let request = AICommandServiceRequest(spokenInstruction: "Proofread", targetText: longText,
            customInstruction: "", dictionaryEntries: [], sttLanguage: .english,
            outputLanguage: .automatic(.english), outputLanguageWasSpoken: false)
        let task = Task { await service.execute(request, operation: operation, progress: { log.append($0) }) }
        await log.waitForFirst()
        #expect(log.values.first?.completed == 0)
        #expect((log.values.first?.total ?? 0) > 1)
        if cancellation == 2 { task.cancel() }
        else { service.cancel(operation: cancellation == 1 ? operation : UUID()) }
        let count = log.values.count
        let outcome = await task.value
        #expect(outcome == (cancellation == 0 ? .failed(.timeout) : .cancelled))
        if cancellation != 0 { #expect(log.values.count == count) }
        let finalCount = log.values.count
        for _ in 0..<10 { await Task.yield() }
        #expect(log.values.count == finalCount)
        #expect(!service.hasOperationInFlight)
        service.cancel(operation: operation)
        #expect(await service.execute(request, operation: operation, progress: { log.append($0) }) == .cancelled)
        #expect(log.values.count == finalCount)
    }
}

@Suite("Long-text messages and routing")
@MainActor
struct LongTextMessagesTests {
    private func result(task: ClassifiedTaskType, status: CommandStatus = .complete,
                        chunked: Bool = true, intent: CommandOutputIntent = .showResult) -> CommandResult {
        var routing = CommandRouting(outputIntent: intent, requiresWebPrecheck: false, hasTarget: true)
        routing.kind = task == .explain_analyze ? .answer : .content
        routing.taskType = task
        return CommandResult(routing: routing, text: "Synthetic result", status: status,
            diagnostics: CommandDiagnostics(generator: FakeGenerator()),
            chunking: chunked ? ChunkingSummary(chunkCount: 3, mergeStages: 1) : nil)
    }

    private func dispatch(_ result: CommandResult) -> AICommandDispatch {
        AICommandDispatchPolicy.dispatch(AICommandService.outcome(for: result), hasActualSource: true,
            explicitInsertionAllowedAtRecordingStart: true, explicitInsertionAllowedNow: true)
    }

    @Test func notesOnlyForChunkedSummaryAndExplanationShown() {
        for task in [ClassifiedTaskType.summarize, .explain_analyze] {
            let value = result(task: task)
            let note = AICommandChunkingNote(result: value)
            #expect(note?.chunkCount == 3)
            #expect(dispatch(value) == .showResult("Synthetic result", notice: nil, note: note))
            #expect(dispatch(result(task: task, chunked: false)) == .showResult("Synthetic result", notice: nil))
            #expect(dispatch(result(task: task, intent: .insertAtTarget)) == .explicitTargetInsertion("Synthetic result"))
        }
        let summary = AICommandChunkingNote(result: result(task: .summarize))
        #expect(summary?.text(language: .japanese) == "長い文章を分けて要約しました（3区間）。")
        #expect(summary?.text(language: .english) == "The long text was summarized in parts (3 sections).")
        let explanation = AICommandChunkingNote(result: result(task: .explain_analyze))
        #expect(explanation?.text(language: .japanese)
            == "長い文章を分けて読み、まとめました（3区間）。対象は選択した文章全体です。")
        for task in [ClassifiedTaskType.proofread_rewrite, .translate, .extract] {
            #expect(AICommandChunkingNote(result: result(task: task)) == nil)
        }
    }

    @Test func chunkedCommandDispositionsMatchSingleShot() {
        for status in [CommandStatus.complete, .needsReview([.truncated]), .failed(.timeout)] {
            for intent in [CommandOutputIntent.automatic, .showResult, .insertAtTarget] {
                #expect(dispatch(result(task: .proofread_rewrite, status: status, intent: intent))
                    == dispatch(result(task: .proofread_rewrite, status: status, chunked: false, intent: intent)))
            }
        }
        #expect(dispatch(result(task: .summarize, status: .failed(.timeout))) == .failure(.timeout))
        let review = result(task: .summarize, status: .needsReview([.truncated]))
        #expect(dispatch(review) == .showResult("Synthetic result", notice: .needsReview,
            note: AICommandChunkingNote(result: review)))
    }

    @Test func messagesHaveRequiredTranslations() {
        for key in AICommandMessages.allKeys + DictationCleanupMessages.allKeys + [HUDChunkProgress.accessibilityKey] {
            #expect(AppLocalizationCatalog.requiredEnglishKeys.contains(key))
            #expect(AppLocalizer.hasTranslation(for: key, language: .english))
        }
        for key in [AICommandChunkingNote.summaryKey, AICommandChunkingNote.explanationKey,
                    HUDChunkProgress.accessibilityKey, AICommandMessages.inputTooLongKey,
                    DictationCleanupMessages.reasonKey(.contextSizeExceeded)] {
            #expect(AppLocalizer.hasTranslation(for: key, language: .japanese))
        }
    }
}
