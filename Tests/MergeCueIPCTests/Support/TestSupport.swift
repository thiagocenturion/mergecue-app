import Darwin
import Foundation
import MergeCueCore
import Testing
@testable import MergeCueIPC

/// A private, SHORT temporary MergeCue home under `/tmp` (`sun_path` is limited to 104 bytes), removed afterwards.
struct TestHome: Sendable {
    let rootPath: String
    let paths: MergeCuePaths

    static func make() throws -> TestHome {
        var template = Array("/tmp/mcipc-XXXXXX".utf8CString)
        let created: String? = template.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress, mkdtemp(base) != nil else { return nil }
            return String(cString: base)
        }
        guard let path = created else { throw TestFailure("mkdtemp failed: \(String(cString: strerror(errno)))") }
        let root = URL(filePath: path, directoryHint: .isDirectory)
        return TestHome(rootPath: path, paths: MergeCuePaths(root: root, fallbackSocketParent: root))
    }

    var socketPath: String { paths.socketPath }
    var tokenPath: String { MergeCuePaths.fileSystemPath(paths.ipcToken) }
    var ipcDirectoryPath: String { MergeCuePaths.fileSystemPath(paths.ipcDirectory) }

    func remove() {
        try? FileManager.default.removeItem(atPath: rootPath)
    }

    func readToken() throws -> String {
        try String(contentsOfFile: tokenPath, encoding: .utf8)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Runs `body` with a fresh temp home and always cleans it up.
func withTestHome<T>(_ body: (TestHome) async throws -> T) async throws -> T {
    let home = try TestHome.make()
    defer { home.remove() }
    return try await body(home)
}

/// Starts a server with `handler`, runs `body`, then stops it.
func withServer<T>(
    home: TestHome,
    handler: any IPCRequestHandling = FakeEngine(),
    peerValidator: (any PeerValidator)? = nil,
    configuration: IPCServer.Configuration = IPCServer.Configuration(),
    _ body: (IPCServer) async throws -> T
) async throws -> T {
    let server = IPCServer(paths: home.paths, handler: handler, peerValidator: peerValidator, configuration: configuration)
    try await server.start()
    do {
        let value = try await body(server)
        await server.stop()
        return value
    } catch {
        await server.stop()
        throw error
    }
}

func makeClient(_ home: TestHome, timeout: TimeInterval = 10) -> IPCClient {
    IPCClient(paths: home.paths, clientInfo: IPCClientInfo(name: "mcipc-tests", version: "1.0"), timeout: timeout)
}

/// Fixed instants for golden tests.
enum Fixtures {
    /// 2026-01-01T00:00:00.123Z
    static let date = Date(timeIntervalSince1970: 1_767_225_600.123)
    /// 2026-01-01T00:00:00Z
    static let wholeDate = Date(timeIntervalSince1970: 1_767_225_600)
    static let taskID = TaskID(rawValue: "mc_abc123")!
    static let changeRef = ChangeRequestRef(string: "github:github.com/acme/payments-api#42")!
}

/// Captures the `IPCError` thrown by `body`; nil (and a recorded issue) when it succeeds or throws something else.
func expectIPCError<T>(sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> T) async -> IPCError? {
    do {
        _ = try await body()
        Issue.record("Expected an IPCError, but the call succeeded.", sourceLocation: sourceLocation)
        return nil
    } catch let error as IPCError {
        return error
    } catch {
        Issue.record("Expected an IPCError, got \(error).", sourceLocation: sourceLocation)
        return nil
    }
}

// MARK: - Fake engine

/// Deterministic handler that mimics the engine's contract for a few methods.
struct FakeEngine: IPCRequestHandling {
    var delay: Duration = .zero
    let recorder = CallRecorder()

    func handle(method: IPCMethod, params: JSONValue, client: IPCClientInfo) async -> Result<JSONValue, IPCError> {
        await recorder.record(method: method, client: client)
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        do throws(IPCError) {
            switch method {
            case .ping:
                _ = try IPCCoding.decodeParams(PingParams.self, from: params)
                return IPCCoding.result(PingResult(appVersion: "1.0-test", isDemo: true))
            case .claimTask:
                let claim = try IPCCoding.decodeValidatedParams(ClaimTaskParams.self, from: params)
                guard claim.expectedVersion == 3 else {
                    return .failure(IPCError(.versionConflict, "Task changed; re-read it with get_task.", retryable: true, data: ["current_version": 3]))
                }
                return IPCCoding.result(ClaimTaskResult(
                    taskID: claim.taskID,
                    state: .working,
                    version: 4,
                    leaseID: "lease_" + claim.agentName,
                    leaseExpiresAt: Fixtures.date,
                    heartbeatIntervalSeconds: 60,
                    checkout: TaskCheckoutDTO(policy: .isolatedWorktree, worktreePath: "/tmp/wt", sourceBranch: "feature", targetBranch: "main")
                ))
            case .listAttention:
                // Echoes the numeric suffix of `repo` ("repo-7") as `total` so concurrent callers can check routing.
                let query = try IPCCoding.decodeValidatedParams(ListAttentionParams.self, from: params)
                let index = query.repo.flatMap { Int($0.split(separator: "-").last ?? "") } ?? -1
                return IPCCoding.result(ListAttentionResult(items: [], total: index))
            case .getThread:
                // Returns a body of the requested size ("thr_<bytes>") to exercise large frames.
                let request = try IPCCoding.decodeParams(GetThreadParams.self, from: params)
                let size = Int(request.threadID.dropFirst(4)) ?? 0
                let body = UntrustedText(source: UntrustedText.Source.reviewComment, text: String(repeating: "x", count: size))
                return IPCCoding.result(ThreadDTO(
                    threadID: request.threadID,
                    changeRef: Fixtures.changeRef,
                    kind: .diffThread,
                    resolvable: true,
                    comments: [ThreadCommentDTO(commentID: "1", author: "rev", createdAt: Fixtures.date, kind: .comment, body: body)]
                ))
            default:
                return .failure(IPCError(.unsupported, "FakeEngine does not implement \(method.rawValue)."))
            }
        } catch {
            return .failure(error)
        }
    }
}

actor CallRecorder {
    private(set) var calls: [(IPCMethod, IPCClientInfo)] = []

    func record(method: IPCMethod, client: IPCClientInfo) {
        calls.append((method, client))
    }
}

// MARK: - Raw socket peer (blocking I/O on a background queue, never on the cooperative pool)

final class RawConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "mcipc-tests.raw")
    private var buffer: [UInt8] = []

    private init(fd: Int32) {
        self.fd = fd
    }

    static func connect(to path: String) async throws -> RawConnection {
        try await onBackground {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw TestFailure("socket failed") }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let address = try POSIXSocket.address(for: path)
            let result = POSIXSocket.connect(fd, to: address)
            guard result == 0 else {
                Darwin.close(fd)
                throw TestFailure("connect failed: \(POSIXSocket.describe(result))")
            }
            return RawConnection(fd: fd)
        }
    }

    /// Writes all bytes; returns the errno if the peer went away mid-write.
    @discardableResult
    func write(_ data: Data) async -> Int32 {
        await Self.onBackgroundNonThrowing { [fd] in
            var offset = 0
            let bytes = [UInt8](data)
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return errno
                }
            }
            return 0
        }
    }

    func writeLine(_ text: String) async {
        await write(Data((text + "\n").utf8))
    }

    /// Next newline-terminated line, or nil on EOF/timeout.
    func readLine() async -> String? {
        await Self.onBackgroundNonThrowing { [self] in
            queue.sync {
                while true {
                    if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                        let line = String(decoding: buffer[..<newline], as: UTF8.self)
                        buffer.removeFirst(newline + 1)
                        return line
                    }
                    var chunk = [UInt8](repeating: 0, count: 65536)
                    let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
                    if count > 0 {
                        buffer.append(contentsOf: chunk[0..<count])
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        return nil
                    }
                }
            }
        }
    }

    /// True if the peer closed the connection (read returns 0) before the receive timeout.
    func waitForEOF() async -> Bool {
        await Self.onBackgroundNonThrowing { [fd] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
                if count == 0 { return true }
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno == ECONNRESET
                }
            }
        }
    }

    func close() {
        Darwin.close(fd)
    }

    private static func onBackground<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private static func onBackgroundNonThrowing<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: body())
            }
        }
    }
}

/// Decodes a raw response line.
func decodeResponse(_ line: String?) throws -> IPCResponse {
    guard let line else { throw TestFailure("no response line (EOF or timeout)") }
    return try IPCCoding.decoder().decode(IPCResponse.self, from: Data(line.utf8))
}

/// A syntactically valid request line.
func requestLine(id: String, token: String, method: String = "ping", params: String = "{}", version: Int = 1) -> String {
    #"{"client":{"name":"raw","pid":1,"version":"1"},"id":"\#(id)","method":"\#(method)","params":\#(params),"token":"\#(token)","v":\#(version)}"#
}

/// Polls `condition` until true or `timeout` elapses.
func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// `st_mode & 0o7777` and file type of `path` (lstat).
func fileMode(_ path: String) -> (type: mode_t, permissions: mode_t, uid: uid_t)? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return (info.st_mode & S_IFMT, info.st_mode & 0o7777, info.st_uid)
}
