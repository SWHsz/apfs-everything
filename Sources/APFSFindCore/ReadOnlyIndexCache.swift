import CAPFSShim
import Darwin
import Foundation

/// Benchmark access never creates lock files, cleans temps, or modifies daily state.
public final class ReadOnlyIndexCache {
    private let fd:Int32
    public init(directory:String) throws {
        let normalized = try SnapshotStore.normalizedDirectory(directory)
        fd = apfs_open_cache_directory(normalized,0)
        guard fd >= 0 else { throw SnapshotError.io("open read-only cache",errno) }
    }
    deinit { close(fd) }
    public func mappedBase(identity:VolumeIdentity) throws -> MMapBaseIndex {
        let listing = openat(fd,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
        guard listing >= 0 else { throw SnapshotError.io("enumerate read-only cache",errno) }
        guard let directory = fdopendir(listing) else { close(listing); throw SnapshotError.io("fdopendir cache",errno) }
        defer { closedir(directory) }
        while let record = readdir(directory) {
            let name = withUnsafeBytes(of:record.pointee.d_name) { String(decoding:$0.prefix { $0 != 0 },as:UTF8.self) }
            guard name.hasSuffix(".apfsidx"),name.utf8.count == 72,
                  name.dropLast(8).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            let readerFD = openat(fd,name,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
            guard readerFD >= 0 else { continue }
            if let reader = try? SnapshotReader(fileDescriptor:readerFD,expectedIdentity:identity),let base = reader.mappedBase { return base }
        }
        throw SnapshotError.invalid("no matching read-only namespace v2 cache")
    }
}
