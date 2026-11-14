import AppKit
import Foundation
import FoundationModels
import Synchronization
import ItJustTalksAI

/// 通常音声入力（ハンズフリー送信を含む）のAI整形要求。利用者の文章を含むため、ログへ出さない。
struct DictationCleanupRequest {
    /// 録音停止時の文字起こし。音声で指定した出力言語の指示は除去済み。
    var transcript: String
    /// 通常用カスタム指示（ハンズフリーは録音開始時のスナップショット）。
    var customInstruction: String
    var dictionaryEntries: [PersonalDictionaryEntry]
    /// 音声認識言語の設定。固定プロンプトの言語はこれに従う（G1）。
    var sttLanguage: AppLanguage
    var outputLanguage: OutputLanguageResolution
    var handsFree: Bool

    var promptLanguage: PromptLanguage {
        PromptLanguage(sttLanguage: sttLanguage.localeIdentifier)
    }

    func cleanupInput() -> CleanupInput {
        let instruction = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return CleanupInput(
            transcript: transcript,
            customInstruction: instruction.isEmpty ? nil : instruction,
            dictionaryEntries: dictionaryEntries.map(\.aiDictionaryEntry),
            promptLanguage: promptLanguage,
            outputLanguage: Self.outputLanguage(outputLanguage, promptLanguage: promptLanguage),
            handsFree: handsFree
        )
    }

    /// 明示的に固定された出力言語だけを渡す。自動判定・混在は「文字起こしと同じ」（nil）。
    static func outputLanguage(_ resolution: OutputLanguageResolution, promptLanguage: PromptLanguage) -> OutputLanguage? {
        guard case .fixed(let language) = resolution else { return nil }
        switch (language, promptLanguage) {
        case (.japanese, .ja): return OutputLanguage(code: "ja", name: "日本語")
        case (.english, .ja): return OutputLanguage(code: "en", name: "英語")
        case (.japanese, .en): return OutputLanguage(code: "ja", name: "Japanese")
        case (.english, .en): return OutputLanguage(code: "en", name: "English")
        }
    }
}

extension PersonalDictionaryEntry {
    /// AI処理（整形・AIに指示）へ渡す辞書項目。どの経路も同じ変換を使う（選択は `ItJustTalksAI` 側）。
    var aiDictionaryEntry: DictionaryEntry {
        let memo = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictionaryEntry(
            preferred: preferredForm,
            readings: spokenForms,
            memo: memo.isEmpty ? nil : memo,
            isEnabled: enabled
        )
    }
}

/// `ItJustTalksAI` を読み込まないファイルから失敗理由を扱うための別名。
typealias DictationFailureReason = AIFailureReason

/// 整形の結果。`complete` だけを自動で挿入・送信してよい。
enum DictationCleanupOutcome: Equatable {
    case complete(String)
    /// 生成はできたが確認が必要（生成文がある場合はそれを表示用に持つ）。
    case needsReview(String?, reasonCodes: [String] = [])
    case failed(AIFailureReason)
    /// 利用者の取消。取消後に届いた結果もここへ落とす（STATE-08）。
    case cancelled
}

/// 整形結果を、挿入・送信・結果ウィンドウのどれに回すかの判断（§3.1）。
enum DictationCleanupDisposition: Equatable {
    /// AI結果を挿入する。送信はハンズフリーの既存条件（停止根拠など）を満たす場合だけ。
    case insert(String)
    /// 通常モードのAI失敗：辞書の字面置換だけを施した文（語を削る処理はしない）を挿入し
    /// 「未整形」を通知する。生の原文は呼び出し側が「直前の原文」として別に保持する。
    case insertUnformatted(String, reason: AIFailureReason)
    /// 挿入も送信もせず、結果ウィンドウに表示する。
    case showResult(String, notice: DictationResultNotice)
    /// 取消：何も挿入・送信しない。
    case discard
}

enum DictationResultNotice: Equatable {
    case aiFailed(AIFailureReason)
    case needsReview
    case validationReview([String])
    /// 音声認識の確定が期限内に終わらなかった（未確定の末尾を含む全文）。
    case transcriptionTimedOut
    /// 確定結果が空で、途中結果だけがある。
    case transcriptionFinalEmpty
    case transcriptionIncomplete
}

enum DictationCleanupDispositionPolicy {
    static func disposition(
        for outcome: DictationCleanupOutcome,
        original: String,
        handsFree: Bool,
        fallback: (String) -> String = { $0 }
    ) -> DictationCleanupDisposition {
        switch outcome {
        case .complete(let text):
            return .insert(text)
        case .failed(let reason):
            // AI不可による非整形は、利用者の整形OFFと区別する（VOICE-11）。
            // ハンズフリーでは原文を挿入・送信しない（HF-06）。
            return handsFree
                ? .showResult(original, notice: .aiFailed(reason))
                : .insertUnformatted(fallback(original), reason: reason)
        case .needsReview(let text, let reasonCodes):
            let notice: DictationResultNotice = reasonCodes.isEmpty ? .needsReview : .validationReview(reasonCodes)
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .showResult(text, notice: notice)
            }
            return .showResult(original, notice: notice)
        case .cancelled:
            return .discard
        }
    }
}

/// 録音停止時の文字起こしが、自動の挿入・送信に使える完全なものかの判断（RV-02）。
enum DictationTranscriptCompletenessPolicy {
    enum Decision: Equatable {
        /// 確定結果をそのまま使う。
        case proceed
        /// 不完全。挿入も送信もせず、全文を結果ウィンドウに表示する。
        case review(String, notice: DictationResultNotice)
        /// 確定結果も途中結果も無い。
        case empty
    }

    static func decision(for stop: TranscriptionStopResult) -> Decision {
        let fullTextIsEmpty = stop.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if stop.timedOut, !stop.audioLost, !stop.recognitionFailed {
            return fullTextIsEmpty ? .empty : .review(stop.fullText, notice: .transcriptionTimedOut)
        }
        if stop.recognitionFailed || stop.audioLost {
            return .review(stop.fullText, notice: .transcriptionIncomplete)
        }
        if stop.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fullTextIsEmpty ? .empty : .review(stop.fullText, notice: .transcriptionFinalEmpty)
        }
        if stop.hasUnfinalizedTail {
            return .review(stop.fullText, notice: .transcriptionIncomplete)
        }
        return .proceed
    }

    static func usesVoiceTriggerFallback(for stop: TranscriptionStopResult, isVoiceTriggerSend: Bool) -> Bool {
        guard isVoiceTriggerSend else { return false }
        return decision(for: stop) == .review(stop.fullText, notice: .transcriptionFinalEmpty)
    }
}

/// RV-02を「AIに指示」にも適用する。確定が不完全な指示（打切り・確定結果なし）では
/// 生成せず、選択文章にも触れず、未確定の末尾を含む全文を結果ウィンドウに表示する。
/// 例：「翻訳して。置き換えず表示だけにして」の後半が未確定のまま自動置換されるのを防ぐ。
enum AICommandTranscriptCompletenessPolicy {
    static let transcriptionTimedOutKey = "音声認識の確定が時間内に終わらなかったため、AIに指示を実行せず、選択文章にも触れていません。未確定の末尾を含む指示の全文を表示しています。内容を確認して、もう一度指示してください。"
    static let transcriptionFinalEmptyKey = "音声認識の結果を確定できなかったため、AIに指示を実行せず、選択文章にも触れていません。途中結果を表示しています。内容を確認して、もう一度指示してください。"

    enum Decision: Equatable {
        case proceed
        case showTranscript(String, noticeKey: String)
        /// 確定結果も途中結果も無い。既存の空文字経路に任せる。
        case empty
    }

    static func decision(for stop: TranscriptionStopResult) -> Decision {
        switch DictationTranscriptCompletenessPolicy.decision(for: stop) {
        case .proceed:
            return .proceed
        case .empty:
            return .empty
        case .review(let fullText, let notice):
            return .showTranscript(
                fullText,
                noticeKey: notice == .transcriptionIncomplete ? DictationCleanupMessages.transcriptionIncompleteKey
                    : (notice == .transcriptionTimedOut ? transcriptionTimedOutKey : transcriptionFinalEmptyKey)
            )
        }
    }
}

extension DictationTranscriptCompletenessPolicy {
    /// 不完全な文字起こしを表示・保持する本文。ハンズフリーでは末尾のトリガー句を除く（送信の合図を本文に残さない）。
    static func reviewText(_ text: String, handsFreeTriggers: HandsFreeSendTriggerPolicy.CompiledTriggers?) -> String {
        guard let handsFreeTriggers else { return text }
        return HandsFreeSendTriggerPolicy.strippingTrailingTriggers(text, triggers: handsFreeTriggers)
    }
}

/// 停止後の処理経路。録音開始時のAI整形ON/OFFだけで決め、ライブ設定は見ない。
enum DictationProcessingPathPolicy {
    enum Path: Equatable {
        /// AI整形を通す（結果は `DictationCleanupDispositionPolicy` に従う）。
        case cleanup
        /// 利用者が整形をOFFにしていた：原文を挿入し、ハンズフリーは既存の条件で送信する。
        case raw
    }

    @MainActor
    static func path(for session: VoiceSession) -> Path {
        session.cleanupEnabledAtRecordingStart ? .cleanup : .raw
    }
}

/// 利用者向けの文言（日本語キー。表示時に `AppLocalizer` で翻訳する）。
enum DictationCleanupMessages {
    /// 通常モードで原文を挿入した時の通知の前置き。
    static let unformattedInsertedKey = "AI整形できなかったため、未整形の原文を入力しました。"
    /// 通常モードで、辞書の表記だけを反映した文（原文と異なる）を挿入した時の通知の前置き。
    static let dictionaryOnlyInsertedKey = "AIで整えられなかったため、辞書の表記だけを反映した文を入力しました。原文はメニューの「直前の原文をコピー」で取り出せます。"
    static let handsFreeCancelledKey = "AI整形を完了できなかったため、ハンズフリーでの自動挿入・送信を中止しました。内容を確認してコピーしてください。"
    static let needsReviewKey = "AI整形の結果に確認が必要な点があるため、自動では入力・送信しませんでした。内容を確認してコピーしてください。原文はメニューの「直前の原文をコピー」で取り出せます。"
    static let transcriptionTimedOutKey = "音声認識の確定が時間内に終わらなかったため、自動では入力・送信しませんでした。未確定の末尾を含む全文を表示しています。内容を確認してコピーしてください。"
    static let transcriptionFinalEmptyKey = "音声認識の結果を確定できなかったため、自動では入力・送信しませんでした。途中結果を表示しています。内容を確認してコピーしてください。"

    static let transcriptionIncompleteKey = "音声の取得または認識が不完全なため、自動処理を中止しました。取得できた全文を表示しています。内容を確認してコピーしてください。"

    /// AI失敗時に挿入した文が原文と同一なら従来の「未整形の原文」、辞書で変わっていれば辞書反映の通知。
    static func unformattedNoticeKey(inserted: String, original: String) -> String {
        inserted == original ? unformattedInsertedKey : dictionaryOnlyInsertedKey
    }

    /// 失敗理由ごとの説明（§6.4）。
    static func reasonKey(_ reason: AIFailureReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligenceがオフのため、AI整形を使えませんでした。"
        case .deviceNotEligible:
            return "このMacはApple Intelligenceに対応していないため、AI整形を使えませんでした。"
        case .modelNotReady, .assetsUnavailable:
            return "AIモデルを準備中のため、AI整形を使えませんでした。しばらくしてからお試しください。"
        case .modelUnavailable:
            return "オンデバイスAIを利用できないため、AI整形を使えませんでした。"
        case .rateLimited:
            return "AIが混み合っています。少し待ってから再度お試しください。"
        case .timeout:
            return "AI整形を時間内に完了できませんでした。"
        case .guardrail:
            return "安全機能によりAIが処理を行いませんでした。"
        case .customInstructionTooLong:
            return "カスタム指示が長すぎるため整形できません"
        case .contextSizeExceeded:
            return "文章が長すぎるため、分けてもAI整形できませんでした。文章を短くして、もう一度お試しください。"
        case .unsupportedLanguage:
            return "この言語はAI処理に対応していません。"
        case .validationFailed, .generationError, .cancelled:
            return "AI整形を完了できませんでした。"
        }
    }

    static let supportedLanguagesKey = "AI処理の対応言語は日本語と英語です。"

    static func reasonKeys(_ reason: AIFailureReason) -> [String] {
        [reasonKey(reason)] + (reason == .unsupportedLanguage ? [supportedLanguagesKey] : [])
    }

    static func noticeKeys(_ notice: DictationResultNotice) -> [String] {
        switch notice {
        case .aiFailed(let reason): return [handsFreeCancelledKey] + reasonKeys(reason)
        case .needsReview, .validationReview: return [needsReviewKey]
        case .transcriptionTimedOut: return [transcriptionTimedOutKey]
        case .transcriptionFinalEmpty: return [transcriptionFinalEmptyKey]
        case .transcriptionIncomplete: return [transcriptionIncompleteKey]
        }
    }

    static var allKeys: [String] {
        [unformattedInsertedKey, dictionaryOnlyInsertedKey, handsFreeCancelledKey, needsReviewKey, transcriptionTimedOutKey, transcriptionFinalEmptyKey, transcriptionIncompleteKey, supportedLanguagesKey]
            + AIFailureReason.allCases.map(reasonKey)
    }
}

/// 通常音声入力のAI整形を `CleanupPipeline` と1つの `GenerationCoordinator` で行う、アプリ側の窓口。
///
/// - 生成はオンデバイスの `SystemLanguageModel`（`OnDeviceGenerator`）だけ。試験では生成器を差し替える。
/// - 取消した操作の結果は、後から届いても `cancelled` として返す（STATE-08、V-04）。
/// - 文章・辞書・指示の本文をログへ出さない。
@MainActor
final class DictationCleanupService {
    /// 「AI処理をリセット」で作り直す。止まらない作業を抱えた古い調停役は、新しい要求を塞がない。
    private(set) var coordinator: GenerationCoordinator
    private let generator: any TextGenerating
    private let pipeline: CleanupPipeline
    private let fallbackComputation: (@Sendable (CleanupInput) async -> String)?
    private let deadline: DeadlinePolicy
    private let coordinatorConfiguration: GenerationCoordinator.Configuration
    private var inFlightOperations: Set<UUID> = []
    private var fallbackWorkers: [UUID: Task<String?, Never>] = [:]
    /// prewarm と取消の順序を保つ（取消が先に届いて、取消済みの準備が残らないように）。
    private var controlChain: Task<Void, Never>?
    private var cancelledOperations: [UUID] = []
    private static let rememberedCancellations = 32

    init(
        generator: any TextGenerating = DictationCleanupService.makeOnDeviceGenerator(),
        pipeline: CleanupPipeline = .product(),
        coordinatorConfiguration: GenerationCoordinator.Configuration = .default,
        deadline: DeadlinePolicy = .cleanup,
        fallbackComputation: (@Sendable (CleanupInput) async -> String)? = nil
    ) {
        self.generator = generator
        self.pipeline = pipeline
        self.fallbackComputation = fallbackComputation
        self.deadline = deadline
        self.coordinatorConfiguration = coordinatorConfiguration
        self.coordinator = GenerationCoordinator(generator: generator, configuration: coordinatorConfiguration)
    }

    /// 「AI処理をリセット」：実行中の操作をすべて取り消し、調停役を作り直す（R1）。
    /// 古い調停役に残った作業の結果は届けない。次の要求は新しい調停役で受け付ける。
    func reset() {
        for operation in inFlightOperations {
            cancel(operation: operation)
        }
        inFlightOperations.removeAll()
        coordinator = GenerationCoordinator(generator: generator, configuration: coordinatorConfiguration)
    }

    var hasOperationInFlight: Bool { !inFlightOperations.isEmpty }

    /// 製品の生成器。macOS 27未満では常に「利用不可」を返す。
    nonisolated static func makeOnDeviceGenerator() -> any TextGenerating {
        if #available(macOS 27, *) {
            return OnDeviceGenerator()
        }
        return UnavailableTextGenerator()
    }

    var availability: ModelAvailability { generator.availability }

    /// 録音開始時に、整形の静的な指示でセッションを準備する（§6.2）。モデルが使えない時は何もしない。
    func prewarm(operation: UUID, sttLanguage: AppLanguage) {
        guard generator.availability.isAvailable else { return }
        let template = PromptCatalog.template(.cleanup, language: PromptLanguage(sttLanguage: sttLanguage.localeIdentifier))
        let guardrails = pipeline.configuration.guardrailsOverride ?? AITask.cleanup.guardrails
        enqueueControl { coordinator in
            await coordinator.prewarm(operation: operation, instructions: template.text, guardrails: guardrails)
        }
    }

    /// 操作を取り消す。準備済みセッションも破棄し、以後この操作の結果は届けない。
    func cancel(operation: UUID) {
        fallbackWorkers[operation]?.cancel()
        if !cancelledOperations.contains(operation) {
            cancelledOperations.append(operation)
            if cancelledOperations.count > Self.rememberedCancellations {
                cancelledOperations.removeFirst(cancelledOperations.count - Self.rememberedCancellations)
            }
        }
        enqueueControl { coordinator in
            await coordinator.cancel(operation: operation)
        }
    }

    func isCancelled(_ operation: UUID) -> Bool {
        cancelledOperations.contains(operation)
    }

    /// 通常モードでAI整形が失敗した時に挿入する文。AIを使わず、辞書の字面置換だけを行う（語を削らない）。
    /// `original` は呼び出し側が保持する生の原文（変更しない）。
    func fallbackText(for original: String, request: DictationCleanupRequest, operation: UUID) async -> String? {
        guard !isCancelled(operation), !Task.isCancelled else { return nil }
        inFlightOperations.insert(operation)
        defer { inFlightOperations.remove(operation) }
        var input = request.cleanupInput()
        input.transcript = original
        let fallbackInput = input
        let pipeline = self.pipeline
        let fallbackComputation = self.fallbackComputation
        let worker = Task.detached(priority: .userInitiated) { () -> String? in
            guard !Task.isCancelled else { return nil }
            let text: String
            if let fallbackComputation {
                text = await fallbackComputation(fallbackInput)
            } else {
                text = pipeline.deterministicFallbackText(for: fallbackInput)
            }
            return Task.isCancelled ? nil : text
        }
        fallbackWorkers[operation] = worker
        defer { fallbackWorkers.removeValue(forKey: operation) }
        let text = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !isCancelled(operation), !Task.isCancelled else { return nil }
        return text
    }

    func cleanup(
        _ request: DictationCleanupRequest,
        operation: UUID,
        progress: (@MainActor @Sendable (ChunkProgress) -> Void)? = nil
    ) async -> DictationCleanupOutcome {
        guard !isCancelled(operation), !Task.isCancelled else { return .cancelled }
        if case .unavailable(let reason) = generator.availability {
            return .failed(AIFailureReason(.modelUnavailable(reason)))
        }
        await controlChain?.value
        guard !isCancelled(operation), !Task.isCancelled else { return .cancelled }
        inFlightOperations.insert(operation)
        defer { inFlightOperations.remove(operation) }
        let coordinator = self.coordinator
        let delivery = ChunkProgressDelivery()
        defer { delivery.stop() }
        let outcome = await withTaskCancellationHandler {
            await pipeline.run(
                request.cleanupInput(),
                operation: operation,
                coordinator: coordinator,
                deadline: deadline,
                progress: { [weak self] value in
                    guard let progress, delivery.isActive, !Task.isCancelled else { return }
                    Task { @MainActor [weak self] in
                        guard delivery.isActive, let self, self.inFlightOperations.contains(operation),
                              !self.isCancelled(operation) else { return }
                        progress(value)
                    }
                }
            )
        } onCancel: {
            delivery.stop()
        }
        // 結果を適用する直前に、取消済みでないことを確かめる（STATE-02/08）。
        guard !isCancelled(operation), !Task.isCancelled else { return .cancelled }
        switch outcome {
        case .cancelled:
            return .cancelled
        case .delivered(let result):
            switch result.status {
            case .complete:
                guard let text = result.text,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failed(.generationError)
                }
                return .complete(text)
            case .needsReview(let reasons):
                return .needsReview(result.text, reasonCodes: reasons.map(\.diagnosticName))
            case .failed(.cancelled):
                // 利用者が取り消していないのに取消扱いで終わった結果は、黙って捨てず失敗として扱う。
                return .failed(.generationError)
            case .failed(let reason):
                return .failed(reason)
            }
        }
    }

    private func enqueueControl(_ body: @escaping @Sendable (GenerationCoordinator) async -> Void) {
        let previous = controlChain
        let coordinator = self.coordinator
        controlChain = Task {
            await previous?.value
            await body(coordinator)
        }
    }
}

/// macOS 27未満で使う、常に「利用不可」を返す生成器。モデルへは一切触れない。
private struct UnavailableTextGenerator: TextGenerating {
    var availability: ModelAvailability { .unavailable(.unknown) }
    var contextSize: Int { 0 }
    var variantName: String? { nil }

    func tokenCount(for subject: TokenCountSubject) async throws(AIFailure) -> Int {
        throw .modelUnavailable(.unknown)
    }

    func schemaTokenCount<Output: Generable>(for type: Output.Type) async throws(AIFailure) -> Int {
        throw .modelUnavailable(.unknown)
    }

    func generate(_ request: GenerationRequest) async throws(AIFailure) -> GenerationResult {
        throw .modelUnavailable(.unknown)
    }

    func generate<Output: Generable & Sendable>(
        _ request: GenerationRequest,
        generating type: Output.Type
    ) async throws(AIFailure) -> StructuredGenerationResult<Output> {
        throw .modelUnavailable(.unknown)
    }
}

/// 取消・音声認識の打切り・AI失敗の時の原文を、メモリ上だけで一時的に保持する（RV-03 / ADD-01）。
///
/// 次の録音開始、または保持から10分で消える。ディスク・ログ・履歴へは渡さない。
@MainActor
final class LastOriginalTranscriptStore {
    static let retentionSeconds: TimeInterval = 600

    private var text: String?
    private var storedAt: Date?
    private var currentRecordingSessionID: UUID?
    private let now: () -> Date
    private var expiryTask: Task<Void, Never>?
    /// 保持の有無が変わった時に呼ぶ（メニューの有効・無効の更新用）。
    var onAvailabilityChange: ((Bool) -> Void)?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// 新しい録音の開始。前の原文を消し、以後はこの録音の原文だけを受け付ける。
    func recordingStarted(sessionID: UUID) {
        currentRecordingSessionID = sessionID
        clear()
    }

    /// 原文を保持する。後から始まった録音がある場合、古い録音の原文は受け付けない。
    func remember(_ original: String, sessionID: UUID) {
        guard currentRecordingSessionID == nil || currentRecordingSessionID == sessionID else { return }
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        text = original
        storedAt = now()
        scheduleExpiry()
        onAvailabilityChange?(true)
    }

    /// 保持中の原文。保持から10分（壁時計。スリープ中も進む）を過ぎていれば消して nil を返す。
    var current: String? {
        expireIfNeeded()
        return text
    }

    /// 期限切れなら消す。スリープ復帰時にも呼び、メニューの有効状態を更新する。
    func expireIfNeeded() {
        guard text != nil, let storedAt else { return }
        let elapsed = now().timeIntervalSince(storedAt)
        // 時計が過去へ戻った場合も保持を延ばさない。
        if elapsed >= Self.retentionSeconds || elapsed < 0 {
            clear()
        }
    }

    var hasTranscript: Bool { current != nil }

    /// 利用者の明示操作（メニュー）からだけ呼ぶ。書き込めた時だけ true。
    @discardableResult
    func copy(to pasteboard: NSPasteboard) -> Bool {
        guard let current else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(current, forType: .string)
    }

    func clear() {
        expiryTask?.cancel()
        expiryTask = nil
        let hadText = text != nil
        text = nil
        storedAt = nil
        if hadText { onAvailabilityChange?(false) }
    }

    /// スリープ中も進む `ContinuousClock` で待ち、最後は壁時計で判定する。
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let storedAt else { return }
        let remaining = max(0, Self.retentionSeconds - now().timeIntervalSince(storedAt))
        expiryTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            do {
                try await Task.sleep(until: clock.now + .seconds(remaining), clock: clock)
            } catch {
                return
            }
            guard let self else { return }
            self.expiryTask = nil
            self.expireIfNeeded()
            if self.text != nil { self.scheduleExpiry() }
        }
    }
}

/// Queued main-actor updates must also stop when the caller's task is cancelled.
final class ChunkProgressDelivery: Sendable {
    private let active = Mutex(true)
    var isActive: Bool { active.withLock { $0 } }
    func stop() { active.withLock { $0 = false } }
}
