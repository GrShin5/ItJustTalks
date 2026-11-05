import Foundation
import Testing
@testable import ItJustTalks

@Suite("Corrupted history deletion UI quality")
@MainActor
struct HistoryUIQualityTests {
    @Test(arguments: [false, true])
    func corruptedHistoryAllowsWholeFileDeletionButBlocksPartialEdits(unreadable: Bool) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InputHistoryStore(storageRootURL: root)
        let entry = InputHistoryEntry.aiCommandTranscript("Synthetic history body")
        #expect(store.append(entry, retentionDays: 0) == .saved)
        let file = root.appendingPathComponent("history/input_history.jsonl")
        var damaged = try Data(contentsOf: file)
        damaged.append(unreadable ? Data([0xFF]) : Data("not synthetic JSON\n".utf8))
        try damaged.write(to: file)
        store.load()
        #expect(store.loadStatus == (unreadable ? .unreadable : .malformed(rowCount: 1)))
        #expect(store.deleteEntriesWithoutStoredText() == .blockedByMalformedHistory)
        if !unreadable {
            #expect(store.delete(id: entry.id) == .blockedByMalformedHistory)
            #expect(store.setExcluded(id: entry.id, excluded: true) == .blockedByMalformedHistory)
        }
        #expect(try Data(contentsOf: file) == damaged)
        #expect(store.deleteAll() == .saved)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.entries.isEmpty)
        #expect(store.loadStatus == .missing)
        #expect(!store.lastOperationFailed)
        #expect(InputHistoryStore(storageRootURL: root).loadStatus == .missing)
        #expect(store.deleteAll() == .saved)
    }

    @Test func deletionFailurePreservesCorruptedFileAndCanRetry() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("input_history.jsonl")
        let damaged = Data("invalid synthetic JSON\n".utf8)
        try damaged.write(to: file)
        var failRemoval = true
        var fileIO = InputHistoryFileIO.live
        fileIO.remove = { url in
            if failRemoval { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        let store = InputHistoryStore(storageRootURL: root, fileIO: fileIO)
        #expect(store.entries.isEmpty)
        #expect(store.deleteAll() == .failed)
        #expect(store.loadStatus == .malformed(rowCount: 1))
        #expect(store.lastOperationFailed)
        #expect(try Data(contentsOf: file) == damaged)
        failRemoval = false
        #expect(store.deleteAll() == .saved)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func corruptedHistoryDeleteAllIsEnabledAndExplicitlyConfirmed() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/ItJustTalks/Settings/SettingsView.swift"), encoding: .utf8)
        #expect(source.contains(".disabled(historyStore.entries.isEmpty && !historyNeedsAttention)"))
        #expect(source.contains("result = historyStore.deleteAll()"))
        #expect(source.contains(".disabled(historyStore.metadataOnlyCount == 0 || historyNeedsAttention)"))
        #expect(source.contains(".disabled(selectedVisibleHistoryIDs.isEmpty || historyNeedsAttention)"))
        #expect(source.contains(".disabled(unselectedVisibleHistoryIDs.isEmpty || historyNeedsAttention)"))
        #expect(source.contains(".sheet(isPresented: historyDeletionConfirmationBinding)"))
        let key = "破損または読み取れない履歴ファイル全体を削除します。表示できない本文やメタデータもすべて削除されます。件数は確認できません。この操作は元に戻せません。"
        #expect(source.contains(key))
        for language in AppLanguage.allCases {
            #expect(AppLocalizer.hasTranslation(for: key, language: language))
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
