import Foundation
import XCTest
@testable import APFSFindCore

final class SnapshotFormatTests: XCTestCase {
    func testCRC32StandardVectorAndIncrementalChunks() {
        let vector = Data("123456789".utf8)
        XCTAssertEqual(SnapshotFormat.crc(vector), 0xcbf43926)
        let first = SnapshotFormat.crc(Data(vector.prefix(4)))
        XCTAssertEqual(SnapshotFormat.crc(Data(vector.dropFirst(4)), previous: first), 0xcbf43926)
    }
    func testFixedRecordEncodingHasExplicitLittleEndianAndReservedBytes() {
        let record = SnapshotRecord(parentID: 0x12345678, nameOffset: 0x01020304,
            nameLength: 0x1122, kind: .symlink, flags: 1, fileID: 0x0102030405060708)
        let bytes = record.encoded
        XCTAssertEqual(bytes.count, 24)
        XCTAssertEqual(Array(bytes[0..<4]), [0x78,0x56,0x34,0x12])
        XCTAssertEqual(Array(bytes[4..<8]), [4,3,2,1])
        XCTAssertEqual(Array(bytes[8..<12]), [0x22,0x11,3,1])
        XCTAssertEqual(Array(bytes[12..<16]), [0,0,0,0])
        XCTAssertEqual(Array(bytes[16..<24]), [8,7,6,5,4,3,2,1])
        XCTAssertThrowsError(try SnapshotFormat.add(.max, 1))
        XCTAssertThrowsError(try SnapshotFormat.multiply(.max, 24))
    }
}
