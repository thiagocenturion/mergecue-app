import Darwin
import Foundation
import MergeCueCore

/// One backup directory written by `AgentRegistrar` before it changed an agent's MCP configuration.
public struct AgentConfigBackup: Sendable, Hashable {
    public var agent: AgentKind
    public var directory: URL
    /// From the directory name (`<agent>-<UTC timestamp>[-N]`).
    public var createdAt: Date
    /// File-system birth time of the directory (orders backups made within the same second).
    var birthTime: Double = 0
}

/// Retention and deletion of agent-config backups (S10). Backups hold copies of the agent's config files (which may
/// contain other MCP servers' secrets), so MergeCue keeps only the most recent `keepPerAgent` per agent and lets
/// the owner delete them all. Only directories directly under `<root>/backups` whose name starts with a known
/// agent slug and that contain MergeCue's `manifest.json` are ever touched; symlinks are never followed.
public enum AgentConfigBackups {
    /// Backups kept per agent after each new one.
    public static let keepPerAgent = 3

    /// `<root>/backups`.
    public static func root(_ paths: MergeCuePaths) -> URL {
        paths.root.appending(path: "backups", directoryHint: .isDirectory)
    }

    /// Every MergeCue backup, newest first.
    public static func list(paths: MergeCuePaths) -> [AgentConfigBackup] {
        let rootPath = MergeCuePaths.fileSystemPath(root(paths))
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: rootPath) else { return [] }
        var result: [AgentConfigBackup] = []
        for name in names {
            guard let (agent, date) = parse(name) else { continue }
            let path = (rootPath as NSString).appendingPathComponent(name)
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let manifest = (path as NSString).appendingPathComponent("manifest.json")
            guard lstat(manifest, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            var directoryInfo = stat()
            _ = lstat(path, &directoryInfo)
            let birth = Double(directoryInfo.st_birthtimespec.tv_sec) + Double(directoryInfo.st_birthtimespec.tv_nsec) / 1e9
            result.append(AgentConfigBackup(
                agent: agent, directory: URL(filePath: path, directoryHint: .isDirectory), createdAt: date, birthTime: birth
            ))
        }
        return result.sorted { ($0.createdAt, $0.birthTime, $0.directory.path) > ($1.createdAt, $1.birthTime, $1.directory.path) }
    }

    /// Deletes all but the newest `keep` backups of `agent`; `preserving` (the backup just written) always counts
    /// as the newest. Returns how many were deleted.
    @discardableResult
    public static func prune(paths: MergeCuePaths, agent: AgentKind, keep: Int = keepPerAgent, preserving: URL? = nil) -> Int {
        func key(_ url: URL) -> String {
            let path = MergeCuePaths.fileSystemPath(url)
            return path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        let preserved = preserving.map(key)
        var backups = list(paths: paths).filter { $0.agent == agent }
        if let preserved, let index = backups.firstIndex(where: { key($0.directory) == preserved }) {
            backups.insert(backups.remove(at: index), at: 0)
        }
        return backups.dropFirst(max(0, keep)).reduce(0) { $0 + (remove($1) ? 1 : 0) }
    }

    /// Deletes every MergeCue backup. Returns how many were deleted.
    @discardableResult
    public static func deleteAll(paths: MergeCuePaths) -> Int {
        list(paths: paths).reduce(0) { $0 + (remove($1) ? 1 : 0) }
    }

    private static func remove(_ backup: AgentConfigBackup) -> Bool {
        (try? FileManager.default.removeItem(at: backup.directory)) != nil
    }

    /// `claude-code-20260927T101500Z` / `…-2` → (agent, date).
    static func parse(_ name: String) -> (AgentKind, Date)? {
        for agent in AgentKind.allCases where name.hasPrefix(agent.slug + "-") {
            let rest = name.dropFirst(agent.slug.count + 1)
            let stamp = String(rest.prefix(16))
            guard stamp.count == 16, let date = Self.formatter.date(from: stamp) else { continue }
            let suffix = rest.dropFirst(16)
            guard suffix.isEmpty || (suffix.hasPrefix("-") && suffix.dropFirst().allSatisfy(\.isNumber)) else { continue }
            return (agent, date)
        }
        return nil
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}
