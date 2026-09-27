import Darwin
import Foundation

/// Kernel-reported identity of the process on the other end of a Unix socket.
public struct IPCPeerCredentials: Sendable, Hashable, CustomStringConvertible {
    /// Effective uid (`getpeereid`).
    public var uid: uid_t
    /// Effective gid (`getpeereid`).
    public var gid: gid_t
    /// `LOCAL_PEERPID`, when available.
    public var pid: pid_t?
    /// Raw `audit_token_t` bytes (`LOCAL_PEERTOKEN`), when available. Preferred over `pid` for code-signature
    /// checks because it cannot be confused by pid reuse.
    public var auditToken: Data?

    public init(uid: uid_t, gid: gid_t, pid: pid_t? = nil, auditToken: Data? = nil) {
        self.uid = uid
        self.gid = gid
        self.pid = pid
        self.auditToken = auditToken
    }

    public var description: String {
        "peer(uid: \(uid), pid: \(pid.map(String.init) ?? "?"))"
    }
}

/// Thin, allocation-free wrappers over the BSD socket calls used by the server and the client.
enum POSIXSocket {
    /// `sizeof(sun_path)` on Darwin (104), including the terminating NUL.
    static let sunPathCapacity = MemoryLayout<sockaddr_un>.size - 2

    enum AddressError: Error, Equatable {
        case pathTooLong(byteCount: Int)
        case emptyPath
    }

    /// A `sockaddr_un` for `path` (must be shorter than `sunPathCapacity` bytes).
    static func address(for path: String) throws(AddressError) -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty else { throw .emptyPath }
        guard bytes.count < sunPathCapacity else { throw .pathTooLong(byteCount: bytes.count) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Calls `body` with `address` viewed as a generic `sockaddr`.
    static func withSockaddr<Result>(_ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result) -> Result {
        var copy = address
        return withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// A new `AF_UNIX`/`SOCK_STREAM` socket with `FD_CLOEXEC` and `SO_NOSIGPIPE`, or `-errno`.
    static func makeStreamSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -errno }
        guard configure(fd) else {
            let code = errno
            close(fd)
            return -code
        }
        return fd
    }

    /// Applies `FD_CLOEXEC` and `SO_NOSIGPIPE` (a vanished peer yields `EPIPE`, never a process-killing SIGPIPE).
    @discardableResult
    static func configure(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else { return false }
        var on: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    /// Sets `O_NONBLOCK`.
    @discardableResult
    static func setNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// `connect(2)`; returns 0 or the `errno`.
    static func connect(_ fd: Int32, to address: sockaddr_un) -> Int32 {
        while true {
            let result = withSockaddr(address) { Darwin.connect(fd, $0, $1) }
            if result == 0 { return 0 }
            let code = errno
            if code == EINTR { continue }
            return code
        }
    }

    /// uid/gid/pid/audit token of the connected peer, or nil if `getpeereid` fails.
    static func peerCredentials(_ fd: Int32) -> IPCPeerCredentials? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }

        var pid: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        let hasPID = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) == 0 && pid > 0

        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        let hasToken = getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0
            && tokenLength == socklen_t(MemoryLayout<audit_token_t>.size)
        let tokenData = hasToken ? withUnsafeBytes(of: &token) { Data($0) } : nil

        return IPCPeerCredentials(uid: uid, gid: gid, pid: hasPID ? pid : nil, auditToken: tokenData)
    }

    /// `strerror` text for diagnostics.
    static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
