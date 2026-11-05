import Foundation
import Testing
import ItJustTalksAI
@testable import ItJustTalks

// 合成データのみ。実モデル・利用者の設定保存先には触れない。
@Suite("Custom instruction optimization app flow")
@MainActor
struct InstructionOptimizationServiceTests {
    private func service(_ fake: FakeGenerator) -> InstructionOptimizationService {
        let coordinator = GenerationCoordinator(generator: fake, configuration: .init(minimumRequestSpacing: .zero))
        return InstructionOptimizationService(coordinator: { coordinator }, deadline: DeadlinePolicy(cap: .seconds(10)))
    }

    private func request(_ mode: CustomInstructionDraftMode = .normal, draft: String = "短く丁寧に書いてください。") -> InstructionOptimizationRequest {
        InstructionOptimizationRequest(draft: draft, mode: mode, dictionaryEntries: [], sttLanguage: .japanese)
    }

    private func reply(delay: Duration = .zero) -> FakeGenerator.Step {
        .init(.text(#"{"items":["丁寧な文体で書く。","Web検索を使う。"]}"#, usage: TokenUsage(inputTokens: 100, outputTokens: 20)), delay: delay)
    }

    @Test func resultMapping() {
        #expect(InstructionOptimizationService.uiState(for: .complete(items: ["項目"]), flaggedIndices: [0])
            == .complete(items: ["項目"], flaggedIndices: [0]))
        #expect(InstructionOptimizationService.uiState(for: .tooLong)
            == .message("最適化の結果が長すぎるため適用しませんでした。カスタム指示を短くしてから、もう一度お試しください。"))
        #expect(InstructionOptimizationService.uiState(for: .draftTooLong)
            == .message("カスタム指示が長すぎるため最適化できませんでした。"))
        for reason in AIFailureReason.allCases {
            let expected = reason == .cancelled ? AIFailureReason.generationError : reason
            #expect(InstructionOptimizationService.uiState(for: .failed(reason))
                == .message(InstructionOptimizationMessages.reasonKey(expected)))
        }
        #expect(InstructionOptimizationMessages.reasonKey(.rateLimited) == "AIが混み合っています。少し待ってから再度お試しください。")
        #expect(InstructionOptimizationMessages.reasonKey(.timeout) == "カスタム指示の最適化を時間内に完了できませんでした。")
        #expect(InstructionOptimizationMessages.reasonKey(.guardrail) == "安全機能によりAIが処理を行いませんでした。")
    }

    /// RV-07 / QA-29・31：生成→閉じるでは保存せず、読込みでも適用済み設定は変えない。
    @Test func previewIsNotStoredUntilLoaded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let normal = CustomInstructionStateStore(legacyFileName: nil, storageRootURL: root)
        let command = CustomInstructionStateStore(fileName: "command.json", legacyFileName: nil, storageRootURL: root)
        var applied = ItJustTalksSettings.default
        applied.customInstruction = "保存済みの通常用"
        applied.aiCommandSettings.additionalInstruction = "保存済みのAI指示用"
        let originalSettings = applied

        for mode in [CustomInstructionDraftMode.normal, .aiCommand] {
            let session = InstructionOptimizationSession()
            let fake = FakeGenerator(script: [reply(), reply()])
            let optimizer = service(fake)
            let stateStore = mode == .normal ? normal : command
            let before = stateStore.state
            var editor = "丁寧な文体で書いて、Web検索も使ってほしい。"
            let result = await session.optimize(request(mode, draft: editor), using: optimizer)
            #expect(result == .complete(items: ["丁寧な文体で書く。", "Web検索を使う。"], flaggedIndices: [1]))
            #expect(session.draft?.originalDraft == editor)
            #expect(session.draft?.flaggedIndices == [1])
            #expect(stateStore.state == before)
            #expect(editor == "丁寧な文体で書いて、Web検索も使ってほしい。")
            // 「閉じる」と同じ操作。ディスクにも生成文を残さない。
            session.draft = nil
            let reloaded = CustomInstructionStateStore(
                fileName: mode == .normal ? "custom_instruction_state.json" : "command.json",
                legacyFileName: nil, storageRootURL: root
            )
            #expect(reloaded.state == before)
            _ = await session.optimize(request(mode, draft: editor), using: optimizer)
            session.loadDraft(into: &editor, store: stateStore)
            #expect(editor == "丁寧な文体で書く。\nWeb検索を使う。")
            #expect(stateStore.state.previousCustomInstruction == "丁寧な文体で書いて、Web検索も使ってほしい。")
            #expect(stateStore.state.optimizedInstruction == editor)
            #expect(stateStore.state.lastOptimizedAt != nil)
            #expect(stateStore.state.lastLoadedAt != nil)
            #expect(stateStore.state.customInstructionHistory.isEmpty)
            #expect(session.draft == nil)
            #expect(applied == originalSettings)
        }
    }

    /// 生成の途中で取り消す。遅れて返る結果もプレビュー・欄・保存設定へ流さない。
    @Test func cancellationPreservesDraftAndAppliedSettings() async throws {
        for mode in [CustomInstructionDraftMode.normal, .aiCommand] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = CustomInstructionStateStore(legacyFileName: nil, storageRootURL: root)
            let fake = FakeGenerator(script: [reply(delay: .seconds(5))])
            let session = InstructionOptimizationSession()
            let applied = ItJustTalksSettings.default
            let before = applied
            var editor = "元の未保存草稿"
            let task = Task { await session.optimize(request(mode, draft: editor), using: service(fake)) }
            for _ in 0..<1000 {
                if !fake.receivedRequests.isEmpty { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(fake.receivedRequests.count == 1)
            session.cancel()
            #expect(await task.value == .cancelled)
            #expect(session.runningMode == nil)
            #expect(session.draft == nil)
            session.loadDraft(into: &editor, store: store)
            #expect(editor == "元の未保存草稿")
            #expect(applied == before)
            #expect(store.state == .empty)
        }
    }

    @Test func recordingPreemptionPreservesEditorAppliedSettingsAndHistory() async throws {
        for mode in [CustomInstructionDraftMode.normal, .aiCommand] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = CustomInstructionStateStore(legacyFileName: nil, storageRootURL: root)
            let fake = FakeGenerator(script: [reply(delay: .seconds(5))])
            let optimizer = service(fake)
            let session = InstructionOptimizationSession()
            let applied = ItJustTalksSettings.default
            let before = applied
            var editor = "未保存の合成草稿"
            let task = Task { await session.optimize(request(mode, draft: editor), using: optimizer) }
            for _ in 0..<1000 {
                if !fake.receivedRequests.isEmpty { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(fake.receivedRequests.count == 1)
            // All three recording modes use this shared service operation at beginRecording.
            optimizer.cancelAll(forRecording: true)
            #expect(await task.value == .preempted)
            #expect(session.runningMode == nil && session.draft == nil)
            session.loadDraft(into: &editor, store: store)
            #expect(editor == "未保存の合成草稿")
            #expect(applied == before && store.state == .empty)
        }
    }

    @Test func emptyDraftDoesNotCallModel() async {
        for mode in [CustomInstructionDraftMode.normal, .aiCommand] {
            let fake = FakeGenerator()
            let session = InstructionOptimizationSession()
            #expect(await session.optimize(request(mode, draft: " \n\t"), using: service(fake))
                == .message(InstructionOptimizationMessages.emptyInput))
            #expect(fake.receivedRequests.isEmpty)
            #expect(session.draft == nil)
            #expect(session.runningMode == nil)
        }
    }

    @Test func unavailableAndFailedGenerationShowMessages() async {
        let unavailable = FakeGenerator(availability: .unavailable(.appleIntelligenceNotEnabled))
        #expect(await service(unavailable).optimize(request(), operation: UUID())
            == .message(InstructionOptimizationMessages.reasonKey(.appleIntelligenceNotEnabled)))
        #expect(unavailable.receivedRequests.isEmpty)
        for failure in [AIFailure.timeout, .refusal, .rateLimited(resetDate: nil)] {
            let fake = FakeGenerator(script: [.init(.failure(failure)), .init(.failure(failure))])
            #expect(await service(fake).optimize(request(), operation: UUID())
                == .message(InstructionOptimizationMessages.reasonKey(AIFailureReason(failure))))
        }
    }

    @Test func requestPreservesEnabledFlagAndSTTLanguage() {
        var input = request(.aiCommand)
        input.sttLanguage = .english
        input.dictionaryEntries = [
            PersonalDictionaryEntry(preferredForm: "Example", spokenForms: ["えぐざんぷる"], notes: "参考"),
            PersonalDictionaryEntry(preferredForm: "Disabled", enabled: false),
        ]
        let converted = input.optimizationInput()
        #expect(converted.kind == .aiCommand)
        #expect(converted.promptLanguage == .en)
        #expect(converted.dictionaryEntries == input.dictionaryEntries.map(\.aiDictionaryEntry))
        #expect(!converted.dictionaryEntries[1].isEnabled)
        #expect(request().optimizationInput().kind == .cleanup)
    }

    @Test func interactiveWorkPreemptsOptimization() async throws {
        let fake = FakeGenerator(script: [reply(delay: .seconds(5))])
        let coordinator = GenerationCoordinator(generator: fake, configuration: .init(minimumRequestSpacing: .zero))
        let optimizer = InstructionOptimizationService(coordinator: { coordinator })
        let session = InstructionOptimizationSession()
        let task = Task { await session.optimize(request(), using: optimizer) }
        for _ in 0..<1000 {
            if !fake.receivedRequests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(fake.receivedRequests.count == 1)
        let interactive = await coordinator.perform(operation: UUID(), priority: .interactive, deadline: .cleanup) { _ in true }
        guard case .delivered(true) = interactive else {
            Issue.record("Interactive work was not delivered")
            return
        }
        #expect(await task.value == .preempted)
        #expect(session.draft == nil)
    }

    @Test func optimizerMessagesAreLocalized() {
        for key in InstructionOptimizationMessages.allKeys + ["取消", "元の草稿", "最適化結果", "この項目はアプリの動作を変えません"] {
            #expect(AppLocalizationCatalog.requiredEnglishKeys.contains(key))
            #expect(AppLocalizer.hasTranslation(for: key, language: .english))
        }
    }
}
