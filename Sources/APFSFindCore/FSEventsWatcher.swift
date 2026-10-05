import Foundation
import CoreServices

public enum WatcherError: Error, CustomStringConvertible {
    case cannotCreate, cannotStart
    public var description: String {
        switch self {
        case .cannotCreate: "Could not create FSEvents stream"
        case .cannotStart: "Could not start FSEvents stream (check sandbox and directory access)"
        }
    }
}

private final class EventCallbackBox: @unchecked Sendable {
    let handler: @Sendable ([FileSystemEvent]) -> Void
    init(_ handler: @escaping @Sendable ([FileSystemEvent]) -> Void) { self.handler = handler }
}

/// Sprint 1 uses host-level IDs in memory only. Per-device streams, UUIDs and
/// durable cursors are intentionally deferred; there is no cross-restart cursor.
public final class FSEventsWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "apfsfind.fsevents")
    private var stream: FSEventStreamRef?
    public init() {}
    public static func currentEventID() -> UInt64 { FSEventsGetCurrentEventId() }

    public func start(root: String, since id: UInt64, latencyMilliseconds: Double,
                      handler: @escaping @Sendable ([FileSystemEvent]) -> Void) throws {
        try lock.withLock {
            guard stream == nil else { return }
            let box = Unmanaged.passRetained(EventCallbackBox(handler))
            var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil,
                release: { pointer in
                    if let pointer { Unmanaged<EventCallbackBox>.fromOpaque(pointer).release() }
                }, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
                guard let info else { return }
                let strings = unsafeBitCast(paths, to: CFArray.self) as! [String]
                var events: [FileSystemEvent] = []
                events.reserveCapacity(count)
                for i in 0..<min(count, strings.count) {
                    events.append(FileSystemEvent(path: strings[i], flags: flags[i], id: ids[i]))
                }
                Unmanaged<EventCallbackBox>.fromOpaque(info).takeUnretainedValue().handler(events)
            }
            // Replay the complete first historical chunk, including overlapping
            // IDs before `since`, so chunk boundaries do not leave an event gap.
            // The coordinator's namespace updates tolerate this duplicate history.
            let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFullHistory)
            guard let created = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                                   id, latencyMilliseconds / 1000, options) else {
                box.release()
                throw WatcherError.cannotCreate
            }
            FSEventStreamSetDispatchQueue(created, callbackQueue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                throw WatcherError.cannotStart
            }
            stream = created
        }
    }

    public func flush() {
        lock.withLock { if let stream { FSEventStreamFlushSync(stream) } }
    }
    public func stop() {
        lock.withLock {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            callbackQueue.sync {}
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
    deinit { stop() }
}
