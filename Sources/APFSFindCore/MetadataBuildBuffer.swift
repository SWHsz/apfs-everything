import CAPFSShim
import Darwin
import Foundation

/// Compact file-backed scratch columns. Private mappings avoid SIGBUS on a
/// sparse shared mapping if storage fills; publication uses checked pwrite.
/// Scratch changes need not survive a process restart, and the unlinked file
/// cannot be mistaken for a valid sidecar or cleaned by another publisher.
public final class MetadataBuildBuffer: @unchecked Sendable {
    public let count: Int
    public let allocatedBytes: Int
    private let lock = NSLock()
    private var knownSizes = 0
    private let address: UnsafeMutableRawPointer
    private let owner: OwnedBenchmarkDirectory
    public init(count:Int,directory:String = "/private/tmp",beforeMapping:()throws->Void = {}) throws {
        guard count > 0, UInt64(count) <= SnapshotFormat.maxRecords else { throw SnapshotError.invalid("metadata build count") }
        self.count = count; allocatedBytes = count*16+(count+3)/4
        let temporaryOwner = try OwnedBenchmarkDirectory(parent:directory,prefix:"apfsfind-real-cache-")
        var success = false
        defer { if !success { try? temporaryOwner.remove() } }
        let directoryFD = apfs_open_cache_directory(temporaryOwner.path,0)
        guard directoryFD >= 0 else { throw SnapshotError.io("open build directory",errno) }
        defer { close(directoryFD) }
        let fd = openat(directoryFD,"columns.tmp",O_CREAT|O_EXCL|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw SnapshotError.io("create metadata columns",errno) }
        defer { close(fd); _ = unlinkat(directoryFD,"columns.tmp",0) }
        guard fchmod(fd,0o600) == 0, ftruncate(fd,off_t(allocatedBytes)) == 0 else { throw SnapshotError.io("allocate metadata columns",errno) }
        try beforeMapping()
        guard let p = mmap(nil,allocatedBytes,PROT_READ|PROT_WRITE,MAP_PRIVATE,fd,0),p != MAP_FAILED else { throw SnapshotError.io("mmap metadata columns",errno) }
        owner = temporaryOwner; address = p; success = true
    }
    deinit { munmap(address,allocatedBytes); try? owner.remove() }
    private func put(_ value:FileMetadataValue,at id:Int) {
        guard (0..<count).contains(id) else { return }
        address.storeBytes(of:(value.logicalSize ?? 0).littleEndian,toByteOffset:id*8,as:UInt64.self)
        address.storeBytes(of:(value.modificationTimeNanoseconds ?? 0).littleEndian,toByteOffset:count*8+id*8,as:Int64.self)
        let offset = count*16+id/4, shift = (id%4)*2
        let flags:UInt8 = (value.logicalSize == nil ? 0 : 1) | (value.modificationTimeNanoseconds == nil ? 0 : 2)
        let old = address.load(fromByteOffset:offset,as:UInt8.self)
        knownSizes += (flags & 1 == 0 ? 0 : 1) - (old >> shift & 1 == 0 ? 0 : 1)
        address.storeBytes(of:(old & ~(3 << shift)) | (flags << shift),toByteOffset:offset,as:UInt8.self)
    }
    public func update(_ values:[(Int,FileMetadataValue)]) { lock.withLock { for (id,value) in values { put(value,at:id) } } }
    public func update(_ value:FileMetadataValue,at id:Int) { lock.withLock { put(value,at:id) } }
    public var unknownSizes:Int { lock.withLock { count-knownSizes } }
    public func value(_ id:Int) -> FileMetadataValue {
        lock.withLock {
            guard (0..<count).contains(id) else { return .unknown }
            let flags = address.load(fromByteOffset:count*16+id/4,as:UInt8.self) >> ((id%4)*2)
            return .init(logicalSize:flags & 1 == 0 ? nil : UInt64(littleEndian:address.loadUnaligned(fromByteOffset:id*8,as:UInt64.self)),
                modificationTimeNanoseconds:flags & 2 == 0 ? nil : Int64(littleEndian:address.loadUnaligned(fromByteOffset:count*8+id*8,as:Int64.self)))
        }
    }
}
