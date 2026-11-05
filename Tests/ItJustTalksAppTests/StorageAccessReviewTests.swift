import Foundation
import Darwin
import Testing
@testable import ItJustTalks

@Suite struct StorageAccessReviewTests {
    @Test func loggerRefusesLinkedRootDirectoryAndFiles() throws {
        let fm = FileManager.default
        for kind in 0..<4 {
            let container = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? fm.removeItem(at: container) }
            let root = container.appendingPathComponent("root")
            let outside = container.appendingPathComponent("outside")
            try fm.createDirectory(at: outside.appendingPathComponent("logs"), withIntermediateDirectories: true)
            let victim = outside.appendingPathComponent("logs/itjusttalks.log")
            let original = Data(repeating: 0x31, count: 5 * 1024 * 1024 + 1)
            try original.write(to: victim)
            if kind == 0 {
                try fm.createSymbolicLink(at: root, withDestinationURL: outside)
            } else {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
                let logs = root.appendingPathComponent("logs")
                if kind == 1 {
                    try fm.createSymbolicLink(at: logs, withDestinationURL: outside.appendingPathComponent("logs"))
                } else {
                    try fm.createDirectory(at: logs, withIntermediateDirectories: true)
                    let target = logs.appendingPathComponent("itjusttalks.log")
                    if kind == 2 { try fm.createSymbolicLink(at: target, withDestinationURL: victim) }
                    else { try fm.linkItem(at: victim, to: target) }
                }
            }
            let logger = AppLog(storageRootURL: root)
            logger.rotateIfNeeded()
            logger.append("count=1\n")
            #expect(try Data(contentsOf: victim) == original)
            #expect(!fm.fileExists(atPath: outside.appendingPathComponent("logs/itjusttalks.log.1").path))
        }
    }

    @Test func recoveryRefusesLinkedParentAndHardLinkedFile() throws {
        let fm = FileManager.default
        let container = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: container) }
        let outside = container.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("dictionary.json")
        let original = Data("synthetic dictionary".utf8)
        try original.write(to: victim)
        let linked = container.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: outside)
        let unsafe = linked.appendingPathComponent("dictionary.json")
        #expect(throws: (any Error).self) { try DictionaryRecoveryFileIO.live.read(unsafe) }
        #expect(throws: (any Error).self) { try DictionaryRecoveryFileIO.live.atomicWrite(Data(), unsafe) }
        #expect(throws: (any Error).self) {
            try DictionaryRecoveryFileIO.live.createExclusive(Data(), linked.appendingPathComponent("backup.json"))
        }
        let hardLink = container.appendingPathComponent("hard.json")
        try fm.linkItem(at: victim, to: hardLink)
        #expect(throws: (any Error).self) { try DictionaryRecoveryFileIO.live.read(hardLink) }
        #expect(throws: (any Error).self) { try DictionaryRecoveryFileIO.live.atomicWrite(Data(), hardLink) }
        #expect(try Data(contentsOf: victim) == original)
    }

    @Test func recoverySafetyErrorsPreserveExternalDataAndPermissions() throws {
        let fm = FileManager.default
        let container = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: container) }
        let actual = container.appendingPathComponent("actual")
        let alias = container.appendingPathComponent("ancestor")
        try fm.createDirectory(at: actual.appendingPathComponent("root"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: actual)
        let root = alias.appendingPathComponent("root")
        let original = Data("synthetic recovery data".utf8)
        let main = root.appendingPathComponent("dictionary.json")
        try original.write(to: main)
        #expect(try DictionaryRecoveryFileIO.live.read(main) == original)

        let outside = container.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let recovery = root.appendingPathComponent("Recovery")
        try fm.createSymbolicLink(at: recovery, withDestinationURL: outside)
        #expect(throws: DictionaryRecoveryError.unsafeFile) {
            try DictionaryRecoveryFileIO.live.createDirectory(recovery)
        }
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
        try fm.removeItem(at: recovery)
        try DictionaryRecoveryFileIO.live.createDirectory(recovery)

        let shared = outside.appendingPathComponent("shared.json")
        try original.write(to: shared)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: shared.path)
        let backup = recovery.appendingPathComponent("backup.json")
        try fm.linkItem(at: shared, to: backup)
        #expect(throws: DictionaryRecoveryError.backupAlreadyExists) {
            try DictionaryRawBackupWriter.create(original, at: backup)
        }
        #expect(throws: DictionaryRecoveryError.unsafeFile) {
            try DictionaryRecoveryFileIO.live.read(backup)
        }
        let mode = try fm.attributesOfItem(atPath: shared.path)[.posixPermissions] as? NSNumber
        #expect(mode.map { $0.intValue & 0o777 } == 0o640)
        #expect(try Data(contentsOf: shared) == original)
        #expect(try Data(contentsOf: main) == original)
    }

    @Test func emptyRecoveryBackupIsVerifiedAndPublished() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let backup = root.appendingPathComponent("empty.json")
        try DictionaryRawBackupWriter.create(Data(), at: backup)
        #expect(try DictionaryRecoveryFileIO.live.read(backup).isEmpty)
    }

    @Test func recoveryBackupVerifiesBeforeExclusivePublication() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let backup = root.appendingPathComponent("backup.json")
        let original = Data("synthetic backup".utf8)
        #expect(throws: DictionaryRecoveryError.verificationFailed) {
            try DictionaryRawBackupWriter.create(original, at: backup, writeContents: { _, _ in })
        }
        #expect(!fm.fileExists(atPath: backup.path))
        try DictionaryRawBackupWriter.create(original, at: backup)
        #expect(try DictionaryRecoveryFileIO.live.read(backup) == original)
        #expect(throws: DictionaryRecoveryError.backupAlreadyExists) {
            try DictionaryRawBackupWriter.create(Data(), at: backup)
        }
        #expect(try DictionaryRecoveryFileIO.live.read(backup) == original)
    }
}
