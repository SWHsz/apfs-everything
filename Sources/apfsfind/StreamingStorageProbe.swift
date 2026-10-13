import APFSFindCore
import Darwin
import Foundation

/// Disposable APFS-driver entry point. The injected pause only establishes the
/// detach timing; scanning, assembly, storage monitoring and recovery are the
/// production PersistentIndexCoordinator path, with explicit equivalent pages.
enum StreamingStorageProbe {
  static func run(_ args:[String]) throws -> Int32 {
    guard args.count==3,["cold","recovery"].contains(args[0]) else {throw CLIError.usage("streaming storage probe mode/source/cache")}
    let mode=args[0],armed=CancellationToken()
    if mode=="cold" {armed.cancel()}
    let c=try PersistentIndexCoordinator(root:args[1],configuration:.init(fullRebuildMinInterval:0,maxConsecutiveRebuildFailures:1),
      cacheDirectory:args[2],maintenanceScheduler:.init(),streamingSource:SyntheticBuildSource(entries:65537),streamingBuildFault:{point,_ in
        if point == .afterSections && armed.isCancelled {
          try emit(["streaming_before_assembly":true,"mode":mode]);Thread.sleep(forTimeInterval:0.75)
        }
      })
    defer {c.stop(policy:.fast)}
    do {
      try c.start()
      guard c.waitUntilLive(timeout:30) else {throw CLIError.startupFailed("streaming removal startup")}
      if mode=="cold" {throw CLIError.startupFailed("cold probe failed to observe detach")}
      armed.cancel();c.rebuild()
      let until=ProcessInfo.processInfo.systemUptime+30
      while ProcessInfo.processInfo.systemUptime<until {
        do {try c.validateStorage()}
        catch {c.storageWillUnmount();try emit(["structured_io_error":String(describing:error),"mode":mode,"crashed":false]);return 0}
        Thread.sleep(forTimeInterval:0.02)
      }
      throw CLIError.startupFailed("recovery removal timed out")
    } catch {
      let text=String(describing:error)
      guard !(error is CLIError) else {throw error}
      try emit(["structured_io_error":text,"mode":mode,"crashed":false]);return 0
    }
  }
  private static func emit(_ value:[String:Any]) throws {print(String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),as:UTF8.self));fflush(stdout)}
}
