import CryptoKit
import Foundation

/// Storage identity is independent of the source's FSEvents/device identity.
public enum IndexStoragePolicy: Codable, Sendable, Equatable {
  case defaultInternal
  case volume(storageVolumeUUID: UUID, relativeDirectory: String)
}

public struct IndexStorageLocator: Codable, Sendable, Equatable {
  public let version: UInt32
  public let sourceVolumeUUID: UUID
  public let sourceRootFileID: UInt64
  public let sourceRelativeRootHash: String
  public let policy: IndexStoragePolicy
  public let updatedAt: Date
  public init(identity: VolumeIdentity, policy: IndexStoragePolicy, updatedAt: Date = Date()) {
    version = 1; sourceVolumeUUID = identity.volumeUUID; sourceRootFileID = identity.rootFileID
    sourceRelativeRootHash = Self.rootHash(identity.relativeRoot)
    self.policy = policy; self.updatedAt = updatedAt
  }
  public static func rootHash(_ relativeRoot: String) -> String {
    SHA256.hash(data: Data(relativeRoot.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  public func matches(_ identity: VolumeIdentity) -> Bool {
    version == 1 && sourceVolumeUUID == identity.volumeUUID && sourceRootFileID == identity.rootFileID
      && sourceRelativeRootHash == Self.rootHash(identity.relativeRoot)
  }
}

public enum IndexStorageState: Sendable, Equatable {
  case available, migrating, readOnly, offline, identityChanged
  case lowSpace(required: UInt64, available: UInt64)
  case unsafePath(String), failed(String)
}

public struct ResolvedIndexStorage: Sendable, Equatable {
  public let sourceVolumeUUID: UUID
  public let storageVolumeUUID: UUID
  public let storageMountPath: String
  public let relativeDirectory: String
  public let absoluteDirectory: String
  public let state: IndexStorageState
}

public enum IndexStorageSpace {
  public static let minimumMargin: UInt64 = 256 * 1024 * 1024
  public static func requiredMigration(namespace: UInt64, metadata: UInt64, overhead: UInt64 = 64 * 1024) throws -> UInt64 {
    let total = try add(try add(namespace, metadata), overhead)
    return try add(total, max(minimumMargin, total / 10 + (total % 10 == 0 ? 0 : 1)))
  }
  public static func requiredCompaction(currentFiles: UInt64, newNamespace: UInt64, newMetadata: UInt64) throws -> UInt64 {
    let total = try add(try add(currentFiles, newNamespace), newMetadata)
    return try add(total, max(minimumMargin, total / 10 + (total % 10 == 0 ? 0 : 1)))
  }
  private static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
    let (value, overflow) = a.addingReportingOverflow(b)
    guard !overflow else { throw SnapshotError.invalid("index storage space overflow") }
    return value
  }
}

public struct IndexStorageStatus:Sendable {
  public let resolved:ResolvedIndexStorage
  public let state:IndexStorageState
  public let indexBytes:UInt64,requiredMigrationBytes:UInt64,requiredCompactionBytes:UInt64,availableBytes:UInt64
}
