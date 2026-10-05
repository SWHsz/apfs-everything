import CAPFSShim
import CoreServices
import Darwin
import Foundation

public struct VolumeIdentity: Sendable, Equatable {
    public let root: String
    public let deviceID: UInt64
    public let rootFileID: UInt64
    public let volumeUUID: UUID
    public let historyUUID: UUID
    public let mountPoint: String
    public let relativeRoot: String

    public init(root: String, deviceID: UInt64, rootFileID: UInt64, volumeUUID: UUID,
                historyUUID: UUID, mountPoint: String, relativeRoot: String) {
        self.root = root; self.deviceID = deviceID; self.rootFileID = rootFileID
        self.volumeUUID = volumeUUID; self.historyUUID = historyUUID
        self.mountPoint = mountPoint; self.relativeRoot = relativeRoot
    }

    public static func discover(root: String) throws -> VolumeIdentity {
        var info = APFSVolumeInfo()
        guard apfs_volume_info(root, &info) == 0 else { throw ScannerError(path: root, code: errno) }
        let volume = withUnsafeBytes(of: info.volume_uuid) { UUID(bytes: Array($0)) }
        let mount = withUnsafeBytes(of: info.mount_point) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard let history = FSEventsCopyUUIDForDevice(dev_t(truncatingIfNeeded: info.device_id)) else {
            throw WatcherError.historyUnavailable
        }
        let historyID = UUID(uuidString: CFUUIDCreateString(nil, history) as String)!
        let relative: String
        if root == mount { relative = "" }
        else if mount == "/" { relative = String(root.dropFirst()) }
        else if root.hasPrefix(mount + "/") { relative = String(root.dropFirst(mount.count + 1)) }
        else {
            // Data-volume firmlinks (/Users, /private/var) have an absolute alias
            // outside f_mntonname. Verify its device/inode before using the alias
            // components as a volume-relative path; never infer by volume name.
            let candidate = mount + root
            var actual = APFSDirectoryInfo()
            guard apfs_directory_info(candidate, info.device_id, 1, &actual) == 0,
                  actual.file_id == info.root_file_id else { throw ScannerError(path: root, code: EXDEV) }
            relative = String(root.dropFirst())
        }
        return .init(root: root, deviceID: info.device_id, rootFileID: info.root_file_id,
            volumeUUID: volume, historyUUID: historyID, mountPoint: mount, relativeRoot: relative)
    }

    public func currentEventID(clock: () -> CFAbsoluteTime = { CFAbsoluteTimeGetCurrent() },
                               fence: (dev_t, CFAbsoluteTime) -> UInt64 = { FSEventsGetLastEventIdForDeviceBeforeTime($0, $1) }) -> UInt64 {
        // FSEvents.h explicitly specifies POSIX seconds despite its CFAbsoluteTime
        // typedef. Convert the injected CF clock at this API boundary (not Date).
        fence(dev_t(truncatingIfNeeded: deviceID), clock() + kCFAbsoluteTimeIntervalSince1970)
    }

    public func absoluteCallbackPath(_ raw: String) -> String? {
        // The probe on macOS 27 returned device-relative paths with no leading
        // slash. Strip an optional leading slash defensively, then enforce the
        // watched relative-root boundary before reconstructing the caller alias.
        let path = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        if relativeRoot.isEmpty { return PathCanonicalizer.normalize((root == "/" ? "" : root) + "/" + path) }
        if path == relativeRoot { return root }
        guard path.hasPrefix(relativeRoot + "/") else { return nil }
        return PathCanonicalizer.normalize(root + String(path.dropFirst(relativeRoot.count)))
    }
}

extension UUID {
    init(bytes: [UInt8]) {
        precondition(bytes.count == 16)
        self.init(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                         bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    var bytes: [UInt8] { withUnsafeBytes(of: uuid) { Array($0) } }
}
