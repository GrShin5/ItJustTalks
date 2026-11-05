import Foundation
import AppKit
import AVFoundation
import FoundationModels
import ItJustTalksAI

private actor AsyncRegressionGate {
    private var released = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var observers: [String: [CheckedContinuation<Void, Never>]] = [:]

    func wait(_ key: String) async {
        if released.remove(key) != nil { return }
        let pendingObservers = observers.removeValue(forKey: key) ?? []
        pendingObservers.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    func waitUntilBlocked(_ key: String) async {
        if waiters[key]?.isEmpty == false { return }
        await withCheckedContinuation { continuation in
            observers[key, default: []].append(continuation)
        }
    }

    func release(_ key: String) {
        let pending = waiters.removeValue(forKey: key) ?? []
        if pending.isEmpty {
            released.insert(key)
        } else {
            pending.forEach { $0.resume() }
        }
    }
}

private final class AsyncRegressionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed: [UUID: Int] = [:]
    private var callbacks: [UUID: [String]] = [:]

    func recordConsumed(_ streamID: UUID) {
        lock.lock()
        consumed[streamID, default: 0] += 1
        lock.unlock()
    }

    func recordCallback(_ streamID: UUID, text: String) {
        lock.lock()
        callbacks[streamID, default: []].append(text)
        lock.unlock()
    }

    func consumedCount(for streamID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return consumed[streamID, default: 0]
    }

    func callbackCount(for streamID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callbacks[streamID, default: []].count
    }
}

private final class FakeTemporaryCopyState: @unchecked Sendable {
    let firstSleepGate = AsyncRegressionGate()
    private let lock = NSLock()
    private var storedChangeCount = 0
    private var sleepCount = 0
    private var restoreCalls = 0
    var firstObservedChangeCount = 1
    var writesSecondChange = false

    var changeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedChangeCount
    }

    func setChangeCount(_ value: Int) {
        lock.lock()
        storedChangeCount = value
        lock.unlock()
    }

    func sleep(_ nanoseconds: UInt64) async {
        let count = nextSleepCount()
        if count == 1 {
            await firstSleepGate.wait("copy-poll")
        } else {
            setChangeCount(writesSecondChange && count >= 3 ? 2 : firstObservedChangeCount)
        }
    }

    private func nextSleepCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        sleepCount += 1
        return sleepCount
    }

    func restore(expected: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedChangeCount == expected else { return false }
        restoreCalls += 1
        storedChangeCount += 1
        return true
    }

    var restoreCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return restoreCalls
    }
}

/// 最初の生成だけ、取消に応じず止まり続ける生成器（「AI処理をリセット」の回帰用）。モデルへは触れない。
private final class StuckOnceGenerator: TextGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let gate = AsyncRegressionGate()

    let availability: ModelAvailability = .available
    let contextSize = 4096
    let variantName: String? = "stuck-once"

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func release() async {
        await gate.release("stuck")
    }

    func tokenCount(for subject: TokenCountSubject) async throws(AIFailure) -> Int {
        switch subject {
        case .instructions(let text), .prompt(let text):
            return max(1, text.count / 2)
        }
    }

    func schemaTokenCount<Output: Generable>(for type: Output.Type) async throws(AIFailure) -> Int {
        10
    }

    func generate(_ request: GenerationRequest) async throws(AIFailure) -> GenerationResult {
        let isFirst = lock.withLock { () -> Bool in
            calls += 1
            return calls == 1
        }
        if isFirst {
            // 取消を無視して待ち続ける（協調しない作業の再現）。
            await gate.wait("stuck")
        }
        return GenerationResult(
            text: "明日の会議は午後3時からです。",
            usage: TokenUsage(inputTokens: 100, outputTokens: 12),
            isTruncated: false,
            latency: .zero
        )
    }

    func generate<Output: Generable & Sendable>(
        _ request: GenerationRequest,
        generating type: Output.Type
    ) async throws(AIFailure) -> StructuredGenerationResult<Output> {
        throw .other(code: "StuckOnceGenerator.structured")
    }
}

struct AsyncRegressionResult {
    let passed: Bool
    let name: String
}

@MainActor
enum AsyncRegressionTests {
    static func run() async -> [AsyncRegressionResult] {
        var results: [AsyncRegressionResult] = []
        results += await transcriptionStartOwnership()
        results += await transcriptionRuntimeTeardown()
        results += await speechLanguageTimeout()
        results += await clipboardCancellationReceipt()
        results += await clipboardCancellationSecondChange()
        results += await aiCaptureLateCompletionOwnership()
        results += await dictationCleanupOutcomes()
        results += await dictationCleanupCancellation()
        results += await sttTimeoutKeepsUnconfirmedTail()
        results += lastOriginalTranscriptRecovery()
        results += dictationPathFixedAtRecordingStart()
        results += await aiProcessingResetRecreatesCoordinator()
        results += await unusedPrewarmIsDiscarded()
        results += lastOriginalExpiryAfterSleep()
        results += incompleteHandsFreeTextDropsTrigger()
        return results
    }

    private static func dictationPathFixedAtRecordingStart() -> [AsyncRegressionResult] {
        // 経路は録音開始時の値だけで決まる。録音中にライブ設定を切り替えても、sessionの値は変わらない。
        let snapshot = HandsFreeSendSnapshot(
            settings: HandsFreeSendSettings(enabled: true),
            sttLanguage: .japanese,
            externalCompatibilityEnabledAtRecordingStart: false
        )
        let startedOn = VoiceSession(mode: .voiceInput, cleanupEnabledAtRecordingStart: true)
        let startedOff = VoiceSession(mode: .voiceInput, cleanupEnabledAtRecordingStart: false)
        let handsFreeOn = VoiceSession(mode: .voiceInput, handsFreeSendSnapshot: snapshot, cleanupEnabledAtRecordingStart: true)
        let handsFreeOff = VoiceSession(mode: .voiceInput, handsFreeSendSnapshot: snapshot, cleanupEnabledAtRecordingStart: false)
        return [AsyncRegressionResult(
            passed: DictationProcessingPathPolicy.path(for: startedOn) == .cleanup
                && DictationProcessingPathPolicy.path(for: startedOff) == .raw
                && DictationProcessingPathPolicy.path(for: handsFreeOn) == .cleanup
                && DictationProcessingPathPolicy.path(for: handsFreeOff) == .raw
                && RecordingStartPrewarmPolicy.shouldPrewarm(
                    mode: startedOn.mode, cleanupEnabled: startedOn.cleanupEnabledAtRecordingStart, aiAvailable: true)
                && !RecordingStartPrewarmPolicy.shouldPrewarm(
                    mode: startedOff.mode, cleanupEnabled: startedOff.cleanupEnabledAtRecordingStart, aiAvailable: true),
            name: "dictation processing path is fixed by the cleanup setting at recording start, not the live setting"
        )]
    }

    private static func aiProcessingResetRecreatesCoordinator() async -> [AsyncRegressionResult] {
        // 対照：リセットしないと、取消しても止まらない作業が次の整形を塞ぐ（timeout）。
        let blockedGenerator = StuckOnceGenerator()
        let blockedService = dictationService(blockedGenerator, cancelDrainLimit: .milliseconds(150))
        let stuckOperation = UUID()
        let stuck = Task { @MainActor in
            await blockedService.cleanup(dictationRequest(handsFree: false), operation: stuckOperation)
        }
        await waitUntilAsyncSleeping { blockedGenerator.callCount >= 1 }
        blockedService.cancel(operation: stuckOperation)
        let stuckOutcome = await stuck.value
        let blockedNext = await blockedService.cleanup(dictationRequest(handsFree: false), operation: UUID())

        // リセット：実行中の操作を取り消し、調停役を作り直す。次の整形は新しい調停役で完了する。
        let generator = StuckOnceGenerator()
        let service = dictationService(generator, cancelDrainLimit: .milliseconds(150))
        let oldCoordinator = service.coordinator
        let running = Task { @MainActor in
            await service.cleanup(dictationRequest(handsFree: false), operation: UUID())
        }
        await waitUntilAsyncSleeping { generator.callCount >= 1 }
        let wasInFlight = service.hasOperationInFlight
        service.reset()
        let runningOutcome = await running.value
        let recovered = await service.cleanup(dictationRequest(handsFree: false), operation: UUID())

        await blockedGenerator.release()
        await generator.release()
        return [AsyncRegressionResult(
            passed: stuckOutcome == .cancelled
                && blockedNext == .failed(.timeout)
                && wasInFlight
                && runningOutcome == .cancelled
                && service.coordinator !== oldCoordinator
                && !service.hasOperationInFlight
                && recovered == .complete(dictationCleaned),
            name: "AI processing reset cancels running cleanup and recreates the coordinator so stuck work cannot block the next request"
        )]
    }

    private static func unusedPrewarmIsDiscarded() async -> [AsyncRegressionResult] {
        // 整形しなかった操作（不完全・空・送信キーのみ・整形OFF）でも、処理の終わりに取り消せば準備を残さない。
        let fake = FakeGenerator()
        let service = dictationService(fake)
        let operation = UUID()
        service.prewarm(operation: operation, sttLanguage: .japanese)
        await waitUntilAsyncSleeping { await service.coordinator.hasPrewarmedSession }
        let prepared = await service.coordinator.hasPrewarmedSession
        service.cancel(operation: operation)
        await waitUntilAsyncSleeping { !(await service.coordinator.hasPrewarmedSession) }
        let discarded = !(await service.coordinator.hasPrewarmedSession)
        return [AsyncRegressionResult(
            passed: prepared && discarded && fake.receivedRequests.isEmpty,
            name: "a prewarmed cleanup session is discarded when the operation ends without cleanup"
        )]
    }

    private static func lastOriginalExpiryAfterSleep() -> [AsyncRegressionResult] {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let store = LastOriginalTranscriptStore(now: { clock })
        var availability: [Bool] = []
        store.onAvailabilityChange = { availability.append($0) }
        let session = UUID()
        store.recordingStarted(sessionID: session)
        store.remember(dictationOriginal, sessionID: session)
        // スリープで待機タスクが止まっていても、壁時計で10分を過ぎていれば復帰時に消える。
        clock = clock.addingTimeInterval(LastOriginalTranscriptStore.retentionSeconds + 3_600)
        store.expireIfNeeded()
        return [AsyncRegressionResult(
            passed: availability == [true, false] && !store.hasTranscript,
            name: "the last original expires by wall clock across sleep and disables the menu item on wake"
        )]
    }

    private static func incompleteHandsFreeTextDropsTrigger() -> [AsyncRegressionResult] {
        let triggers = HandsFreeSendTriggerPolicy.compileTriggers(
            settings: HandsFreeSendSettings(enabled: true),
            sttLanguage: .japanese
        )
        let text = "明日の会議は午後3時からです ストップ送信"
        let handsFree = DictationTranscriptCompletenessPolicy.reviewText(text, handsFreeTriggers: triggers)
        let normal = DictationTranscriptCompletenessPolicy.reviewText(text, handsFreeTriggers: nil)
        return [AsyncRegressionResult(
            passed: !handsFree.contains("ストップ送信")
                && handsFree.hasPrefix("明日の会議は午後3時からです")
                && normal == text,
            name: "incomplete hands-free text drops the trigger phrase before it is shown or kept"
        )]
    }

    private static func waitUntilAsyncSleeping(_ predicate: () async -> Bool) async {
        for _ in 0..<2_000 where !(await predicate()) {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: - 通常音声入力のAFM整形（FakeGeneratorのみ。モデル・ネットワークへは触れない）

    private static let dictationOriginal = "えーと、明日の会議は午後3時からです"
    private static let dictationCleaned = "明日の会議は午後3時からです。"

    private static func dictationService(
        _ fake: any TextGenerating,
        cancelDrainLimit: Duration = .milliseconds(200)
    ) -> DictationCleanupService {
        DictationCleanupService(
            generator: fake,
            coordinatorConfiguration: GenerationCoordinator.Configuration(
                minimumRequestSpacing: .zero,
                rateLimitDefaultWait: .milliseconds(10),
                cancelDrainLimit: cancelDrainLimit
            ),
            deadline: DeadlinePolicy(cap: .seconds(10))
        )
    }

    private static func dictationRequest(handsFree: Bool) -> DictationCleanupRequest {
        DictationCleanupRequest(
            transcript: dictationOriginal,
            customInstruction: "",
            dictionaryEntries: [],
            sttLanguage: .japanese,
            outputLanguage: .automatic(.japanese),
            handsFree: handsFree
        )
    }

    private static func dictationCleanupOutcomes() async -> [AsyncRegressionResult] {
        var results: [AsyncRegressionResult] = []

        // complete → 挿入（ハンズフリーの送信可否は既存の停止根拠ルールに委ねる）。
        let completeFake = FakeGenerator(script: [
            .init(.text(dictationCleaned, usage: TokenUsage(inputTokens: 100, outputTokens: 12))),
        ])
        let complete = await dictationService(completeFake).cleanup(dictationRequest(handsFree: true), operation: UUID())
        results.append(AsyncRegressionResult(
            passed: complete == .complete(dictationCleaned)
                && DictationCleanupDispositionPolicy.disposition(
                    for: complete, original: dictationOriginal, handsFree: true) == .insert(dictationCleaned)
                && DictationCleanupDispositionPolicy.disposition(
                    for: complete, original: dictationOriginal, handsFree: false) == .insert(dictationCleaned)
                && completeFake.receivedRequests.count == 1,
            name: "AFM dictation cleanup: a complete result is inserted in normal and hands-free mode"
        ))

        // failed → ハンズフリーは挿入も送信もせず、原文を結果ウィンドウへ。通常は原文＋未整形通知。
        let failedFake = FakeGenerator(script: [.init(.failure(.refusal))])
        let failed = await dictationService(failedFake).cleanup(dictationRequest(handsFree: true), operation: UUID())
        results.append(AsyncRegressionResult(
            passed: failed == .failed(.guardrail)
                && DictationCleanupDispositionPolicy.disposition(
                    for: failed, original: dictationOriginal, handsFree: true)
                    == .showResult(dictationOriginal, notice: .aiFailed(.guardrail))
                && DictationCleanupDispositionPolicy.disposition(
                    for: failed, original: dictationOriginal, handsFree: false)
                    == .insertUnformatted(dictationOriginal, reason: .guardrail),
            name: "AFM dictation cleanup: hands-free failure inserts and sends nothing and shows the original; normal inserts it unformatted"
        ))

        // needsReview → どちらのモードでも結果ウィンドウ。送信経路（.insert）へは進まない。
        let review = DictationCleanupOutcome.needsReview("確認が必要な結果")
        results.append(AsyncRegressionResult(
            passed: DictationCleanupDispositionPolicy.disposition(
                for: review, original: dictationOriginal, handsFree: true)
                == .showResult("確認が必要な結果", notice: .needsReview)
                && DictationCleanupDispositionPolicy.disposition(
                    for: review, original: dictationOriginal, handsFree: false)
                    == .showResult("確認が必要な結果", notice: .needsReview)
                && DictationCleanupDispositionPolicy.disposition(
                    for: .needsReview(nil), original: dictationOriginal, handsFree: true)
                    == .showResult(dictationOriginal, notice: .needsReview),
            name: "AFM dictation cleanup: needsReview goes to the result window and is never sent"
        ))

        // AI不可 → モデルを呼ばずに「AI不可」として失敗し、理由ごとの文言を出す（整形OFFとは別経路）。
        let unavailableFake = FakeGenerator(availability: .unavailable(.appleIntelligenceNotEnabled))
        let unavailableService = dictationService(unavailableFake)
        let unavailable = await unavailableService.cleanup(dictationRequest(handsFree: false), operation: UUID())
        let unavailableKey = DictationCleanupMessages.reasonKey(.appleIntelligenceNotEnabled)
        let unavailableFamily: [AIFailureReason] = [.appleIntelligenceNotEnabled, .deviceNotEligible, .modelNotReady, .modelUnavailable]
        let familyKeys = unavailableFamily.map(DictationCleanupMessages.reasonKey)
        let genericKey = DictationCleanupMessages.reasonKey(.generationError)
        results.append(AsyncRegressionResult(
            passed: unavailable == .failed(.appleIntelligenceNotEnabled)
                && unavailableFake.receivedRequests.isEmpty
                && DictationCleanupDispositionPolicy.disposition(
                    for: unavailable, original: dictationOriginal, handsFree: false)
                    == .insertUnformatted(dictationOriginal, reason: .appleIntelligenceNotEnabled)
                && unavailableKey.contains("Apple Intelligence")
                && Set(familyKeys).count == familyKeys.count
                && !familyKeys.contains(genericKey)
                && Set([.rateLimited, .timeout, .guardrail, .contextSizeExceeded].map(DictationCleanupMessages.reasonKey))
                    .isDisjoint(with: familyKeys + [genericKey])
                && !unavailableService.isCancelled(UUID()),
            name: "AFM dictation cleanup: AI unavailable fails without a model call and shows a distinct unavailable message"
        ))

        results.append(AsyncRegressionResult(
            passed: DictationCleanupMessages.allKeys.allSatisfy { key in
                AppLocalizationCatalog.requiredEnglishKeys.contains(key)
                    && AppLocalizer.text(key, language: .japanese) == key
                    && AppLocalizer.text(key, language: .english) != key
                    && AppLocalizer.hasTranslation(for: key, language: .english)
            } && ["直前の原文をコピー"].allSatisfy { key in
                AppLocalizationCatalog.requiredEnglishKeys.contains(key)
                    && AppLocalizer.text(key, language: .english) == "Copy last original transcript"
            },
            name: "AFM dictation cleanup messages and the recovery menu item are localized in ja and en"
        ))
        return results
    }

    private static func dictationCleanupCancellation() async -> [AsyncRegressionResult] {
        // 生成中に取り消し、後から結果が届いても挿入・送信しない（STATE-08、V-04）。
        let lateFake = FakeGenerator(script: [
            .init(.text(dictationCleaned, usage: TokenUsage(inputTokens: 100, outputTokens: 12)), delay: .milliseconds(800)),
        ])
        let service = dictationService(lateFake)
        let operation = UUID()
        service.prewarm(operation: operation, sttLanguage: .japanese)
        let running = Task { @MainActor in
            await service.cleanup(dictationRequest(handsFree: true), operation: operation)
        }
        for _ in 0..<2_000 where lateFake.receivedRequests.isEmpty {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let requestWasRunning = !lateFake.receivedRequests.isEmpty
        service.cancel(operation: operation)
        let lateOutcome = await running.value

        // 取消が整形開始より先なら、モデルを呼ばない。
        let earlyFake = FakeGenerator(script: [.init(.text(dictationCleaned))])
        let earlyService = dictationService(earlyFake)
        let earlyOperation = UUID()
        earlyService.cancel(operation: earlyOperation)
        let earlyOutcome = await earlyService.cleanup(dictationRequest(handsFree: false), operation: earlyOperation)
        let prewarmDiscarded = !(await service.coordinator.hasPrewarmedSession)

        return [AsyncRegressionResult(
            passed: requestWasRunning
                && lateOutcome == .cancelled
                && DictationCleanupDispositionPolicy.disposition(
                    for: lateOutcome, original: dictationOriginal, handsFree: true) == .discard
                && earlyOutcome == .cancelled
                && earlyFake.receivedRequests.isEmpty
                && prewarmDiscarded,
            name: "AFM dictation cleanup: a result arriving after cancel is never inserted or sent"
        )]
    }

    private static func sttTimeoutKeepsUnconfirmedTail() async -> [AsyncRegressionResult] {
        let resultsGate = AsyncRegressionGate()
        let streamID = UUID()
        let seam = TranscriptionEngine.LifecycleTestSeam(
            suspend: { point, id in
                if point == .fakeResultsStream {
                    await resultsGate.wait(id.uuidString)
                }
            },
            bypassSpeechFramework: true,
            finishTimeoutSeconds: 0.02,
            didConsumeBuffer: nil
        )
        let engine = TranscriptionEngine(lifecycleTestSeam: seam)
        try? await engine.reconfigure(to: .japanese)
        _ = try? await engine.startStreaming(streamID: streamID) { _, _, _ in }
        engine.debugAcceptTextResult("明日の会議は", isFinal: true)
        engine.debugAcceptTextResult("午後3時からです", isFinal: false)
        let stopped = await engine.stopStreamingResult(streamID: streamID)
        await resultsGate.release(streamID.uuidString)
        let fullText = "明日の会議は午後3時からです"

        // 確定結果が空で途中結果だけがある場合も、通常モードで結果ウィンドウへ回す。
        let finalEmpty = TranscriptionStopResult(finalText: "", fullText: "途中結果だけ", timedOut: false)
        let complete = TranscriptionStopResult(finalText: fullText, fullText: fullText, timedOut: false)
        let nothing = TranscriptionStopResult(finalText: "", fullText: " ", timedOut: true)

        return [
            AsyncRegressionResult(
                passed: stopped.timedOut
                    && stopped.finalText == "明日の会議は"
                    && stopped.fullText == fullText
                    && DictationTranscriptCompletenessPolicy.decision(for: stopped)
                        == .review(fullText, notice: .transcriptionTimedOut),
                name: "STT finalize timeout keeps the unconfirmed tail and routes the full text to the result window"
            ),
            AsyncRegressionResult(
                passed: DictationTranscriptCompletenessPolicy.decision(for: finalEmpty)
                    == .review("途中結果だけ", notice: .transcriptionFinalEmpty)
                    && DictationTranscriptCompletenessPolicy.decision(for: complete) == .proceed
                    && DictationTranscriptCompletenessPolicy.decision(for: nothing) == .empty,
                name: "an empty final STT result with a partial goes to the result window instead of being dropped"
            ),
        ]
    }

    private static func lastOriginalTranscriptRecovery() -> [AsyncRegressionResult] {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = LastOriginalTranscriptStore(now: { clock })
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.itjusttalks.regression.original.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let cancelledSession = UUID()
        store.recordingStarted(sessionID: cancelledSession)
        let emptyBeforeCancel = !store.hasTranscript && !store.copy(to: pasteboard)
        // 取消経路と同じく、取消したsessionの原文を保持する。
        store.remember(dictationOriginal, sessionID: cancelledSession)
        let copied = store.copy(to: pasteboard) && pasteboard.string(forType: .string) == dictationOriginal

        // 9分59秒後はまだ回収でき、10分で消える。
        clock = clock.addingTimeInterval(LastOriginalTranscriptStore.retentionSeconds - 1)
        let stillAvailable = store.current == dictationOriginal
        clock = clock.addingTimeInterval(1)
        let expired = store.current == nil && !store.copy(to: pasteboard)

        // 次の録音開始で消え、古い録音から遅れて届いた原文は受け付けない。
        store.remember(dictationOriginal, sessionID: cancelledSession)
        let nextSession = UUID()
        store.recordingStarted(sessionID: nextSession)
        let clearedOnNextRecording = !store.hasTranscript
        store.remember("古い録音の原文", sessionID: cancelledSession)
        let staleRejected = !store.hasTranscript

        return [AsyncRegressionResult(
            passed: emptyBeforeCancel && copied && stillAvailable && expired && clearedOnNextRecording && staleRejected,
            name: "cancel keeps the original for the Copy last original transcript menu until the next recording or 10 minutes"
        )]
    }

    private static func transcriptionStartOwnership() async -> [AsyncRegressionResult] {
        var results: [AsyncRegressionResult] = []
        for point in [
            TranscriptionEngine.LifecycleTestPoint.startAfterPriorStop,
            .startAfterFormat,
            .startAfterAnalyzerLaunch,
        ] {
            results.append(await transcriptionStartOwnership(at: point))
        }
        return results
    }

    private static func transcriptionStartOwnership(
        at suspendedPoint: TranscriptionEngine.LifecycleTestPoint
    ) async -> AsyncRegressionResult {
        let startGate = AsyncRegressionGate()
        let resultsGate = AsyncRegressionGate()
        let firstID = UUID()
        let secondID = UUID()
        let seam = TranscriptionEngine.LifecycleTestSeam(
            suspend: { point, streamID in
                if point == suspendedPoint, streamID == firstID {
                    await startGate.wait("first-format")
                } else if point == .fakeResultsStream {
                    await resultsGate.wait(streamID.uuidString)
                }
            },
            bypassSpeechFramework: true,
            finishTimeoutSeconds: 0.05
        )
        let engine = TranscriptionEngine(lifecycleTestSeam: seam)
        try? await engine.reconfigure(to: .japanese)

        let firstStart = Task { @MainActor in
            do {
                _ = try await engine.startStreaming(streamID: firstID)
                return false
            } catch {
                return true
            }
        }
        await startGate.waitUntilBlocked("first-format")
        engine.cancelPendingStart(streamID: firstID)
        let secondStarted = (try? await engine.startStreaming(streamID: secondID)) != nil
            || engine.debugActiveStreamID == secondID
        await startGate.release("first-format")
        let firstRejected = await firstStart.value
        let secondStayedActive = engine.debugActiveStreamID == secondID
        await resultsGate.release(secondID.uuidString)
        _ = await engine.stopStreaming(streamID: secondID)

        let pointName: String
        switch suspendedPoint {
        case .startAfterPriorStop: pointName = "prior-stop"
        case .startAfterFormat: pointName = "format"
        case .startAfterAnalyzerLaunch: pointName = "analyzer-launch"
        default: pointName = "unexpected"
        }
        return AsyncRegressionResult(
            passed: firstRejected && secondStarted && secondStayedActive,
            name: "STT start lease rejects A at \(pointName) while B remains active"
        )
    }

    private static func transcriptionRuntimeTeardown() async -> [AsyncRegressionResult] {
        let resultsGate = AsyncRegressionGate()
        let recorder = AsyncRegressionRecorder()
        let streamID = UUID()
        let seam = TranscriptionEngine.LifecycleTestSeam(
            suspend: { point, id in
                if point == .fakeResultsStream {
                    await resultsGate.wait(id.uuidString)
                }
            },
            bypassSpeechFramework: true,
            finishTimeoutSeconds: 0.02,
            didConsumeBuffer: { recorder.recordConsumed($0) }
        )
        let engine = TranscriptionEngine(lifecycleTestSeam: seam)
        try? await engine.reconfigure(to: .japanese)
        _ = try? await engine.startStreaming(streamID: streamID) { id, text, _ in
            recorder.recordCallback(id, text: text)
        }
        let oldSink = engine.makeAudioSink()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        oldSink(buffer)
        await waitUntil { recorder.consumedCount(for: streamID) == 1 }

        let transcript = await engine.stopStreaming(streamID: streamID)
        let timedOut = engine.didTimeOutDuringFinishStreaming
        oldSink(buffer)
        await Task.yield()
        let oldSinkClosed = recorder.consumedCount(for: streamID) == 1

        await resultsGate.release(streamID.uuidString)
        await Task.yield()
        await Task.yield()
        let lateResultRejected = recorder.callbackCount(for: streamID) == 0
            && engine.partialText.isEmpty
            && transcript.isEmpty

        return [
            AsyncRegressionResult(
                passed: timedOut && oldSinkClosed && lateResultRejected,
                name: "STT timeout closes the old sink and rejects a noncooperative late result"
            ),
        ]
    }

    private static func speechLanguageTimeout() async -> [AsyncRegressionResult] {
        let gate = AsyncRegressionGate()
        var blockFirstPreparation = true
        let seam = TranscriptionEngine.LifecycleTestSeam(
            suspend: { point, _ in
                if point == .reconfigureAfterAssets, blockFirstPreparation {
                    blockFirstPreparation = false
                    await gate.wait("language-assets")
                }
            },
            bypassSpeechFramework: true
        )
        let engine = TranscriptionEngine(localeIdentifier: "ja-JP", lifecycleTestSeam: seam)
        let coordinator = SpeechLanguagePreparationCoordinator(
            engine: engine,
            timeoutNanoseconds: 10_000_000
        )
        let busyRefused: Bool
        switch await coordinator.prepare(to: .english, isVoiceProcessing: true) {
        case .failure(.busy): busyRefused = true
        default: busyRefused = false
        }
        let busyKeptCurrentLanguage = engine.debugLocaleIdentifier.lowercased().hasPrefix("ja")
        let preparation = Task { @MainActor in
            await coordinator.prepare(to: .english, isVoiceProcessing: false)
        }
        await gate.waitUntilBlocked("language-assets")
        let timedOut: Bool
        switch await preparation.value {
        case .failure(.timedOut): timedOut = true
        default: timedOut = false
        }
        await gate.release("language-assets")
        await waitUntil { !engine.debugHasActiveReconfigurationLease }
        let lateCommitRejected = engine.debugLocaleIdentifier.lowercased().hasPrefix("ja")

        let retry = await coordinator.prepare(to: .english, isVoiceProcessing: false)
        let retrySucceeded: Bool
        switch retry {
        case .success: retrySucceeded = true
        case .failure: retrySucceeded = false
        }
        let retryCommitted = retrySucceeded
            && engine.debugLocaleIdentifier.lowercased().hasPrefix("en")
        return [
            AsyncRegressionResult(
                passed: busyRefused
                    && busyKeptCurrentLanguage
                    && timedOut
                    && lateCommitRejected
                    && retryCommitted,
                name: "speech language refuses recording-time changes and rejects timeout late commits before retry"
            ),
        ]
    }

    private static func clipboardCancellationReceipt() async -> [AsyncRegressionResult] {
        let state = FakeTemporaryCopyState()
        let capture = SelectedTextCapture()
        let task = Task { @MainActor in
            await capture.debugCaptureTemporaryCopy(runtime: temporaryCopyRuntime(state))
        }
        await state.firstSleepGate.waitUntilBlocked("copy-poll")
        task.cancel()
        await state.firstSleepGate.release("copy-poll")
        let result = await task.value
        guard case .cancelledTemporaryCopy(let receipt) = result else {
            return [AsyncRegressionResult(
                passed: false,
                name: "clipboard cancellation receipt restores once and refuses a changed board"
            )]
        }
        let restored = receipt.resolve(restoreOriginal: true) == .restored
        let secondActionIgnored = receipt.resolve(restoreOriginal: true) == .alreadyResolved

        let changedReceipt = ClipboardCancellationReceipt(
            expectedChangeCount: 4,
            currentChangeCount: { 5 },
            restoreSnapshot: { _ in false }
        )
        let changedRefused = changedReceipt.resolve(restoreOriginal: true) == .clipboardChanged
        let expiredReceipt = ClipboardCancellationReceipt(
            expectedChangeCount: 7,
            lifetimeSeconds: 0,
            currentChangeCount: { 7 },
            restoreSnapshot: { _ in false }
        )
        let expiredRefused = expiredReceipt.resolve(restoreOriginal: true) == .expired
        return [AsyncRegressionResult(
            passed: restored
                && secondActionIgnored
                && state.restoreCallCount == 1
                && changedRefused
                && expiredRefused,
            name: "clipboard cancellation receipt restores once and refuses change or expiry"
        )]
    }

    private static func clipboardCancellationSecondChange() async -> [AsyncRegressionResult] {
        let state = FakeTemporaryCopyState()
        state.writesSecondChange = true
        let capture = SelectedTextCapture()
        let task = Task { @MainActor in
            await capture.debugCaptureTemporaryCopy(runtime: temporaryCopyRuntime(state))
        }
        await state.firstSleepGate.waitUntilBlocked("copy-poll")
        task.cancel()
        await state.firstSleepGate.release("copy-poll")
        let result = await task.value
        let rejected: Bool
        if case .unavailable(.clipboardChanged) = result {
            rejected = true
        } else {
            rejected = false
        }
        let directJumpState = FakeTemporaryCopyState()
        directJumpState.firstObservedChangeCount = 2
        let directJumpTask = Task { @MainActor in
            await capture.debugCaptureTemporaryCopy(runtime: temporaryCopyRuntime(directJumpState))
        }
        await directJumpState.firstSleepGate.waitUntilBlocked("copy-poll")
        directJumpTask.cancel()
        await directJumpState.firstSleepGate.release("copy-poll")
        let directJumpResult = await directJumpTask.value
        let directJumpRejected: Bool
        if case .unavailable(.clipboardChanged) = directJumpResult {
            directJumpRejected = true
        } else {
            directJumpRejected = false
        }
        return [AsyncRegressionResult(
            passed: rejected && state.restoreCallCount == 0,
            name: "clipboard cancellation observes only the remaining copy window and rejects a second change"
        ), AsyncRegressionResult(
            passed: directJumpRejected && directJumpState.restoreCallCount == 0,
            name: "clipboard cancellation rejects a direct two-change jump"
        )]
    }

    private static func aiCaptureLateCompletionOwnership() async -> [AsyncRegressionResult] {
        let zeroGate = AsyncRegressionGate()
        let zeroOwnership = AICommandCaptureCompletionGate()
        let oldZeroLease = zeroOwnership.begin()
        let oldZero = Task { @MainActor in
            await zeroGate.wait("zero")
            if case .stale = zeroOwnership.classify(.none, lease: oldZeroLease, appIsIdle: false) {
                return true
            }
            return false
        }
        await zeroGate.waitUntilBlocked("zero")
        let currentZeroLease = zeroOwnership.begin()
        await zeroGate.release("zero")
        let zeroIgnored = await oldZero.value
            && zeroOwnership.activeCaptureID == currentZeroLease.id

        let receiptGate = AsyncRegressionGate()
        let receiptOwnership = AICommandCaptureCompletionGate()
        let oldReceiptLease = receiptOwnership.begin()
        receiptOwnership.authorizeUserCancellation()
        let staleReceipt = ClipboardCancellationReceipt(
            expectedChangeCount: 1,
            currentChangeCount: { 1 },
            restoreSnapshot: { _ in true }
        )
        let oldReceipt = Task { @MainActor in
            await receiptGate.wait("receipt")
            if case .stale = receiptOwnership.classify(
                .cancelledTemporaryCopy(staleReceipt),
                lease: oldReceiptLease,
                appIsIdle: true
            ) {
                return true
            }
            return false
        }
        await receiptGate.waitUntilBlocked("receipt")
        let currentReceiptLease = receiptOwnership.begin()
        await receiptGate.release("receipt")
        let receiptIgnored = await oldReceipt.value
            && receiptOwnership.activeCaptureID == currentReceiptLease.id
            && !staleReceipt.isUsable()

        return [AsyncRegressionResult(
            passed: zeroIgnored && receiptIgnored,
            name: "late zero-change and receipt capture completions cannot mutate a replacement capture"
        )]
    }

    private static func temporaryCopyRuntime(
        _ state: FakeTemporaryCopyState
    ) -> SelectedTextCapture.TemporaryCopyTestRuntime {
        SelectedTextCapture.TemporaryCopyTestRuntime(
            snapshotIsComplete: true,
            snapshotStillCurrent: { state.changeCount == 0 },
            changeCount: { state.changeCount },
            copiedString: { nil },
            postCopy: { true },
            secureInputEnabled: { false },
            targetMatches: { true },
            restoreSnapshot: { state.restore(expected: $0) },
            sleep: { await state.sleep($0) }
        )
    }

    private static func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<1_000 where !predicate() {
            await Task.yield()
        }
    }

}
