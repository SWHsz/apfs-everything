import APFSFindCore
import Darwin
import Foundation

/// Opt-in owned-fixture acceptance harness, never enabled in the production bundle.
@MainActor
enum NativeSmokeActions {
  static func emit(_ stage:String,_ value:[String:Any]) {
    guard let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) else{return}
    FileHandle.standardOutput.write(Data(("[resource-smoke] "+stage+" "+String(decoding:data,as:UTF8.self)+"\n").utf8))
  }
  static func run(_ coordinator:MultiVolumeCoordinator,restart:Bool=false) async {
    guard Bundle.main.bundleIdentifier?.hasPrefix("local.apfsfind.desktop.smoke.")==true else{return}
    let deadline=ProcessInfo.processInfo.systemUptime+1200
    while ProcessInfo.processInfo.systemUptime<deadline {
      let states=await coordinator.sessionsSnapshot()
      if states.count==2 && states.allSatisfy({$0.state == .live && $0.metadataAvailable}) {break}
      do {try await Task.sleep(for:.milliseconds(500))} catch{return}
    }
    let states=await coordinator.sessionsSnapshot()
    guard states.count==2 && states.allSatisfy({$0.state == .live && $0.metadataAvailable}) else{emit("actions_unavailable",["reason":"sessions not live with metadata"]);return}
    var queries:[[String:Any]]=[]
    let sorts=[SearchSortDescriptor(),.init(key:.name,direction:.ascending),.init(key:.name,direction:.descending),.init(key:.modificationTime,direction:.ascending),.init(key:.modificationTime,direction:.descending),.init(key:.size,direction:.ascending),.init(key:.size,direction:.descending)]
    for sort in sorts {
      var times:[Double]=[],complete=true
      for _ in 0..<5 {
        let result=await coordinator.search(.init(query:"f",limit:51,sort:sort));times.append(result.latencyMilliseconds);complete = complete && result.metadataComplete
      }
      queries.append(["key":sort.key.rawValue,"direction":sort.direction.rawValue,"p95_ms":times.sorted()[Int(ceil(Double(times.count)*0.95))-1],"metadata_complete":complete])
    }
    emit(restart ? "restart_queries":"queries",["sorts":queries])
    guard let path=Bundle.main.object(forInfoDictionaryKey:"APFSFindOwnedFixture") as? String,
      PathCanonicalizer.parent(of:path)=="/Volumes/Data 1/everything/.build",
      URL(fileURLWithPath:path).lastPathComponent.hasPrefix("apfsfind-fixture-"),
      UUID(uuidString:String(URL(fileURLWithPath:path).lastPathComponent.dropFirst("apfsfind-fixture-".count))) != nil,
      let attributes=try? FileManager.default.attributesOfItem(atPath:path),
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value==getuid(),
      attributes[.type] as? FileAttributeType == .typeDirectory else {emit("fixture_error",["reason":"missing owned fixture"]);return}
    let prefix="apfsfindv061fixture-"
    do {
      if !restart {
        await coordinator.setAllPaused(.userGlobal,enabled:true)
        let paused=await coordinator.sessionsSnapshot().allSatisfy{$0.state == .paused}
        try Data(repeating:0,count:37).write(to:URL(fileURLWithPath:path+"/"+prefix+"born"))
        try FileManager.default.removeItem(atPath:path+"/"+prefix+"base-1")
        try FileManager.default.moveItem(atPath:path+"/"+prefix+"base-2",toPath:path+"/"+prefix+"renamed")
        await coordinator.setAllPaused(.userGlobal,enabled:false)
        emit("global_pause_resume",["paused":paused,"owned_changes":3])
      }
      let expected=Set((3...12).map{path+"/"+prefix+"base-\($0)"}+[path+"/"+prefix+"born",path+"/"+prefix+"renamed"])
      let end=ProcessInfo.processInfo.systemUptime+120
      var actual=Set<String>(),metadataCorrect=false
      while ProcessInfo.processInfo.systemUptime<end {
        let result=await coordinator.search(.init(query:prefix,limit:100,sort:.init(key:.size)))
        actual=Set(result.hits.map(\.path).filter{$0.hasPrefix(path+"/")})
        metadataCorrect=result.hits.first{$0.path==path+"/"+prefix+"born"}?.logicalSize==37
        if actual==expected && metadataCorrect {break}
        do {try await Task.sleep(for:.milliseconds(100))} catch{return}
      }
      emit(restart ? "restart_fixture_verify":"fixture_verify",["passed":actual==expected && metadataCorrect,"expected":expected.count,"actual":actual.count,"metadata_size_correct":metadataCorrect,"scope":"all owned fixture paths; not a full filesystem consistency assertion"])
      if let data=try? await coordinator.resourceDiagnosticsJSON(){FileHandle.standardOutput.write(Data(("[resource-smoke] "+(restart ? "restart_diagnostics":"actions_diagnostics")+" "+String(decoding:data,as:UTF8.self)+"\n").utf8))}
    } catch {emit("fixture_error",["reason":String(describing:error)])}
    emit(restart ? "restart_complete":"native_actions_complete",[:])
  }
}
