import Darwin
import Foundation
import MergeCueCore
import Synchronization

/// Captured result of a finished child process.
public struct ProcessResult: Sendable, Hashable {
    /// Exit status, or `128 + signal` when the process was killed by a signal.
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    /// The process exceeded its timeout (or the calling task was cancelled) and was terminated.
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    /// Exit code 0 within the timeout.
    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

/// Errors starting a child process.
public enum ProcessRunnerError: Error, Sendable, Equatable, LocalizedError {
    case spawnFailed(path: String, errno: Int32)
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let path, let code): "Could not start \(path): \(String(cString: strerror(code)))."
        case .invalidArgument(let detail): "Invalid process argument: \(detail)."
        }
    }
}

/// Runs short-lived helper commands (`command -v`, `--version`, `claude mcp …`, `open`). Injectable for tests.
public protocol ProcessRunning: Sendable {
    /// Runs `executable` with `arguments` (no shell involved), stdin at `/dev/null`, and waits for it to exit.
    /// On timeout the whole process group gets SIGTERM, then SIGKILL, and `timedOut` is set.
    func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        timeout: TimeInterval
    ) async throws -> ProcessResult
}

/// `posix_spawn`-based runner. Each child gets its own process group (so a login shell's children can be killed
/// together on timeout), inherits no file descriptors except stdin (`/dev/null`) and the stdout/stderr pipes,
/// and output is bounded to `maxOutputBytes` per stream.
public struct ProcessRunner: ProcessRunning {
    public var maxOutputBytes: Int
    /// After the child exits, how long to keep draining pipes that grandchildren may still hold open.
    public var drainGrace: TimeInterval

    public init(maxOutputBytes: Int = 1 << 20, drainGrace: TimeInterval = 1) {
        self.maxOutputBytes = maxOutputBytes
        self.drainGrace = drainGrace
    }

    public func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        let path = MergeCuePaths.fileSystemPath(executable)
        for value in [path] + arguments + environment.flatMap({ [$0.key, $0.value] }) where value.utf8.contains(0) {
            throw ProcessRunnerError.invalidArgument("NUL byte")
        }
        let cancelled = CancellationFlag()
        let config = RunConfig(
            path: path,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory.map(MergeCuePaths.fileSystemPath),
            timeout: max(0.05, timeout),
            maxOutputBytes: maxOutputBytes,
            drainGrace: drainGrace
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, any Error>) in
                let thread = Thread {
                    continuation.resume(with: Result { try Self.runBlocking(config, cancelled: cancelled) })
                }
                thread.name = "MergeCue.ProcessRunner"
                thread.start()
            }
        } onCancel: {
            cancelled.set()
        }
    }

    // MARK: Blocking implementation

    private struct RunConfig: Sendable {
        var path: String
        var arguments: [String]
        var environment: [String: String]
        var currentDirectory: String?
        var timeout: TimeInterval
        var maxOutputBytes: Int
        var drainGrace: TimeInterval
    }

    private static func runBlocking(_ config: RunConfig, cancelled: CancellationFlag) throws -> ProcessResult {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw ProcessRunnerError.spawnFailed(path: config.path, errno: errno) }
        guard pipe(&errPipe) == 0 else {
            let code = errno
            close(outPipe[0]); close(outPipe[1])
            throw ProcessRunnerError.spawnFailed(path: config.path, errno: code)
        }
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let directory = config.currentDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, directory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGPIPE)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)

        let argv = CStringArray([config.path] + config.arguments)
        let envp = CStringArray(config.environment.map { "\($0.key)=\($0.value)" }.sorted())
        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, config.path, &actions, &attributes, argv.pointers, envp.pointers)
        close(outPipe[1])
        close(errPipe[1])
        guard spawnResult == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw ProcessRunnerError.spawnFailed(path: config.path, errno: spawnResult)
        }

        var stdout = BoundedBuffer(limit: config.maxOutputBytes)
        var stderr = BoundedBuffer(limit: config.maxOutputBytes)
        var openFDs: [Int32: Int] = [outPipe[0]: 1, errPipe[0]: 2]
        let start = Date()
        var exitStatus: Int32?
        var exitedAt: Date?
        var timedOut = false
        var termSentAt: Date?
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            if !openFDs.isEmpty {
                var pollFDs = openFDs.keys.sorted().map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
                let ready = poll(&pollFDs, nfds_t(pollFDs.count), 50)
                if ready > 0 {
                    for entry in pollFDs where entry.revents != 0 {
                        let count = chunk.withUnsafeMutableBytes { read(entry.fd, $0.baseAddress, $0.count) }
                        if count > 0 {
                            if openFDs[entry.fd] == 1 {
                                stdout.append(chunk[0..<count])
                            } else {
                                stderr.append(chunk[0..<count])
                            }
                        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
                            close(entry.fd)
                            openFDs[entry.fd] = nil
                        }
                    }
                }
            } else {
                usleep(20_000)
            }

            if exitStatus == nil {
                var status: Int32 = 0
                let reaped = waitpid(pid, &status, WNOHANG)
                if reaped == pid {
                    exitStatus = Self.decodeStatus(status)
                    exitedAt = Date()
                } else if reaped < 0, errno != EINTR {
                    exitStatus = -1
                    exitedAt = Date()
                }
            }

            if let exitedAt {
                if openFDs.isEmpty || Date().timeIntervalSince(exitedAt) > config.drainGrace { break }
                continue
            }

            if cancelled.isSet || Date().timeIntervalSince(start) > config.timeout {
                timedOut = true
                if let sentAt = termSentAt {
                    if Date().timeIntervalSince(sentAt) > 1 { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
                } else {
                    kill(-pid, SIGTERM)
                    kill(pid, SIGTERM)
                    termSentAt = Date()
                }
            }
        }
        for fd in openFDs.keys { close(fd) }
        if timedOut { kill(-pid, SIGKILL) }

        return ProcessResult(
            exitCode: exitStatus ?? -1,
            stdout: stdout.string,
            stderr: stderr.string,
            timedOut: timedOut
        )
    }

    private static func decodeStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        return 128 + signal
    }
}

/// Keeps at most `limit` bytes.
private struct BoundedBuffer {
    let limit: Int
    var data = Data()

    init(limit: Int) { self.limit = limit }

    mutating func append(_ bytes: ArraySlice<UInt8>) {
        let room = limit - data.count
        guard room > 0 else { return }
        data.append(contentsOf: bytes.prefix(room))
    }

    var string: String { String(decoding: data, as: UTF8.self) }
}

/// NUL-terminated C string array owned for the duration of a spawn.
private final class CStringArray {
    private(set) var pointers: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) {
        pointers = strings.map { strdup($0) } + [nil]
    }

    deinit {
        for pointer in pointers { free(pointer) }
    }
}

/// Thread-safe one-way flag.
final class CancellationFlag: Sendable {
    private let state = Mutex(false)

    func set() { state.withLock { $0 = true } }
    var isSet: Bool { state.withLock { $0 } }
}

/// A lock-protected value shareable across escaping closures.
final class Locked<Value: Sendable>: Sendable {
    private let state: Mutex<Value>

    init(_ value: Value) { state = Mutex(value) }

    var value: Value {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func mutate<R>(_ body: (inout Value) -> R) -> R { state.withLock { body(&$0) } }
}
