import XCTest
@testable import APFSFindCore

final class VerificationRaceTests: XCTestCase {
    func testPersistentMissingAndGhostRemainFailures() {
        let v = VerificationResult.revalidated(missing: ["/missing"], extra: ["/ghost"],
            exists: { $0 == "/missing" }, indexed: { $0 == "/ghost" })
        XCTAssertEqual(v.missing, ["/missing"])
        XCTAssertEqual(v.extra, ["/ghost"])
        XCTAssertFalse(v.isConsistent)
        XCTAssertTrue(v.racedPaths.isEmpty)
    }
    func testPostScanRemovalAndCreationAreRetainedAsAuditableRaces() {
        let v = VerificationResult.revalidated(missing: ["/removed"], extra: ["/created"],
            exists: { $0 == "/created" }, indexed: { $0 == "/created" })
        XCTAssertTrue(v.isConsistent)
        XCTAssertFalse(v.rawSetsAgree)
        XCTAssertEqual(v.rawMissing, ["/removed"])
        XCTAssertEqual(v.rawExtra, ["/created"])
        XCTAssertEqual(v.racedPaths, ["/created", "/removed"])
    }
    func testUnavailableMetadataDoesNotHideDifferences() {
        let v = VerificationResult.revalidated(missing: ["/a"], extra: ["/b"],
            exists: { _ in nil }, indexed: { _ in false })
        XCTAssertEqual(v.missing, ["/a"])
        XCTAssertEqual(v.extra, ["/b"])
        XCTAssertFalse(v.isConsistent)
    }
    func testRevalidationCanReverseTheOriginalDifferenceCategory() {
        let v = VerificationResult.revalidated(missing: ["/now-ghost"], extra: ["/now-missing"],
            exists: { $0 == "/now-missing" }, indexed: { $0 == "/now-ghost" })
        XCTAssertEqual(v.missing, ["/now-missing"])
        XCTAssertEqual(v.extra, ["/now-ghost"])
        XCTAssertFalse(v.isConsistent)
    }
}
