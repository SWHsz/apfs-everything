import Foundation
import XCTest
@testable import APFSFindCore

final class SnapshotObservationTests:XCTestCase {
  func testUpdateDuringInitialSnapshotCannotBeLostOrOverwritten() async {
    let observation=SnapshotObservation<Int>(),reading=DispatchSemaphore(value:0),updated=DispatchSemaphore(value:0)
    DispatchQueue.global().async {
      guard reading.wait(timeout:.now()+5) == .success else {return}
      observation.send(1)
      updated.signal()
    }
    func staleSnapshot() -> Int {
      reading.signal()
      XCTAssertEqual(updated.wait(timeout:.now()+5),.success)
      return 0
    }
    let stream=observation.stream(initial:staleSnapshot())
    var iterator=stream.makeAsyncIterator()
    let value=await iterator.next()
    XCTAssertEqual(value,1,"the final update must survive subscription and initial snapshot races")
  }
  func testInitialAndSubsequentValuesAreDelivered() async {
    let observation=SnapshotObservation<Int>(),stream=observation.stream(initial:0)
    var iterator=stream.makeAsyncIterator()
    let initial=await iterator.next();XCTAssertEqual(initial,0)
    observation.send(1)
    let next=await iterator.next();XCTAssertEqual(next,1)
  }
}
