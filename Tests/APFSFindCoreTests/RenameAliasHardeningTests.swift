import Foundation
import XCTest
@testable import APFSFindCore

final class RenameAliasHardeningTests: XCTestCase {
  func testTenThousandRenamesBoundFrozenChainsAndCheckpointRestart() throws {
    let cache = try TemporaryTree(cache:true), identity = snapshotIdentity(), ram = FileIndex(root:identity.root), store = try SnapshotStore(directory:cache.root,identity:identity)
    ram.apply([.upsert(.init(path:identity.root+"/A/file",kind:.file))])
    let ns = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:1,store:store)
    _ = try MetadataWriter.write(store:store,base:ns.header,cursor:1,value:{ _ in .init(logicalSize:7,modificationTimeNanoseconds:11) })
    let metadata = MetadataIndexCoordinator(); metadata.bind(namespace:try store.reader(expectedIdentity:identity).mappedBase!,mapped:try store.metadataReader(base:ns.header))
    var current = identity.root+"/A", capped = 0, maximumDepth = 0, first:[Double] = [], last:[Double] = []
    for i in 0..<10_000 {
      let before = metadata.capture(), next = identity.root+(i % 2 == 0 ? "/B" : "/A")
      let value = before.value(path:current+"/file"); XCTAssertEqual(value.logicalSize,7)
      let reused = metadata.reuseDirectoryRename(original:current,destination:next,from:before)
      metadata.update(path:current,value:nil)
      // The updater enumerates the affected subtree if the frozen alias cap is
      // reached. Model its authoritative bulk metadata result here.
      if !reused { capped += 1; metadata.update(path:next+"/file",value:value) }
      let snapshot = metadata.capture(), start = ProcessInfo.processInfo.systemUptime
      XCTAssertEqual(snapshot.value(path:next+"/file").logicalSize,7)
      let elapsed = ProcessInfo.processInfo.systemUptime-start
      if i < 100 { first.append(elapsed) }; if i >= 9900 { last.append(elapsed) }
      maximumDepth = max(maximumDepth,snapshot.maximumAliasDepth)
      XCTAssertLessThanOrEqual(snapshot.maximumAliasDepth,16); XCTAssertLessThanOrEqual(snapshot.overlay.retainedRenameBytes,32*1024*1024)
      current = next
    }
    XCTAssertGreaterThan(capped,0); XCTAssertLessThanOrEqual(maximumDepth,16)
    // A linear 10k-depth regression is orders of magnitude larger. Allow normal
    // sanitizer/system noise; structural limits remain the primary guarantee.
    XCTAssertLessThan(last.reduce(0,+),max(0.05,first.reduce(0,+)*10))
    let final = metadata.capture(), rebuilt = FileIndex(root:identity.root)
    rebuilt.apply([.upsert(.init(path:current+"/file",kind:.file))])
    let newNS = try SnapshotV2Writer.write(source:.ram(rebuilt,rebuilt.stats().generation),identity:identity,generation:rebuilt.stats().generation,cursor:2,store:store)
    let base = try store.reader(expectedIdentity:identity).mappedBase!
    _ = try MetadataWriter.write(store:store,base:newNS.header,cursor:2,value:{ final.value(path:base.reconstructPath($0)) })
    let restarted = MetadataIndexCoordinator(); restarted.bind(namespace:base,mapped:try store.metadataReader(base:newNS.header))
    XCTAssertEqual(restarted.capture().value(path:current+"/file").logicalSize,7); XCTAssertEqual(restarted.capture().maximumAliasDepth,0)
  }
  func testAliasCountAndRetainedBytesRejectBeforeRetainingNewGraph() throws {
    let metadata = MetadataIndexCoordinator()
    for i in 0..<1000 {
      _ = metadata.reuseDirectoryRename(original:"/A",destination:"/B\(i)",from:metadata.capture())
      let snapshot = metadata.capture()
      XCTAssertLessThanOrEqual(snapshot.renamedDirectories.count,64); XCTAssertLessThanOrEqual(snapshot.maximumAliasDepth,16)
      XCTAssertLessThanOrEqual(snapshot.overlay.retainedRenameBytes,32*1024*1024)
    }
    XCTAssertTrue(metadata.renameNeedsMaintenance)
  }
}
