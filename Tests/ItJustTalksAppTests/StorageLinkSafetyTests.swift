import Foundation
import Darwin
import Testing
@testable import ItJustTalks

@MainActor
@Suite struct StorageLinkSafetyTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test(arguments: [false, true])
    func sharedStorageIORejectsFileLinks(hardLink: Bool) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("synthetic-target")
        let bytes = Data("synthetic".utf8)
        try bytes.write(to: target)
        for name in ["settings.json", "optimizer.json", "onboarding.json"] {
            let file = root.appendingPathComponent(name)
            if hardLink { try FileManager.default.linkItem(at: target, to: file) }
            else { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target) }
            #expect(throws: (any Error).self) { try StoragePermissions.readData(at: file) }
            #expect(throws: (any Error).self) {
                try StoragePermissions.writeAtomically(Data("replacement".utf8), to: file)
            }
            #expect(try Data(contentsOf: target) == bytes)
        }
        #expect(SettingsStore(storageRootURL: root).loadStatus == .failedToDecode)
        let optimizer = CustomInstructionStateStore(fileName: "optimizer.json", legacyFileName: nil, storageRootURL: root)
        #expect(optimizer.state.customInstructionHistory.isEmpty)
        optimizer.recordCustomInstructionSave("合成指示", previousInstruction: nil)
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test(arguments: [false, true])
    func storesRejectLinkedValidDocuments(hardLink: Bool) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        func installLink(_ source: URL, name: String) throws -> URL {
            let destination = root.appendingPathComponent(name)
            if hardLink { try FileManager.default.linkItem(at: source, to: destination) }
            else { try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source) }
            return destination
        }
        let settingsSource = root.appendingPathComponent("settings-source")
        try JSONEncoder().encode(ItJustTalksSettings.default).write(to: settingsSource)
        _ = try installLink(settingsSource, name: "settings.json")
        #expect(SettingsStore(storageRootURL: root).loadStatus == .failedToDecode)

        let optimizerSource = root.appendingPathComponent("optimizer-source")
        let original = CustomInstructionStateStore(fileName: optimizerSource.lastPathComponent,
            legacyFileName: nil, storageRootURL: root)
        original.recordCustomInstructionSave("合成の保存済み指示", previousInstruction: nil)
        let optimizerBytes = try Data(contentsOf: optimizerSource)
        _ = try installLink(optimizerSource, name: "optimizer.json")
        let linked = CustomInstructionStateStore(fileName: "optimizer.json", legacyFileName: nil, storageRootURL: root)
        #expect(linked.state.customInstructionHistory.isEmpty)
        linked.recordCustomInstructionSave("合成の変更指示", previousInstruction: nil)
        #expect(try Data(contentsOf: optimizerSource) == optimizerBytes)

        let intent = try #require(OnboardingRestartIntent(mode: .firstRun, step: .welcome,
            bundleIdentifier: "test.synthetic"))
        let onboardingSource = root.appendingPathComponent("onboarding-source")
        let bytes = try JSONEncoder().encode(intent)
        try bytes.write(to: onboardingSource)
        let onboardingLink = try installLink(onboardingSource, name: "onboarding.json")
        let onboarding = OnboardingRestartIntentStore(fileURL: onboardingLink)
        #expect(throws: (any Error).self) { try onboarding.save(intent) }
        #expect(onboarding.load(bundleIdentifier: "test.synthetic") == nil)
        #expect(try Data(contentsOf: onboardingSource) == bytes)
    }

    @Test func sharedAtomicWriterAllowsAncestorLinksAndPreservesExclusiveBackup() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let parent = base.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let alias = base.appendingPathComponent("ancestor")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
        let root = alias.appendingPathComponent("storage")
        StoragePermissions.ensureDirectory(at: root)
        let file = root.appendingPathComponent("settings.json")
        let bytes = Data("synthetic".utf8)
        try StoragePermissions.writeAtomically(bytes, to: file, withoutOverwriting: true)
        #expect(try StoragePermissions.readData(at: file) == bytes)
        #expect(try mode(file) == 0o600)
        #expect(throws: (any Error).self) {
            try StoragePermissions.writeAtomically(Data("replace".utf8), to: file, withoutOverwriting: true)
        }
        #expect(try StoragePermissions.readData(at: file) == bytes)
        try StoragePermissions.writeAtomically(Data("replace".utf8), to: file)
        #expect(try StoragePermissions.readData(at: file) == Data("replace".utf8))
    }

    @Test(arguments: [false, true])
    func historyFileLinksCannotBeReadAppendedOrChmodded(hardLink: Bool) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("history")
        StoragePermissions.ensureDirectory(at: directory)
        let target = root.appendingPathComponent("synthetic-target")
        let bytes = Data("synthetic-link-target".utf8)
        try bytes.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let link = directory.appendingPathComponent("input_history.jsonl")
        if hardLink { try FileManager.default.linkItem(at: target, to: link) }
        else { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target) }
        #expect(throws: (any Error).self) { try InputHistoryFileIO.live.read(link) }
        #expect(throws: (any Error).self) { try InputHistoryFileIO.live.append(Data("append".utf8), link) }
        #expect(throws: (any Error).self) { try InputHistoryFileIO.live.atomicWrite(Data("replace".utf8), link) }
        StoragePermissions.applyFileMode(to: link)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try mode(target) == 0o644)
        let store = InputHistoryStore(storageRootURL: root)
        #expect(store.loadStatus == .unreadable)
        #expect(store.append(.aiCommandTranscript("合成入力"), retentionDays: 0) == .failed)
        #expect(store.entries.isEmpty)
    }

    @Test(arguments: [false, true])
    func rootAndChildDirectoryLinksAreRejected(child: Bool) throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let root = base.appendingPathComponent("root")
        let link: URL
        if child {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            link = root.appendingPathComponent("history")
        } else { link = root }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        StoragePermissions.ensureDirectory(at: link)
        let store = InputHistoryStore(storageRootURL: root)
        #expect(store.loadStatus == .unreadable)
        #expect(store.append(.aiCommandTranscript("合成入力"), retentionDays: 0) == .failed)
        #expect(try mode(target) == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func ordinaryHistoryStillReadsAndAppends() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InputHistoryStore(storageRootURL: root)
        let entry = InputHistoryEntry.aiCommandTranscript("通常の合成入力")
        #expect(store.append(entry, retentionDays: 0) == .saved)
        #expect(InputHistoryStore(storageRootURL: root).entries.map(\.id) == [entry.id])
        #expect(store.delete(id: entry.id) == .saved)
        #expect(InputHistoryStore(storageRootURL: root).entries.isEmpty)
        #expect(try mode(root.appendingPathComponent("history/input_history.jsonl")) == 0o600)
    }

    @Test func ancestorSymlinkAllowsHistoryAndPermissionUpdates() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let parent = base.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        let alias = base.appendingPathComponent("ancestor-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
        let root = alias.appendingPathComponent("storage")
        let store = InputHistoryStore(storageRootURL: root)
        #expect(store.loadStatus == .missing)
        let entry = InputHistoryEntry.aiCommandTranscript("祖先リンク経由の合成入力")
        #expect(store.append(entry, retentionDays: 0) == .saved)
        #expect(InputHistoryStore(storageRootURL: root).entries.map(\.id) == [entry.id])
        let file = root.appendingPathComponent("history/input_history.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        StoragePermissions.applyFileMode(to: file, storageRoot: root)
        #expect(try mode(file) == 0o600)
        #expect(try mode(root) == 0o700)
        #expect(try mode(parent) == 0o755)
        #expect(store.delete(id: entry.id) == .saved)
        #expect(InputHistoryStore(storageRootURL: root).entries.isEmpty)
        #expect(store.append(entry, retentionDays: 0) == .saved)
        #expect(store.deleteAll() == .saved)
    }

    @Test(arguments: [false, true])
    func ancestorSymlinkDoesNotPermitRootOrChildSymlink(child: Bool) throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let parent = base.appendingPathComponent("parent")
        let target = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let alias = base.appendingPathComponent("ancestor-link")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
        let root = alias.appendingPathComponent("storage")
        if child { StoragePermissions.ensureDirectory(at: root) }
        let link = child ? root.appendingPathComponent("history") : root
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = InputHistoryStore(storageRootURL: root)
        #expect(store.loadStatus == .unreadable)
        #expect(store.append(.aiCommandTranscript("合成入力"), retentionDays: 0) == .failed)
        let file = root.appendingPathComponent("history/input_history.jsonl")
        #expect(throws: (any Error).self) { try InputHistoryFileIO.live.atomicWrite(Data(), file) }
        #expect(try mode(target) == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test(arguments: [false, true])
    func ancestorSymlinkDoesNotPermitFileLinks(hardLink: Bool) throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let alias = base.appendingPathComponent("ancestor-link")
        let parent = base.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)
        let root = alias.appendingPathComponent("storage")
        let directory = root.appendingPathComponent("history")
        StoragePermissions.ensureDirectory(at: directory, storageRoot: root)
        let target = base.appendingPathComponent("outside-file")
        let original = Data("synthetic".utf8)
        try original.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let file = directory.appendingPathComponent("input_history.jsonl")
        if hardLink { try FileManager.default.linkItem(at: target, to: file) }
        else { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target) }
        #expect(throws: (any Error).self) { try InputHistoryFileIO.live.read(file) }
        #expect(throws: (any Error).self) { try InputHistoryFileIO.live.append(Data(), file) }
        #expect(throws: (any Error).self) { try InputHistoryFileIO.live.atomicWrite(Data(), file) }
        StoragePermissions.applyFileMode(to: file, storageRoot: root)
        #expect(try Data(contentsOf: target) == original)
        #expect(try mode(target) == 0o644)
    }

    @Test func nestedDirectorySymlinkCannotEscapeExplicitRoot() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("storage")
        let nested = root.appendingPathComponent("one/two")
        StoragePermissions.ensureDirectory(at: nested, storageRoot: root)
        let target = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let file = target.appendingPathComponent("synthetic-file")
        try Data("synthetic".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let link = nested.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let escapedFile = link.appendingPathComponent("synthetic-file")
        #expect(throws: (any Error).self) {
            let descriptor = try StoragePermissions.openRegularFile(at: escapedFile, flags: O_RDONLY, storageRoot: root)
            close(descriptor)
        }
        StoragePermissions.applyFileMode(to: escapedFile, storageRoot: root)
        StoragePermissions.ensureDirectory(at: link.appendingPathComponent("new"), storageRoot: root)
        #expect(try mode(file) == 0o644)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("new").path))
    }

}
