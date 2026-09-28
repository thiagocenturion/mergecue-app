import Darwin
import Foundation
import MergeCueCore
import Testing
@testable import MergeCueIPC

@Suite("Socket security, lifecycle and availability", .timeLimit(.minutes(1)))
struct IPCSecurityTests {
    // MARK: Permissions and files

    @Test func directorySocketAndTokenPermissions() async throws {
        try await withTestHome { home in
            try await withServer(home: home) { _ in
                let directory = try #require(fileMode(home.ipcDirectoryPath))
                #expect(directory.type == S_IFDIR)
                #expect(directory.permissions == 0o700)
                #expect(directory.uid == getuid())

                let socket = try #require(fileMode(home.socketPath))
                #expect(socket.type == S_IFSOCK)
                #expect(socket.permissions == 0o600)
                #expect(socket.uid == getuid())

                let token = try #require(fileMode(home.tokenPath))
                #expect(token.type == S_IFREG)
                #expect(token.permissions == 0o600)
                let text = try home.readToken()
                #expect(text.count == IPCProtocol.tokenHexLength)
                #expect(IPCFileSecurity.isWellFormedToken(text))
                #expect(text == text.lowercased())
            }
        }
    }

    @Test func looseExistingDirectoryIsTightened() async throws {
        try await withTestHome { home in
            #expect(mkdir(home.ipcDirectoryPath, 0o755) == 0)
            #expect(chmod(home.ipcDirectoryPath, 0o755) == 0)
            try await withServer(home: home) { _ in
                #expect(fileMode(home.ipcDirectoryPath)?.permissions == 0o700)
            }
        }
    }

    @Test func symlinkedDirectoryIsRefused() async throws {
        try await withTestHome { home in
            let elsewhere = home.rootPath + "/elsewhere"
            #expect(mkdir(elsewhere, 0o700) == 0)
            #expect(symlink(elsewhere, home.ipcDirectoryPath) == 0)
            let server = IPCServer(paths: home.paths, handler: FakeEngine(), peerValidator: nil)
            await #expect(throws: IPCServerError.insecureDirectory(path: home.ipcDirectoryPath, reason: "it is a symbolic link")) {
                try await server.start()
            }
            #expect(await !server.isRunning)
            #expect(fileMode(elsewhere + "/token") == nil)
        }
    }

    @Test func regularFileAtSocketPathIsNeverReplaced() async throws {
        try await withTestHome { home in
            #expect(mkdir(home.ipcDirectoryPath, 0o700) == 0)
            #expect(FileManager.default.createFile(atPath: home.socketPath, contents: Data("keep".utf8)))
            let server = IPCServer(paths: home.paths, handler: FakeEngine(), peerValidator: nil)
            await #expect(throws: IPCServerError.insecureSocketPath(path: home.socketPath, reason: "it exists and is not a socket")) {
                try await server.start()
            }
            #expect(FileManager.default.contents(atPath: home.socketPath) == Data("keep".utf8))
        }
    }

    @Test func socketPathTooLongIsReported() async throws {
        try await withTestHome { home in
            let longPath = home.rootPath + "/" + String(repeating: "s", count: 110) + ".sock"
            let paths = MergeCuePaths(root: URL(filePath: home.rootPath), socketOverride: URL(filePath: longPath))
            let socketPath = paths.socketPath
            #expect(socketPath.utf8.count > 104)
            let server = IPCServer(paths: paths, handler: FakeEngine(), peerValidator: nil)
            await #expect(throws: IPCServerError.socketPathTooLong(path: socketPath, byteCount: socketPath.utf8.count)) {
                try await server.start()
            }
        }
    }

    // MARK: Lifecycle

    @Test func staleSocketIsCleanedUp() async throws {
        try await withTestHome { home in
            #expect(mkdir(home.ipcDirectoryPath, 0o700) == 0)
            try createStaleSocket(at: home.socketPath)
            #expect(fileMode(home.socketPath)?.type == S_IFSOCK)
            try await withServer(home: home) { _ in
                let ping = try await makeClient(home).ping()
                #expect(ping.appVersion == "1.0-test")
            }
        }
    }

    @Test func secondInstanceDoesNotHijackALiveSocket() async throws {
        try await withTestHome { home in
            try await withServer(home: home) { _ in
                let token = try home.readToken()
                let second = IPCServer(paths: home.paths, handler: FakeEngine(), peerValidator: nil)
                await #expect(throws: IPCServerError.alreadyRunning(socketPath: home.socketPath)) {
                    try await second.start()
                }
                #expect(try home.readToken() == token)
                #expect(try await makeClient(home).ping().isDemo)
            }
        }
    }

    @Test func stopRemovesSocketAndTokenAndRestartRotatesToken() async throws {
        try await withTestHome { home in
            let server = IPCServer(paths: home.paths, handler: FakeEngine(), peerValidator: nil)
            let client = makeClient(home)
            try await server.start()
            try await server.start() // idempotent
            let firstToken = try home.readToken()
            #expect(try await client.ping().isDemo)

            await server.stop()
            #expect(await !server.isRunning)
            #expect(fileMode(home.socketPath) == nil)
            #expect(fileMode(home.tokenPath) == nil)
            let unavailable = await expectIPCError { try await client.ping() }
            #expect(unavailable == .appUnavailable(reason: "token_missing"))
            await server.stop() // idempotent

            try await server.start()
            let secondToken = try home.readToken()
            #expect(secondToken != firstToken)
            #expect(try await client.ping().isDemo)
            await server.stop()
            #expect(fileMode(home.socketPath) == nil)
        }
    }

    @Test func stopClosesOpenConnections() async throws {
        try await withTestHome { home in
            let server = IPCServer(paths: home.paths, handler: FakeEngine(), peerValidator: nil)
            try await server.start()
            let connection = try await RawConnection.connect(to: home.socketPath)
            defer { connection.close() }
            #expect(await eventually { await server.connectionCount() == 1 })
            await server.stop()
            #expect(await connection.waitForEOF())
        }
    }

    // MARK: App unavailable

    @Test func appUnavailableWhenNothingIsRunning() async throws {
        try await withTestHome { home in
            let client = makeClient(home)
            let noToken = await expectIPCError { try await client.ping() }
            #expect(noToken?.code == .appUnavailable)
            #expect(noToken?.message == "MergeCue app is not running. Open MergeCue and retry.")
            #expect(noToken?.retryable == true)

            // A token without a socket (ENOENT).
            #expect(mkdir(home.ipcDirectoryPath, 0o700) == 0)
            try IPCFileSecurity.writeToken(IPCFileSecurity.generateToken(), to: home.tokenPath)
            let noSocket = await expectIPCError { try await client.ping() }
            #expect(noSocket == .appUnavailable(reason: "not_running"))

            // A leftover socket nobody listens on (ECONNREFUSED).
            try createStaleSocket(at: home.socketPath)
            let refused = await expectIPCError { try await client.ping() }
            #expect(refused == .appUnavailable(reason: "not_running"))

            // A malformed token is not "the app".
            try Data("not-a-token".utf8).write(to: URL(filePath: home.tokenPath))
            let malformed = await expectIPCError { try await client.ping() }
            #expect(malformed == .appUnavailable(reason: "token_invalid"))
        }
    }

    // MARK: Authentication

    @Test func badTokenIsRejectedAndTheConnectionClosed() async throws {
        try await withTestHome { home in
            try await withServer(home: home) { _ in
                let connection = try await RawConnection.connect(to: home.socketPath)
                defer { connection.close() }
                await connection.writeLine(requestLine(id: "bad", token: String(repeating: "0", count: 64)))
                let response = try decodeResponse(await connection.readLine())
                #expect(response.id == "bad")
                #expect(response.error?.code == .unauthorized)
                #expect(response.result == nil)
                #expect(await connection.waitForEOF())
            }
        }
    }

    @Test func missingTokenIsRejected() async throws {
        try await withTestHome { home in
            try await withServer(home: home) { _ in
                let connection = try await RawConnection.connect(to: home.socketPath)
                defer { connection.close() }
                await connection.writeLine(#"{"client":{"name":"raw","pid":1,"version":"1"},"id":"x","method":"ping","params":{},"v":1}"#)
                #expect(try decodeResponse(await connection.readLine()).error?.code == .unauthorized)
                #expect(await connection.waitForEOF())
            }
        }
    }

    @Test func clientWithAStaleTokenGetsUnauthorized() async throws {
        try await withTestHome { home in
            let engine = FakeEngine()
            try await withServer(home: home, handler: engine) { _ in
                try Data(String(repeating: "a", count: 64).utf8).write(to: URL(filePath: home.tokenPath))
                let error = await expectIPCError { try await makeClient(home).ping() }
                #expect(error?.code == .unauthorized)
                #expect(error?.retryable == false)
                #expect(await engine.recorder.calls.isEmpty)
            }
        }
    }

    @Test func clientRetriesOnceWhenTheTokenRotatedMidCall() async throws {
        try await withTestHome { home in
            // The validator runs on accept, i.e. after the client read the (stale) token file and before the server
            // reads the request: it restores the real token, as an app restart between the two would.
            let restorer = TokenRestoringValidator(tokenPath: home.tokenPath)
            let engine = FakeEngine()
            try await withServer(home: home, handler: engine, peerValidator: restorer) { _ in
                restorer.realToken = try home.readToken()
                try Data(String(repeating: "b", count: 64).utf8).write(to: URL(filePath: home.tokenPath))
                let ping = try await makeClient(home).ping()
                #expect(ping.isDemo)
                #expect(restorer.validations == 2)
                #expect(await engine.recorder.calls.count == 1)
            }
        }
    }

    @Test func malformedAndOversizeFramesCloseTheConnection() async throws {
        try await withTestHome { home in
            try await withServer(home: home) { _ in
                let garbage = try await RawConnection.connect(to: home.socketPath)
                defer { garbage.close() }
                await garbage.writeLine("this is not json")
                let malformed = try decodeResponse(await garbage.readLine())
                #expect(malformed.error?.code == .invalidParams)
                #expect(await garbage.waitForEOF())

                let oversize = try await RawConnection.connect(to: home.socketPath)
                defer { oversize.close() }
                await oversize.write(Data(repeating: UInt8(ascii: "x"), count: IPCProtocol.maxFrameBytes + 1))
                let response = try decodeResponse(await oversize.readLine())
                #expect(response.id == "")
                #expect(response.error?.code == .invalidParams)
                #expect(response.error?.message.contains("4 MiB") == true)
                #expect(await oversize.waitForEOF())
            }
        }
    }

    /// S13: the token is checked before the protocol version, so an unauthenticated peer learns nothing (not even
    /// the supported versions), and any pre-auth error closes the connection.
    @Test func tokenIsCheckedBeforeTheProtocolVersion() async throws {
        try await withTestHome { home in
            try await withServer(home: home) { _ in
                let connection = try await RawConnection.connect(to: home.socketPath)
                defer { connection.close() }
                await connection.writeLine(requestLine(id: "v9", token: "wrong", version: 9))
                let response = try decodeResponse(await connection.readLine())
                #expect(response.error?.code == .unauthorized)
                #expect(response.error?.data == nil)
                #expect(await connection.waitForEOF())
            }
        }
    }

    /// S13: after its first request, a connection that goes quiet is closed too.
    @Test func idleConnectionsAreClosedAfterTheFirstFrame() async throws {
        try await withTestHome { home in
            try await withServer(home: home, configuration: IPCServer.Configuration(handshakeTimeout: 5, idleTimeout: 0.2)) { server in
                let token = try home.readToken()
                let connection = try await RawConnection.connect(to: home.socketPath)
                defer { connection.close() }
                await connection.writeLine(requestLine(id: "p1", token: token))
                let ping = try decodeResponse(await connection.readLine())
                #expect(ping.id == "p1")
                #expect(await connection.waitForEOF())
                #expect(await eventually { await server.connectionCount() == 0 })
            }
        }
    }

    @Test func silentConnectionsAreClosedAfterTheHandshakeWindow() async throws {
        try await withTestHome { home in
            try await withServer(home: home, configuration: IPCServer.Configuration(handshakeTimeout: 0.2)) { server in
                let connection = try await RawConnection.connect(to: home.socketPath)
                defer { connection.close() }
                #expect(await connection.waitForEOF())
                #expect(await eventually { await server.connectionCount() == 0 })
            }
        }
    }

    // MARK: Peer validation

    @Test func peerValidatorSeesKernelCredentials() async throws {
        let validator = RecordingValidator()
        try await withTestHome { home in
            try await withServer(home: home, peerValidator: validator) { _ in
                let ping = try await makeClient(home).ping()
                #expect(ping.isDemo)
            }
        }
        let peer = try #require(validator.peers.first)
        #expect(peer.uid == getuid())
        #expect(peer.pid == getpid())
        #expect(peer.auditToken?.count == MemoryLayout<audit_token_t>.size)
    }

    @Test func rejectedPeersGetUnauthorized() async throws {
        try await withTestHome { home in
            try await withServer(home: home, peerValidator: RejectingValidator()) { _ in
                let error = await expectIPCError { try await makeClient(home).ping() }
                #expect(error?.code == .unauthorized)
                #expect(error?.message.contains("not allowed") == true)
            }
        }
    }

    @Test func codeSignatureValidatorRejectsANonMatchingRequirement() async throws {
        let validator = try #require(try CodeSignaturePeerValidator.make(requirement: #"identifier "dev.mergecue.never-matches" and anchor apple generic"#))
        #expect(throws: PeerValidationError.self) {
            try validator.validate(IPCPeerCredentials(uid: getuid(), gid: getgid(), pid: getpid()))
        }
        try await withTestHome { home in
            try await withServer(home: home, peerValidator: validator) { _ in
                let error = await expectIPCError { try await makeClient(home).ping() }
                #expect(error?.code == .unauthorized)
            }
        }
    }

    @Test func codeSignatureValidatorIsOptIn() throws {
        #expect(try CodeSignaturePeerValidator.make(requirement: nil) == nil)
        #expect(try CodeSignaturePeerValidator.make(requirement: "  ") == nil)
        #expect(throws: PeerValidationError.self) { try CodeSignaturePeerValidator(requirement: "this is not a requirement (") }
        #expect(CodeSignaturePeerValidator.requirement(teamIdentifier: "TTSKDZ455K") == #"anchor apple generic and certificate leaf[subject.OU] = "TTSKDZ455K""#)
        #expect(throws: PeerValidationError.self) {
            try CodeSignaturePeerValidator(requirement: "anchor apple").validate(IPCPeerCredentials(uid: getuid(), gid: getgid()))
        }
    }

    // MARK: Helpers

    /// Binds a socket at `path` and closes it without unlinking (what a crashed app leaves behind).
    private func createStaleSocket(at path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestFailure("socket failed") }
        defer { close(fd) }
        let address = try POSIXSocket.address(for: path)
        let result = POSIXSocket.withSockaddr(address) { bind(fd, $0, $1) }
        guard result == 0 else { throw TestFailure("bind failed: \(POSIXSocket.describe(errno))") }
    }
}

private struct RejectingValidator: PeerValidator {
    func validate(_ peer: IPCPeerCredentials) throws {
        throw PeerValidationError("nope")
    }
}

private final class TokenRestoringValidator: PeerValidator, @unchecked Sendable {
    private let lock = NSLock()
    private let tokenPath: String
    private var storedToken: String?
    private var count = 0

    init(tokenPath: String) {
        self.tokenPath = tokenPath
    }

    var realToken: String? {
        get { lock.withLock { storedToken } }
        set { lock.withLock { storedToken = newValue } }
    }

    var validations: Int {
        lock.withLock { count }
    }

    func validate(_ peer: IPCPeerCredentials) throws {
        let token: String? = lock.withLock {
            count += 1
            return storedToken
        }
        if let token {
            try Data(token.utf8).write(to: URL(filePath: tokenPath))
        }
    }
}

private final class RecordingValidator: PeerValidator, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [IPCPeerCredentials] = []

    var peers: [IPCPeerCredentials] {
        lock.withLock { recorded }
    }

    func validate(_ peer: IPCPeerCredentials) throws {
        lock.withLock { recorded.append(peer) }
    }
}
