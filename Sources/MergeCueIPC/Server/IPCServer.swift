import Darwin
import Foundation
import MergeCueCore

/// The app side of the private channel: a Unix-domain stream socket at `MergeCuePaths.socket`.
///
/// `start()`:
/// 1. creates/verifies the private directories (`ipc/` 0700, real directory, owned by us — symlinks refused);
/// 2. removes a *stale* socket (a socket we own that nobody listens on) — anything else at the path is refused and
///    a live listener means another instance is running;
/// 3. writes a fresh 32-byte hex token to `ipc/token` (0600, atomic rename) — regenerated on every start;
/// 4. binds, `chmod 0600`s the socket and listens; connections are accepted on a dispatch source.
///
/// Every connection must come from the same uid (`getpeereid`), may additionally be vetted by a `PeerValidator`,
/// and every request must carry the token (constant-time comparison). I/O never blocks the Swift concurrency
/// pool; only the handler runs there. `stop()` closes everything and removes the socket and token files.
public actor IPCServer {
    /// Tunables (defaults match the contract).
    public struct Configuration: Sendable, Hashable {
        /// Maximum frame size in either direction (4 MiB).
        public var maxFrameBytes: Int
        /// Concurrent connections; extra connections are closed immediately.
        public var maxConnections: Int
        /// A connection that sends nothing within this window is closed.
        public var handshakeTimeout: TimeInterval
        /// After its first frame, a connection with no request in flight is closed when no new frame arrives
        /// within this window (the MCP helper opens one connection per call).
        public var idleTimeout: TimeInterval
        /// Reading from a connection pauses while this many requests wait for the handler.
        public var maxQueuedRequestsPerConnection: Int
        /// `listen(2)` backlog.
        public var backlog: Int32

        public init(
            maxFrameBytes: Int = IPCProtocol.maxFrameBytes,
            maxConnections: Int = 64,
            handshakeTimeout: TimeInterval = 10,
            idleTimeout: TimeInterval = 60,
            maxQueuedRequestsPerConnection: Int = 16,
            backlog: Int32 = 64
        ) {
            self.maxFrameBytes = max(1024, maxFrameBytes)
            self.maxConnections = max(1, maxConnections)
            self.handshakeTimeout = max(0.05, handshakeTimeout)
            self.idleTimeout = max(0.05, idleTimeout)
            self.maxQueuedRequestsPerConnection = max(1, maxQueuedRequestsPerConnection)
            self.backlog = max(1, backlog)
        }
    }

    private struct Running: Sendable {
        var listener: IPCListener
        var token: String
        var socketPath: String
        var socketIdentity: FileIdentity
        var tokenPath: String
    }

    public nonisolated let paths: MergeCuePaths
    public nonisolated let configuration: Configuration
    private let handler: any IPCRequestHandling
    private let peerValidator: (any PeerValidator)?
    private var running: Running?
    private let log = MCLog.ipc

    public init(
        paths: MergeCuePaths,
        handler: any IPCRequestHandling,
        peerValidator: (any PeerValidator)?,
        configuration: Configuration = Configuration()
    ) {
        self.paths = paths
        self.handler = handler
        self.peerValidator = peerValidator
        self.configuration = configuration
    }

    deinit {
        if let running {
            running.listener.stop()
            IPCFileSecurity.removeSocket(at: running.socketPath, ifIdentity: running.socketIdentity)
            IPCFileSecurity.removeToken(at: running.tokenPath, ifContents: running.token)
        }
    }

    public var isRunning: Bool {
        running != nil
    }

    /// Starts listening. Idempotent while running.
    public func start() throws(IPCServerError) {
        guard running == nil else { return }
        let socketPath = paths.socketPath
        let tokenPath = MergeCuePaths.fileSystemPath(paths.ipcToken)
        let address: sockaddr_un
        do {
            address = try POSIXSocket.address(for: socketPath)
        } catch {
            throw .socketPathTooLong(path: socketPath, byteCount: socketPath.utf8.count)
        }

        try IPCFileSecurity.prepareDirectories(for: paths)
        try IPCFileSecurity.removeStaleSocket(at: socketPath, address: address)

        // The token exists before the socket, so a client that can connect can always authenticate.
        let token = IPCFileSecurity.generateToken()
        try IPCFileSecurity.writeToken(token, to: tokenPath)

        let fd: Int32
        let identity: FileIdentity
        do throws(IPCServerError) {
            fd = try Self.bindAndListen(socketPath: socketPath, address: address, backlog: configuration.backlog)
            guard let bound = FileIdentity.of(socketPath) else {
                close(fd)
                throw .system(operation: "lstat \(socketPath)", code: errno)
            }
            identity = bound
        } catch {
            IPCFileSecurity.removeToken(at: tokenPath, ifContents: token)
            throw error
        }

        let processor = IPCRequestProcessor(token: token, handler: handler, maxFrameBytes: configuration.maxFrameBytes)
        let listener = IPCListener(listeningFD: fd, processor: processor, configuration: configuration, peerValidator: peerValidator)
        listener.start()
        running = Running(listener: listener, token: token, socketPath: socketPath, socketIdentity: identity, tokenPath: tokenPath)
        log.info("IPC: listening on \(socketPath)\(peerValidator == nil ? "" : " (peer code-signature check on)")")
    }

    /// Stops accepting, closes open connections and removes the socket and token files (only if they are still
    /// ours). Idempotent.
    public func stop() {
        guard let running else { return }
        self.running = nil
        running.listener.stop()
        IPCFileSecurity.removeSocket(at: running.socketPath, ifIdentity: running.socketIdentity)
        IPCFileSecurity.removeToken(at: running.tokenPath, ifContents: running.token)
        log.info("IPC: stopped")
    }

    /// Open connections (diagnostics/tests); 0 when stopped.
    public func connectionCount() async -> Int {
        guard let listener = running?.listener else { return 0 }
        return await listener.connectionCount()
    }

    // MARK: Socket setup

    /// socket → bind → chmod 0600 (no symlink following) → verify → listen; the returned descriptor is
    /// non-blocking and close-on-exec. The socket file is unlinked again on failure.
    private static func bindAndListen(socketPath: String, address: sockaddr_un, backlog: Int32) throws(IPCServerError) -> Int32 {
        let fd = POSIXSocket.makeStreamSocket()
        guard fd >= 0 else { throw .system(operation: "socket", code: -fd) }
        guard POSIXSocket.setNonBlocking(fd) else {
            let code = errno
            close(fd)
            throw .system(operation: "fcntl O_NONBLOCK", code: code)
        }
        let bindResult = POSIXSocket.withSockaddr(address) { bind(fd, $0, $1) }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            if code == EADDRINUSE { throw .alreadyRunning(socketPath: socketPath) }
            throw .system(operation: "bind \(socketPath)", code: code)
        }
        func fail(_ error: IPCServerError) -> IPCServerError {
            close(fd)
            unlink(socketPath)
            return error
        }
        guard fchmodat(AT_FDCWD, socketPath, IPCFileSecurity.fileMode, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw fail(.system(operation: "chmod 0600 \(socketPath)", code: errno))
        }
        var info = stat()
        guard lstat(socketPath, &info) == 0 else {
            throw fail(.system(operation: "lstat \(socketPath)", code: errno))
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid(), info.st_mode & 0o777 == IPCFileSecurity.fileMode else {
            throw fail(.insecureSocketPath(path: socketPath, reason: "the bound socket does not have the expected owner and mode 0600"))
        }
        guard listen(fd, backlog) == 0 else {
            throw fail(.system(operation: "listen", code: errno))
        }
        return fd
    }
}
