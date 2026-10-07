import Foundation

public enum EntryKind: String, Sendable, Equatable {
  case file, directory, symlink, other
}

/// Metadata for a namespace entry. No file contents are stored or read.
public struct NamespaceEntry: Sendable, Equatable {
  public var path: String
  public var kind: EntryKind
  public var deviceID: UInt64
  public var fileID: UInt64?
  public var isMountPoint: Bool

  /// A directory inode is only meaningful on its device. Mount flags also
  /// change traversal eligibility even when both inode numbers are identical.
  public func hasSameDirectoryIdentity(as other: NamespaceEntry) -> Bool {
    kind == .directory && other.kind == .directory && fileID == other.fileID
      && deviceID == other.deviceID && isMountPoint == other.isMountPoint
  }

  public init(
    path: String, kind: EntryKind, deviceID: UInt64 = 0, fileID: UInt64? = nil,
    isMountPoint: Bool = false
  ) {
    self.path = path
    self.kind = kind
    self.deviceID = deviceID
    self.fileID = fileID
    self.isMountPoint = isMountPoint
  }
}

public enum IndexMutation: Sendable {
  case upsert(NamespaceEntry)
  case remove(String)
}

public struct FileEntry: Sendable {
  public let id: Int32
  public var parentID: Int32
  public var name: String
  public var foldedName: String
  public var kind: EntryKind
  public var isDeleted: Bool
  public var path: String
  public var deviceID: UInt64
  public var fileID: UInt64?
  public var isMountPoint: Bool

  var namespaceEntry: NamespaceEntry {
    NamespaceEntry(
      path: path, kind: kind, deviceID: deviceID, fileID: fileID, isMountPoint: isMountPoint)
  }

  static func fold(_ name: String) -> String {
    // ASCII is common in bulk indexes; this exactly matches the POSIX
    // case-insensitive fold without creating Foundation objects per record.
    let bytes = Array(name.utf8)
    if bytes.allSatisfy({ $0 < 128 }) {
      return String(decoding: bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }
    return name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .precomposedStringWithCanonicalMapping
  }
}

public struct SearchHit: Sendable, Equatable {
  public let path: String
  public let kind: EntryKind
  public let matchRank: MatchRank
  public let logicalSize: UInt64?
  public let modificationTimeNanoseconds: Int64?
  public let metadataFreshness: MetadataFreshness

  public init(path: String, kind: EntryKind, matchRank: MatchRank = .substring,
              logicalSize: UInt64? = nil, modificationTimeNanoseconds: Int64? = nil,
              metadataFreshness: MetadataFreshness = .unavailable) {
    self.path = path
    self.kind = kind
    self.matchRank = matchRank
    self.logicalSize = kind == .file ? logicalSize : nil
    self.modificationTimeNanoseconds = modificationTimeNanoseconds
    self.metadataFreshness = metadataFreshness
  }
}

public struct SearchResult: Sendable {
  public let hits: [SearchHit]
  public let latencyMilliseconds: Double
  public let generation: UInt64
  public let freshness: SearchFreshness
  public let cancelled: Bool
  public init(hits: [SearchHit], latencyMilliseconds: Double, generation: UInt64,
              freshness: SearchFreshness = .live, cancelled: Bool = false) {
    self.hits = hits; self.latencyMilliseconds = latencyMilliseconds; self.generation = generation
    self.freshness = freshness; self.cancelled = cancelled
  }
}

public struct IndexStats: Sendable {
  public let totalEntries: Int
  public let liveEntries: Int
  public let tombstones: Int
  public let files: Int
  public let directories: Int
  public let generation: UInt64
}
