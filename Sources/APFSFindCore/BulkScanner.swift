import CAPFSShim
import Darwin
import Foundation

public struct DirectoryStamp: Sendable, Equatable {
    public let seconds: Int64
    public let nanoseconds: Int64
    public init(seconds: Int64, nanoseconds: Int64) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }
}

public struct ScanResult: Sendable {
    public let scannedEntries: [ScannedEntry]
    public var entries: [NamespaceEntry] { scannedEntries.map(\.namespace) }
    public let unreadableDirectories: Int
    public let elapsedMilliseconds: Double
    public let rootDeviceID: UInt64
    public let cancelled: Bool
}

public struct ScannerError: Error, CustomStringConvertible, Sendable {
    public let path: String
    public let code: Int32
    public var description: String {
        "Cannot enumerate \(path): \(String(cString: strerror(code))) (\(code))"
    }
}

/// Metadata-only bulk scanner. Worker state is independent of the online index.
public protocol DirectoryReading {
    func readDirectory(_ path: String, rootDeviceID: UInt64,
                       cancellation: CancellationToken) throws -> [NamespaceEntry]
}

public final class BulkScanner: DirectoryReading, @unchecked Sendable {
    private let requestedRoot: String
    public let workerCount: Int
    private let metrics: Metrics
    private let excludedRoots: [String]
    private let checkpoint: @Sendable () throws -> Void

    public init(root: String, workerCount: Int = 4, metrics: Metrics = Metrics(), excludedRoots: [String] = [], checkpoint: @escaping @Sendable () throws -> Void = {}) {
        self.checkpoint = checkpoint
        requestedRoot = root
        self.workerCount = min(16, max(1, workerCount))
        self.metrics = metrics
        self.excludedRoots = PathCanonicalizer.minimalRoots(excludedRoots + Self.maintenanceExclusions(root: root))
    }

    public static func volumeJournalExclusions(root: String, mountPoint: String) -> [String] {
        let journal = (mountPoint == "/" ? "" : mountPoint) + "/.fseventsd"
        return PathCanonicalizer.isWithin(journal, root: root) ? [journal] : []
    }
    /// The service's own journal files are not a maintainable user namespace.
    /// Scope the exclusion to the actual mount root, never a basename pattern.
    public static func maintenanceExclusions(root: String) -> [String] {
        var info = APFSVolumeInfo()
        guard apfs_volume_info(root, &info) == 0 else { return [] }
        let mount = withUnsafeBytes(of: info.mount_point) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return volumeJournalExclusions(root: root, mountPoint: mount)
    }

    private func applyThreadPolicy() {
        switch apfs_deny_dataless_materialization() {
        case 0: break
        case 1: metrics.record("dataless_policy_unavailable")
        default: metrics.record("dataless_policy_errors")
        }
    }

    private func rootInfo() throws -> (String, APFSDirectoryInfo) {
        applyThreadPolicy()
        // Explicit scan roots are resolved once; descendants are never realpath-ed.
        let path = try PathCanonicalizer.canonicalRoot(requestedRoot)
        var info = APFSDirectoryInfo()
        guard apfs_directory_info(path, 0, 0, &info) == 0 else {
            throw ScannerError(path: path, code: errno)
        }
        return (path, info)
    }

    public func rootDeviceID() throws -> UInt64 {
        try rootInfo().1.device_id
    }

    public static func shouldTraverse(deviceID: UInt64, rootDeviceID: UInt64) -> Bool {
        deviceID == rootDeviceID
    }

    public static func shouldTraverse(entry: NamespaceEntry, rootDeviceID: UInt64) -> Bool {
        entry.kind == .directory && !entry.isMountPoint &&
            shouldTraverse(deviceID: entry.deviceID, rootDeviceID: rootDeviceID)
    }

    /// Uses a secure directory open, including O_NOFOLLOW on intermediate components.
    /// A failure deliberately returns nil so the mtime optimization cannot hide it.
    public static func directoryStamp(_ path: String) -> DirectoryStamp? {
        _ = apfs_deny_dataless_materialization() // Best effort; this API has no metrics sink.
        var info = APFSDirectoryInfo()
        guard apfs_directory_info(path, 0, 0, &info) == 0 else { return nil }
        return DirectoryStamp(seconds: info.mtime_seconds, nanoseconds: info.mtime_nanoseconds)
    }

    public func readDirectory(_ path: String, rootDeviceID: UInt64) throws -> [NamespaceEntry] {
        try readScannedDirectory(path, rootDeviceID: rootDeviceID, cancellation: nil).map(\.namespace)
    }

    /// Cancel between bulk pages; never return a partial directory as a complete diff.
    public func readDirectory(_ path: String, rootDeviceID: UInt64,
                              cancellation: CancellationToken) throws -> [NamespaceEntry] {
        let entries = try readScannedDirectory(path, rootDeviceID: rootDeviceID,
                                        cancellation: Optional(cancellation),maximumEntries:100_000, yieldToQueries:true).map(\.namespace)
        guard !cancellation.isCancelled else { throw ScannerError(path: path, code: ECANCELED) }
        return entries
    }

    public func readScannedDirectory(_ path: String, rootDeviceID: UInt64,
                               cancellation: CancellationToken? = nil, collectEntries:Bool = true, visit:(@Sendable ([ScannedEntry])->Void)? = nil, maximumEntries:Int? = nil, yieldToQueries:Bool = false) throws -> [ScannedEntry] {
        applyThreadPolicy()
        var error: Int32 = 0
        guard let reader = apfs_bulk_reader_open(path, rootDeviceID, 1, &error) else {
            throw ScannerError(path: path, code: error)
        }
        defer {
            if apfs_bulk_reader_close(reader) != 0 { metrics.record("scanner_close_errors") }
        }
        var result: [ScannedEntry] = []
        while cancellation?.isCancelled != true {
            try checkpoint()
            if yieldToQueries && result.count >= 4096 {
                let pressure = SystemResourceSignals.shared.current()
                if pressure.activeQueries > 0 || pressure.memoryPressure == .critical { throw MaintenanceYield(reason:"reconciliation query/pressure") }
            }
            var records: UnsafePointer<APFSDirectoryEntry>?
            var count = 0
            guard apfs_bulk_reader_next(reader, &records, &count) == 0 else {
                throw ScannerError(path: path, code: errno)
            }
            if count == 0 { break }
            guard let records else { throw ScannerError(path: path, code: EIO) }
            var page: [ScannedEntry] = []
            for record in UnsafeBufferPointer(start: records, count: count) {
                if cancellation?.isCancelled == true { break }
                if record.error_code != 0 {
                    recordFailure(Int32(record.error_code))
                    continue
                }
                guard let namePointer = record.name, record.name_length > 0 else {
                    throw ScannerError(path: path, code: EIO)
                }
                let bytes = UnsafeRawPointer(namePointer).assumingMemoryBound(to: UInt8.self)
                let name = String(decoding: UnsafeBufferPointer(start: bytes, count: record.name_length), as: UTF8.self)
                guard name != ".", name != ".." else { continue }
                let childPath = (path == "/" ? "/" : path + "/") + name
                if excludedRoots.contains(where: { PathCanonicalizer.isWithin(childPath, root: $0) }) { continue }
                let kind: EntryKind
                switch record.object_type {
                case UInt32(APFS_OBJECT_FILE.rawValue): kind = .file
                case UInt32(APFS_OBJECT_DIRECTORY.rawValue): kind = .directory
                case UInt32(APFS_OBJECT_SYMLINK.rawValue): kind = .symlink
                default: kind = .other
                }
                page.append(ScannedEntry(namespace: NamespaceEntry(path: childPath,
                                             kind: kind, deviceID: record.device_id,
                                             fileID: record.has_file_id != 0 ? record.file_id : nil,
                                             isMountPoint: record.is_mount_point != 0), metadata: FileMetadataValue(record)))
            }
            visit?(page)
            result += collectEntries ? page : page.filter { Self.shouldTraverse(entry:$0.namespace,rootDeviceID:rootDeviceID) }
            if let maximumEntries, result.count > maximumEntries { throw ScannerError(path:path,code:EOVERFLOW) }
            metrics.record("scanner_entries",by:page.count)
        }
        metrics.record("scanner_directories")
        return result
    }

    @discardableResult
    private func recordFailure(_ code: Int32) -> Bool {
        switch code {
        case ENOENT, ENOTDIR, ELOOP:
            metrics.record("scanner_races")
            return false
        case EXDEV:
            metrics.record("scanner_boundaries")
            return false
        case ENODATA:
            metrics.record("scanner_unreadable_directories")
            metrics.record("scanner_dataless_skips")
            return true
        case EACCES, EPERM:
            metrics.record("scanner_unreadable_directories")
            metrics.record("scanner_permission_denied")
            return true
        default:
            metrics.record("scanner_unreadable_directories")
            metrics.record("scanner_errors")
            return true
        }
    }

    public func scan(cancellation: CancellationToken = CancellationToken(),
                     collectEntries: Bool = true, visit: (@Sendable ([ScannedEntry]) -> Void)? = nil) throws -> ScanResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let (root, info) = try rootInfo()
        let rootEntry = ScannedEntry(namespace: NamespaceEntry(path: root, kind: .directory,
                                       deviceID: info.device_id, fileID: info.file_id), metadata: FileMetadataValue(
                                        modificationTimeNanoseconds: FileMetadataValue.unixNanoseconds(
                                            seconds: info.mtime_seconds, nanoseconds: info.mtime_nanoseconds)))
        if cancellation.isCancelled {
            return ScanResult(scannedEntries: [rootEntry], unreadableDirectories: 0,
                              elapsedMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6,
                              rootDeviceID: info.device_id, cancelled: true)
        }
        // A root failure is fatal. Never publish an empty replacement after EACCES/EIO.
        let children: [ScannedEntry]
        do { children = try readScannedDirectory(root, rootDeviceID: info.device_id, cancellation:cancellation,collectEntries:collectEntries,visit:collectEntries ? nil : visit) }
        catch let error as ScannerError { recordFailure(error.code); throw error }
        visit?(collectEntries ? [rootEntry]+children : [rootEntry])
        let work = ScanWork(entries: collectEntries ? [rootEntry] + children : [],
                            directories: children.filter { Self.shouldTraverse(entry: $0.namespace, rootDeviceID: info.device_id) }.map(\.namespace.path))
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "apfsfind.scan", qos: .utility, attributes: .concurrent)
        for _ in 0..<workerCount {
            group.enter()
            queue.async { [self] in
                defer { group.leave() }
                applyThreadPolicy()
                while let directory = work.next(cancellation: cancellation) {
                    do {
                        let entries = try readScannedDirectory(directory, rootDeviceID: info.device_id,
                                                        cancellation:cancellation,collectEntries:collectEntries,visit:collectEntries ? nil : visit)
                        let directories = cancellation.isCancelled ? [] : entries.filter {
                            Self.shouldTraverse(entry: $0.namespace, rootDeviceID: info.device_id)
                        }.map(\.namespace.path)
                        if collectEntries { visit?(entries) }
                        work.complete(entries: collectEntries ? entries : [], directories: directories, unreadable: false)
                    } catch let error as ScannerError {
                        work.complete(entries: [], directories: [], unreadable: recordFailure(error.code))
                    } catch let error as MaintenanceYield {
                        work.abort(error); work.complete(entries: [], directories: [], unreadable: false)
                    } catch {
                        metrics.record("scanner_unreadable_directories")
            metrics.record("scanner_errors")
                        work.complete(entries: [], directories: [], unreadable: true)
                    }
                }
            }
        }
        group.wait()
        let final = work.result()
        if let error = final.error { throw error }
        return ScanResult(scannedEntries: final.entries, unreadableDirectories: final.unreadable,
                          elapsedMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6,
                          rootDeviceID: info.device_id, cancelled: cancellation.isCancelled)
    }
}

/// A bounded number of workers share a directory frontier and append private read results.
private final class ScanWork: @unchecked Sendable {
    private let condition = NSCondition()
    private var entries: [ScannedEntry]
    private var directories: [String]
    private var nextIndex = 0
    private var active = 0
    private var unreadable = 0
    private var error: (any Error)?

    init(entries: [ScannedEntry], directories: [String]) {
        self.entries = entries
        self.directories = directories
    }

    func next(cancellation: CancellationToken) -> String? {
        condition.lock()
        defer { condition.unlock() }
        while nextIndex == directories.count && active > 0 && !cancellation.isCancelled && error == nil {
            condition.wait()
        }
        guard error == nil, !cancellation.isCancelled, nextIndex < directories.count else { return nil }
        let path = directories[nextIndex]
        nextIndex += 1
        active += 1
        if nextIndex >= 4096 {
            directories.removeFirst(nextIndex)
            nextIndex = 0
        }
        return path
    }

    func complete(entries: [ScannedEntry], directories: [String], unreadable: Bool) {
        condition.lock()
        self.entries += entries
        self.directories += directories
        if unreadable { self.unreadable += 1 }
        active -= 1
        condition.broadcast()
        condition.unlock()
    }

    func abort(_ error: any Error) { condition.lock(); if self.error == nil { self.error = error }; condition.broadcast(); condition.unlock() }

    func result() -> (entries: [ScannedEntry], unreadable: Int, error: (any Error)?) {
        condition.lock()
        defer { condition.unlock() }
        return (entries, unreadable, error)
    }
}
