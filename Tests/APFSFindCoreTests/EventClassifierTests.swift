import XCTest
import CoreServices
@testable import APFSFindCore

final class EventClassifierTests: XCTestCase {
    func testReplayOverlapNeverSuppressesSpecialFlagsOrNewEvents() {
        let create = UInt32(kFSEventStreamEventFlagItemCreated|kFSEventStreamEventFlagItemIsFile)
        XCTAssertTrue(EventClassifier.ordinaryReplayOverlap(.init(path:"/old",flags:create,id:90),floor:100))
        for flag in [kFSEventStreamEventFlagMustScanSubDirs,kFSEventStreamEventFlagHistoryDone,
                     kFSEventStreamEventFlagUserDropped,kFSEventStreamEventFlagKernelDropped,
                     kFSEventStreamEventFlagRootChanged,kFSEventStreamEventFlagEventIdsWrapped] {
            XCTAssertFalse(EventClassifier.ordinaryReplayOverlap(.init(path:"/old",flags:create|UInt32(flag),id:90),floor:100))
        }
        for id in [UInt64(0),101,UInt64.max] {
            XCTAssertFalse(EventClassifier.ordinaryReplayOverlap(.init(path:"/new",flags:create,id:id),floor:100))
        }
    }
    private func classify(_ flags: Int) -> EventClassification {
        EventClassifier.classify(.init(path: "/tmp/example", flags: UInt32(flags)))
    }
    func testContentOnlyFlagsIgnored() {
        for flag in [kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemInodeMetaMod,
                     kFSEventStreamEventFlagItemXattrMod, kFSEventStreamEventFlagItemFinderInfoMod,
                     kFSEventStreamEventFlagItemChangeOwner] {
            XCTAssertEqual(classify(flag | kFSEventStreamEventFlagItemIsFile), .contentOnly)
        }
    }
    func testCreateRemoveRenameAndCompound() {
        XCTAssertEqual(classify(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile), .simpleCreate(.file))
        XCTAssertEqual(classify(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir), .simpleCreate(.directory))
        XCTAssertEqual(classify(kFSEventStreamEventFlagItemRemoved), .simpleRemove)
        XCTAssertEqual(classify(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemModified), .ambiguous)
        XCTAssertEqual(classify(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved), .ambiguous)
        XCTAssertEqual(classify(kFSEventStreamEventFlagItemCreated), .ambiguous)
        XCTAssertEqual(classify(0), .ambiguous)
        XCTAssertEqual(classify(Int(0x80000000)), .ambiguous)
    }
    func testUntypedMetadataCannotBeAssumedToBeContentOnly() {
        for flag in [kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemInodeMetaMod,
                     kFSEventStreamEventFlagItemXattrMod, kFSEventStreamEventFlagItemFinderInfoMod,
                     kFSEventStreamEventFlagItemChangeOwner] {
            XCTAssertEqual(classify(flag), .ambiguous)
        }
    }
    func testInvalidationPrecedesOtherFlags() {
        for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
                     kFSEventStreamEventFlagEventIdsWrapped, kFSEventStreamEventFlagRootChanged] {
            XCTAssertEqual(classify(flag | kFSEventStreamEventFlagMustScanSubDirs), .invalidated)
        }
        XCTAssertEqual(classify(kFSEventStreamEventFlagMustScanSubDirs), .subtreeDirty)
        XCTAssertEqual(classify(kFSEventStreamEventFlagHistoryDone), .historyDone)
    }
}
