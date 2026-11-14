import Foundation
import Testing
@testable import ItJustTalks

@Suite("Output history recording")
@MainActor
struct HistoryRecordingPolicyTests {
    @Test func everyRulesTableRow() {
        typealias Situation = HistoryRecordingPolicy.Situation
        let rows: [(String, Situation, Bool, String?, String?)] = [
            (InputHistoryMode.voiceInput, .inserted, false, "raw_transcript_output", "inserted"),
            (InputHistoryMode.handsFreeSend, .inserted, false, "raw_transcript_output", "inserted"),
            (InputHistoryMode.voiceInput, .inserted, true, "raw_transcript_output", "inserted"),
            (InputHistoryMode.voiceInput, .insertionFailedShown, false, "raw_transcript_output", "failed"),
            (InputHistoryMode.voiceInput, .shownInWindow, false, "raw_transcript_output", "shown_in_window"),
            (InputHistoryMode.voiceInput, .reviewShown, false, "review_text", "shown_in_window"),
            (InputHistoryMode.voiceInput, .insertButtonSucceeded, false, nil, nil),
            (InputHistoryMode.aiCommand, .inserted, false, "ai_command_output", "inserted"),
            (InputHistoryMode.aiCommand, .shownInWindow, false, "ai_command_output", "shown_in_window"),
            (InputHistoryMode.aiCommand, .reviewShown, false, "review_text", "shown_in_window"),
            (InputHistoryMode.aiCommand, .guidance, false, nil, nil),
            (InputHistoryMode.handsFreeSend, .sendWordOnly, false, nil, nil),
            (InputHistoryMode.aiCommand, .cancelled, false, nil, nil),
            (InputHistoryMode.aiCommand, .customInstructionOptimization, false, nil, nil),
        ]
        for (mode, situation, failed, kind, status) in rows {
            let decision = HistoryRecordingPolicy.decision(mode: mode, output: "Synthetic output",
                situation: situation, cleanupEnabled: failed, cleanupDidFail: failed)
            #expect(decision?.kind == kind)
            #expect(decision?.status == status)
            if failed { #expect(decision?.marks.contains(InputHistoryFlag.cleanupFailed) == true) }
            if situation == .reviewShown { #expect(decision?.marks.contains(InputHistoryFlag.needsReview) == true) }
        }
        #expect(HistoryRecordingPolicy.decision(mode: InputHistoryMode.voiceInput, output: " ",
                                               situation: .shownInWindow) == nil)
    }

    @Test func cleanedAndUnformattedOutputsKeepTheTrimmedBody() throws {
        for cleanupFailed in [false, true] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = InputHistoryStore(storageRootURL: root)
            let output = "  Synthetic final output\n"
            store.recordNormalInputIfNeeded(mode: InputHistoryMode.voiceInput, historyEnabled: true,
                historyRetentionDays: 180, textToInsert: output, cleanupEnabled: true,
                cleanupDidFail: cleanupFailed, insertResult: .inserted, cleanupLatencyMs: nil)
            let entry = InputHistoryStore(storageRootURL: root).entries.first
            // Surrounding whitespace is trimmed, as before; the body itself is unchanged.
            #expect(entry?.storedText == "Synthetic final output")
            #expect(entry?.storedTextKind == (cleanupFailed
                ? InputHistoryStoredTextKind.rawTranscriptOutput : InputHistoryStoredTextKind.aiAssistedOutput))
            #expect(entry?.flags.contains(InputHistoryFlag.cleanupFailed) == cleanupFailed)
        }
    }

    @Test func cancelBeforeOutputCreatesZeroEntries() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InputHistoryStore(storageRootURL: root)
        if let decision = HistoryRecordingPolicy.decision(mode: InputHistoryMode.aiCommand,
            output: "Synthetic instruction", situation: .cancelled) {
            store.recordOutput(mode: InputHistoryMode.aiCommand, output: "Synthetic instruction",
                kind: decision.kind, status: decision.status, startHistoryEnabled: true,
                currentHistoryEnabled: true, retentionDays: 0)
        }
        #expect(store.entries.isEmpty)
        #expect(InputHistoryStore(storageRootURL: root).entries.isEmpty)
    }

    @Test func insertButtonUpdatesWithoutDoubleSavingAndDeletionIsRespected() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InputHistoryStore(storageRootURL: root)
        let id = UUID()
        for _ in 0..<2 {
            #expect(store.recordOutput(id: id, mode: InputHistoryMode.voiceInput, output: "Synthetic output",
                kind: InputHistoryStoredTextKind.reviewText, status: InputHistoryInsertStatus.shownInWindow,
                marks: [InputHistoryFlag.needsReview], startHistoryEnabled: true,
                currentHistoryEnabled: true, retentionDays: 0) == .saved)
        }
        #expect(store.updateInsertStatus(id: id, status: InputHistoryInsertStatus.inserted) == .saved)
        let loaded = InputHistoryStore(storageRootURL: root)
        #expect(loaded.entries.count == 1)
        #expect(loaded.entries.first?.id == id)
        #expect(loaded.entries.first?.storedText == "Synthetic output")
        #expect(loaded.entries.first?.insertStatus == InputHistoryInsertStatus.inserted)
        #expect(loaded.entries.first?.flags == [InputHistoryFlag.needsReview])
        #expect(store.delete(id: id) == .saved)
        #expect(store.updateInsertStatus(id: id, status: InputHistoryInsertStatus.inserted) == .saved)
        #expect(InputHistoryStore(storageRootURL: root).entries.isEmpty)
    }

    @Test func outputConsentRequiresBothStartAndSaveTime() throws {
        for start in [false, true] {
            for current in [false, true] {
                let root = temporaryRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let store = InputHistoryStore(storageRootURL: root)
                store.recordOutput(mode: InputHistoryMode.aiCommand, output: "Synthetic answer",
                    kind: InputHistoryStoredTextKind.aiCommandOutput, status: InputHistoryInsertStatus.inserted,
                    sourceLabel: .clipboard, startHistoryEnabled: start,
                    currentHistoryEnabled: current, retentionDays: 0)
                #expect(store.entries.count == (start && current ? 1 : 0))
                #expect(InputHistoryStore(storageRootURL: root).entries.count == (start && current ? 1 : 0))
            }
        }
    }

    @Test func legacyInstructionsLoadAlongsideOutputs() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InputHistoryStore(storageRootURL: root)
        let legacy = InputHistoryEntry.aiCommandTranscript("Synthetic legacy instruction")
        #expect(store.append(legacy, retentionDays: 0) == .saved)
        store.recordOutput(mode: InputHistoryMode.aiCommand, output: "Synthetic answer",
            kind: InputHistoryStoredTextKind.aiCommandOutput, status: InputHistoryInsertStatus.inserted,
            startHistoryEnabled: true, currentHistoryEnabled: true, retentionDays: 0)
        let loaded = InputHistoryStore(storageRootURL: root)
        #expect(loaded.visibleEntries(limit: 0, mode: InputHistoryMode.aiCommand).count == 2)
        #expect(loaded.entries.contains { $0.id == legacy.id && $0.storedText == legacy.storedText })
        let allValid = loaded.entries.allSatisfy { $0.isValidForStorage }
        #expect(allValid)
    }

    @Test func productionRecordsOnlyAtOutputAndInsertButtonUpdates() throws {
        let app = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ItJustTalks/ItJustTalksApp.swift"), encoding: .utf8)
        #expect(!app.contains("saveAICommandTranscriptIfNeeded"))
        // An incomplete AI instruction is the spoken instruction itself: shown, never stored.
        #expect(!app.contains("recordSessionOutput(fullText"))
        // Secure Input keeps the body out of history; other insertion failures are marked.
        #expect(app.contains("presentNormalInputFallback(textToInsert, historySituation: nil)"))
        #expect(app.contains("historySituation: .insertionFailedShown, historySession: session"))
        #expect(app.contains("guard let session, !session.isCancelled else { return nil }"))
        #expect(app.contains("recordSessionOutput(text, session: session, situation: .shownInWindow)"))
        #expect(app.contains("updateInsertStatus(id: historyID"))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("history-output-" + UUID().uuidString)
    }
}
