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
    let prefix="apfsfindv062fixture-"
    do {
      let before = try await ActiveLiveSmoke.sample(coordinator)
      let pressure = restart ? nil : Task {
        while !Task.isCancelled {
          _ = await coordinator.search(.init(query:"f",limit:51))
          await Task.yield()
        }
      }
      defer { pressure?.cancel() }
      var allPassed = true
      for round in restart ? [10] : Array(1...10) {
        if !restart {
          await coordinator.setAllPaused(.userGlobal,enabled:true)
          let paused=await coordinator.sessionsSnapshot().allSatisfy{$0.state == .paused}
          try Data(repeating:0,count:37+round).write(to:URL(fileURLWithPath:path+"/"+prefix+"born-\(round)"))
          try FileManager.default.removeItem(atPath:path+"/"+prefix+(round == 1 ? "base-1" : "born-\(round-1)"))
          try FileManager.default.moveItem(atPath:path+"/"+prefix+(round == 1 ? "base-2" : "renamed-\(round-1)"),toPath:path+"/"+prefix+"renamed-\(round)")
          try Data(repeating:1,count:100+round).write(to:URL(fileURLWithPath:path+"/"+prefix+"base-3"))
          await coordinator.setAllPaused(.userGlobal,enabled:false)
          emit("global_pause_resume",["round":round,"paused":paused,"owned_changes":4])
        }
        let expected=Set((3...12).map{path+"/"+prefix+"base-\($0)"}+[path+"/"+prefix+"born-\(round)",path+"/"+prefix+"renamed-\(round)"])
        var values:[String:(UInt64,Int64)]=[:]
        for file in expected {
          var st=stat()
          guard lstat(file,&st)==0 else {throw POSIXError(.ENOENT)}
          values[file]=(UInt64(st.st_size),Int64(st.st_mtimespec.tv_sec)*1_000_000_000+Int64(st.st_mtimespec.tv_nsec))
        }
        let start=ProcessInfo.processInfo.systemUptime, end=start+30
        var actual=Set<String>(),metadataCorrect=false, mismatches:[[String:Any]]=[]
        while ProcessInfo.processInfo.systemUptime<end {
          let result=await coordinator.search(.init(query:prefix,limit:100,sort:.init(key:.size)))
          let hits=result.hits.filter{$0.path.hasPrefix(path+"/")}
          actual=Set(hits.map(\.path))
          mismatches=hits.compactMap { hit in
            guard let value=values[hit.path], hit.logicalSize != value.0 || hit.modificationTimeNanoseconds != value.1 else{return nil}
            // Only owned generated slots; never include real filenames/paths.
            return ["slot":String(hit.path.dropFirst((path+"/"+prefix).count)),
              "expected_size":value.0,"actual_size":hit.logicalSize.map{NSNumber(value:$0)} ?? NSNull(),
              "expected_mtime_ns":value.1,"actual_mtime_ns":hit.modificationTimeNanoseconds.map{NSNumber(value:$0)} ?? NSNull()]
          }
          metadataCorrect=hits.count==expected.count && hits.allSatisfy{values[$0.path] != nil} && mismatches.isEmpty
          if actual==expected && metadataCorrect {break}
          do {try await Task.sleep(for:.milliseconds(100))} catch{return}
        }
        let after=try await ActiveLiveSmoke.sample(coordinator)
        let passed=actual==expected && metadataCorrect && after.fullScans==before.fullScans && after.resourceYieldRebuilds==before.resourceYieldRebuilds
        allPassed = allPassed && passed
        emit(restart ? "restart_fixture_verify":"fixture_verify",["round":round,"passed":passed,"expected":expected.count,"actual":actual.count,"metadata_size_mtime_correct":metadataCorrect,"mismatches":mismatches,"seconds":ProcessInfo.processInfo.systemUptime-start,"full_scans_delta":after.fullScans-before.fullScans,"resource_yield_rebuild_delta":after.resourceYieldRebuilds-before.resourceYieldRebuilds,"scope":"owned fixture; not a full filesystem consistency assertion"])
      }
      pressure?.cancel()
      emit("convergence_rounds",["passed":allPassed,"rounds":restart ? 1 : 10])
      if let data=try? await coordinator.resourceDiagnosticsJSON(){FileHandle.standardOutput.write(Data(("[resource-smoke] "+(restart ? "restart_diagnostics":"actions_diagnostics")+" "+String(decoding:data,as:UTF8.self)+"\n").utf8))}
    } catch {emit("fixture_error",["reason":String(describing:error)])}
    emit(restart ? "restart_complete":"native_actions_complete",[:])
  }
}
