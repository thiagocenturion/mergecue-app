import Darwin
import Foundation

/// File-system helpers for the SQLite database file and its companions (`-wal`, `-shm`, `-journal`).
///
/// SQLite creates `-wal`/`-shm`/`-journal` with the permission bits of the main database file, so creating the
/// database as 0600 up front keeps every companion private as well.
enum DatabaseFile {
    /// Suffixes of the files SQLite keeps next to a database.
    static let companionSuffixes = ["-wal", "-shm", "-journal"]

    /// Mode of every database file MergeCue creates.
    static let fileMode: mode_t = 0o600
    /// Mode of a parent directory the store has to create.
    static let directoryMode: mode_t = 0o700

    /// Creates `path` as an empty 0600 file if it does not exist (and a missing parent directory as 0700), then
    /// tightens it — and any existing companion file — to 0600. Refuses symlinks, non-regular files and files owned
    /// by another user.
    static func preparePrivateFile(atPath path: String) throws {
        try ensureParentDirectory(of: path)
        try createOrTighten(path, create: true)
        for suffix in companionSuffixes {
            try createOrTighten(path + suffix, create: false)
        }
    }

    /// Removes the database file and its companions. Missing files are ignored.
    static func removeFiles(atPath path: String) throws {
        for candidate in [path] + companionSuffixes.map({ path + $0 }) {
            guard unlink(candidate) == 0 || errno == ENOENT else {
                throw posixError("remove \(candidate)")
            }
        }
    }

    /// Creates a new directory at `path` with mode 0700 (fails if it exists).
    static func createPrivateDirectory(atPath path: String) throws {
        guard mkdir(path, directoryMode) == 0 else { throw posixError("create \(path)") }
        guard chmod(path, directoryMode) == 0 else { throw posixError("chmod \(path)") }
    }

    /// Sets `path` (not following symlinks) to mode 0600.
    static func makePrivate(atPath path: String) throws {
        try createOrTighten(path, create: false)
    }

    /// Permission bits of `path` (tests, diagnostics).
    static func permissions(atPath path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & 0o777
    }

    // MARK: Internals

    private static func ensureParentDirectory(of path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw StoreError.sqlite(code: SQLiteResultCode.cantOpen, message: "\(parent) is not a directory")
            }
            return
        }
        do {
            try FileManager.default.createDirectory(
                atPath: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Int(directoryMode)]
            )
        } catch {
            throw StoreError.sqlite(
                code: SQLiteResultCode.cantOpen,
                message: "cannot create \(parent): \(error.localizedDescription)"
            )
        }
    }

    private static func createOrTighten(_ path: String, create: Bool) throws {
        var flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        if create { flags |= O_CREAT }
        let fd = open(path, flags, fileMode)
        guard fd >= 0 else {
            if !create, errno == ENOENT { return }
            throw posixError("open \(path)")
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError("stat \(path)") }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw StoreError.sqlite(code: SQLiteResultCode.cantOpen, message: "\(path) is not a regular file")
        }
        guard info.st_uid == getuid() else {
            throw StoreError.sqlite(code: SQLiteResultCode.cantOpen, message: "\(path) is owned by another user")
        }
        if info.st_mode & 0o777 != fileMode {
            guard fchmod(fd, fileMode) == 0 else { throw posixError("chmod \(path)") }
        }
    }

    private static func posixError(_ context: String) -> StoreError {
        let code = errno
        return .sqlite(code: SQLiteResultCode.cantOpen, message: "\(context): \(String(cString: strerror(code)))")
    }
}
