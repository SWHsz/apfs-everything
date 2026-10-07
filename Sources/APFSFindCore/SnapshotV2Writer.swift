import Darwin
import Foundation

/// Export sources retain ordinals and directory paths, never full base FileEntry.
public enum V2Source: Sendable {
  case ram(FileIndex, UInt64)
  case hybrid(HybridCapture)
  func metadata(_ ref: EntryRef, device: UInt64) throws -> SnapshotExportEntry {
    switch self {
    case .ram(let index, let generation):
      guard case .base(let id) = ref else { throw SnapshotError.invalid("RAM ref") }
      return try index.exportLiveChunk(
        ids: [Int32(id)][...], expectedGeneration: generation, rootDeviceID: device)[0]
    case .hybrid(let c):
      switch ref {
      case .base(let id):
        let r = c.base.record(at: id)
        return .init(
          id: 0, parentID: 0, name: c.base.name(at: id), kind: r.kind,
          fileID: r.fileID == 0 ? nil : r.fileID, isBoundary: r.flags != 0)
      case .delta(let id):
        let d = c.delta[id]!
        return .init(
          id: 0, parentID: 0, name: d.name, kind: d.entry.kind, fileID: d.entry.fileID,
          isBoundary: d.entry.isMountPoint || d.entry.deviceID != c.base.header.rootDeviceID)
      }
    }
  }
  func children(_ ref: EntryRef, path: String) throws -> [EntryRef] {
    switch self {
    case .ram(let index, let generation):
      guard case .base(let id) = ref else { return [] }
      return try index.exportTreeChildren(Int32(id), generation: generation).map {
        .base(UInt32($0))
      }
    case .hybrid(let c): return c.children(ref, path: path)
    }
  }
  var rootRef: EntryRef {
    switch self {
    case .ram: return .base(0)
    case .hybrid: return .base(0)
    }
  }
}

public enum SnapshotV2Writer {
  public static func write(
    source: V2Source, identity: VolumeIdentity, generation: UInt64, cursor: UInt64,
    store: SnapshotStore,
    cancellation: CancellationToken = .init(), beforePublish: @escaping () throws -> Void = {},
    fault: ((SnapshotFailurePoint) throws -> Void)? = nil,
    install: ((MMapBaseIndex, [String: EntryRef], () throws -> Void) throws -> Void)? = nil,
    prepareMetadata: (([EntryRef], SnapshotHeader) -> Void)? = nil,
    completed: (([EntryRef], SnapshotHeader) -> Void)? = nil,
    resourceMetrics: Metrics? = nil, resourceStage: String = "snapshot"
  ) throws -> SnapshotWriteResult {
    let started = ProcessInfo.processInfo.systemUptime
    let resourceStart = ProcessResourceSample.capture()
    var peak = Metrics.processUsage().residentBytes
    var refs: [EntryRef] = []
    var records: [BaseRecord] = []
    var children: [UInt32] = []
    struct Work {
      let ref: EntryRef
      let parent: UInt32
      let slot: Int
      let path: String
      let closing: Int?
    }
    var pending = [
      Work(ref: source.rootRef, parent: .max, slot: -1, path: identity.root, closing: nil)
    ]
    var nameLength: UInt64 = 0
    var foldLength: UInt64 = 0
    while let work = pending.popLast() {
      if refs.count % 4096 == 0, cancellation.isCancelled { throw SnapshotError.cancelled }
      if let close = work.closing {
        records[close].subtreeEnd = UInt32(records.count)
        continue
      }
      guard refs.count < Int(SnapshotFormat.maxRecords) else {
        throw SnapshotError.invalid("v2 record limit")
      }
      let id = UInt32(refs.count)
      let m = try source.metadata(work.ref, device: identity.deviceID)
      let name = id == 0 ? "" : m.name
      let folded = FileEntry.fold(name)
      guard name.utf8.count <= NAME_MAX, folded.utf8.count <= UInt16.max,
        id == 0
          || (!name.isEmpty && name != "." && name != ".." && !name.utf8.contains(0)
            && !name.utf8.contains(47)),
        nameLength <= UInt32.max, foldLength <= UInt32.max
      else { throw SnapshotError.invalid("v2 basename/blob limit") }
      let direct =
        m.kind == .directory && !m.isBoundary ? try source.children(work.ref, path: work.path) : []
      let first = children.count
      if work.slot >= 0 { children[work.slot] = id }
      children += Array(repeating: 0, count: direct.count)
      refs.append(work.ref)
      records.append(
        .init(
          parent: work.parent, firstChild: UInt32(first), childCount: UInt32(direct.count),
          subtreeEnd: id + 1,
          nameOffset: UInt32(nameLength), foldedOffset: UInt32(foldLength),
          nameLength: UInt16(name.utf8.count), foldedLength: UInt16(folded.utf8.count),
          kind: m.kind, flags: m.isBoundary ? 1 : 0, fileID: m.fileID ?? 0))
      nameLength += UInt64(name.utf8.count)
      foldLength += UInt64(folded.utf8.count)
      pending.append(Work(ref: work.ref, parent: work.parent, slot: -1, path: "", closing: Int(id)))
      for (slot, child) in direct.enumerated().reversed() {
        let cm = try source.metadata(child, device: identity.deviceID)
        let path = cm.kind == .directory ? (work.path == "/" ? "" : work.path) + "/" + cm.name : ""
        pending.append(Work(ref: child, parent: id, slot: first + slot, path: path, closing: nil))
      }
    }
    guard nameLength <= UInt32.max, foldLength <= UInt32.max else {
      throw SnapshotError.invalid("v2 blob overflow")
    }
    let root = Data(identity.root.utf8)
    let tableOffset = (UInt64(256 + root.count) + 7) & ~UInt64(7)
    let tableLength = UInt64(records.count) * 40
    let nameOffset = tableOffset + tableLength
    let foldOffset = nameOffset + nameLength
    let childOffset = foldOffset + foldLength
    var h = SnapshotHeader(
      recordCount: UInt64(records.count), recordTableOffset: tableOffset,
      recordTableLength: tableLength,
      nameBlobOffset: nameOffset, nameBlobLength: nameLength, rootPathOffset: 256,
      rootPathLength: UInt64(root.count),
      createdAtUnixSeconds: UInt64(max(0, Date().timeIntervalSince1970)),
      indexGeneration: generation, lastProcessedEventID: cursor,
      rootDeviceID: identity.deviceID, volumeUUID: identity.volumeUUID,
      historyUUID: identity.historyUUID, payloadCRC32: 0,
      fileLength: childOffset + UInt64(children.count) * 4 + 16, rootFileID: identity.rootFileID,
      snapshotUUID: UUID())
    guard h.fileLength <= SnapshotFormat.maxFileBytes, generation != .max, cursor != .max else {
      throw SnapshotError.invalid("v2 file/cursor limit")
    }
    var prepared: MMapBaseIndex?
    var directoryMap: [String: EntryRef] = [:]
    try store.publish(
      write: { fd in
        var crc: UInt32 = 0
        func emit(_ bytes: Data) throws {
          try snapshotWriteAll(fd, bytes)
          crc = SnapshotFormat.crc(bytes, previous: crc)
        }
        try snapshotWriteAll(fd, Data(repeating: 0, count: 256))
        try fault?(.afterHeader)
        try emit(root)
        try emit(Data(repeating: 0, count: Int(tableOffset) - 256 - root.count))
        for start in stride(from: 0, to: records.count, by: 4096) {
          guard !cancellation.isCancelled else { throw SnapshotError.cancelled }
          var data = Data()
          data.reserveCapacity(4096 * 40)
          for record in records[start..<min(start + 4096, records.count)] {
            data.append(record.encoded)
          }
          try emit(data)
          peak = max(peak, Metrics.processUsage().residentBytes)
        }
        for folded in [false, true] {
          for start in stride(from: 0, to: refs.count, by: 4096) {
            guard !cancellation.isCancelled else { throw SnapshotError.cancelled }
            var data = Data()
            for i in start..<min(start + 4096, refs.count) {
              let name = i == 0 ? "" : try source.metadata(refs[i], device: identity.deviceID).name
              data.append(contentsOf: (folded ? FileEntry.fold(name) : name).utf8)
            }
            try emit(data)
          }
        }
        for start in stride(from: 0, to: children.count, by: 4096) {
          var data = Data(repeating: 0, count: min(4096, children.count - start) * 4)
          for i in start..<min(start + 4096, children.count) {
            data.put(children[i], at: (i - start) * 4)
          }
          try emit(data)
        }
        var footer = Data(repeating: 0, count: 16)
        footer.replaceSubrange(0..<8, with: Array("APFSEND\0".utf8))
        footer.put(crc, at: 8)
        try emit(footer)
        h.payloadCRC32 = crc
        var header = h.encoded()
        header.append(Data(repeating: 0, count: 64))
        header.put(UInt32(2), at: 8)
        header.put(UInt32(256), at: 12)
        header.put(UInt32(40), at: 20)
        header.put(foldOffset, at: 192)
        header.put(foldLength, at: 200)
        header.put(childOffset, at: 208)
        header.put(UInt64(children.count) * 4, at: 216)
        header.put(UInt32(0), at: 148)
        header.put(SnapshotFormat.crc(header), at: 148)
        try snapshotWriteAll(fd, header, offset: 0)
        prepareMetadata?(refs,h)
      },
      beforePublish: {
        guard !cancellation.isCancelled else { throw SnapshotError.cancelled }
        try beforePublish()
      }, fault: fault,
      validate: { fd in
        resourceMetrics?.set(resourceStage + ".rss_before_mmap", to: Int(Metrics.processUsage().residentBytes))
        let b = try MMapBaseIndex(fileDescriptor: fd, identity: identity)
        resourceMetrics?.set(resourceStage + ".rss_after_mmap", to: Int(b.residentAfterMmap))
        resourceMetrics?.set(resourceStage + ".rss_after_validation", to: Int(b.residentAfterValidation))
        prepared = b
        directoryMap = [:] // Compatibility argument only; runtime resolves components.
        resourceMetrics?.set(resourceStage + ".rss_after_directory_map", to: Int(Metrics.processUsage().residentBytes))
        peak = max(peak, Metrics.processUsage().residentBytes)
      },
      commit: install.map { handler in
        { publish in
          guard let base = prepared else { throw SnapshotError.invalid("no staged mapping") }
          try handler(base, directoryMap, publish)
        }
      }, resourceMetrics: resourceMetrics, resourceStage: resourceStage)
    completed?(refs,h)
    resourceMetrics?.recordResources(resourceStage + ".total", since: resourceStart)
    return .init(
      header: h, durationMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
      peakResidentBytes: peak)
  }
}
