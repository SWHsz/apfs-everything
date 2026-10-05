import XCTest
import CoreServices
@testable import APFSFindCore

final class EventClassifierTests: XCTestCase {
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
    func testInvalidationPrecedesOtherFlags() {
        for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
                     kFSEventStreamEventFlagEventIdsWrapped, kFSEventStreamEventFlagRootChanged] {
            XCTAssertEqual(classify(flag | kFSEventStreamEventFlagMustScanSubDirs), .invalidated)
        }
        XCTAssertEqual(classify(kFSEventStreamEventFlagMustScanSubDirs), .subtreeDirty)
        XCTAssertEqual(classify(kFSEventStreamEventFlagHistoryDone), .historyDone)
    }
}
