import CoreServices
import Foundation
import XCTest
@testable import APFSFindCore

private final class DeviceProbe: @unchecked Sendable {
    let lock = NSLock()
    var paths: [String] = []
    func append(_ values: [String]) { lock.withLock { paths += values } }
    func snapshot() -> [String] { lock.withLock { paths } }
}

final class PerDeviceWatcherTests: XCTestCase {
    func testSDKDeviceRelativeCallbackPathsForTemporarySubdirectory() throws {
        try requireFSEvents()
        let tree = try TemporaryTree()
        let identity = try VolumeIdentity.discover(root: tree.root)
        let probe = DeviceProbe()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(probe).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let names = unsafeBitCast(paths, to: CFArray.self) as! [String]
            let relevant = (0..<min(count, names.count)).filter {
                flags[$0] & UInt32(kFSEventStreamEventFlagHistoryDone) == 0
            }.map { names[$0] }
            Unmanaged<DeviceProbe>.fromOpaque(info).takeUnretainedValue().append(relevant)
        }
        let stream = try XCTUnwrap(FSEventStreamCreateRelativeToDevice(nil, callback, &context,
            dev_t(truncatingIfNeeded: identity.deviceID), [identity.relativeRoot] as CFArray,
            identity.currentEventID(), 0.02, UInt32(kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFullHistory)))
        let queue = DispatchQueue(label: "apfsfind.device-probe")
        FSEventStreamSetDispatchQueue(stream, queue)
        defer {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream)
            queue.sync {}; FSEventStreamRelease(stream); withExtendedLifetime(probe) {}
        }
        XCTAssertTrue(FSEventStreamStart(stream))
        try tree.file("probe-file")
        let expected = identity.relativeRoot + "/probe-file"
        waitFor("device-relative probe callback", timeout: 5) { probe.snapshot().contains(expected) }
        XCTAssertTrue(probe.snapshot().contains(expected), "Actual raw paths: \(probe.snapshot())")
        XCTAssertEqual(identity.absoluteCallbackPath(expected), tree.path("probe-file"))
        XCTAssertNil(identity.absoluteCallbackPath(identity.relativeRoot + "-other/file"))
        print("[probe] mount=\(identity.mountPoint), relative root=\(identity.relativeRoot), callback has no leading slash")
    }
}
