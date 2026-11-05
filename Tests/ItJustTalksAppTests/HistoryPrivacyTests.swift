import Foundation
import Testing
@testable import ItJustTalks

@Suite("QA-34 history deletion privacy")
@MainActor
struct HistoryPrivacyTests {
    @Test func deleteLeavesNoStoredBodyOnDisk() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "P7_HISTORY_MARKER_ムラサキ_\(UUID().uuidString)"
        let entry = InputHistoryEntry.aiCommandTranscript("合成テキスト \(marker)")
        let store = InputHistoryStore(storageRootURL: root)
        #expect(store.append(entry, retentionDays: 0) == .saved)
        #expect(store.entries.contains { $0.id == entry.id })
        #expect(try fileBytes(under: root).contains { $0.range(of: Data(marker.utf8)) != nil })

        #expect(store.delete(id: entry.id) == .saved)
        #expect(!store.entries.contains { $0.id == entry.id })
        for bytes in try fileBytes(under: root) {
            #expect(bytes.range(of: Data(marker.utf8)) == nil)
        }
        let reloaded = InputHistoryStore(storageRootURL: root)
        #expect(!reloaded.entries.contains { $0.id == entry.id })
    }

    @Test func deleteAllLeavesNoStoredBodiesOnDisk() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let markers = ["P7_HISTORY_MARKER_ムラサキ_\(UUID().uuidString)",
                       "P7_HISTORY_MARKER_ミドリ_\(UUID().uuidString)"]
        let store = InputHistoryStore(storageRootURL: root)
        for marker in markers {
            #expect(store.append(.aiCommandTranscript("合成テキスト \(marker)"), retentionDays: 0) == .saved)
        }
        #expect(store.entries.count == 2)
        let before = try fileBytes(under: root)
        for marker in markers {
            #expect(before.contains { $0.range(of: Data(marker.utf8)) != nil })
        }

        #expect(store.deleteAll() == .saved)
        #expect(store.entries.isEmpty)
        for bytes in try fileBytes(under: root) {
            for marker in markers {
                #expect(bytes.range(of: Data(marker.utf8)) == nil)
            }
        }
        #expect(InputHistoryStore(storageRootURL: root).entries.isEmpty)
    }

    @Test func disabledHistoryNeverStoresNonemptyOutput() {
        let results: [TextInjectorResult] = [
            .inserted, .unicodeSubmitted, .scopedClipboardFallbackSubmitted,
            .externalCompatibilityDisabled, .manualFallbackRequired, .clipboardMayHaveBeenLost,
            .clipboardVariantPasteConfirmed, .clipboardVariantPasteSubmittedUnverified,
            .clipboardVariantPasteMayHaveLostClipboard, .insertionUnconfirmed,
            .secureInputBlocked, .failed(CocoaError(.fileWriteUnknown)),
        ]
        for result in results {
            for cleanupEnabled in [false, true] {
                for cleanupDidFail in [false, true] {
                    #expect(!NormalInputHistoryPolicy.shouldStoreText(
                        historyEnabled: false, cleanupEnabled: cleanupEnabled,
                        cleanupDidFail: cleanupDidFail, output: "合成の非空出力", result: result
                    ))
                }
            }
        }
    }

    @Test func allThreeModesWithHistoryOffLeaveNoBodyOnDisk() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InputHistoryStore(storageRootURL: root)
        let marker = "SYNTHETIC_HISTORY_OFF_" + UUID().uuidString
        for mode in [InputHistoryMode.voiceInput, InputHistoryMode.handsFreeSend, InputHistoryMode.aiCommand] {
            if mode == InputHistoryMode.aiCommand {
                for source in [AICommandInputSource.selection, .clipboard] {
                    for startEnabled in [false, true] {
                        var settings = AICommandSettings.default
                        settings.historyEnabled = startEnabled
                        #expect(store.recordAICommandTranscriptIfNeeded(marker, settings: settings,
                            currentHistoryEnabled: false, inputSource: source) == .saved)
                    }
                }
            } else {
                for cleanupEnabled in [false, true] {
                    #expect(store.recordNormalInputIfNeeded(mode: mode, historyEnabled: false,
                        historyRetentionDays: 180, textToInsert: marker, cleanupEnabled: cleanupEnabled,
                        cleanupDidFail: false, insertResult: .inserted, cleanupLatencyMs: nil) == .saved)
                }
            }
            #expect(store.entries.isEmpty)
            #expect(InputHistoryStore(storageRootURL: root).entries.isEmpty)
            #expect(try fileBytes(under: root).allSatisfy { $0.range(of: Data(marker.utf8)) == nil })
        }
    }

    @Test func deleteAllRefusesLinkedDirectoriesAndDirectoryLeaf() throws {
        let fm = FileManager.default
        for linkedRoot in [false, true] {
            let container = try temporaryRoot()
            defer { try? fm.removeItem(at: container) }
            let outside = container.appendingPathComponent("outside")
            let root = container.appendingPathComponent("root")
            try fm.createDirectory(at: outside.appendingPathComponent("history"), withIntermediateDirectories: true)
            let victim = outside.appendingPathComponent("history/input_history.jsonl")
            let data = Data("synthetic malformed history".utf8)
            try data.write(to: victim)
            if linkedRoot {
                try fm.createSymbolicLink(at: root, withDestinationURL: outside)
            } else {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: root.appendingPathComponent("history"),
                                          withDestinationURL: outside.appendingPathComponent("history"))
            }
            let store = InputHistoryStore(storageRootURL: root)
            #expect(store.loadStatus == .unreadable)
            #expect(store.deleteAll() == .failed)
            #expect(store.lastOperationFailed)
            #expect(try Data(contentsOf: victim) == data)
        }
        let root = try temporaryRoot()
        defer { try? fm.removeItem(at: root) }
        let store = InputHistoryStore(storageRootURL: root)
        let leaf = root.appendingPathComponent("history/input_history.jsonl")
        try fm.createDirectory(at: leaf, withIntermediateDirectories: true)
        let child = leaf.appendingPathComponent("synthetic")
        try Data("synthetic".utf8).write(to: child)
        #expect(store.deleteAll() == .failed)
        #expect(fm.fileExists(atPath: child.path))
    }

    @Test func orphanedHistoryTempsAreRemovedAtStartupAndDeleteAll() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InputHistoryStore(storageRootURL: root)
        let directory = root.appendingPathComponent("history")
        for startup in [true, false] {
            for prefix in [".storage-", ".history-"] {
                try Data("SYNTHETIC_ORPHAN".utf8).write(to:
                    directory.appendingPathComponent(prefix + UUID().uuidString + ".tmp"))
            }
            if startup { StoragePermissions.remediateStorageRoot(root) }
            else { #expect(store.deleteAll() == .saved) }
            #expect(try fileBytes(under: root).isEmpty)
        }
        let unrelated = directory.appendingPathComponent("unrelated.tmp")
        try Data("synthetic".utf8).write(to: unrelated)
        #expect(store.deleteAll() == .saved)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fileBytes(under directory: URL) throws -> [Data] {
        var files: [Data] = []
        for url in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                files.append(contentsOf: try fileBytes(under: url))
            } else {
                files.append(try Data(contentsOf: url))
            }
        }
        return files
    }
}
