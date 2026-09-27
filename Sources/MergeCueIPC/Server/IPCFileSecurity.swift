import Darwin
import Foundation
import MergeCueCore

/// Why the IPC server could not start.
public enum IPCServerError: Error, Sendable, Equatable, LocalizedError {
    /// A directory is a symlink, not a directory, or owned by another user.
    case insecureDirectory(path: String, reason: String)
    /// Something that is not our stale socket occupies the socket path.
    case insecureSocketPath(path: String, reason: String)
    /// The socket path does not fit `sockaddr_un.sun_path` (104 bytes incl. NUL on macOS).
    case socketPathTooLong(path: String, byteCount: Int)
    /// Another MergeCue instance is already listening on the socket.
    case alreadyRunning(socketPath: String)
    /// A system call failed.
    case system(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .insecureDirectory(let path, let reason):
            "Refusing to use \(path) for MergeCue IPC: \(reason)."
        case .insecureSocketPath(let path, let reason):
            "Refusing to replace \(path): \(reason)."
        case .socketPathTooLong(let path, let byteCount):
            "The IPC socket path is too long (\(byteCount) bytes, limit \(POSIXSocket.sunPathCapacity - 1)): \(path)."
        case .alreadyRunning(let socketPath):
            "Another MergeCue instance is already listening on \(socketPath)."
        case .system(let operation, let code):
            "\(operation) failed: \(POSIXSocket.describe(code)) (errno \(code))."
        }
    }
}

/// Identity of a filesystem object (to remove only the socket we created).
struct FileIdentity: Sendable, Hashable {
    var device: dev_t
    var inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }

    /// `lstat` identity of `path`, or nil.
    static func of(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(info)
    }
}

/// Filesystem hardening for the IPC directory, socket and token (all POSIX, no symlink following).
enum IPCFileSecurity {
    static let directoryMode: mode_t = 0o700
    static let fileMode: mode_t = 0o600

    // MARK: Directories

    /// Creates `path` with mode 0700 or verifies an existing one: it must be a real directory (not a symlink) owned
    /// by the current user; a looser mode is tightened to 0700 through the opened descriptor.
    static func ensurePrivateDirectory(_ path: String) throws(IPCServerError) {
        if mkdir(path, directoryMode) != 0 {
            let code = errno
            guard code == EEXIST else { throw .system(operation: "mkdir \(path)", code: code) }
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            var info = stat()
            if lstat(path, &info) == 0 {
                let type = info.st_mode & S_IFMT
                if type == S_IFLNK { throw .insecureDirectory(path: path, reason: "it is a symbolic link") }
                if type != S_IFDIR { throw .insecureDirectory(path: path, reason: "it is not a directory") }
            }
            throw .system(operation: "open \(path)", code: code)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .system(operation: "fstat \(path)", code: errno) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw .insecureDirectory(path: path, reason: "it is not a directory")
        }
        guard info.st_uid == getuid() else {
            throw .insecureDirectory(path: path, reason: "it is owned by uid \(info.st_uid), not the current user (uid \(getuid()))")
        }
        if info.st_mode & 0o7777 != directoryMode {
            guard fchmod(fd, directoryMode) == 0 else { throw .system(operation: "chmod 0700 \(path)", code: errno) }
        }
    }

    /// Creates `path` (and missing parents, mode 0700) when absent; an existing path must resolve to a directory.
    /// Used for the data root and for a user-chosen `MERGECUE_SOCKET` directory, whose mode is left alone.
    static func ensureDirectoryExists(_ path: String) throws(IPCServerError) {
        var info = stat()
        if stat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                throw .insecureDirectory(path: path, reason: "it is not a directory")
            }
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty, parent != path {
            try ensureDirectoryExists(parent)
        }
        if mkdir(path, directoryMode) != 0 {
            let code = errno
            guard code == EEXIST else { throw .system(operation: "mkdir \(path)", code: code) }
        }
    }

    /// Prepares every directory the server needs: data root, private `ipc/` (token), private socket directory
    /// (the `ipc/` directory itself or the `/tmp/mergecue-<uid>` fallback), or an existing override directory.
    static func prepareDirectories(for paths: MergeCuePaths) throws(IPCServerError) {
        try ensureDirectoryExists(MergeCuePaths.fileSystemPath(paths.root))
        let ipcDirectory = MergeCuePaths.fileSystemPath(paths.ipcDirectory)
        try ensurePrivateDirectory(ipcDirectory)
        let socketDirectory = MergeCuePaths.fileSystemPath(paths.socketDirectory)
        guard socketDirectory != ipcDirectory else { return }
        if paths.usesSocketOverride {
            try ensureDirectoryExists(socketDirectory)
        } else {
            try ensurePrivateDirectory(socketDirectory)
        }
    }

    // MARK: Socket

    /// Unlinks a stale socket left by a crashed instance. Only a *socket* owned by the current user that nobody is
    /// listening on is removed; anything else at the path is refused, and a live listener means another instance.
    static func removeStaleSocket(at path: String, address: sockaddr_un) throws(IPCServerError) {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return }
            throw .system(operation: "lstat \(path)", code: code)
        }
        let type = info.st_mode & S_IFMT
        guard type == S_IFSOCK else {
            throw .insecureSocketPath(path: path, reason: type == S_IFLNK ? "it is a symbolic link" : "it exists and is not a socket")
        }
        guard info.st_uid == getuid() else {
            throw .insecureSocketPath(path: path, reason: "the socket is owned by uid \(info.st_uid)")
        }
        let probe = POSIXSocket.makeStreamSocket()
        guard probe >= 0 else { throw .system(operation: "socket", code: -probe) }
        let result = POSIXSocket.connect(probe, to: address)
        close(probe)
        switch result {
        case 0:
            throw .alreadyRunning(socketPath: path)
        case ECONNREFUSED, ENOENT:
            if unlink(path) != 0, errno != ENOENT {
                throw .system(operation: "unlink \(path)", code: errno)
            }
        default:
            throw .system(operation: "probe \(path)", code: result)
        }
    }

    /// Removes the socket at `path` only if it is still the one we bound (same device + inode).
    static func removeSocket(at path: String, ifIdentity identity: FileIdentity) {
        guard FileIdentity.of(path) == identity else { return }
        unlink(path)
    }

    // MARK: Token

    /// 32 random bytes from the system CSPRNG, lowercase hex (64 characters).
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: IPCProtocol.tokenHexLength / 2)
        arc4random_buf(&bytes, bytes.count)
        return hex(bytes)
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var characters = [UInt8]()
        characters.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            characters.append(digits[Int(byte >> 4)])
            characters.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }

    /// Atomically writes the token with mode 0600: exclusive temp file (no symlink following) → fsync → rename.
    static func writeToken(_ token: String, to path: String) throws(IPCServerError) {
        let directory = (path as NSString).deletingLastPathComponent
        let temporary = "\(directory)/.token-\(generateToken().prefix(12)).tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, fileMode)
        guard fd >= 0 else { throw .system(operation: "create \(temporary)", code: errno) }
        var failure: IPCServerError?
        if fchmod(fd, fileMode) != 0 {
            failure = .system(operation: "chmod 0600 \(temporary)", code: errno)
        }
        if failure == nil {
            let bytes = Array(token.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return write(fd, base + offset, raw.count - offset)
                }
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    failure = .system(operation: "write \(temporary)", code: written < 0 ? errno : EIO)
                    break
                }
            }
        }
        if failure == nil, fsync(fd) != 0 {
            failure = .system(operation: "fsync \(temporary)", code: errno)
        }
        close(fd)
        if failure == nil, rename(temporary, path) != 0 {
            failure = .system(operation: "rename \(temporary) → \(path)", code: errno)
        }
        if let failure {
            unlink(temporary)
            throw failure
        }
    }

    /// Reads a token file without following symlinks (a regular file of at most 4 KiB), trimmed of whitespace.
    /// Failures carry the `errno` of the failing call (`EINVAL` for a non-regular or oversized file).
    static func readToken(at path: String) -> Result<String, TokenReadError> {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .failure(TokenReadError(code: errno)) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .failure(TokenReadError(code: errno)) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= 4096 else { return .failure(TokenReadError(code: EINVAL)) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var total = 0
        while total < buffer.count {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return read(fd, base + total, raw.count - total)
            }
            if count > 0 {
                total += count
            } else if count == 0 {
                break
            } else if errno != EINTR {
                return .failure(TokenReadError(code: errno))
            }
        }
        let text = String(decoding: buffer[0..<total], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(text)
    }

    struct TokenReadError: Error, Sendable, Equatable {
        var code: Int32
    }

    /// Removes the token file only if it still holds `token` (a newer instance may have replaced it).
    static func removeToken(at path: String, ifContents token: String) {
        guard case .success(let current) = readToken(at: path), current == token else { return }
        unlink(path)
    }

    /// Whether `token` has the expected shape (64 lowercase or uppercase hex characters).
    static func isWellFormedToken(_ token: String) -> Bool {
        token.utf8.count == IPCProtocol.tokenHexLength && token.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
        }
    }
}
