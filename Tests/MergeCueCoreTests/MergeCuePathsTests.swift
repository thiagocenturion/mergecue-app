import Foundation
import MergeCueCore
import Testing

@Suite("MergeCuePaths")
struct MergeCuePathsTests {
    @Test func honorsMergeCueHome() throws {
        let home = try Fixture.temporaryDirectory("paths")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = MergeCuePaths(environment: ["MERGECUE_HOME": home.path(percentEncoded: false)])
        let root = home.standardizedFileURL.path(percentEncoded: false)
        #expect(paths.usesCustomHome)
        #expect(paths.root.path(percentEncoded: false).hasPrefix(root.hasSuffix("/") ? String(root.dropLast()) : root))
        #expect(paths.database.lastPathComponent == "mergecue.sqlite")
        #expect(paths.database.deletingLastPathComponent().standardizedFileURL == paths.root.standardizedFileURL)
        #expect(paths.ipcDirectory.lastPathComponent == "ipc")
        #expect(paths.ipcToken.lastPathComponent == "token")
        #expect(paths.ipcToken.deletingLastPathComponent().standardizedFileURL == paths.ipcDirectory.standardizedFileURL)
        #expect(paths.worktrees.lastPathComponent == "worktrees")
        #expect(paths.handoff.lastPathComponent == "handoff")
        #expect(paths.logs.lastPathComponent == "logs")
        #expect(paths.logs.deletingLastPathComponent().standardizedFileURL == paths.root.standardizedFileURL)
    }

    @Test func defaultLocationsWithoutEnvironment() {
        let paths = MergeCuePaths(environment: [:])
        #expect(!paths.usesCustomHome)
        #expect(paths.root.path(percentEncoded: false).hasSuffix("Library/Application Support/MergeCue/")
            || paths.root.path(percentEncoded: false).hasSuffix("Library/Application Support/MergeCue"))
        #expect(paths.logs.path(percentEncoded: false).contains("Library/Logs/MergeCue"))
        // Resolving paths must not create anything; nothing here touches the real directories.
    }

    @Test func shortRootKeepsSocketInIPCDirectory() throws {
        let home = URL(filePath: "/tmp/mc-short", directoryHint: .isDirectory)
        let paths = MergeCuePaths(environment: ["MERGECUE_HOME": home.path(percentEncoded: false)])
        #expect(!paths.usesFallbackSocket)
        #expect(paths.socketPath == "/tmp/mc-short/ipc/mergecue.sock")
        #expect(paths.socketDirectory.standardizedFileURL == paths.ipcDirectory.standardizedFileURL)
    }

    @Test func longRootFallsBackToTmp() {
        let longHome = "/tmp/" + String(repeating: "a", count: 90)
        let paths = MergeCuePaths(environment: ["MERGECUE_HOME": longHome])
        #expect(paths.usesFallbackSocket)
        #expect(paths.socketPath == "/tmp/mergecue-\(getuid())/mergecue.sock")
        #expect(paths.socketPath.utf8.count <= MergeCuePaths.maxSocketPathBytes)
        #expect(paths.database.path(percentEncoded: false).hasPrefix(longHome))
    }

    @Test func boundaryIsOneHundredBytes() {
        // "/ipc/mergecue.sock" is 18 bytes: a 82-byte root gives exactly 100 bytes (kept), 83 gives 101 (fallback).
        let exact = "/tmp/" + String(repeating: "b", count: 77)
        #expect(!MergeCuePaths(environment: ["MERGECUE_HOME": exact]).usesFallbackSocket)
        #expect(MergeCuePaths(environment: ["MERGECUE_HOME": exact]).socketPath.utf8.count == 100)
        let over = exact + "c"
        #expect(MergeCuePaths(environment: ["MERGECUE_HOME": over]).usesFallbackSocket)
    }

    @Test func socketOverrideWins() {
        let paths = MergeCuePaths(environment: [
            "MERGECUE_HOME": "/tmp/" + String(repeating: "a", count: 120),
            "MERGECUE_SOCKET": "/tmp/custom/mc.sock",
        ])
        #expect(paths.usesSocketOverride)
        #expect(!paths.usesFallbackSocket)
        #expect(paths.socketPath == "/tmp/custom/mc.sock")
    }

    @Test func emptyEnvironmentValuesAreIgnored() {
        let paths = MergeCuePaths(environment: ["MERGECUE_HOME": "  ", "MERGECUE_SOCKET": ""])
        #expect(!paths.usesCustomHome)
        #expect(!paths.usesSocketOverride)
    }

    @Test func tildeIsExpanded() {
        let paths = MergeCuePaths(environment: ["MERGECUE_HOME": "~/mc-test-home"])
        #expect(!paths.root.path(percentEncoded: false).contains("~"))
        #expect(paths.root.path(percentEncoded: false).hasPrefix(NSHomeDirectory()))
    }

    /// Hermetic: the socket lives inside the temporary directory (`MERGECUE_SOCKET`), so the real shared
    /// `/tmp/mergecue-<uid>` directory a running app uses is never created or chmod-ed by tests.
    @Test func ensureDirectoriesCreatesPrivateDirectories() throws {
        let home = try Fixture.temporaryDirectory("ensure")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = MergeCuePaths(environment: [
            "MERGECUE_HOME": home.appending(path: "data").path(percentEncoded: false),
            "MERGECUE_SOCKET": home.appending(path: "data/ipc/mc.sock").path(percentEncoded: false),
        ])
        #expect(!paths.usesFallbackSocket)
        #expect(paths.socketPath.hasPrefix(MergeCuePaths.fileSystemPath(home.standardizedFileURL)))
        try paths.ensureDirectories()
        for directory in [paths.root, paths.ipcDirectory, paths.worktrees, paths.handoff, paths.logs] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path(percentEncoded: false))
            #expect(attributes[.type] as? FileAttributeType == .typeDirectory)
            #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o700, "\(directory.path)")
        }

        // Existing directories with loose permissions are tightened; running twice is fine.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.ipcDirectory.path(percentEncoded: false))
        try paths.ensureDirectories()
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.ipcDirectory.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o700)
    }

    /// The `/tmp` fallback branch, exercised against an injected parent directory.
    @Test func fallbackSocketDirectoryIsCreatedPrivateAndOwned() throws {
        let home = try Fixture.temporaryDirectory("fallback")
        defer { try? FileManager.default.removeItem(at: home) }
        let longRoot = home.appending(path: String(repeating: "r", count: 110), directoryHint: .isDirectory)
        let paths = MergeCuePaths(
            environment: ["MERGECUE_HOME": longRoot.path(percentEncoded: false)],
            fallbackSocketParent: home
        )
        #expect(paths.usesFallbackSocket)
        let expectedDirectory = MergeCuePaths.fileSystemPath(home.standardizedFileURL) + "/mergecue-\(getuid())"
        #expect(MergeCuePaths.fileSystemPath(paths.socketDirectory) == expectedDirectory)
        #expect(paths.socketPath == expectedDirectory + "/mergecue.sock")

        try paths.ensureDirectories()
        let attributes = try FileManager.default.attributesOfItem(atPath: expectedDirectory)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o700)
        #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())

        // A symlink planted in place of the directory is refused.
        try FileManager.default.removeItem(atPath: expectedDirectory)
        let elsewhere = home.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: expectedDirectory, withDestinationPath: elsewhere.path(percentEncoded: false))
        #expect(throws: MergeCuePathsError.self) { try paths.ensureDirectories() }
    }

    @Test func defaultFallbackParentIsTmp() {
        #expect(MergeCuePaths.fallbackSocketDirectory.path(percentEncoded: false).hasPrefix("/tmp/mergecue-\(getuid())"))
        #expect(MergeCuePaths(root: URL(filePath: "/tmp/" + String(repeating: "z", count: 100))).socketPath == "/tmp/mergecue-\(getuid())/mergecue.sock")
    }

    @Test func ensureDirectoriesRejectsFileInTheWay() throws {
        let home = try Fixture.temporaryDirectory("blocked")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = MergeCuePaths(root: home)
        try Data().write(to: paths.worktrees)
        #expect(throws: MergeCuePathsError.self) { try paths.ensureDirectories() }
    }
}
