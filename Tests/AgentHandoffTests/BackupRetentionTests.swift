import Foundation
import MergeCueCore
import Testing
@testable import AgentHandoff

/// S10: agent-config backups are bounded (last 3 per agent) and can be deleted; nothing else is touched.
@Suite("Agent config backup retention")
struct BackupRetentionTests {
    typealias Sandbox = RegistrarTests.Sandbox

    @Test func registerUnregisterCyclesKeepOnlyTheLastThreeBackupsPerAgent() async throws {
        let box = try Sandbox()
        try Data("{\"numStartups\": 3}\n".utf8).write(to: box.claudeConfig)
        let registrar = box.registrar()
        var last: URL?
        for _ in 0..<3 {
            let add = try box.plan(.claudeCode)
            _ = try await registrar.register(add, consent: await RegistrationConsent.userConfirmed(add, at: fixedNow))
            let remove = try box.plan(.claudeCode, action: .unregister)
            last = try await registrar.unregister(remove, consent: await RegistrationConsent.userConfirmed(remove, at: fixedNow)).backup?.directory
        }
        let kept = AgentConfigBackups.list(paths: box.paths)
        #expect(kept.count == AgentConfigBackups.keepPerAgent)
        #expect(kept.allSatisfy { $0.agent == .claudeCode })
        // The backup written last is always kept (it holds the config just before the latest change).
        let lines = box.logLines().filter { $0.hasPrefix("mcp remove") }
        #expect(lines.count == 3)
        #expect(Set(kept.map(\.directory)).count == 3)
        let newest = try #require(last)
        #expect(kept.contains { MergeCuePaths.fileSystemPath($0.directory) == MergeCuePaths.fileSystemPath(newest) })
    }

    @Test func deleteAllRemovesOnlyMergeCueBackups() throws {
        let box = try Sandbox()
        let root = AgentConfigBackups.root(box.paths)
        func make(_ name: String, manifest: Bool = true) throws {
            let directory = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if manifest { try Data("{}".utf8).write(to: directory.appending(path: "manifest.json")) }
        }
        try make("claude-20260101T000000Z")
        try make("claude-20260102T000000Z")
        try make("codex-20260101T000000Z")
        try make("codex-20260101T000000Z-1")
        try make("notes", manifest: false)
        try make("claude-20260103T000000Z", manifest: false)
        let outside = box.root.appending(path: "precious", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: outside.appending(path: "manifest.json"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "claude-20260104T000000Z"), withDestinationURL: outside)

        let listed = AgentConfigBackups.list(paths: box.paths)
        #expect(listed.map(\.directory.lastPathComponent) == [
            "claude-20260102T000000Z", "codex-20260101T000000Z-1", "codex-20260101T000000Z", "claude-20260101T000000Z",
        ])
        #expect(AgentConfigBackups.prune(paths: box.paths, agent: .codex, keep: 1) == 1)
        #expect(AgentConfigBackups.deleteAll(paths: box.paths) == 3)
        #expect(AgentConfigBackups.list(paths: box.paths).isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "notes").path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "claude-20260103T000000Z").path))
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: "manifest.json").path))
    }
}
