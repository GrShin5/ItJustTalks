import Foundation
import Combine
import ItJustTalksAI

/// 草稿・辞書・生成結果をログへ出さない。固定指示の言語は音声認識言語に合わせる。
struct InstructionOptimizationRequest {
    var draft: String
    var mode: CustomInstructionDraftMode
    var dictionaryEntries: [PersonalDictionaryEntry]
    var sttLanguage: AppLanguage

    func optimizationInput() -> InstructionOptimizationInput {
        InstructionOptimizationInput(
            draft: draft,
            kind: mode == .normal ? .cleanup : .aiCommand,
            dictionaryEntries: dictionaryEntries.map(\.aiDictionaryEntry),
            promptLanguage: PromptLanguage(sttLanguage: sttLanguage.localeIdentifier)
        )
    }
}

enum InstructionOptimizationUIState: Equatable {
    case complete(items: [String], flaggedIndices: [Int])
    case message(String)
    case cancelled
    case preempted
}

enum InstructionOptimizationMessages {
    static let preempted = "録音のため最適化を中断しました。もう一度実行してください。"
    static let emptyInput = "最適化するカスタムインストラクションを入力してください。"
    static let tooLong = "最適化の結果が長すぎるため適用しませんでした。カスタム指示を短くしてから、もう一度お試しください。"
    static let draftTooLong = "カスタム指示が長すぎるため最適化できませんでした。"

    static func reasonKey(_ reason: AIFailureReason) -> String {
        // 既存のAI整形と同じ案内を、最適化の操作名で示す。
        if reason == .contextSizeExceeded || reason == .customInstructionTooLong { return draftTooLong }
        return DictationCleanupMessages.reasonKey(reason).replacingOccurrences(of: "AI整形", with: "カスタム指示の最適化")
    }

    static var allKeys: [String] {
        [emptyInput, tooLong, draftTooLong, preempted] + AIFailureReason.allCases.map(reasonKey)
    }
}

/// 整形・AIに指示と同じ調停役で実行する。音声入力が来たら最適化を取り消して譲る。
@MainActor
final class InstructionOptimizationService {
    private let coordinatorProvider: @MainActor () -> GenerationCoordinator
    private let pipeline: InstructionOptimizerPipeline
    private let deadline: DeadlinePolicy
    private var inFlight: [UUID: GenerationCoordinator] = [:]
    private var cancelledOperations: [UUID] = []
    private var preemptedOperations: Set<UUID> = []

    init(
        coordinator: @escaping @MainActor () -> GenerationCoordinator,
        pipeline: InstructionOptimizerPipeline = InstructionOptimizerPipeline(),
        deadline: DeadlinePolicy = DeadlinePolicy(cap: DeadlineConstants.longTextCap)
    ) {
        coordinatorProvider = coordinator
        self.pipeline = pipeline
        self.deadline = deadline
    }

    func cancel(operation: UUID, forRecording: Bool = false) {
        if forRecording { preemptedOperations.insert(operation) } else { preemptedOperations.remove(operation) }
        cancelledOperations.removeAll { $0 == operation }
        cancelledOperations.append(operation)
        if cancelledOperations.count > 32 { preemptedOperations.remove(cancelledOperations.removeFirst()) }
        // リセットで調停役が替わっても、実行を受け付けた調停役を取り消す。
        let coordinator = inFlight[operation] ?? coordinatorProvider()
        Task { await coordinator.cancel(operation: operation) }
    }

    func cancelAll(forRecording: Bool = false) {
        for operation in Array(inFlight.keys) { cancel(operation: operation, forRecording: forRecording) }
    }

    func optimize(_ request: InstructionOptimizationRequest, operation: UUID) async -> InstructionOptimizationUIState {
        guard !Task.isCancelled else { return .cancelled }
        if cancelledOperations.contains(operation) {
            return preemptedOperations.contains(operation) ? .preempted : .cancelled
        }
        guard !request.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .message(InstructionOptimizationMessages.emptyInput)
        }
        let coordinator = coordinatorProvider()
        if case .unavailable(let reason) = coordinator.generator.availability {
            return .message(InstructionOptimizationMessages.reasonKey(AIFailureReason(.modelUnavailable(reason))))
        }
        inFlight[operation] = coordinator
        defer { inFlight[operation] = nil }
        let pipeline = self.pipeline
        let input = request.optimizationInput()
        let outcome = await coordinator.perform(operation: operation, priority: .optimization, deadline: deadline) { context in
            await pipeline.run(input, using: context)
        }
        guard !Task.isCancelled else { return .cancelled }
        if cancelledOperations.contains(operation) {
            return preemptedOperations.contains(operation) ? .preempted : .cancelled
        }
        switch outcome {
        case .cancelled(let cause): return cause == .preempted ? .preempted : .cancelled
        case .delivered(let result):
            return Self.uiState(for: result.status, flaggedIndices: result.permissionFlaggedIndices)
        }
    }

    nonisolated static func uiState(
        for status: InstructionOptimizationStatus, flaggedIndices: [Int] = []
    ) -> InstructionOptimizationUIState {
        switch status {
        case .complete(let items): return .complete(items: items, flaggedIndices: flaggedIndices)
        case .tooLong: return .message(InstructionOptimizationMessages.tooLong)
        case .draftTooLong: return .message(InstructionOptimizationMessages.draftTooLong)
        case .failed(.cancelled): return .message(InstructionOptimizationMessages.reasonKey(.generationError))
        case .failed(let reason): return .message(InstructionOptimizationMessages.reasonKey(reason))
        }
    }
}

/// 設定画面の一時状態。生成・取消・プレビューでは保存せず、欄への読込みだけを記録する（RV-07）。
@MainActor
final class InstructionOptimizationSession: ObservableObject {
    @Published private(set) var runningMode: CustomInstructionDraftMode?
    @Published var draft: CustomInstructionOptimizationDraft?
    private var operation: UUID?
    private var service: InstructionOptimizationService?

    func optimize(_ request: InstructionOptimizationRequest, using service: InstructionOptimizationService) async -> InstructionOptimizationUIState {
        cancel()
        let operation = UUID()
        self.operation = operation
        self.service = service
        runningMode = request.mode
        let result = await service.optimize(request, operation: operation)
        guard self.operation == operation else { return .cancelled }
        self.operation = nil
        self.service = nil
        runningMode = nil
        if case .complete(let items, let flaggedIndices) = result {
            draft = CustomInstructionOptimizationDraft(
                mode: request.mode, originalDraft: request.draft, items: items, flaggedIndices: flaggedIndices
            )
        }
        return result
    }

    func cancel() {
        if let operation { service?.cancel(operation: operation) }
        operation = nil
        service = nil
        runningMode = nil
    }

    func loadDraft(into editor: inout String, store: CustomInstructionStateStore) {
        guard let draft else { return }
        store.recordOptimizedInstructionLoaded(previousCustomInstruction: editor, optimizedInstruction: draft.optimizedInstruction)
        editor = draft.optimizedInstruction
        self.draft = nil
    }
}
