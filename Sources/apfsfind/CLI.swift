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
        var help = false
    }

    static let usage = """
    apfsfind v0.1.0 — macOS in-memory filename search

    Usage:
      apfsfind serve [--root PATH] [--latency-ms 20] [--workers 4]
      apfsfind bench [--files 10000] [--latency-ms 20]

    The default command is serve and the default root is $HOME.
    --latency-ms must be between 1 and 1000. No index or log files are saved.
    Startup waits for replay and recovery to finish; Ctrl+C cancels it.
    Benchmark uses only a temporary directory created by this process.

    Interactive commands: :stats  :verify  :rebuild  :quit
    Ordinary text searches filenames, case-insensitively (up to 50 paths).
    """

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var cursor = 0
        if let first = arguments.first, !first.hasPrefix("-") {
            guard first == "serve" || first == "bench" else {
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
            guard cursor < arguments.count else { throw CLIError.usage("Missing value for \(flag)") }
            let value = arguments[cursor]
            cursor += 1
            switch flag {
            case "--root":
                guard options.command == "serve", !value.isEmpty else {
                    throw CLIError.usage("--root is only accepted by serve; benchmark always owns its temporary directory.")
                }
                options.root = NSString(string: value).expandingTildeInPath
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
        let options = try parse(arguments)
        if options.help { print(usage); return 0 }
        if options.command == "bench" {
            return try BenchmarkRunner(files: options.files, latencyMilliseconds: options.latencyMilliseconds).run()
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
        let coordinator = try UpdateCoordinator(root: options.root, configuration: .init(
            latencyMilliseconds: options.latencyMilliseconds, workerCount: options.workers))
        let shutdown = ShutdownSignal { coordinator.stop() }
        defer { coordinator.stop(); withExtendedLifetime(shutdown) {} }
        TerminalOutput.info("Scanning \(options.root)")
        try coordinator.start { TerminalOutput.info($0) }
        if shutdown.isCancelled { throw CLIError.interrupted }
        try waitForStartup(coordinator, shutdown: shutdown)
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
            case ":verify":
                let result = try coordinator.verify()
                print("verify: missing=\(result.missing.count) extra=\(result.extra.count) consistent=\(result.isConsistent)")
                for path in result.missing.prefix(20) { print("missing: \(path)") }
                for path in result.extra.prefix(max(0, 20 - result.missing.count)) { print("extra: \(path)") }
            case ":rebuild":
                coordinator.rebuild()
                print("Rebuild requested; searches continue while the replacement index is built.")
            default:
                if query.hasPrefix(":") { print("Unknown command. Use :stats, :verify, :rebuild or :quit."); continue }
                let result = coordinator.index.search(query, limit: 50)
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
        while !coordinator.waitUntilLive(timeout: 1) {
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
