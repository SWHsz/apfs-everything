import Foundation
import XCTest
@testable import APFSFindCore

final class CacheReleaseTests: XCTestCase, @unchecked Sendable {
  func testPressureReplacesStorageAndPreservesMostRecentRefs() {
    let cache=HotDirectoryCache(capacity:16384), v=PathResolutionVersion(baseUUID:UUID(),generation:7)
    cache.reset(version:v,root:"/fixture")
    func path(_ i:Int)->String { "/fixture/"+String(repeating:"long-component/",count:100)+String(i) }
    for i in 0..<16384 { cache.insert(path(i),ref:.delta(UInt32(i)),version:v) }
    XCTAssertEqual(cache.lookup(path(0),version:v),.delta(0))
    weak var old:AnyObject?=cache.storageForTesting
    let before=cache.statistics
    cache.setPressure(.warning,root:"/fixture")
    XCTAssertNil(old)
    XCTAssertEqual(cache.statistics["hot_directory_cache_entries"],2048)
    XCTAssertLessThan(cache.statistics["hot_directory_cache_storage_capacity",default:0],before["hot_directory_cache_storage_capacity",default:0])
    XCTAssertEqual(cache.lookup(path(0),version:v),.delta(0))
    XCTAssertNil(cache.lookup(path(1),version:v))
    XCTAssertEqual(cache.lookup(path(16383),version:v),.delta(16383))
    cache.invalidate(prefix:path(16383)); XCTAssertNil(cache.lookup(path(16383),version:v))
    weak var warning:AnyObject?=cache.storageForTesting
    cache.setPressure(.critical,root:"/fixture")
    XCTAssertNil(warning); XCTAssertEqual(cache.statistics["hot_directory_cache_entries"],1)
    XCTAssertEqual(cache.lookup("/fixture",version:v),.base(0))
    cache.setPressure(.normal,root:"/fixture")
    XCTAssertEqual(cache.statistics["hot_directory_cache_entries"],1)
    XCTAssertNil(cache.lookup("/fixture",version:.init(baseUUID:v.baseUUID,generation:8)))
    XCTAssertEqual(cache.statistics["hot_directory_cache_rebuilds"],2)
  }
  func testConcurrentLookupsAndPressureKeepCapacityBounded() {
    let cache=HotDirectoryCache(capacity:16384), v=PathResolutionVersion(baseUUID:UUID(),generation:3)
    cache.reset(version:v,root:"/fixture")
    DispatchQueue.concurrentPerform(iterations:2000) { i in
      cache.insert("/fixture/\(i)",ref:.delta(UInt32(i)),version:v)
      _=cache.lookup("/fixture/\(i)",version:v)
      if i%300==0 { cache.setPressure(.warning,root:"/fixture") }
      if i%500==0 { cache.invalidate(prefix:"/fixture/\(i)") }
    }
    cache.setPressure(.critical,root:"/fixture")
    XCTAssertEqual(cache.statistics["hot_directory_cache_entries"],1)
    XCTAssertEqual(cache.lookup("/fixture",version:v),.base(0))
  }
}
