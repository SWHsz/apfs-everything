import CAPFSShim
import Darwin
import Foundation

/// Queue-confined metadata traversal: one secure descriptor and one 64 KiB
/// getattrlistbulk page. Namespace reconciliation still uses atomic listings.
final class MetadataDirectoryCursor {
    let path: String
    let fileID: UInt64
    private var reader: OpaquePointer?
    private let excludedRoots: [String]
    private let metrics: Metrics
    private let pageMetric: String
    private(set) var finished = false
    var children: [String] = []

    init(path:String,device:UInt64,excludedRoots:[String],metrics:Metrics,pageMetric:String = "metadata_subtree_bulk_pages") throws {
        self.path = path;self.excludedRoots = excludedRoots;self.metrics = metrics;self.pageMetric = pageMetric
        _ = apfs_deny_dataless_materialization()
        var error:Int32 = 0
        guard let reader = apfs_bulk_reader_open(path,device,1,&error) else {throw ScannerError(path:path,code:error)}
        self.reader = reader;fileID = apfs_bulk_reader_file_id(reader)
    }
    deinit {close()}
    func close() {
        if let reader {
            if apfs_bulk_reader_close(reader) != 0 {metrics.record("scanner_close_errors")}
            self.reader = nil
        }
    }
    func next(cancellation:CancellationToken) throws -> [ScannedEntry] {
        guard !cancellation.isCancelled else {close();throw ScannerError(path:path,code:ECANCELED)}
        guard !finished,let reader else {return []}
        _ = apfs_deny_dataless_materialization()
        var records:UnsafePointer<APFSDirectoryEntry>?,count = 0
        guard apfs_bulk_reader_next(reader,&records,&count) == 0 else {throw ScannerError(path:path,code:errno)}
        if count == 0 {finished = true;close();return []}
        guard let records else {throw ScannerError(path:path,code:EIO)}
        var page:[ScannedEntry] = []
        for record in UnsafeBufferPointer(start:records,count:count) {
            guard !cancellation.isCancelled else {close();throw ScannerError(path:path,code:ECANCELED)}
            if record.error_code != 0 {
                metrics.record("metadata_page_entry_errno_\(record.error_code)")
                switch Int32(record.error_code) {
                case ENOENT,ENOTDIR,ELOOP:metrics.record("scanner_races")
                case EXDEV:metrics.record("scanner_boundaries")
                case EPERM,EACCES:metrics.record("scanner_permission_denied");metrics.record("scanner_unreadable_directories")
                case ENODATA:metrics.record("scanner_dataless_skips");metrics.record("scanner_unreadable_directories")
                default:metrics.record("scanner_errors");metrics.record("scanner_unreadable_directories")
                }
                continue
            }
            guard let bytes = record.name,record.name_length > 0 else {throw ScannerError(path:path,code:EIO)}
            let name = String(decoding:UnsafeBufferPointer(start:UnsafeRawPointer(bytes).assumingMemoryBound(to:UInt8.self),count:record.name_length),as:UTF8.self)
            guard name != ".",name != ".." else {continue}
            let child = (path == "/" ? "/" : path+"/")+name
            if excludedRoots.contains(where:{PathCanonicalizer.isWithin(child,root:$0)}) {continue}
            let kind:EntryKind
            switch record.object_type {
            case UInt32(APFS_OBJECT_FILE.rawValue):kind = .file
            case UInt32(APFS_OBJECT_DIRECTORY.rawValue):kind = .directory
            case UInt32(APFS_OBJECT_SYMLINK.rawValue):kind = .symlink
            default:kind = .other
            }
            page.append(.init(namespace:.init(path:child,kind:kind,deviceID:record.device_id,
                fileID:record.has_file_id != 0 ? record.file_id : nil,isMountPoint:record.is_mount_point != 0),metadata:FileMetadataValue(record)))
        }
        metrics.record("scanner_entries",by:page.count)
        metrics.record(pageMetric)
        return page
    }
}
