import CAPFSShim
import Foundation

public enum ThermalLevel: String, Sendable { case nominal, fair, serious, critical }
public struct ResourceSnapshot: Sendable {
    public var timestamp: Double
    public var memoryPressure: MemoryPressureLevel
    public var cpuIdleEWMA: Double?
    public var thermalState: ThermalLevel
    public var lowPowerMode: Bool
    public var interactive: Bool
    public var activeQueries: Int
    public var lastInteractionAge: Double
    public init(timestamp:Double = ProcessInfo.processInfo.systemUptime,memoryPressure:MemoryPressureLevel = .normal,
                cpuIdleEWMA:Double? = nil,thermalState:ThermalLevel = .nominal,lowPowerMode:Bool = false,
                interactive:Bool = false,activeQueries:Int = 0,lastInteractionAge:Double = 86400) {
        self.timestamp = timestamp; self.memoryPressure = memoryPressure; self.cpuIdleEWMA = cpuIdleEWMA
        self.thermalState = thermalState; self.lowPowerMode = lowPowerMode; self.interactive = interactive
        self.activeQueries = activeQueries; self.lastInteractionAge = lastInteractionAge
    }
}
public protocol ResourceSignalProviding: AnyObject, Sendable {
    func current() -> ResourceSnapshot
    func observe(_ callback:@escaping @Sendable (ResourceSnapshot)->Void) -> UUID
    func removeObserver(_ id:UUID)
    func setSamplingEnabled(_ enabled:Bool)
}
public final class FakeResourceSignals: ResourceSignalProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot:ResourceSnapshot
    private var callbacks:[UUID:@Sendable(ResourceSnapshot)->Void] = [:]
    private var sampling = false
    public let metrics = Metrics()
    public init(_ snapshot:ResourceSnapshot = .init(cpuIdleEWMA:1)) { self.snapshot = snapshot }
    public func current() -> ResourceSnapshot { lock.withLock { snapshot } }
    public func update(_ snapshot:ResourceSnapshot) {
        let listeners = lock.withLock { self.snapshot = snapshot; return Array(callbacks.values) }
        for callback in listeners { callback(snapshot) }
    }
    public func observe(_ callback:@escaping @Sendable(ResourceSnapshot)->Void)->UUID {
        let id = UUID(); lock.withLock { callbacks[id] = callback }; return id
    }
    public func removeObserver(_ id:UUID) { _ = lock.withLock { callbacks.removeValue(forKey:id) } }
    public func setSamplingEnabled(_ enabled:Bool) {
        lock.withLock { if sampling != enabled { sampling = enabled; metrics.record(enabled ? "cpu_sampler_starts" : "cpu_sampler_stops") } }
    }
    public var isSampling:Bool { lock.withLock { sampling } }
}

/// Notifications remain event-driven. The only timer exists while the scheduler
/// has pending/running work; there is no permanent idle CPU poll.
public final class SystemResourceSignals: ResourceSignalProviding, @unchecked Sendable {
    public static let shared = SystemResourceSignals()
    private let lock = NSLock()
    private let queue = DispatchQueue(label:"apfsfind.resources",qos:.utility)
    private var snapshot = ResourceSnapshot()
    private var callbacks:[UUID:@Sendable(ResourceSnapshot)->Void] = [:]
    private var timer:DispatchSourceTimer?
    private var previous:APFSCPUCounter?
    private var interactionAt = -86400.0
    private var visible = false
    private var memorySource:DispatchSourceMemoryPressure?
    private var notifications:[NSObjectProtocol] = []
    public let metrics = Metrics()
    public init() {
        refreshEnvironment()
        let source = DispatchSource.makeMemoryPressureSource(eventMask:[.normal,.warning,.critical],queue:queue)
        source.setEventHandler { [weak self,weak source] in
            guard let self,let flags = source?.data else { return }
            self.modify { $0.memoryPressure = flags.contains(.critical) ? .critical : (flags.contains(.warning) ? .warning : .normal) }
        }
        memorySource = source; source.resume()
        for name in [ProcessInfo.thermalStateDidChangeNotification,Notification.Name.NSProcessInfoPowerStateDidChange] {
            notifications.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:nil) { [weak self] _ in self?.refreshEnvironment() })
        }
    }
    deinit { timer?.cancel(); memorySource?.cancel(); for token in notifications { NotificationCenter.default.removeObserver(token) } }
    private func refreshEnvironment() {
        let thermal:ThermalLevel
        switch ProcessInfo.processInfo.thermalState { case .nominal: thermal = .nominal; case .fair: thermal = .fair
        case .serious: thermal = .serious; case .critical: thermal = .critical; @unknown default: thermal = .critical }
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        modify { $0.thermalState = thermal; $0.lowPowerMode = low }
    }
    private func modify(_ update:(inout ResourceSnapshot)->Void) {
        let pair = lock.withLock { update(&snapshot); snapshot.timestamp = ProcessInfo.processInfo.systemUptime
            snapshot.lastInteractionAge = max(0,snapshot.timestamp-interactionAt)
            snapshot.interactive = visible && snapshot.lastInteractionAge < 10
            return (snapshot,Array(callbacks.values)) }
        for callback in pair.1 { callback(pair.0) }
    }
    public func current()->ResourceSnapshot {
        lock.withLock { var value = snapshot; value.timestamp = ProcessInfo.processInfo.systemUptime
            value.lastInteractionAge = max(0,value.timestamp-interactionAt); value.interactive = visible && value.lastInteractionAge < 10
            return value }
    }
    public func observe(_ callback:@escaping @Sendable(ResourceSnapshot)->Void)->UUID {
        let id = UUID(); lock.withLock { callbacks[id] = callback }; return id
    }
    public func removeObserver(_ id:UUID) { _ = lock.withLock { callbacks.removeValue(forKey:id) } }
    public func setSamplingEnabled(_ enabled:Bool) {
        lock.withLock {
            if enabled && timer == nil {
                var initial = APFSCPUCounter(); previous = apfs_system_cpu(&initial) == 0 ? initial : nil
                snapshot.cpuIdleEWMA = nil
                let source = DispatchSource.makeTimerSource(queue:queue)
                source.schedule(deadline:.now()+2,repeating:2,leeway:.milliseconds(100))
                source.setEventHandler { [weak self] in self?.sampleCPU() }
                timer = source; metrics.record("cpu_sampler_starts"); source.resume()
            } else if !enabled, let old = timer {
                old.cancel(); timer = nil; previous = nil; snapshot.cpuIdleEWMA = nil; metrics.record("cpu_sampler_stops")
            }
        }
    }
    private func sampleCPU() {
        refreshEnvironment() // Pending-work fallback also covers CLI processes without a main run loop.
        var current = APFSCPUCounter(); guard apfs_system_cpu(&current) == 0 else { return }
        let value:Double? = lock.withLock {
            guard timer != nil else { return nil }; metrics.record("cpu_sampler_wakeups")
            defer { previous = current }
            guard let previous else { return nil }
            let idle = UInt64(current.idle &- previous.idle)
            let total = idle+UInt64(current.user &- previous.user)+UInt64(current.system &- previous.system)+UInt64(current.nice &- previous.nice)
            guard total > 0 else { return nil }
            let raw = Double(idle)/Double(total)
            return snapshot.cpuIdleEWMA.map { 0.4*raw+0.6*$0 } ?? raw
        }
        if let value { modify { $0.cpuIdleEWMA = value } }
    }
    /// Explicit smoke/test hook; the production desktop never calls this.
    public func simulateMemoryPressureForTesting(_ level:MemoryPressureLevel) { modify { $0.memoryPressure = level } }
    public func reportVisibility(_ isVisible:Bool) {
        lock.withLock { visible = isVisible; interactionAt = ProcessInfo.processInfo.systemUptime }
        modify { _ in }
    }
    public func reportInteraction() { lock.withLock { interactionAt = ProcessInfo.processInfo.systemUptime }; modify { _ in } }
    public func beginQuery() { modify { $0.activeQueries += 1 } }
    public func endQuery() { modify { $0.activeQueries = max(0,$0.activeQueries-1) } }
    public var isSampling:Bool { lock.withLock { timer != nil } }
}
public final class InteractiveActivityController: Sendable {
    public static let shared = InteractiveActivityController()
    public init() {}
    public func visibility(_ visible:Bool) { SystemResourceSignals.shared.reportVisibility(visible) }
    public func interaction() { SystemResourceSignals.shared.reportInteraction() }
    public func beginQuery() { SystemResourceSignals.shared.beginQuery() }
    public func endQuery() { SystemResourceSignals.shared.endQuery() }
}
