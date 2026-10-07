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
                    // readlink's char* import differs between SDKs. Passing
                    // &Array to an untyped pointer can address the Array value,
                    // rather than its elements (ASan caught this on Xcode 16.4).
                    var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
                    let count = bytes.withUnsafeMutableBufferPointer {
                        readlink(alias, $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        let target = String(decoding: bytes.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
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
        guard fd >= 0 else {
            if errno == EPERM {throw SnapshotError.unsafePath(normalized+": existing cache must be owned by the current user with mode 0700; permissions were not changed")}
            throw SnapshotError.io("open local cache (no symlinks)",errno)
        }
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
        let started = ProcessInfo.processInfo.systemUptime
        let fd = openat(directoryFD, filename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        let openMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        guard fd >= 0 else { throw SnapshotError.io("open", errno) }
        let reader = try SnapshotReader(fileDescriptor: fd, expectedIdentity: expectedIdentity)
        reader.openMilliseconds = openMS
        return reader
    }

    public var metadataFilename: String { String(filename.dropLast(8)) + ".apfsmeta" }
    public var metadataPath: String { directory + "/" + metadataFilename }
    public func metadataReader(base: SnapshotHeader) throws -> MMapMetadataIndex {
        let fd = openat(directoryFD, metadataFilename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw SnapshotError.io("open metadata", errno) }
        return try MMapMetadataIndex(fileDescriptor: fd, base: base)
    }
    public func effectiveMetadataCursor(for header: MetadataHeader) -> (cursor: UInt64, valid: Bool) {
        let fd = openat(directoryFD, metadataFilename + ".state", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return (header.cursor, false) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == geteuid(), st.st_mode & S_IFMT == S_IFREG,
              st.st_mode & 0o7777 == 0o600, st.st_size == MetadataCursorState.size else { return (header.cursor, false) }
        var data = Data(repeating: 0, count: MetadataCursorState.size)
        let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count == data.count, let state = try? MetadataCursorState.decode(data), state.matches(header) else {
            return (header.cursor, false)
        }
        return (state.cursor, true)
    }
    public func writeMetadataState(header: MetadataHeader, cursor: UInt64, beforePublish: () throws -> Void = {},
                                   fault: ((SnapshotFailurePoint) throws -> Void)? = nil) throws {
        let bytes = try MetadataCursorState(header: header, cursor: cursor).encoded()
        try publish(name: metadataFilename + ".state", write: { try snapshotWriteAll($0, bytes) },
                    beforePublish: beforePublish, fault: fault)
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
        // dup shares a directory offset with directoryFD: later cleanup would
        // resume at EOF. Open a separate description and close it on failure.
        let fd = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return }
        guard let stream = fdopendir(fd) else { close(fd); return }
        defer { closedir(stream) }
        while let record = readdir(stream) {
            let name = withUnsafeBytes(of: record.pointee.d_name) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard (name.hasPrefix(filename + ".") || name.hasPrefix(metadataFilename + ".")), name.hasSuffix(".tmp") else { continue }
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

    /// Called while the namespace publisher already holds this store's advisory lock.
    func stageMetadata(header:MetadataHeader, base:SnapshotHeader, payload:Data, footer:Data,
                       fault:((SnapshotFailurePoint)throws->Void)?) throws -> StagedMetadataFile {
        guard activityLock.withLock({publishing}) else { throw SnapshotError.invalid("metadata staging requires namespace publication") }
        let temporary = metadataFilename + "." + UUID().uuidString + ".tmp"
        var fd = openat(directoryFD,temporary,O_CREAT|O_EXCL|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw SnapshotError.io("stage metadata",errno) }
        do {
            guard fchmod(fd,0o600) == 0 else { throw SnapshotError.io("chmod staged metadata",errno) }
            try snapshotWriteAll(fd,header.encoded()); try fault?(.afterHeader)
            try snapshotWriteAll(fd,payload); try snapshotWriteAll(fd,footer); try fault?(.beforeFileSync)
            guard fsync(fd) == 0 else { throw SnapshotError.io("fsync staged metadata",errno) }
            let result = close(fd); fd = -1
            guard result == 0 else { throw SnapshotError.io("close staged metadata",errno) }
            let readerFD = openat(directoryFD,temporary,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
            guard readerFD >= 0 else { throw SnapshotError.io("open staged metadata",errno) }
            _ = try MMapMetadataIndex(fileDescriptor:readerFD,base:base)
            return StagedMetadataFile(store:self,temporary:temporary,header:header,fault:fault)
        } catch {
            if fd >= 0 { close(fd) }; _ = unlinkat(directoryFD,temporary,0); throw error
        }
    }
    fileprivate func discardMetadataStage(_ name:String) { _ = unlinkat(directoryFD,name,0) }
    fileprivate func commitMetadataStage(_ temporary:String, beforePublish:()throws->Void,
                                          fault:((SnapshotFailurePoint)throws->Void)?) throws {
        guard activityLock.withLock({ if publishing { return false }; publishing = true; return true }) else { throw SnapshotError.busy }
        defer { activityLock.withLock { publishing = false } }
        guard flock(lockFD,LOCK_EX|LOCK_NB) == 0 else { throw SnapshotError.busy }
        defer { _ = flock(lockFD,LOCK_UN) }
        let backup = metadataFilename + "." + UUID().uuidString + ".backup.tmp"
        var linked = false, renamed = false
        do {
            try beforePublish(); try fault?(.beforeRename)
            if try hasSafeFinal(metadataFilename) {
                guard linkat(directoryFD,metadataFilename,directoryFD,backup,0) == 0 else { throw SnapshotError.io("metadata backup",errno) }
                linked = true
            }
            guard renameat(directoryFD,temporary,directoryFD,metadataFilename) == 0 else { throw SnapshotError.io("publish staged metadata",errno) }
            renamed = true; try fault?(.afterRename); try fault?(.directorySync)
            guard fsync(directoryFD) == 0 else { throw SnapshotError.io("fsync metadata directory",errno) }
            if linked { _ = unlinkat(directoryFD,backup,0) }
        } catch {
            if renamed {
                if linked { _ = renameat(directoryFD,backup,directoryFD,metadataFilename) }
                else { _ = unlinkat(directoryFD,metadataFilename,0) }
                _ = fsync(directoryFD)
            } else if linked { _ = unlinkat(directoryFD,backup,0) }
            throw error
        }
    }

    func publish<T>(name: String? = nil, write: (Int32) throws -> T, beforePublish: () throws -> Void,
                    fault: ((SnapshotFailurePoint) throws -> Void)? = nil,
                    validate: ((Int32) throws -> Void)? = nil,
                    commit: ((() throws -> Void) throws -> Void)? = nil,
                    resourceMetrics: Metrics? = nil, resourceStage: String = "snapshot") throws -> T {
        let final = name ?? filename
        guard final == filename || final == filename + ".state" || final == metadataFilename || final == metadataFilename + ".state" else { throw SnapshotError.unsafePath(final) }
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
            let serializationStart = ProcessResourceSample.capture()
            let result = try write(fd)
            resourceMetrics?.recordResources(resourceStage + ".serialization", since: serializationStart)
            let publicationStart = ProcessResourceSample.capture()
            try fault?(.beforeFileSync)
            guard fsync(fd) == 0 else { throw SnapshotError.io("fsync tmp", errno) }
            let closing = close(fd); fd = -1
            guard closing == 0 else { throw SnapshotError.io("close tmp", errno) }
            if let validate {
                let readerFD = openat(directoryFD, temporary, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard readerFD >= 0 else { throw SnapshotError.io("open staged base", errno) }
                // validate takes ownership, including on failure.
                try validate(readerFD)
            }
            func publishFinal() throws {
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
            }
            if let commit { try commit(publishFinal) } else { try publishFinal() }
            resourceMetrics?.recordResources(resourceStage + ".fsync_validate_publish", since: publicationStart)
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

final class StagedMetadataFile {
    let header:MetadataHeader
    private let store:SnapshotStore
    private let temporary:String
    private let fault:((SnapshotFailurePoint)throws->Void)?
    init(store:SnapshotStore,temporary:String,header:MetadataHeader,fault:((SnapshotFailurePoint)throws->Void)?) {
        self.store = store; self.temporary = temporary; self.header = header; self.fault = fault
    }
    func publish(beforePublish:()throws->Void = {}) throws { try store.commitMetadataStage(temporary,beforePublish:beforePublish,fault:fault) }
    deinit { store.discardMetadataStage(temporary) }
}
