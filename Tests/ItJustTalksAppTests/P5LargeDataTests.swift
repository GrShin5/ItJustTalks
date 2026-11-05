import Foundation
import Testing
import ItJustTalksAI
@testable import ItJustTalks

@Suite("P5 large stored data and failure delivery")
@MainActor
struct P5LargeDataTests {
    @Test func twentyThousandCharactersSurviveSettingsAndHistorySave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let instruction = String(repeating: "合成指示", count: 5000)
        #expect(instruction.count == 20_000)
        let settings = SettingsStore(storageRootURL: root)
        settings.settings.customInstruction = instruction
        settings.settings.aiCommandSettings.additionalInstruction = instruction
        settings.save()
        let reloaded = SettingsStore(storageRootURL: root)
        #expect(reloaded.settings.customInstruction == instruction)
        #expect(reloaded.settings.aiCommandSettings.additionalInstruction == instruction)
        for file in ["normal.json", "command.json"] {
            let history = CustomInstructionStateStore(fileName: file, legacyFileName: nil, storageRootURL: root)
            history.recordCustomInstructionSave(instruction, previousInstruction: nil)
            let loaded = CustomInstructionStateStore(fileName: file, legacyFileName: nil, storageRootURL: root)
            #expect(loaded.state.customInstructionHistory == [instruction])
        }
    }

    @Test func csvLimitSurvivesAppConversionAndSharedSelection() throws {
        let start = ContinuousClock.now
        let csv = "word,readings,notes,enabled\n" + (0..<1000).map {
            "Product\($0),alias\($0),Synthetic memo,true\n"
        }.joined()
        let parsed = try UserDictionaryCSV.parse(data: Data(csv.utf8))
        #expect(parsed.issues.isEmpty)
        #expect(parsed.rows.count == UserDictionaryCSV.maximumDataRows)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalDictionaryStore(storageRootURL: root)
        let draft = UserDictionaryImportPlanner.makeDraft(parseResult: parsed, existingEntries: store.entries)
        let receipt = try store.applyImport(draft)
        #expect(receipt.insertedCount == 1000)
        let reloaded = PersonalDictionaryStore(storageRootURL: root)
        let entries = reloaded.entries
        #expect(entries == store.entries)
        let converted = entries.map(\.aiDictionaryEntry)
        let selection = DictionarySelector().select(entries: converted, text: "alias999")
        #expect(selection.selected.map(\.hint.preferred) == ["Product999"])
        #expect(entries.count == 1000 && converted.count == 1000)
        #expect(ContinuousClock.now - start < .seconds(60))
    }

    @Test func instructionFailureKeepsOriginalAndNeverSends() {
        let reason = AIFailureReason.customInstructionTooLong
        #expect(DictationCleanupDispositionPolicy.disposition(for: .failed(reason), original: "原文", handsFree: false)
                == .insertUnformatted("原文", reason: reason))
        #expect(DictationCleanupDispositionPolicy.disposition(for: .failed(reason), original: "原文", handsFree: true)
                == .showResult("原文", notice: .aiFailed(reason)))
        #expect(DictationCleanupMessages.reasonKey(reason) == "カスタム指示が長すぎるため整形できません")
        #expect(AICommandDispatchPolicy.dispatch(.failed(reason), hasActualSource: true,
                explicitInsertionAllowedAtRecordingStart: true, explicitInsertionAllowedNow: true) == .failure(reason))
        #expect(AICommandMessages.reasonKey(reason).contains("カスタム指示が長すぎる"))
    }

    @Test func lengthAndFailureMessagesHaveEnglishTranslations() {
        let keys = ["AIで最適化", "適正", "長め", "処理できない長さ", "モデルを利用できないため、長さは推定です。",
                    "本文の処理に使える容量が少なくなります。「AIで最適化」で指示を短くしてください。",
                    DictationCleanupMessages.reasonKey(.customInstructionTooLong),
                    AICommandMessages.reasonKey(.customInstructionTooLong)]
        for key in keys {
            #expect(AppLocalizationCatalog.requiredEnglishKeys.contains(key))
            #expect(AppLocalizer.hasTranslation(for: key, language: .english))
        }
    }
}
