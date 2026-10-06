import APFSFindCore
import Foundation

struct DesktopTestVolumeProvider: MountedVolumeProvider {
  let roots: [String]
  func mountedVolumes() throws -> [VolumeDescriptor] {
    try roots.enumerated().map { index, root in
      let canonical = try PathCanonicalizer.canonicalRoot(root)
      return .init(volumeUUID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                   displayName: "Test Volume \(index + 1)", mountPath: canonical, isSystemVolume: index == 0)
    }
  }
}
final class DesktopTestSelection: VolumeSelectionStore, @unchecked Sendable {
  private let lock = NSLock()
  private var ids: Set<UUID>
  init(_ ids: Set<UUID>) { self.ids = ids }
  func load() -> Set<UUID> { lock.withLock { ids } }
  func save(_ ids: Set<UUID>) { lock.withLock { self.ids = ids } }
}
struct AppPreferences {
  let testRoots: [String]
  let testCache: String?
  init(arguments: [String]) throws {
    var roots: [String] = [], cache: String?, i = 0
    while i < arguments.count {
      let flag = arguments[i]; i += 1
      if flag == "-NSDocumentRevisionsDebugMode" { i += 1; continue }
      guard ["--test-root", "--test-cache"].contains(flag), i < arguments.count else { continue }
      if flag == "--test-root" { roots.append(arguments[i]) } else { cache = arguments[i] }; i += 1
    }
    // Explicitly renamed smoke bundles can be launched by native UI automation
    // without command-line arguments. Production bundles never use these keys.
    if roots.isEmpty, Bundle.main.bundleIdentifier?.hasPrefix("local.apfsfind.desktop.smoke.") == true {
      roots = Bundle.main.object(forInfoDictionaryKey: "APFSFindTestRoots") as? [String] ?? []
      cache = Bundle.main.object(forInfoDictionaryKey: "APFSFindTestCache") as? String
    }
    if !roots.isEmpty, cache == nil { throw CocoaError(.fileNoSuchFile) }
    testRoots = roots; testCache = cache
  }
  func coordinator() throws -> MultiVolumeCoordinator {
    guard !testRoots.isEmpty else { return MultiVolumeCoordinator() }
    let provider = DesktopTestVolumeProvider(roots: testRoots), values = try provider.mountedVolumes(), cache = testCache!
    return MultiVolumeCoordinator(provider: provider, selectionStore: DesktopTestSelection(Set(values.map(\.volumeUUID))),
                                  factory: { try VolumeIndexSession(volume: $0, cacheDirectory: cache, maintenanceScheduler: $1) })
  }
}
