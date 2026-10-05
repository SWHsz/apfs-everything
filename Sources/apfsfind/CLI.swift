import APFSFindCore
import Darwin
import Dispatch
import Foundation

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case replayTimedOut
    case startupFailed(String)
    case interrupted
    case input(Int32)

    var description: String {
        switch self {
        case .usage(let message): return message + "\nRun apfsfind --help for usage."
        case .replayTimedOut: return "FSEvents replay did not reach the live state within 10 seconds."
        case .startupFailed(let message): return message
        case .interrupted: return "Interrupted; the watcher and workers have stopped."
        case .input(let code): return "Cannot read standard input: \(String(cString: strerror(code)))."
        }
    }
}

enum TerminalOutput {
    static func error(_ message: String) {
        FileHandle.standardError.write(Data("[error] \(message)\n".utf8))
    }

    static func info(_ message: String) {
        let rendered = message.hasPrefix("[info] ") ? message : "[info] " + message
        FileHandle.standardError.write(Data((rendered + "\n").utf8))
    }
}

/// Dispatch signals avoid doing Swift work inside an asynchronous POSIX signal handler.
final class ShutdownSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let source: DispatchSourceSignal
    private let stop: @Sendable () -> Void

    init(stop: @escaping @Sendable () -> Void) {
        self.stop = stop
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.receive() }
        source.resume()
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    private func receive() {
        lock.withLock { cancelled = true }
        stop()
    }

    deinit {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}

enum CLI {
    struct Options {
        var command = "serve"
        var root = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        var latencyMilliseconds = 20.0
        var files = 10_000
        var workers = 4
        var entries = 100_000
        var delta = 10_000
        var idleSeconds = 60.0
        var volumes = 2
        var ephemeral = false
        var rebuildIndex = false
        var cacheDirectory: String?
        var help = false
    }

    static let usage = """
    apfsfind v0.4.0 — macOS filename search with snapshot recovery

    Usage:
      apfsfind serve [--root PATH] [--latency-ms 20] [--workers 4]
                    [--ephemeral] [--rebuild-index] [--cache-dir PATH]
      apfsfind bench [--files 10000] [--latency-ms 20]
      apfsfind persistence-bench [--entries 100000] [--cache-dir PATH]
      apfsfind hybrid-bench [--entries 100000] [--delta 10000] [--cache-dir PATH]
      apfsfind real-disk-bench --root PATH [--cache-dir /private/tmp/apfsfind-real-cache-UUID]
                             [--idle-seconds 60]

    Additional benchmarks:
      apfsfind usability-bench --root PATH [--cache-dir EXISTING_TEST_CACHE] [--idle-seconds 60]
      apfsfind multivolume-bench --entries-per-volume 100000 --volumes 2

    The default command is serve and the default root is $HOME.
    --latency-ms must be between 1 and 1000. No log files are saved.
    Snapshots default to ~/Library/Application Support/apfsfind/indexes/.
    Cache directories are 0700; snapshots contain sensitive filename metadata (0600).
    --ephemeral disables snapshot reads and writes. --rebuild-index forces a scan.
    Snapshots are written after cold startup or explicit/threshold compaction.
    Compaction runs at thresholds or by :compact; :checkpoint may write only state.
    Search opens when the base is ready; catch-up results may be stale. :quit uses fast exit.
    Real-disk benchmark reads the requested root; mutations use a separate owned UUID directory.
    Its cache is a new UUID child of /private/tmp and is cleaned up after both child processes exit.
    Other benchmarks use only a temporary directory created by this process.

    Interactive commands: :stats  :verify  :rebuild  :checkpoint  :compact  :quit
    Ordinary text searches filenames, case-insensitively (up to 50 paths).
    """

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var cursor = 0
        if let first = arguments.first, !first.hasPrefix("-") {
            guard ["serve", "bench", "persistence-bench", "hybrid-bench", "real-disk-bench", "usability-bench", "multivolume-bench"].contains(first) else {
                throw CLIError.usage("Unknown command: \(first)")
            }
            options.command = first
            cursor = 1
        }
        while cursor < arguments.count {
            let flag = arguments[cursor]
            cursor += 1
            if flag == "--help" || flag == "-h" {
                options.help = true
                continue
            }
            if flag == "--ephemeral" || flag == "--rebuild-index" {
                guard options.command == "serve" else { throw CLIError.usage("\(flag) is only accepted by serve.") }
                if flag == "--ephemeral" { options.ephemeral = true } else { options.rebuildIndex = true }
                continue
            }
            guard cursor < arguments.count else { throw CLIError.usage("Missing value for \(flag)") }
            let value = arguments[cursor]
            cursor += 1
            switch flag {
            case "--cache-dir":
                guard options.command != "bench", !value.isEmpty else { throw CLIError.usage("--cache-dir requires a path and is not accepted by bench.") }
                options.cacheDirectory = NSString(string: value).expandingTildeInPath
            case "--volumes":
                guard options.command == "multivolume-bench", let n = Int(value), (1...8).contains(n) else { throw CLIError.usage("--volumes requires 1...8") }; options.volumes = n
            case "--entries-per-volume":
                guard options.command == "multivolume-bench", let n = Int(value), (100...1_000_000).contains(n) else { throw CLIError.usage("--entries-per-volume requires 100...1000000") }; options.entries = n
            case "--entries":
                guard ["persistence-bench", "hybrid-bench"].contains(options.command), let number = Int(value), (102...1_000_000).contains(number) else {
                    throw CLIError.usage("--entries must be in 102...1000000 for persistence-bench or hybrid-bench.")
                }
                options.entries = number
            case "--delta":
                guard options.command=="hybrid-bench",let n=Int(value),(1...100000).contains(n) else{throw CLIError.usage("--delta must be 1...100000 for hybrid-bench")}
                options.delta=n
            case "--root":
                guard ["serve", "real-disk-bench", "usability-bench"].contains(options.command), !value.isEmpty else {
                    throw CLIError.usage("--root is accepted by serve and real-disk-bench.")
                }
                options.root = NSString(string: value).expandingTildeInPath
            case "--idle-seconds":
                guard ["real-disk-bench", "usability-bench"].contains(options.command), let n = Double(value), n.isFinite, (0...3600).contains(n) else {
                    throw CLIError.usage("--idle-seconds requires 0...3600 for real-disk-bench.")
                }
                options.idleSeconds = n
            case "--latency-ms":
                guard let number = Double(value), number.isFinite, (1...1000).contains(number) else {
                    throw CLIError.usage("--latency-ms must be a finite number in 1...1000.")
                }
                options.latencyMilliseconds = number
            case "--files":
                guard options.command == "bench", let number = Int(value), number > 0 else {
                    throw CLIError.usage("--files must be a positive integer and is only accepted by bench.")
                }
                options.files = number
            case "--workers":
                guard options.command == "serve", let number = Int(value), (1...16).contains(number) else {
                    throw CLIError.usage("--workers must be in 1...16 and is only accepted by serve.")
                }
                options.workers = number
            default: throw CLIError.usage("Unknown option: \(flag)")
            }
        }
        return options
    }

    static func run(arguments: [String]) throws -> Int32 {
        // Internal read-only subprocess probe for allocator-independent benchmark
        // RSS. It does not start a watcher or change the base/state files.
        if arguments.first == "_mmap-probe" {
            guard arguments.count==3 else{throw CLIError.usage("Invalid mmap probe arguments")}
            let root=try PathCanonicalizer.canonicalRoot(arguments[1]),volume=try VolumeIdentity.discover(root:root)
            let store=try SnapshotStore(directory:arguments[2],identity:volume),before=Metrics.processUsage().residentBytes
            let started=ProcessInfo.processInfo.systemUptime,reader=try store.reader(expectedIdentity:volume)
            guard let base=reader.mappedBase else{throw CLIError.startupFailed("Probe requires v2")}
            let hybrid=HybridIndex(base:base)
            var report=hybrid.hybridStats();report["rss_before"]=before;report["rss_after"]=Metrics.processUsage().residentBytes
            report["load_ms"]=(ProcessInfo.processInfo.systemUptime-started)*1000
            report["full_scans"]=0;report["startup_mode"]="mmap_probe"
            print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
            return 0
        }
        if arguments.first == "_usability-worker" { return try UsabilityBenchmarkRunner.worker(Array(arguments.dropFirst())) }
        if arguments.first == "_real-disk-worker" {
            return try RealDiskBenchmarkRunner.worker(Array(arguments.dropFirst()))
        }
        let options = try parse(arguments)
        if options.help { print(usage); return 0 }
        if options.command == "multivolume-bench" { return try MultiVolumeBenchmarkRunner(entries: options.entries, volumeCount: options.volumes).run() }
        if options.command == "usability-bench" { return try UsabilityBenchmarkRunner(root: options.root, cacheDirectory: options.cacheDirectory, idleSeconds: options.idleSeconds).run() }
        if options.command == "bench" {
            return try BenchmarkRunner(files: options.files, latencyMilliseconds: options.latencyMilliseconds).run()
        }
        if options.command == "persistence-bench" {
            return try PersistenceBenchmarkRunner(entries: options.entries, cacheDirectory: options.cacheDirectory,
                latencyMilliseconds: options.latencyMilliseconds).run()
        }
        if options.command=="hybrid-bench" {
            return try HybridBenchmarkRunner(entries:options.entries,deltaCount:options.delta,cacheDirectory:options.cacheDirectory).run()
        }
        if options.command == "real-disk-bench" {
            return try RealDiskBenchmarkRunner(root: options.root, cacheDirectory: options.cacheDirectory,
                                               idleSeconds: options.idleSeconds).run()
        }
        return try serve(options)
    }

    static func exitCode(for error: Error) -> Int32 {
        if let cliError = error as? CLIError {
            switch cliError {
            case .interrupted: return 130
            case .usage: return 2
            default: break
            }
        }
        return 1
    }

    private static func serve(_ options: Options) throws -> Int32 {
        let coordinator = try PersistentIndexCoordinator(root: options.root, configuration: .init(
            latencyMilliseconds: options.latencyMilliseconds, workerCount: options.workers),
            ephemeral: options.ephemeral, rebuildIndex: options.rebuildIndex, cacheDirectory: options.cacheDirectory)
        let shutdown = ShutdownSignal { coordinator.interrupt() }
        defer { coordinator.stop(policy: .fast); withExtendedLifetime(shutdown) {} }
        TerminalOutput.info("Starting filename search in \(options.root)")
        try coordinator.start { TerminalOutput.info($0) }
        if shutdown.isCancelled { throw CLIError.interrupted }
        try waitForStartup(coordinator.core, shutdown: shutdown)
        TerminalOutput.info("Replay complete; live filename search is ready.")
        print(coordinator.stats().description)
        let input = InteractiveInput()
        let interactive = isatty(STDIN_FILENO) == 1
        while !shutdown.isCancelled {
            if interactive { FileHandle.standardOutput.write(Data("apfsfind> ".utf8)) }
            guard let line = try input.nextLine(cancelled: { shutdown.isCancelled }) else { break }
            let query = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty { continue }
            switch query {
            case ":quit": return 0
            case ":stats": print(coordinator.stats().description)
            case ":compact":
                print(coordinator.compact() ? "Compaction requested." : "Compaction already running, disabled or stopping.")
            case ":checkpoint":
                print(coordinator.checkpoint() ? "Checkpoint requested." : "Checkpoint already running, disabled or stopping.")
            case ":verify":
                let result = try coordinator.verify()
                print("verify: missing=\(result.missing.count) extra=\(result.extra.count) consistent=\(result.isConsistent)")
                print("raw scan comparison: missing=\(result.rawMissing.count) extra=\(result.rawExtra.count); current-directory revalidated races=\(result.racedPaths.count)")
                for path in result.missing.prefix(20) { print("missing: \(path)") }
                for path in result.extra.prefix(max(0, 20 - result.missing.count)) { print("extra: \(path)") }
            case ":rebuild":
                coordinator.rebuild()
                print("Rebuild requested; searches continue while the replacement index is built.")
            default:
                if query.hasPrefix(":") { print("Unknown command. Use :stats, :verify, :rebuild, :checkpoint, :compact or :quit."); continue }
                let result = coordinator.search(query, limit: 50)
                if result.freshness != .live { TerminalOutput.info("Index is updating; results may be stale.") }
                for hit in result.hits { print(hit.path) }
                print(String(format: "%d results · %.3f ms · generation %llu", result.hits.count,
                             result.latencyMilliseconds, UInt64(result.generation)))
            }
        }
        return shutdown.isCancelled ? 130 : 0
    }

    /// Large roots may need replay and a full recovery scan. A running recovery
    /// has no arbitrary deadline; benchmarks retain their bounded startup wait.
    private static func waitForStartup(_ coordinator: UpdateCoordinator, shutdown: ShutdownSignal) throws {
        let started = ProcessInfo.processInfo.systemUptime
        while !coordinator.readinessSnapshot().searchAvailable {
            Thread.sleep(forTimeInterval: 0.05)
            if shutdown.isCancelled { throw CLIError.interrupted }
            let status = coordinator.startupStatus()
            if status.state == .failed || status.state == .stopped {
                throw CLIError.startupFailed(status.lastError ?? "Startup stopped before the index became live.")
            }
            if status.automaticRebuildSuspended {
                let detail = status.lastError.map { " Last error: \($0)" } ?? ""
                throw CLIError.startupFailed("Startup recovery failed repeatedly and retries were suspended. Restore directory access and restart apfsfind.\(detail)")
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let progress: String
            switch status.state {
            case .dirty:
                progress = "Recovery queued"
            case .rebuilding:
                progress = "Rebuilding; total scan work: \(status.scannerEntries) entries, \(status.scannerDirectories) directories read"
            default:
                progress = "Replaying filesystem changes"
            }
            let reason = status.recoveryReason.map { "; reason: \($0)" } ?? ""
            TerminalOutput.info(String(format: "%@ (%.1f s); events processed=%d received=%d pending=%d; rebuilds=%d%@; Ctrl+C to cancel",
                                      progress, elapsed, status.processedEvents, status.receivedEvents,
                                      status.pendingEvents, status.rebuilds, reason))
        }
        if shutdown.isCancelled { throw CLIError.interrupted }
    }
}

/// A short poll makes Ctrl+C work even while the user has not entered a line.
private final class InteractiveInput {
    private var buffered = Data()
    private var reachedEOF = false

    func nextLine(cancelled: () -> Bool) throws -> String? {
        while !cancelled() {
            if let newline = buffered.firstIndex(of: 10) {
                let bytes = buffered[..<newline]
                let line = String(decoding: bytes, as: UTF8.self)
                buffered.removeSubrange(...newline)
                return line
            }
            if reachedEOF {
                guard !buffered.isEmpty else { return nil }
                defer { buffered.removeAll() }
                return String(decoding: buffered, as: UTF8.self)
            }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw CLIError.input(errno)
            }
            if ready == 0 { continue }
            if (descriptor.revents & Int16(POLLNVAL)) != 0 { throw CLIError.input(EBADF) }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw CLIError.input(errno)
            }
            if count == 0 { reachedEOF = true } else { buffered.append(contentsOf: bytes.prefix(count)) }
        }
        return nil
    }
}
