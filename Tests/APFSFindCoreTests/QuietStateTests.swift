import Foundation
import XCTest
@testable import APFSFindCore

final class QuietStateTests: XCTestCase {
  func testQuietRequiresLiveMetadataEmptyWorkAndThirtyStableSeconds() {
    var gate=QuietStateGate()
    let v=QuietVolumeState(volumeID:UUID(),state:.live,metadataFreshness:.live,metadataAvailable:true,namespaceGeneration:1,metadataGeneration:1)
    XCTAssertFalse(gate.observe([v],tasks:[],now:0).quiet)
    XCTAssertFalse(gate.observe([v],tasks:[],now:29.9).quiet)
    XCTAssertTrue(gate.observe([v],tasks:[],now:30).quiet)
    var pending=v;pending.metadataPending=1
    XCTAssertFalse(gate.observe([pending],tasks:[],now:31).quiet)
    XCTAssertFalse(gate.observe([v],tasks:[],now:32).quiet)
    XCTAssertTrue(gate.observe([v],tasks:[],now:62).quiet)
    var changed=v;changed.namespaceGeneration=2
    XCTAssertFalse(gate.observe([changed],tasks:[],now:63).quiet)
    XCTAssertTrue(gate.observe([changed],tasks:[],now:93).quiet)
    changed.metadataGeneration=2
    XCTAssertFalse(gate.observe([changed],tasks:[],now:94).quiet)
  }
  func testEveryBlockingConditionAndTaskIsReported() {
    var gate=QuietStateGate()
    var v=QuietVolumeState(volumeID:UUID(),state:.catchingUp,metadataFreshness:.catchingUp,metadataAvailable:true,namespaceGeneration:1,metadataGeneration:1)
    v.namespaceEvents=2;v.metadataPending=3;v.compactionScheduled=true;v.metadataMaintenanceScheduled=true
    let task=MaintenanceTaskSnapshot(id:UUID(),volumeID:v.volumeID,kind:.rebuild,queuedAt:0,startedAt:1,urgency:.required)
    let result=gate.observe([v],tasks:[task],now:20)
    XCTAssertFalse(result.quiet)
    XCTAssertEqual(result.blockers.count,7)
    XCTAssertTrue(result.blockers.contains { $0.contains("metadata pending") })
    XCTAssertTrue(result.blockers.contains { $0.contains("rebuild") })
    XCTAssertFalse(gate.observe([],tasks:[],now:100).quiet)
  }
  func testASCIIShortcutMatchesLexicalReferenceAndPreservesUnicode() {
    func reference(_ p:String)->String? {
      guard p.hasPrefix("/"),!p.utf8.contains(0) else { return nil }
      var parts:[Substring]=[]
      for c in p.split(separator:"/") { if c=="." { continue };if c==".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(c) } }
      return "/"+parts.joined(separator:"/")
    }
    for p in ["/","//","/a/b","/a//b/","/a/./b","/a/../b","/../../a","/..hidden/.../file","relative","/bad\0name","/é/e\u{301}","/目录/../文件"] {
      XCTAssertEqual(PathCanonicalizer.normalize(p),reference(p))
    }
  }
}
