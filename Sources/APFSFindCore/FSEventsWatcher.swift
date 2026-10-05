import Foundation
import CoreServices

public enum WatcherError: Error, CustomStringConvertible {
    case cannotCreate, cannotStart, historyUnavailable
    public var description: String {
        switch self {
        case .cannotCreate: "Could not create FSEvents stream"
        case .cannotStart: "Could not start FSEvents stream (check sandbox and directory access)"
        case .historyUnavailable: "This volume has no usable FSEvents history UUID; durable replay is unavailable"
        }
    }
}

private final class EventCallbackBox: @unchecked Sendable {
    let handler: @Sendable ([FileSystemEvent]) -> Void
    let identity: VolumeIdentity
    init(identity: VolumeIdentity, _ handler: @escaping @Sendable ([FileSystemEvent]) -> Void) {
        self.identity = identity; self.handler = handler
    }
}

/// Both persistent and ephemeral coordinators use the same device-relative
/// stream. An ID is meaningful only alongside that device's history UUID.
public final class FSEventsWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "apfsfind.fsevents")
    private var stream: FSEventStreamRef?
    public init() {}
    public func start(root: String, since id: UInt64, latencyMilliseconds: Double,
                      identity supplied: VolumeIdentity? = nil,
                      handler: @escaping @Sendable ([FileSystemEvent]) -> Void) throws {
        try lock.withLock {
            guard stream == nil else { return }
            let identity = try supplied ?? VolumeIdentity.discover(root: root)
            let box = EventCallbackBox(identity: identity, handler)
            var context = FSEventStreamContext(version: 0,
                info: Unmanaged.passUnretained(box).toOpaque(),
                retain: { pointer in
                    guard let pointer else { return nil }
                    return UnsafeRawPointer(Unmanaged<EventCallbackBox>.fromOpaque(pointer).retain().toOpaque())
                },
                release: { pointer in
                    if let pointer { Unmanaged<EventCallbackBox>.fromOpaque(pointer).release() }
                }, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
                guard let info else { return }
                let strings = unsafeBitCast(paths, to: CFArray.self) as! [String]
                let box = Unmanaged<EventCallbackBox>.fromOpaque(info).takeUnretainedValue()
                var events: [FileSystemEvent] = []
                events.reserveCapacity(count)
                for i in 0..<min(count, strings.count) {
                    let special = flags[i] & UInt32(kFSEventStreamEventFlagHistoryDone |
                        kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagKernelDropped |
                        kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagEventIdsWrapped) != 0
                    let path = special ? box.identity.root : box.identity.absoluteCallbackPath(strings[i])
                    if let path { events.append(FileSystemEvent(path: path, flags: flags[i], id: ids[i])) }
                    else if flags[i] & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                        events.append(FileSystemEvent(path: box.identity.root, flags: flags[i], id: ids[i]))
                    }
                }
                box.handler(events)
            }
            // Replay the complete first historical chunk, including overlapping
            // IDs before `since`, so chunk boundaries do not leave an event gap.
            // The coordinator's namespace updates tolerate this duplicate history.
            let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes |
                kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFullHistory)
            guard let created = FSEventStreamCreateRelativeToDevice(nil, callback, &context,
                    dev_t(truncatingIfNeeded: identity.deviceID), [identity.relativeRoot] as CFArray,
                    id, latencyMilliseconds / 1000, options) else {
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
        lock.withLock {
            if let stream {
                FSEventStreamFlushSync(stream)
                // FlushSync's service boundary and the dispatch delivery boundary
                // are separate. Complete callback copying before draining writer.
                callbackQueue.sync {}
            }
        }
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
