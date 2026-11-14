import Foundation
import Combine
import Darwin

struct InputHistoryFileIO {
    var read: (URL) throws -> Data
    var append: (Data, URL) throws -> Void
    var atomicWrite: (Data, URL) throws -> Void
    var remove: (URL) throws -> Void

    static let live = InputHistoryFileIO(
        read: { url in
            let descriptor = try StoragePermissions.openRegularFile(
                at: url, flags: O_RDONLY, storageRoot: url.deletingLastPathComponent().deletingLastPathComponent()
            )
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            return try handle.readToEnd() ?? Data()
        },
        append: { data, url in
            let descriptor = try StoragePermissions.openRegularFile(
                at: url, flags: O_WRONLY | O_APPEND | O_CREAT,
                storageRoot: url.deletingLastPathComponent().deletingLastPathComponent()
            )
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            _ = fchmod(descriptor, mode_t(StoragePermissions.filePosixPermissions))
            try handle.write(contentsOf: data)
            try handle.synchronize()
        },
        atomicWrite: { data, url in
            try StoragePermissions.writeHistoryAtomically(
                data, to: url, storageRoot: url.deletingLastPathComponent().deletingLastPathComponent()
            )
        },
        remove: { url in
            let root = url.deletingLastPathComponent().deletingLastPathComponent()
            try StoragePermissions.removeOrphanedTemporaryFiles(in: url.deletingLastPathComponent(), storageRoot: root)
            try StoragePermissions.removeRegularFile(at: url, storageRoot: root)
        }
    )
}

@MainActor
final class InputHistoryStore: ObservableObject {
    enum LoadStatus: Equatable {
        case missing
        case ready
        case malformed(rowCount: Int)
        case unreadable
    }
    enum MutationResult: Equatable { case saved, savedWithCleanupWarning, blockedByMalformedHistory, failed }

    @Published private(set) var entries: [InputHistoryEntry] = []
    @Published private(set) var loadStatus: LoadStatus = .missing
    @Published private(set) var lastOperationFailed = false

    private let directoryURL: URL
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileIO: InputHistoryFileIO

    init(storageRootURL: URL? = nil, fileIO: InputHistoryFileIO = .live) {
        let root: URL
        if let storageRootURL { root = storageRootURL }
        else {
            root = OnboardingRuntimeProfile.productionStorageRootURL
        }
        directoryURL = root.appendingPathComponent("history", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("input_history.jsonl")
        self.fileIO = fileIO
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; self.encoder = encoder
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; self.decoder = decoder
        StoragePermissions.ensureDirectory(at: root)
        StoragePermissions.ensureDirectory(at: directoryURL, storageRoot: directoryURL.deletingLastPathComponent())
        load()
    }

    @discardableResult
    func recordOutput(
        id: UUID = UUID(), mode: String, output: String, kind: String, status: String,
        marks: [String] = [], sourceLabel: AICommandInputSource? = nil,
        startHistoryEnabled: Bool, currentHistoryEnabled: Bool, retentionDays: Int,
        cleanupEnabled: Bool = false, cleanupDidFail: Bool = false, latencyMs: Int? = nil
    ) -> MutationResult {
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VoiceSession.allowsAIHistory(startEnabled: startHistoryEnabled,
                                          currentEnabled: currentHistoryEnabled),
              !output.isEmpty else { return .saved }
        guard !entries.contains(where: { $0.id == id }) else { return .saved }
        return append(InputHistoryEntry(
            id: id, mode: mode, storedText: output, storedTextKind: kind,
            cleanupEnabled: cleanupEnabled, cleanupSucceeded: cleanupEnabled && !cleanupDidFail,
            insertStatus: status, flags: marks, modelSlug: nil, reasoningEffort: nil,
            latencyMs: latencyMs, aiCommandInputSource: sourceLabel
        ), retentionDays: retentionDays)
    }

    /// Legacy API cannot record a spoken instruction. Kept for history-off privacy checks.
    @discardableResult
    func recordAICommandTranscriptIfNeeded(
        _ transcript: String, settings: AICommandSettings, currentHistoryEnabled: Bool,
        inputSource: AICommandInputSource
    ) -> MutationResult { .saved }

    @discardableResult
    func recordNormalInputIfNeeded(
        mode: String, historyEnabled: Bool, historyRetentionDays: Int, textToInsert: String,
        cleanupEnabled: Bool, cleanupDidFail: Bool, insertResult: TextInjectorResult, cleanupLatencyMs: Int?
    ) -> MutationResult {
        guard NormalInputHistoryPolicy.shouldRecord(insertResult),
              let decision = HistoryRecordingPolicy.decision(mode: mode, output: textToInsert,
                  situation: .inserted, cleanupEnabled: cleanupEnabled, cleanupDidFail: cleanupDidFail)
        else { return .saved }
        return recordOutput(mode: mode, output: textToInsert, kind: decision.kind, status: decision.status,
            marks: decision.marks, startHistoryEnabled: historyEnabled, currentHistoryEnabled: historyEnabled,
            retentionDays: historyRetentionDays, cleanupEnabled: cleanupEnabled,
            cleanupDidFail: cleanupDidFail, latencyMs: cleanupLatencyMs)
    }

    @discardableResult
    func updateInsertStatus(id: UUID, status: String) -> MutationResult {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].insertStatus != status else { return .saved }
        var candidate = entries
        candidate[index].insertStatus = status
        return rewriteAndPublish(candidate)
    }

    func load() {
        let data: Data
        do { data = try fileIO.read(fileURL) }
        catch {
            entries = []
            let value = error as NSError
            loadStatus = value.domain == NSCocoaErrorDomain && value.code == NSFileReadNoSuchFileError ? .missing : .unreadable
            return
        }
        guard let content = String(data: data, encoding: .utf8) else {
            entries = []; loadStatus = .unreadable; return
        }
        var loaded: [InputHistoryEntry] = []
        var malformedCount = 0
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8), let entry = try? decoder.decode(InputHistoryEntry.self, from: lineData) else {
                malformedCount += 1; continue
            }
            loaded.append(entry)
        }
        entries = loaded.sorted { $0.createdAt > $1.createdAt }
        loadStatus = malformedCount == 0 ? .ready : .malformed(rowCount: malformedCount)
        lastOperationFailed = false
    }

    @discardableResult
    func append(_ entry: InputHistoryEntry, retentionDays: Int) -> MutationResult {
        guard entry.isValidForStorage else {
            AppLog.shared.error("[InputHistoryStore] AIに指示の不正な履歴形式を拒否")
            return fail(.failed)
        }
        do {
            StoragePermissions.ensureDirectory(at: directoryURL.deletingLastPathComponent())
            StoragePermissions.ensureDirectory(at: directoryURL, storageRoot: directoryURL.deletingLastPathComponent())
            var line = try encoder.encode(entry)
            line.append(0x0A)
            try fileIO.append(line, fileURL)
            entries.insert(entry, at: 0)
            lastOperationFailed = false
        } catch {
            AppLog.shared.error("[InputHistoryStore] 履歴追記失敗: \(AppLog.safeDescription(error))")
            return fail(.failed)
        }
        // 追記が失敗した場合はここへ到達せず、既存履歴のpruneも実行しない。
        if retentionDays > 0, prune(mode: entry.mode, retentionDays: retentionDays) != .saved {
            return .savedWithCleanupWarning
        }
        return .saved
    }

    func visibleEntries(limit: Int) -> [InputHistoryEntry] { visibleEntries(limit: limit, mode: InputHistoryMode.all) }
    func visibleEntries(limit: Int, mode: String) -> [InputHistoryEntry] {
        let filtered = mode == InputHistoryMode.all ? entries : entries.filter { $0.mode == mode }
        return limit > 0 ? Array(filtered.prefix(limit)) : filtered
    }
    var storedTextCount: Int { entries.filter(Self.hasStoredText).count }
    var metadataOnlyCount: Int { entries.filter { !Self.hasStoredText($0) }.count }
    var metadataOnlyIDs: Set<UUID> { Set(entries.filter { !Self.hasStoredText($0) }.map(\.id)) }

    @discardableResult
    func setExcluded(id: UUID, excluded: Bool) -> MutationResult {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return .saved }
        var candidate = entries
        candidate[index] = candidate[index].withFlag(InputHistoryFlag.excludedByUser, enabled: excluded)
        return rewriteAndPublish(candidate)
    }
    @discardableResult func delete(id: UUID) -> MutationResult { delete(ids: [id]) }
    @discardableResult
    func delete(ids: Set<UUID>) -> MutationResult {
        guard !ids.isEmpty else { return .saved }
        let candidate = entries.filter { !ids.contains($0.id) }
        guard candidate.count != entries.count else { return .saved }
        return rewriteAndPublish(candidate)
    }
    @discardableResult
    func deleteDisplayedEntries(except selectedIDs: Set<UUID>, displayedIDs: Set<UUID>) -> MutationResult {
        guard !displayedIDs.isEmpty else { return .saved }
        return rewriteAndPublish(entries.filter { !displayedIDs.contains($0.id) || selectedIDs.contains($0.id) })
    }
    @discardableResult
    func deleteEntriesWithoutStoredText() -> MutationResult { rewriteAndPublish(entries.filter(Self.hasStoredText)) }
    @discardableResult
    func deleteAll() -> MutationResult {
        // 明示確認された全削除は、破損行を残さずファイル全体を取り除く。
        do {
            try fileIO.remove(fileURL)
            entries = []; loadStatus = .missing; lastOperationFailed = false
            return .saved
        } catch {
            let value = error as NSError
            if value.domain == NSCocoaErrorDomain && value.code == NSFileNoSuchFileError {
                entries = []; loadStatus = .missing; lastOperationFailed = false
                return .saved
            }
            AppLog.shared.error("[InputHistoryStore] 履歴全削除失敗: \(AppLog.safeDescription(error))")
            return fail(.failed)
        }
    }
    @discardableResult func prune(retentionDays: Int) -> MutationResult { prune(mode: InputHistoryMode.voiceInput, retentionDays: retentionDays) }
    @discardableResult
    func prune(mode: String, retentionDays: Int) -> MutationResult {
        guard retentionDays > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else { return .saved }
        let candidate = entries.filter { !($0.mode == mode && $0.createdAt < cutoff) }
        guard candidate.count != entries.count else { return .saved }
        return rewriteAndPublish(candidate)
    }

    private var allowsRewrite: Bool {
        switch loadStatus { case .missing, .ready: return true; case .malformed, .unreadable: return false }
    }
    private func rewriteAndPublish(_ candidate: [InputHistoryEntry]) -> MutationResult {
        guard allowsRewrite else { return fail(.blockedByMalformedHistory) }
        do {
            StoragePermissions.ensureDirectory(at: directoryURL.deletingLastPathComponent())
            StoragePermissions.ensureDirectory(at: directoryURL, storageRoot: directoryURL.deletingLastPathComponent())
            var data = Data()
            for entry in candidate.sorted(by: { $0.createdAt < $1.createdAt }) {
                data.append(try encoder.encode(entry)); data.append(0x0A)
            }
            try fileIO.atomicWrite(data, fileURL)
            entries = candidate; loadStatus = .ready; lastOperationFailed = false
            return .saved
        } catch {
            AppLog.shared.error("[InputHistoryStore] 履歴書き換え失敗: \(AppLog.safeDescription(error))")
            return fail(.failed)
        }
    }
    private func fail(_ result: MutationResult) -> MutationResult { lastOperationFailed = true; return result }
    static func hasStoredText(_ entry: InputHistoryEntry) -> Bool {
        guard let text = entry.storedText else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
