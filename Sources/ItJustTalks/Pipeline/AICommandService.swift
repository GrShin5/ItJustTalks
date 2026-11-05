import Foundation
import ItJustTalksAI

/// 「AIに指示」の要求。利用者の文章を含むため、ログへ出さない。
struct AICommandServiceRequest {
    /// 音声指示。音声で指定した出力言語の指示は除去済み。
    var spokenInstruction: String
    /// 録音開始時に固定した対象本文（選択またはクリップボード）。nil は一般の依頼。
    var targetText: String?
    /// 「AIに指示」用カスタム指示。文体の参考としてだけ渡す（出力先・権限は変えない）。
    var customInstruction: String
    var dictionaryEntries: [PersonalDictionaryEntry]
    /// 音声認識言語の設定。固定プロンプトの言語はこれに従う（G1）。
    var sttLanguage: AppLanguage
    var outputLanguage: OutputLanguageResolution
    /// 出力言語を今回の発話で指定したか（false は保存設定から）。翻訳では保存設定の言語を使わない。
    var outputLanguageWasSpoken: Bool

    var promptLanguage: PromptLanguage {
        PromptLanguage(sttLanguage: sttLanguage.localeIdentifier)
    }

    func commandInput() -> CommandInput {
        let instruction = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = DictationCleanupRequest.outputLanguage(outputLanguage, promptLanguage: promptLanguage)
        return CommandInput(
            spokenInstruction: spokenInstruction,
            target: targetText,
            customInstruction: instruction.isEmpty ? nil : instruction,
            dictionaryEntries: dictionaryEntries.map(\.aiDictionaryEntry),
            promptLanguage: promptLanguage,
            outputLanguage: outputLanguageWasSpoken ? language : nil,
            settingsOutputLanguage: outputLanguageWasSpoken ? nil : language
        )
    }
}

/// オンデバイスAIの処理結果。出力先はまだ決めていない（`AICommandDispatchPolicy` が決める）。
enum AICommandServiceOutcome: Equatable {
    /// 検査を通った本文。`kind` と音声で明示された届け先から経路を決める。
    case completed(kind: AICommandOutcomeKind, intent: AICommandDestinationIntent, text: String, note: AICommandChunkingNote? = nil)
    /// 生成しない種類（対象不足・実行不可・Web必要）。固定の案内を結果ウィンドウに出す。
    case notGenerated(AICommandOutcomeKind)
    /// 生成はできたが確認が必要。結果ウィンドウだけに出し、選択文章には触れない。
    case needsReview(text: String?, note: AICommandChunkingNote? = nil)
    case failed(AIFailureReason)
    /// 利用者の取消。取消後に届いた結果もここへ落とす（STATE-08）。
    case cancelled
}

/// 本文を参照せず、ライブラリの処理種別と区間数だけから作る表示用注記。
struct AICommandChunkingNote: Equatable, Sendable {
    static let summaryKey = "長い文章を分けて要約しました（%d区間）。"
    static let explanationKey = "長い文章を分けて読み、まとめました（%d区間）。対象は選択した文章全体です。"
    let key: String
    let chunkCount: Int

    init?(result: CommandResult) {
        guard let chunking = result.chunking else { return nil }
        switch result.routing.taskType {
        case .summarize: key = Self.summaryKey
        case .explain_analyze: key = Self.explanationKey
        default: return nil
        }
        chunkCount = chunking.chunkCount
    }

    func text(language: AppLanguage) -> String {
        AppLocalizer.format(key, language: language, chunkCount)
    }
}

/// 処理結果を、自動置換・明示挿入・結果ウィンドウ・失敗表示のどれに回すか。
enum AICommandDispatch: Equatable {
    case discard
    case automaticSourceReplacement(String)
    case explicitTargetInsertion(String)
    /// 結果ウィンドウだけ。選択文章や入力欄には触れない（CMD-09）。
    case showResult(String, notice: AICommandResultNotice?, note: AICommandChunkingNote? = nil)
    /// 固定の案内を結果ウィンドウに出す。
    case showMessage(AICommandMessage)
    /// 失敗HUDのあと、理由を結果ウィンドウに出す。選択文章には触れない（CMD-09）。
    case failure(AIFailureReason)
}

enum AICommandResultNotice: Equatable {
    case needsReview
    case explicitInsertionNotPermitted
}

/// 生成せずに出す固定の案内。
enum AICommandMessage: Equatable {
    /// Web検索が必要な依頼（このアプリはWeb検索を行わない）。
    case webSearchUnavailable
    /// 対象本文が必要なのに無い。
    case targetMissing
    /// 送信・保存・他アプリの操作など、文章の生成ではできない依頼。
    case notExecutable
    /// 対象本文が、分割しても処理できる長さを超えている。
    case inputTooLong

    init(kind: AICommandOutcomeKind) {
        switch kind {
        case .requiresWeb: self = .webSearchUnavailable
        case .clarification: self = .targetMissing
        case .refusal, .content, .answer: self = .notExecutable
        }
    }
}

/// `AICommandOutputRoutingPolicy`（kind × 届け先 × 実本文）と、明示挿入の
/// 録音開始時同意 × 送出時同意のANDを1か所で適用する。検査に通らない結果・失敗は
/// 自動置換・挿入へ進めない。
enum AICommandDispatchPolicy {
    static func dispatch(
        _ outcome: AICommandServiceOutcome,
        hasActualSource: Bool,
        explicitInsertionAllowedAtRecordingStart: Bool,
        explicitInsertionAllowedNow: Bool
    ) -> AICommandDispatch {
        switch outcome {
        case .cancelled:
            return .discard
        case .failed(.contextSizeExceeded):
            return .showMessage(.inputTooLong)
        case .failed(let reason):
            return .failure(reason)
        case .needsReview(let text, let note):
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.validationFailed)
            }
            return .showResult(text, notice: .needsReview, note: note)
        case .notGenerated(let kind):
            return .showMessage(AICommandMessage(kind: kind))
        case .completed(let kind, let intent, let text, let note):
            switch AICommandOutputRoutingPolicy.decision(
                kind: kind,
                destinationIntent: intent,
                hasActualSource: hasActualSource
            ) {
            case .showResult:
                switch kind {
                case .content, .answer:
                    return .showResult(text, notice: nil, note: note)
                case .clarification, .refusal, .requiresWeb:
                    return .showMessage(AICommandMessage(kind: kind))
                }
            case .automaticSourceReplacement:
                return .automaticSourceReplacement(text)
            case .explicitTargetInsertion:
                // 届け先を音声で明示しても、録音開始時と現在の両方で同意が有効でなければ外部へ送らない。
                guard explicitInsertionAllowedAtRecordingStart, explicitInsertionAllowedNow else {
                    return .showResult(text, notice: .explicitInsertionNotPermitted, note: note)
                }
                return .explicitTargetInsertion(text)
            }
        }
    }
}

/// 利用者向けの文言（日本語キー。表示時に `AppLocalizer` で翻訳する）。
enum AICommandMessages {
    static let webSearchUnavailableKey = "このアプリはWeb検索を行いません。最新の情報や外部の情報が必要な依頼には答えられません。選択した文章や話した内容だけで答えられる依頼で、もう一度お試しください。"
    static let targetMissingKey = "処理する文章がありません。文章を選択してから、もう一度お試しください。"
    static let notExecutableKey = "この依頼は実行できません。「AIに指示」は文章の作成・変換だけを行い、送信・保存・他のアプリの操作はしません。"
    static let inputTooLongKey = "文章が長すぎるため、分けても処理できませんでした。文章を短くして、もう一度お試しください。選択していた文章は変更していません。"
    static let needsReviewKey = "AIの結果に確認が必要な点があるため、自動では置き換え・入力しませんでした。内容を確認してコピーしてください。"

    static func messageKey(_ message: AICommandMessage) -> String {
        switch message {
        case .webSearchUnavailable: return webSearchUnavailableKey
        case .targetMissing: return targetMissingKey
        case .notExecutable: return notExecutableKey
        case .inputTooLong: return inputTooLongKey
        }
    }

    /// 失敗理由ごとの説明（§6.4）。
    static func reasonKey(_ reason: AIFailureReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligenceがオフのため、「AIに指示」を使えませんでした。"
        case .deviceNotEligible:
            return "このMacはApple Intelligenceに対応していないため、「AIに指示」を使えませんでした。"
        case .modelNotReady, .assetsUnavailable:
            return "AIモデルを準備中のため、「AIに指示」を使えませんでした。しばらくしてからお試しください。"
        case .modelUnavailable:
            return "オンデバイスAIを利用できないため、「AIに指示」を使えませんでした。"
        case .rateLimited:
            return "AIが混み合っています。少し待ってから再度お試しください。"
        case .timeout:
            return "AIの処理を時間内に完了できませんでした。"
        case .guardrail:
            return "安全機能によりAIが処理を行いませんでした。"
        case .customInstructionTooLong:
            return "カスタム指示が長すぎるため「AIに指示」を処理できません。設定の「AIで最適化」をお試しください。"
        case .contextSizeExceeded:
            return inputTooLongKey
        case .unsupportedLanguage:
            return "この言語はAI処理に対応していません。"
        case .validationFailed, .generationError, .cancelled:
            return "AIの処理を完了できませんでした。選択していた文章は変更していません。"
        }
    }

    static func reasonKeys(_ reason: AIFailureReason) -> [String] {
        [reasonKey(reason)] + (reason == .unsupportedLanguage ? [DictationCleanupMessages.supportedLanguagesKey] : [])
    }

    static var allKeys: [String] {
        [webSearchUnavailableKey, targetMissingKey, notExecutableKey, inputTooLongKey, needsReviewKey,
         DictationCleanupMessages.transcriptionIncompleteKey, DictationCleanupMessages.supportedLanguagesKey,
         AICommandChunkingNote.summaryKey, AICommandChunkingNote.explanationKey]
            + AIFailureReason.allCases.map(reasonKey)
    }
}

extension AICommandOutcomeKind {
    init(_ kind: CommandKind) {
        switch kind {
        case .content: self = .content
        case .answer: self = .answer
        case .clarification: self = .clarification
        case .refusal: self = .refusal
        case .requiresWeb: self = .requiresWeb
        }
    }
}

extension AICommandDestinationIntent {
    init(_ intent: CommandOutputIntent) {
        switch intent {
        case .automatic: self = .automatic
        case .showResult: self = .showResult
        case .insertAtTarget: self = .insertAtCapturedTarget
        }
    }
}

/// 「AIに指示」を `CommandPipeline` とアプリ共通の `GenerationCoordinator` で行う、アプリ側の窓口。
///
/// - 生成はオンデバイスの `SystemLanguageModel` だけ（調停役は通常入力の整形と共有し、同時に1件だけ動かす）。
///   ネットワークには触れない。
/// - 出力先は音声指示だけから決め、対象本文・カスタム指示・辞書の内容では変えない。
/// - 取消した操作の結果は、後から届いても `cancelled` として返す（STATE-08）。
/// - 文章・辞書・指示の本文をログへ出さない。
@MainActor
final class AICommandService {
    private let coordinatorProvider: @MainActor () -> GenerationCoordinator
    private let pipeline: CommandPipeline
    private let deadline: DeadlinePolicy
    private var inFlightOperations: Set<UUID> = []
    private var cancelledOperations: [UUID] = []
    private static let rememberedCancellations = 32

    /// - Parameter coordinator: 現在の調停役を返す（「AI処理をリセット」で作り直されても最新を使う）。
    init(
        coordinator: @escaping @MainActor () -> GenerationCoordinator,
        pipeline: CommandPipeline = CommandPipeline(),
        deadline: DeadlinePolicy = .aiCommand
    ) {
        self.coordinatorProvider = coordinator
        self.pipeline = pipeline
        self.deadline = deadline
    }

    var availability: ModelAvailability { coordinatorProvider().generator.availability }

    var hasOperationInFlight: Bool { !inFlightOperations.isEmpty }

    /// 操作を取り消す。以後この操作の結果は届けない。
    func cancel(operation: UUID) {
        if !cancelledOperations.contains(operation) {
            cancelledOperations.append(operation)
            if cancelledOperations.count > Self.rememberedCancellations {
                cancelledOperations.removeFirst(cancelledOperations.count - Self.rememberedCancellations)
            }
        }
        let coordinator = coordinatorProvider()
        Task { await coordinator.cancel(operation: operation) }
    }

    /// 実行中の操作をすべて取り消す（失敗表示中のEsc、アプリ終了、AI処理のリセット）。
    func cancelAll() {
        for operation in inFlightOperations {
            cancel(operation: operation)
        }
    }

    func isCancelled(_ operation: UUID) -> Bool {
        cancelledOperations.contains(operation)
    }

    func execute(
        _ request: AICommandServiceRequest,
        operation: UUID,
        progress: (@MainActor @Sendable (ChunkProgress) -> Void)? = nil
    ) async -> AICommandServiceOutcome {
        guard !isCancelled(operation), !Task.isCancelled else { return .cancelled }
        let coordinator = coordinatorProvider()
        if case .unavailable(let reason) = coordinator.generator.availability {
            return .failed(AIFailureReason(.modelUnavailable(reason)))
        }
        inFlightOperations.insert(operation)
        defer { inFlightOperations.remove(operation) }
        let delivery = ChunkProgressDelivery()
        defer { delivery.stop() }
        let outcome = await withTaskCancellationHandler {
            await pipeline.run(
                request.commandInput(),
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
            return Self.outcome(for: result)
        }
    }

    nonisolated static func outcome(for result: CommandResult) -> AICommandServiceOutcome {
        let validationReasons: [ValidationReason]
        switch result.status {
        case .complete: validationReasons = []
        case .needsReview(let reasons): validationReasons = reasons
        case .failed: validationReasons = result.diagnostics.validation?.outcome.reasons ?? []
        }
        for reason in validationReasons {
            let validationReason = reason.diagnosticName
            AppLog.shared.warn("[AICommandService] validationReason=\(validationReason)")
        }
        switch result.status {
        case .failed(.cancelled):
            // 利用者が取り消していないのに取消扱いで終わった結果は、黙って捨てず失敗として扱う。
            return .failed(.generationError)
        case .failed(let reason):
            return .failed(reason)
        case .needsReview:
            return .needsReview(text: result.text, note: AICommandChunkingNote(result: result))
        case .complete:
            guard let kind = result.routing.kind else { return .failed(.generationError) }
            switch kind {
            case .clarification, .refusal, .requiresWeb:
                return .notGenerated(AICommandOutcomeKind(kind))
            case .content, .answer:
                guard let text = result.text,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failed(.generationError)
                }
                return .completed(
                    kind: AICommandOutcomeKind(kind),
                    intent: AICommandDestinationIntent(result.routing.outputIntent),
                    text: text,
                    note: AICommandChunkingNote(result: result)
                )
            }
        }
    }
}
