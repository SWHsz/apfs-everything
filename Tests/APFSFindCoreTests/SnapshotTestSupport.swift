import Darwin
import Foundation
@testable import APFSFindCore

func snapshotIdentity(root: String = "/snapshot-fixture", device: UInt64 = 9,
                      volume: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                      history: UUID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!) -> VolumeIdentity {
    .init(root: root, deviceID: device, rootFileID: 123, volumeUUID: volume, historyUUID: history,
          mountPoint: "/", relativeRoot: String(root.dropFirst()))
}

func sampleSnapshotIndex(root: String = "/snapshot-fixture") -> FileIndex {
    let index = FileIndex(root: root)
    index.apply([
        .upsert(.init(path: root + "/dir/deep/Café-a", kind: .file, fileID: 90)),
        .upsert(.init(path: root + "/dir/deep/Cafe\u{301}-b", kind: .file)),
        .upsert(.init(path: root + "/link", kind: .symlink, fileID: 42)),
        .upsert(.init(path: root + "/dead/ghost", kind: .file)), .remove(root + "/dead")
    ])
    return index
}

func repairedChecksums(_ source: Data, payload: Bool = false) -> Data {
    var bytes = source
    if payload {
        bytes.put(SnapshotFormat.crc(Data(bytes.dropFirst(SnapshotFormat.headerSize))), at: 144)
    }
    bytes.put(UInt32(0), at: 148)
    bytes.put(SnapshotFormat.crc(Data(bytes.prefix(SnapshotFormat.headerSize))), at: 148)
    return bytes
}
