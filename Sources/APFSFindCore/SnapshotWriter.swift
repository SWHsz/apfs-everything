import Darwin
import Foundation

public enum SnapshotWriter {
    public static func write(index: FileIndex, identity: VolumeIdentity, cursor: UInt64,
                             store: SnapshotStore, metadata supplied: SnapshotExportMetadata? = nil,
                             cancellation: CancellationToken = .init(),
                             beforePublish: (() throws -> Void)? = nil,
                             fault: ((SnapshotFailurePoint) throws -> Void)? = nil) throws -> SnapshotWriteResult {
        let started = ProcessInfo.processInfo.systemUptime
        guard !cancellation.isCancelled else { throw SnapshotError.cancelled }
        let metadata = supplied ?? index.captureSnapshotMetadata()
        guard metadata.liveEntries > 0, metadata.liveEntries <= SnapshotFormat.maxRecords,
              cursor != UInt64.max, metadata.generation != UInt64.max else { throw SnapshotError.invalid("checkpoint count/cursor") }
        let order = try index.snapshotExportOrder(expectedGeneration: metadata.generation, cancellation: cancellation)
        guard order.count == metadata.liveEntries, order.first == 0 else { throw SnapshotError.invalid("export tree/count") }
        var remap = [UInt32](repeating: .max, count: metadata.totalEntries)
        for (newID, oldID) in order.enumerated() { remap[Int(oldID)] = UInt32(newID) }
        let rootBytes = Data(identity.root.utf8)
        let tableOffset = (UInt64(SnapshotFormat.headerSize + rootBytes.count) + 7) & ~UInt64(7)
        let tableLength = try SnapshotFormat.multiply(UInt64(order.count), UInt64(SnapshotFormat.recordSize))
        let blobOffset = try SnapshotFormat.add(tableOffset, tableLength)
        var peak = Metrics.processUsage().residentBytes
        var crc: UInt32 = 0, blobLength: UInt64 = 0
        var header = SnapshotHeader(recordCount: UInt64(order.count), recordTableOffset: tableOffset,
            recordTableLength: tableLength, nameBlobOffset: blobOffset, nameBlobLength: 0,
            rootPathLength: UInt64(rootBytes.count), createdAtUnixSeconds: UInt64(max(0, Date().timeIntervalSince1970)),
            indexGeneration: metadata.generation, lastProcessedEventID: cursor, rootDeviceID: identity.deviceID,
            volumeUUID: identity.volumeUUID, historyUUID: identity.historyUUID, payloadCRC32: 0,
            fileLength: 0, rootFileID: identity.rootFileID, snapshotUUID: UUID())
        try store.publish(write: { fd in
            func emit(_ bytes: Data) throws {
                try snapshotWriteAll(fd, bytes)
                crc = SnapshotFormat.crc(bytes, previous: crc)
            }
            try snapshotWriteAll(fd, Data(repeating: 0, count: SnapshotFormat.headerSize))
            try fault?(.afterHeader)
            try emit(rootBytes)
            try emit(Data(repeating: 0, count: Int(tableOffset) - SnapshotFormat.headerSize - rootBytes.count))
            for start in stride(from: 0, to: order.count, by: 4096) {
                guard !cancellation.isCancelled else { throw SnapshotError.cancelled }
                let entries = try index.exportLiveChunk(ids: order[start..<min(order.count, start + 4096)],
                    expectedGeneration: metadata.generation, rootDeviceID: identity.deviceID)
                var bytes = Data(); bytes.reserveCapacity(entries.count * SnapshotFormat.recordSize)
                for entry in entries {
                    let root = entry.id == 0
                    let nameLength = root ? 0 : entry.name.utf8.count
                    guard nameLength <= NAME_MAX, root || (nameLength > 0 && entry.name != "." && entry.name != ".." &&
                        !entry.name.utf8.contains(0) && !entry.name.utf8.contains(47)) else { throw SnapshotError.invalid("basename") }
                    let parent = root ? UInt32.max : (entry.parentID >= 0 && Int(entry.parentID) < remap.count ? remap[Int(entry.parentID)] : .max)
                    guard root || parent < remap[Int(entry.id)], blobLength <= UInt32.max else {
                        throw SnapshotError.invalid("parent remap/name blob limit")
                    }
                    bytes.append(SnapshotRecord(parentID: parent, nameOffset: UInt32(blobLength),
                        nameLength: UInt16(nameLength), kind: entry.kind, flags: root ? 0 : (entry.isBoundary ? 1 : 0),
                        fileID: entry.fileID ?? 0).encoded)
                    blobLength = try SnapshotFormat.add(blobLength, UInt64(nameLength))
                }
                try emit(bytes)
                peak = max(peak, Metrics.processUsage().residentBytes)
            }
            guard blobLength <= UInt32.max else { throw SnapshotError.invalid("name blob limit") }
            for start in stride(from: 0, to: order.count, by: 4096) {
                guard !cancellation.isCancelled else { throw SnapshotError.cancelled }
                let entries = try index.exportLiveChunk(ids: order[start..<min(order.count, start + 4096)],
                    expectedGeneration: metadata.generation, rootDeviceID: identity.deviceID)
                var bytes = Data()
                for entry in entries where entry.id != 0 { bytes.append(contentsOf: entry.name.utf8) }
                try emit(bytes)
                peak = max(peak, Metrics.processUsage().residentBytes)
            }
            header.nameBlobLength = blobLength
            header.fileLength = try SnapshotFormat.add(blobOffset, blobLength)
            header.payloadCRC32 = crc
            guard header.fileLength <= SnapshotFormat.maxFileBytes else { throw SnapshotError.invalid("file size limit") }
            var statbuf = stat()
            guard fstat(fd, &statbuf) == 0, UInt64(statbuf.st_size) == header.fileLength else { throw SnapshotError.invalid("written length") }
            try snapshotWriteAll(fd, header.encoded(), offset: 0)
            return ()
        }, beforePublish: {
            guard !cancellation.isCancelled else { throw SnapshotError.cancelled }
            guard index.captureSnapshotMetadata().generation == metadata.generation else { throw SnapshotError.generationChanged }
            try beforePublish?()
        }, fault: fault)
        return SnapshotWriteResult(header: header, durationMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
            peakResidentBytes: max(peak, Metrics.processUsage().residentBytes))
    }
}
