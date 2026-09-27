import Foundation

/// Every on-disk location MergeCue uses. All paths derive from `MERGECUE_HOME` (tests, demos, side-by-side
/// installs) or `~/Library/Application Support/MergeCue`.
public struct MergeCuePaths: Sendable, Hashable {
    public static let homeEnvironmentKey = "MERGECUE_HOME"
    public static let socketEnvironmentKey = "MERGECUE_SOCKET"
    /// `sockaddr_un.sun_path` is 104 bytes on macOS; longer default paths fall back to `/tmp/mergecue-<uid>/`.
    public static let maxSocketPathBytes = 100

    /// Data root.
    public let root: URL
    /// `<root>/mergecue.sqlite`.
    public let database: URL
    /// `<root>/ipc/` (0700).
    public let ipcDirectory: URL
    /// Unix socket path: `MERGECUE_SOCKET`, `<root>/ipc/mergecue.sock`, or the `/tmp` fallback.
    public let socket: URL
    /// Directory containing `socket` (0700 when MergeCue owns it).
    public let socketDirectory: URL
    /// `<root>/ipc/token` (0600, written by the IPC server).
    public let ipcToken: URL
    /// `<root>/worktrees/`.
    public let worktrees: URL
    /// `<root>/handoff/`.
    public let handoff: URL
    /// `~/Library/Logs/MergeCue`, or `<root>/logs` under `MERGECUE_HOME`.
    public let logs: URL
    /// True when `MERGECUE_HOME` is set.
    public let usesCustomHome: Bool
    /// True when the default socket path was too long and the `/tmp/mergecue-<uid>` fallback is used.
    public let usesFallbackSocket: Bool
    /// True when `MERGECUE_SOCKET` overrides the socket path.
    public let usesSocketOverride: Bool

    /// Resolves paths from `environment` (`MERGECUE_HOME`, `MERGECUE_SOCKET`). `fallbackSocketParent` is where the
    /// `mergecue-<uid>/` socket fallback directory lives (`/tmp`; tests pass a temporary directory so they never
    /// touch the shared production socket directory).
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        fallbackSocketParent: URL = MergeCuePaths.defaultFallbackSocketParent
    ) {
        let customHome = environment[Self.homeEnvironmentKey].flatMap { Self.expand($0) }
        let root: URL
        let logs: URL
        if let customHome {
            root = customHome
            logs = customHome.appending(path: "logs", directoryHint: .isDirectory)
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support", directoryHint: .isDirectory)
            let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library", directoryHint: .isDirectory)
            root = support.appending(path: "MergeCue", directoryHint: .isDirectory)
            logs = library.appending(path: "Logs/MergeCue", directoryHint: .isDirectory)
        }
        let socketOverride = environment[Self.socketEnvironmentKey].flatMap { Self.expand($0) }
        self.init(
            root: root,
            logs: logs,
            socketOverride: socketOverride,
            usesCustomHome: customHome != nil,
            fallbackSocketDirectory: Self.fallbackSocketDirectory(in: fallbackSocketParent)
        )
    }

    /// Explicit layout under `root` (tests). `logs` defaults to `<root>/logs`.
    public init(
        root: URL,
        logs: URL? = nil,
        socketOverride: URL? = nil,
        fallbackSocketParent: URL = MergeCuePaths.defaultFallbackSocketParent
    ) {
        self.init(
            root: root,
            logs: logs ?? root.appending(path: "logs", directoryHint: .isDirectory),
            socketOverride: socketOverride,
            usesCustomHome: true,
            fallbackSocketDirectory: Self.fallbackSocketDirectory(in: fallbackSocketParent)
        )
    }

    private init(root: URL, logs: URL, socketOverride: URL?, usesCustomHome: Bool, fallbackSocketDirectory: URL) {
        self.root = Self.directoryURL(root)
        self.database = self.root.appending(path: "mergecue.sqlite", directoryHint: .notDirectory)
        self.ipcDirectory = self.root.appending(path: "ipc", directoryHint: .isDirectory)
        self.ipcToken = ipcDirectory.appending(path: "token", directoryHint: .notDirectory)
        self.worktrees = self.root.appending(path: "worktrees", directoryHint: .isDirectory)
        self.handoff = self.root.appending(path: "handoff", directoryHint: .isDirectory)
        self.logs = Self.directoryURL(logs)
        self.usesCustomHome = usesCustomHome

        if let socketOverride {
            socket = socketOverride.standardizedFileURL
            socketDirectory = Self.directoryURL(socket.deletingLastPathComponent())
            usesFallbackSocket = false
            usesSocketOverride = true
        } else {
            let preferred = ipcDirectory.appending(path: "mergecue.sock", directoryHint: .notDirectory)
            if Self.fileSystemPath(preferred).utf8.count > Self.maxSocketPathBytes {
                socketDirectory = fallbackSocketDirectory
                socket = socketDirectory.appending(path: "mergecue.sock", directoryHint: .notDirectory)
                usesFallbackSocket = true
            } else {
                socket = preferred
                socketDirectory = ipcDirectory
                usesFallbackSocket = false
            }
            usesSocketOverride = false
        }
    }

    /// `/tmp`.
    public static let defaultFallbackSocketParent = URL(filePath: "/tmp", directoryHint: .isDirectory)

    /// `/tmp/mergecue-<uid>/`.
    public static var fallbackSocketDirectory: URL {
        fallbackSocketDirectory(in: defaultFallbackSocketParent)
    }

    /// `<parent>/mergecue-<uid>/`.
    public static func fallbackSocketDirectory(in parent: URL) -> URL {
        directoryURL(parent.appending(path: "mergecue-\(getuid())", directoryHint: .isDirectory))
    }

    /// POSIX path of the socket (for `sockaddr_un`).
    public var socketPath: String { Self.fileSystemPath(socket) }

    /// Creates every MergeCue-owned directory with mode 0700 (tightening existing ones). The `/tmp` socket
    /// fallback directory must be a real directory owned by the current user, otherwise this throws.
    public func ensureDirectories(fileManager: FileManager = .default) throws {
        var directories = [root, ipcDirectory, worktrees, handoff, logs]
        if !usesSocketOverride, socketDirectory != ipcDirectory {
            directories.append(socketDirectory)
        }
        if usesFallbackSocket, fileManager.fileExists(atPath: Self.fileSystemPath(socketDirectory)) {
            // Shared /tmp: refuse a pre-existing directory (or symlink) that someone else controls.
            try Self.verifyOwnedDirectory(socketDirectory)
        }
        for directory in directories {
            try Self.ensurePrivateDirectory(directory, fileManager: fileManager)
        }
        if usesFallbackSocket {
            try Self.verifyOwnedDirectory(socketDirectory)
        }
    }

    // MARK: Internals

    /// Standardized URL flagged as a directory (consistent trailing slash for comparisons).
    private static func directoryURL(_ url: URL) -> URL {
        URL(filePath: fileSystemPath(url.standardizedFileURL), directoryHint: .isDirectory)
    }

    /// POSIX path without a trailing slash (a trailing slash makes `stat` fail for non-directories).
    public static func fileSystemPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    private static func expand(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(filePath: expanded)
        }
        return URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
            .appending(path: expanded)
    }

    private static func ensurePrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        let path = fileSystemPath(url)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw MergeCuePathsError.notADirectory(path) }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    private static func verifyOwnedDirectory(_ url: URL) throws {
        let path = fileSystemPath(url)
        var info = stat()
        guard lstat(path, &info) == 0 else { throw MergeCuePathsError.notADirectory(path) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw MergeCuePathsError.notADirectory(path) }
        guard info.st_uid == getuid() else { throw MergeCuePathsError.insecureDirectory(path) }
    }
}

/// Errors from `MergeCuePaths.ensureDirectories`.
public enum MergeCuePathsError: Error, Sendable, Equatable, LocalizedError {
    case notADirectory(String)
    /// The directory is owned by another user (possible socket hijack attempt).
    case insecureDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory(let path): "\(path) exists but is not a directory."
        case .insecureDirectory(let path): "\(path) is not owned by the current user."
        }
    }
}
