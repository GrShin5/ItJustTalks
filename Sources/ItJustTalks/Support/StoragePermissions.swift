import Foundation
import Darwin

/// ItJustTalksが自前で作成する永続データディレクトリ・ファイルの権限。
/// ディレクトリは0700、ファイルは0600に固定し、リテラルをここへ一元化する。
enum StoragePermissions {
    static let directoryPosixPermissions = 0o700
    static let filePosixPermissions = 0o600
    // 起動時の非同期回収が、進行中の置換保存の一時ファイルを消さないよう直列化する。
    private static let temporaryFileLock = NSLock()

    static var directoryAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: directoryPosixPermissions]
    }

    static var fileAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: filePosixPermissions]
    }

    /// 権限付与は保存の成否契約に含めない。chmodだけ失敗しても書き込みは成功しており、
    /// ここでthrowするとメモリとディスクが食い違い、保存不能扱いになる環境が出る。
    static func applyFileMode(to url: URL, storageRoot: URL? = nil) {
        guard let descriptor = try? openRegularFile(at: url, flags: O_RDONLY, storageRoot: storageRoot) else { return }
        defer { close(descriptor) }
        _ = fchmod(descriptor, mode_t(filePosixPermissions))
    }

    /// ルート自身と配下だけをリンク禁止にする。独自ルートの子を扱う時はルートを明示する。
    static func ensureDirectory(at url: URL, storageRoot: URL? = nil) {
        guard let descriptor = try? openDirectory(at: url, create: true, storageRoot: storageRoot) else { return }
        defer { close(descriptor) }
        _ = fchmod(descriptor, mode_t(directoryPosixPermissions))
    }

    private static func defaultStorageRoot(for url: URL, fallback: URL) -> URL {
        let root = OnboardingRuntimeProfile.storageRootURL ?? OnboardingRuntimeProfile.productionStorageRootURL
        return url.pathComponents.starts(with: root.pathComponents) ? root : fallback
    }

    static func openDirectory(at url: URL, create: Bool, storageRoot: URL? = nil) throws -> Int32 {
        let root = storageRoot ?? defaultStorageRoot(for: url, fallback: url)
        let rootComponents = root.pathComponents
        let components = url.pathComponents
        guard rootComponents.count > 1, components.starts(with: rootComponents),
              !components.contains(".."), !components.contains(".") else {
            throw CocoaError(.fileReadNoPermission)
        }
        // ルート外の祖先リンクは許容する。ルート自身を解決してから開くことはしない。
        let parentURL = root.deletingLastPathComponent()
        var descriptor = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if descriptor < 0, create, errno == ENOENT {
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true,
                                                    attributes: directoryAttributes)
            descriptor = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        do {
            for component in components.dropFirst(rootComponents.count - 1) {
                if create, mkdirat(descriptor, component, mode_t(directoryPosixPermissions)) != 0,
                   errno != EEXIST {
                    throw CocoaError(.fileWriteNoPermission)
                }
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw CocoaError(.fileReadNoPermission) }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// 最終要素は通常ファイル・リンク数1だけを許可する。呼出側が記述子を閉じる。
    static func openRegularFile(at url: URL, flags: Int32, storageRoot: URL? = nil) throws -> Int32 {
        let parentURL = url.deletingLastPathComponent()
        let root = storageRoot ?? defaultStorageRoot(for: url, fallback: parentURL)
        let parent = try openDirectory(at: parentURL, create: false, storageRoot: root)
        defer { close(parent) }
        var before = stat()
        if fstatat(parent, url.lastPathComponent, &before, AT_SYMLINK_NOFOLLOW) == 0 {
            guard before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_nlink == 1 else {
                throw CocoaError(.fileReadNoPermission)
            }
        } else if errno != ENOENT {
            throw CocoaError(.fileReadNoPermission)
        }
        let descriptor = openat(parent, url.lastPathComponent, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
                                mode_t(filePosixPermissions))
        guard descriptor >= 0 else {
            throw CocoaError(errno == ENOENT ? .fileReadNoSuchFile : .fileReadNoPermission)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
            close(descriptor)
            throw CocoaError(.fileReadNoPermission)
        }
        return descriptor
    }

    /// 読み取りも検査済みの記述子を使い、パスを再度開かない。
    static func readData(at url: URL, storageRoot: URL? = nil) throws -> Data {
        let descriptor = try openRegularFile(at: url, flags: O_RDONLY, storageRoot: storageRoot)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    /// 削除対象を検査し、検証済みの親だけを基準に削除する。ディレクトリは削除しない。
    static func removeRegularFile(at url: URL, storageRoot: URL? = nil) throws {
        let parent = try openDirectory(at: url.deletingLastPathComponent(), create: false, storageRoot: storageRoot)
        defer { close(parent) }
        try removeRegularFile(named: url.lastPathComponent, parent: parent)
    }

    private static func removeRegularFile(named name: String, parent: Int32) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw CocoaError(.fileWriteNoPermission)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
              unlinkat(parent, name, 0) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }

    /// 起動時と全削除時だけ呼ぶ。列挙も削除も同じディレクトリ記述子を使う。
    static func removeOrphanedTemporaryFiles(in directory: URL, storageRoot: URL) throws {
        temporaryFileLock.lock()
        defer { temporaryFileLock.unlock() }
        let parent = try openDirectory(at: directory, create: false, storageRoot: storageRoot)
        guard let stream = fdopendir(parent) else {
            close(parent)
            throw CocoaError(.fileReadNoPermission)
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw CocoaError(.fileReadUnknown) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name.hasSuffix(".tmp"),
                  let prefix = [".storage-", ".history-"].first(where: { name.hasPrefix($0) }),
                  UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil else { continue }
            try removeRegularFile(named: name, parent: parent)
        }
    }

    static func rotateLog(at url: URL, maximumBytes: UInt64, storageRoot: URL) throws {
        let parent = try openDirectory(at: url.deletingLastPathComponent(), create: false, storageRoot: storageRoot)
        defer { close(parent) }
        let names = [url.lastPathComponent, url.lastPathComponent + ".1", url.lastPathComponent + ".2"]
        var existing = [Bool]()
        var size: off_t = 0
        for name in names {
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                if name == names[0] { size = info.st_size }
                existing.append(true)
            } else {
                guard errno == ENOENT else { throw CocoaError(.fileReadNoPermission) }
                existing.append(false)
            }
        }
        guard size > 0, UInt64(size) > maximumBytes else { return }
        try removeRegularFile(named: names[2], parent: parent)
        for index in [1, 0] where existing[index] {
            guard renameat(parent, names[index], parent, names[index + 1]) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    static func writeHistoryAtomically(_ data: Data, to url: URL, storageRoot: URL) throws {
        try writeAtomically(data, to: url, storageRoot: storageRoot)
    }

    /// 置換保存は検査済みの親記述子の中だけで完結させる。バックアップは上書き禁止。
    static func writeAtomically(
        _ data: Data, to url: URL, storageRoot: URL? = nil, withoutOverwriting: Bool = false
    ) throws {
        temporaryFileLock.lock()
        defer { temporaryFileLock.unlock() }
        let parent = try openDirectory(at: url.deletingLastPathComponent(), create: false, storageRoot: storageRoot)
        defer { close(parent) }
        var info = stat()
        if fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } else if errno != ENOENT {
            throw CocoaError(.fileWriteNoPermission)
        }
        let temporaryName = ".storage-" + UUID().uuidString + ".tmp"
        let descriptor = openat(parent, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                mode_t(filePosixPermissions))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            unlinkat(parent, temporaryName, 0)
        }
        _ = fchmod(descriptor, mode_t(filePosixPermissions))
        try handle.write(contentsOf: data)
        try handle.synchronize()
        let result = withoutOverwriting
            ? renameatx_np(parent, temporaryName, parent, url.lastPathComponent, UInt32(RENAME_EXCL))
            : renameat(parent, temporaryName, parent, url.lastPathComponent)
        guard result == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// 既存のItJustTalksストレージルート配下の権限を是正する（べき等）。
    /// 作用範囲は`root`配下に閉じる。root自体がsymlinkの場合、リンク先ツリー全体へ
    /// 波及するため何もしない。配下のsymlinkとハードリンクも対象から外す。
    /// 失敗しても起動を止めず、件数をまとめて1回だけ記録する。
    static func remediateStorageRoot(_ root: URL) {
        let fm = FileManager.default
        let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues?.isSymbolicLink != true, rootValues?.isDirectory == true else { return }

        var failureCount = 0
        apply(directoryAttributes, toPath: root.path, storageRoot: root, failureCount: &failureCount)
        do { try removeOrphanedTemporaryFiles(in: root, storageRoot: root) }
        catch { failureCount += 1 }

        // URL版の列挙は/var→/private/varのように祖先リンクを解決したパスを返し、
        // ルートとの前方一致が崩れる。相対パスで列挙してルートから組み立て直す。
        guard let enumerator = fm.enumerator(atPath: root.path) else {
            AppLog.shared.warn("[StoragePermissions] 既存ストレージの列挙に失敗（権限是正をスキップ）")
            return
        }

        while let relativePath = enumerator.nextObject() as? String {
            let url = root.appendingPathComponent(relativePath)
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                failureCount += 1
                continue
            }
            let type = info.st_mode & mode_t(S_IFMT)
            // setAttributesはchmodと同じくsymlinkを辿るため、リンクを是正対象にすると
            // ストレージルート外の権限を書き換えうる。root配下だけという保証を守るため飛ばす。
            if type == mode_t(S_IFLNK) {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = type == mode_t(S_IFDIR)
            if isDirectory {
                do { try removeOrphanedTemporaryFiles(in: url, storageRoot: root) }
                catch { failureCount += 1 }
            }
            // ハードリンクは同じinodeを共有するため、chmodがルート外へ波及する。
            // リンク数が1を超えるファイルは対象外にして、作用範囲をroot配下に閉じる。
            if !isDirectory, info.st_nlink > 1 { continue }
            apply(
                isDirectory ? directoryAttributes : fileAttributes,
                toPath: url.path,
                storageRoot: root,
                failureCount: &failureCount
            )
        }

        if failureCount > 0 {
            AppLog.shared.warn("[StoragePermissions] 権限是正に失敗した項目があります: \(failureCount)件")
        }
    }

    private static func apply(
        _ attributes: [FileAttributeKey: Any],
        toPath path: String,
        storageRoot: URL,
        failureCount: inout Int
    ) {
        do {
            let url = URL(fileURLWithPath: path)
            let directory = attributes[.posixPermissions] as? Int == directoryPosixPermissions
            let descriptor = try directory ? openDirectory(at: url, create: false, storageRoot: storageRoot)
                : openRegularFile(at: url, flags: O_RDONLY, storageRoot: storageRoot)
            defer { close(descriptor) }
            guard fchmod(descriptor, mode_t(directory ? directoryPosixPermissions : filePosixPermissions)) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } catch {
            failureCount += 1
        }
    }
}
