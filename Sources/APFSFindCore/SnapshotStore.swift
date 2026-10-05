import CAPFSShim
import CryptoKit
import Darwin
import Foundation

/// A pinned 0700 directory plus a per-root advisory lock. All snapshot operations
/// are *at calls on the directory descriptor; path replacement cannot redirect
/// publication or cleanup. The zero-byte .lock is coordination, never a WAL.
public final class SnapshotStore: @unchecked Sendable {
    public let directory: String
    public let filename: String
    public var path: String { directory + "/" + filename }
    private let directoryFD: Int32
    private let lockFD: Int32
    private let activityLock = NSLock()
    private var publishing = false

    public static var defaultDirectory: String {
        NSHomeDirectory() + "/Library/Application Support/apfsfind/indexes"
    }
    public static func normalizedDirectory(_ directory: String) throws -> String {
        let expanded = (directory as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        guard var normalized = PathCanonicalizer.normalize(absolute) else { throw SnapshotError.unsafePath(directory) }
        // macOS mktemp returns /var/... and users commonly pass /tmp/... .
        // Permit only these root-owned OS aliases; never resolve arbitrary
        // symlinks in a supplied cache path or its remaining components.
        for (alias, destination) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if normalized == alias || normalized.hasPrefix(alias + "/") {
                var info = stat()
                if lstat(alias, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFLNK {
                    var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX))
                    let count = readlink(alias, &bytes, bytes.count)
                    if count > 0 {
                        let target = String(decoding: bytes.prefix(count), as: UTF8.self)
                        guard target == destination || "/" + target == destination else { throw SnapshotError.unsafePath(alias) }
                        normalized = destination + String(normalized.dropFirst(alias.count))
                    }
                }
            }
        }
        return normalized
    }
    public init(directory: String, identity: VolumeIdentity) throws {
        let normalized = try Self.normalizedDirectory(directory)
        guard normalized != "/",
              !PathCanonicalizer.isWithin(identity.root, root: normalized) else {
            throw SnapshotError.unsafePath(directory)
        }
        self.directory = normalized
        var key = Data(identity.root.utf8); key.append(0); key.append(contentsOf: identity.volumeUUID.bytes)
        filename = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined() + ".apfsidx"
        let fd = apfs_open_cache_directory(normalized, 1)
        guard fd >= 0 else { throw SnapshotError.io("open cache (no symlinks)", errno) }
        let lock = openat(fd, filename + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { let code = errno; close(fd); throw SnapshotError.io("open lock", code) }
        var metadata = stat()
        guard fstat(lock, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o7777 == 0o600 else {
            close(lock); close(fd); throw SnapshotError.unsafePath("checkpoint lock")
        }
        directoryFD = fd; lockFD = lock
        // Do not remove another process's active temp. The lock is also released
        // automatically after SIGKILL, allowing the next opener to clean it up.
        if flock(lockFD, LOCK_EX | LOCK_NB) == 0 {
            cleanupTemps()
            _ = flock(lockFD, LOCK_UN)
        }
    }
    deinit { close(lockFD); close(directoryFD) }

    public func reader(expectedIdentity: VolumeIdentity) throws -> SnapshotReader {
        let fd = openat(directoryFD, filename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw SnapshotError.io("open", errno) }
        return try SnapshotReader(fileDescriptor: fd, expectedIdentity: expectedIdentity)
    }

    public var statePath: String { path + ".state" }
    func readState() throws -> Data {
        let fd = openat(directoryFD, filename + ".state", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw SnapshotError.io("open state", errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == geteuid(), st.st_mode & S_IFMT == S_IFREG,
              st.st_mode & 0o7777 == 0o600, st.st_size == CursorState.size else { throw SnapshotError.invalid("state metadata") }
        var data = Data(repeating: 0, count: CursorState.size)
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == CursorState.size else { throw SnapshotError.invalid("state truncated") }
        return data
    }
    public func effectiveCursor(for header: SnapshotHeader) -> (cursor: UInt64, valid: Bool) {
        guard let bytes = try? readState(), let state = try? CursorState.decode(bytes), state.matches(header) else {
            return (header.lastProcessedEventID, false)
        }
        return (state.cursor, true)
    }
    func writeState(header: SnapshotHeader, cursor: UInt64, beforePublish: () throws -> Void,
                    fault: ((SnapshotFailurePoint) throws -> Void)? = nil) throws {
        let data = try CursorState(header: header, cursor: cursor).encoded()
        try publish(name: filename + ".state", write: { try snapshotWriteAll($0, data) }, beforePublish: beforePublish, fault: fault)
    }

    private func cleanupTemps() {
        guard let stream = fdopendir(dup(directoryFD)) else { return }
        defer { closedir(stream) }
        while let record = readdir(stream) {
            let name = withUnsafeBytes(of: record.pointee.d_name) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard name.hasPrefix(filename + "."), name.hasSuffix(".tmp") else { continue }
            var metadata = stat()
            if fstatat(directoryFD, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
               metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFREG {
                _ = unlinkat(directoryFD, name, 0)
            }
        }
    }
    private func hasSafeFinal(_ name: String) throws -> Bool {
        var metadata = stat()
        if fstatat(directoryFD, name, &metadata, AT_SYMLINK_NOFOLLOW) < 0 {
            if errno == ENOENT { return false }
            throw SnapshotError.io("check final", errno)
        }
        guard metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o7777 == 0o600 else { throw SnapshotError.unsafePath(path) }
        return true
    }

    func publish<T>(name: String? = nil, write: (Int32) throws -> T, beforePublish: () throws -> Void,
                    fault: ((SnapshotFailurePoint) throws -> Void)? = nil) throws -> T {
        let final = name ?? filename
        guard final == filename || final == filename + ".state" else { throw SnapshotError.unsafePath(final) }
        guard activityLock.withLock({ if publishing { return false }; publishing = true; return true }) else {
            throw SnapshotError.busy
        }
        defer { activityLock.withLock { publishing = false } }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw SnapshotError.busy }
        defer { _ = flock(lockFD, LOCK_UN) }
        cleanupTemps()
        _ = try hasSafeFinal(final)
        let temporary = final + "." + UUID().uuidString + ".tmp"
        let backup = final + ".old." + UUID().uuidString + ".tmp"
        var fd = openat(directoryFD, temporary, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SnapshotError.io("create tmp", errno) }
        var linkedBackup = false, renamed = false
        defer { if fd >= 0 { close(fd) } }
        do {
            guard fchmod(fd, 0o600) == 0 else { throw SnapshotError.io("chmod tmp", errno) }
            let result = try write(fd)
            try fault?(.beforeFileSync)
            guard fsync(fd) == 0 else { throw SnapshotError.io("fsync tmp", errno) }
            let closing = close(fd); fd = -1
            guard closing == 0 else { throw SnapshotError.io("close tmp", errno) }
            try beforePublish()
            try fault?(.beforeRename)
            if try hasSafeFinal(final) {
                guard linkat(directoryFD, final, directoryFD, backup, 0) == 0 else { throw SnapshotError.io("backup link", errno) }
                linkedBackup = true
            }
            guard renameat(directoryFD, temporary, directoryFD, final) == 0 else { throw SnapshotError.io("rename", errno) }
            renamed = true
            try fault?(.afterRename)
            try fault?(.directorySync)
            guard fsync(directoryFD) == 0 else { throw SnapshotError.io("fsync cache directory", errno) }
            if linkedBackup { _ = unlinkat(directoryFD, backup, 0) }
            return result
        } catch {
            if renamed {
                if linkedBackup { _ = renameat(directoryFD, backup, directoryFD, final) }
                else { _ = unlinkat(directoryFD, final, 0) }
                _ = fsync(directoryFD)
            } else if linkedBackup { _ = unlinkat(directoryFD, backup, 0) }
            _ = unlinkat(directoryFD, temporary, 0)
            throw error
        }
    }
}

func snapshotWriteAll(_ fd: Int32, _ data: Data, offset: Int64? = nil) throws {
    try data.withUnsafeBytes { raw in
        var written = 0
        while written < raw.count {
            let count: Int
            if let offset {
                count = pwrite(fd, raw.baseAddress!.advanced(by: written), raw.count - written, off_t(offset) + off_t(written))
            } else { count = Darwin.write(fd, raw.baseAddress!.advanced(by: written), raw.count - written) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw SnapshotError.io("write", count == 0 ? EIO : errno) }
            written += count
        }
    }
}
