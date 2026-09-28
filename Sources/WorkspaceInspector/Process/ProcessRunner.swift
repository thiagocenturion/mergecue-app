import Darwin
import Dispatch
import Foundation
import Synchronization

/// What to run. `executable` must be an absolute path; nothing goes through a shell.
struct ProcessSpec: Sendable {
    var executable: String
    /// Arguments after `argv[0]` (which is set to `executable`).
    var arguments: [String]
    var workingDirectory: String
    /// The complete environment of the child (already sanitized by the caller).
    var environment: [String: String]
    /// Bytes written to the child's stdin, then closed. `nil` connects stdin to `/dev/null`.
    var stdin: Data?
    var timeout: TimeInterval
    /// Maximum captured bytes per stream; the rest is read and discarded so the child never blocks.
    var maxOutputBytes: Int
}

/// Captured result of a finished (or killed) child.
struct ProcessOutput: Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
    var stdoutTruncated: Bool
    var stderrTruncated: Bool
    var timedOut: Bool
    var durationMs: Int

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

enum ProcessRunnerError: Error, Sendable, Equatable {
    /// `posix_spawn` failed (errno), e.g. `ENOENT` for a missing executable.
    case spawnFailed(executable: String, errno: Int32)
    case pipeFailed(errno: Int32)
}

/// Runs a child process without a shell, without a controlling terminal and with bounded output.
///
/// - The child is spawned with `POSIX_SPAWN_SETSID`: it leads a new session (so it has **no controlling
///   terminal** — `ssh`/`git` cannot open `/dev/tty` to prompt) and a new process group, which is killed as a
///   whole on timeout or cancellation (`SIGTERM`, then `SIGKILL` after a grace period).
/// - `POSIX_SPAWN_CLOEXEC_DEFAULT`: only stdin/stdout/stderr are inherited; signal dispositions and the mask are
///   reset to defaults.
/// - stdout/stderr are drained concurrently with `poll(2)`; each stream keeps at most `maxOutputBytes`.
/// - Blocking work happens on a Dispatch global queue, never on the Swift cooperative pool.
enum ProcessRunner {
    /// Grace period between `SIGTERM` and `SIGKILL`.
    static let killGrace: TimeInterval = 2
    /// How long to wait for pipes to close after the child exited (grandchildren may hold them).
    static let drainGrace: TimeInterval = 1

    static func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
        let cancelled = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try runBlocking(spec, cancelled: cancelled) })
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    // MARK: Blocking implementation

    private static func runBlocking(_ spec: ProcessSpec, cancelled: CancellationFlag) throws -> ProcessOutput {
        let start = DispatchTime.now()

        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        var inPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw ProcessRunnerError.pipeFailed(errno: errno) }
        guard pipe(&errPipe) == 0 else {
            let code = errno
            closeAll(outPipe)
            throw ProcessRunnerError.pipeFailed(errno: code)
        }
        if spec.stdin != nil {
            guard pipe(&inPipe) == 0 else {
                let code = errno
                closeAll(outPipe + errPipe)
                throw ProcessRunnerError.pipeFailed(errno: code)
            }
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        if spec.stdin != nil {
            posix_spawn_file_actions_adddup2(&fileActions, inPipe[0], STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&fileActions, spec.workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = CStringArray([spec.executable] + spec.arguments)
        let envp = CStringArray(spec.environment.map { "\($0.key)=\($0.value)" }.sorted())
        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, spec.executable, &fileActions, &attributes, argv.pointers, envp.pointers)

        // The child's ends are never used by the parent.
        close(outPipe[1])
        close(errPipe[1])
        if spec.stdin != nil { close(inPipe[0]) }

        guard spawnResult == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            if spec.stdin != nil { close(inPipe[1]) }
            throw ProcessRunnerError.spawnFailed(executable: spec.executable, errno: spawnResult)
        }

        var stdoutStream = BoundedStream(fd: outPipe[0], limit: spec.maxOutputBytes)
        var stderrStream = BoundedStream(fd: errPipe[0], limit: spec.maxOutputBytes)
        var stdinFD: Int32 = -1
        var stdinBytes = [UInt8](spec.stdin ?? Data())
        var stdinOffset = 0
        if spec.stdin != nil {
            stdinFD = inPipe[1]
            _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)
            _ = fcntl(stdinFD, F_SETFL, fcntl(stdinFD, F_GETFL) | O_NONBLOCK)
            if stdinBytes.isEmpty {
                close(stdinFD)
                stdinFD = -1
            }
        }
        for fd in [stdoutStream.fd, stderrStream.fd] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }

        let deadline = start.advanced(bySeconds: spec.timeout)
        var timedOut = false
        var killDeadline: DispatchTime?
        var sentKill = false
        var reaped = false
        var waitStatus: Int32 = 0
        var exitedAt: DispatchTime?

        func signalGroup(_ signal: Int32) {
            // Negative pid: the whole process group (the child is its leader thanks to SETSID).
            if kill(-pid, signal) != 0 { _ = kill(pid, signal) }
        }

        while true {
            var pollFDs: [pollfd] = []
            if stdoutStream.isOpen { pollFDs.append(pollfd(fd: stdoutStream.fd, events: Int16(POLLIN), revents: 0)) }
            if stderrStream.isOpen { pollFDs.append(pollfd(fd: stderrStream.fd, events: Int16(POLLIN), revents: 0)) }
            if stdinFD >= 0 { pollFDs.append(pollfd(fd: stdinFD, events: Int16(POLLOUT), revents: 0)) }

            if pollFDs.isEmpty {
                if reaped { break }
                usleep(10_000)
            } else {
                _ = poll(&pollFDs, nfds_t(pollFDs.count), 50)
                for entry in pollFDs where entry.revents != 0 {
                    if entry.fd == stdoutStream.fd {
                        stdoutStream.drain()
                    } else if entry.fd == stderrStream.fd {
                        stderrStream.drain()
                    } else if entry.fd == stdinFD {
                        if entry.revents & Int16(POLLOUT) != 0 {
                            let written = stdinBytes.withUnsafeBytes { buffer -> Int in
                                guard let base = buffer.baseAddress else { return 0 }
                                return write(stdinFD, base.advanced(by: stdinOffset), buffer.count - stdinOffset)
                            }
                            if written > 0 {
                                stdinOffset += written
                            } else if written < 0, errno != EAGAIN, errno != EINTR {
                                stdinOffset = stdinBytes.count
                            }
                        } else {
                            stdinOffset = stdinBytes.count
                        }
                        if stdinOffset >= stdinBytes.count {
                            close(stdinFD)
                            stdinFD = -1
                            stdinBytes = []
                        }
                    }
                }
            }

            if !reaped {
                let result = waitpid(pid, &waitStatus, WNOHANG)
                if result == pid || (result < 0 && errno == ECHILD) {
                    reaped = true
                    exitedAt = .now()
                }
            }

            let now = DispatchTime.now()
            if reaped {
                if !stdoutStream.isOpen && !stderrStream.isOpen { break }
                if let exitedAt, now > exitedAt.advanced(bySeconds: drainGrace) {
                    // A grandchild still holds the pipes: take the group down and stop reading.
                    signalGroup(SIGKILL)
                    break
                }
                continue
            }
            if !timedOut && (now > deadline || cancelled.isSet) {
                timedOut = true
                signalGroup(SIGTERM)
                killDeadline = now.advanced(bySeconds: killGrace)
            } else if timedOut, !sentKill, let killDeadline, now > killDeadline {
                signalGroup(SIGKILL)
                sentKill = true
            }
        }

        stdoutStream.close()
        stderrStream.close()
        if stdinFD >= 0 { close(stdinFD) }
        if !reaped {
            signalGroup(SIGKILL)
            while waitpid(pid, &waitStatus, 0) < 0 && errno == EINTR {}
        }

        let durationNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return ProcessOutput(
            exitCode: decodeExitStatus(waitStatus),
            stdout: stdoutStream.data,
            stderr: stderrStream.data,
            stdoutTruncated: stdoutStream.truncated,
            stderrTruncated: stderrStream.truncated,
            timedOut: timedOut,
            durationMs: Int(durationNs / 1_000_000)
        )
    }

    /// `WIFEXITED`/`WEXITSTATUS` are macros Swift cannot import. Signals map to `128 + signal` like shells do.
    private static func decodeExitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        return 128 + signal
    }

    private static func closeAll(_ fds: [Int32]) {
        for fd in fds where fd >= 0 { close(fd) }
    }
}

/// A non-blocking pipe reader that keeps at most `limit` bytes.
private struct BoundedStream {
    let fd: Int32
    let limit: Int
    private(set) var data = Data()
    private(set) var truncated = false
    private(set) var isOpen = true

    init(fd: Int32, limit: Int) {
        self.fd = fd
        self.limit = max(0, limit)
    }

    mutating func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while isOpen {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                let room = limit - data.count
                if room >= count {
                    data.append(contentsOf: buffer[0..<count])
                } else {
                    if room > 0 { data.append(contentsOf: buffer[0..<room]) }
                    truncated = true
                }
            } else if count == 0 {
                close()
            } else {
                if errno == EINTR { continue }
                if errno != EAGAIN { close() }
                return
            }
        }
    }

    mutating func close() {
        guard isOpen else { return }
        isOpen = false
        Darwin.close(fd)
    }
}

/// A NULL-terminated `char *[]` that owns its strings.
private final class CStringArray {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointers = .allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            pointers[index] = strdup(string)
        }
        pointers[strings.count] = nil
    }

    deinit {
        for index in 0..<count { free(pointers[index]) }
        pointers.deallocate()
    }
}

private final class CancellationFlag: Sendable {
    private let value = Atomic<Bool>(false)
    func set() { value.store(true, ordering: .relaxed) }
    var isSet: Bool { value.load(ordering: .relaxed) }
}

private extension DispatchTime {
    func advanced(bySeconds seconds: TimeInterval) -> DispatchTime {
        guard seconds.isFinite else { return .distantFuture }
        let clamped = min(max(seconds, 0), 60 * 60 * 24 * 7)
        return self + .nanoseconds(Int(clamped * 1_000_000_000))
    }
}
