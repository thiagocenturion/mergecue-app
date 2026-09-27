import Foundation
import MergeCueCore
import Testing
@testable import MergeCueStore

@Suite("File permissions and secrets")
struct SecurityTests {
    @Test func databaseAndWALFilesArePrivate() async throws {
        let path = try StoreFixture.temporaryDatabasePath("permissions")
        let database = try MergeCueDatabase(path: path)
        try await database.upsertAccount(StoreFixture.account())
        try await database.setSetting("theme", "dark")

        // While the connection is open in WAL mode, all three files exist.
        for file in [path, path + "-wal", path + "-shm"] {
            #expect(FileManager.default.fileExists(atPath: file), "\(file) should exist")
            #expect(DatabaseFile.permissions(atPath: file) == 0o600, "\(file) must be 0600")
        }
    }

    @Test func existingLoosePermissionsAreTightened() async throws {
        let path = try StoreFixture.temporaryDatabasePath("tighten")
        do {
            let database = try MergeCueDatabase(path: path)
            try await database.upsertAccount(StoreFixture.account())
        }
        chmod(path, 0o644)
        FileManager.default.createFile(atPath: path + "-wal", contents: nil, attributes: [.posixPermissions: 0o644])

        let reopened = try MergeCueDatabase(path: path)
        #expect(DatabaseFile.permissions(atPath: path) == 0o600)
        #expect(DatabaseFile.permissions(atPath: path + "-wal") == 0o600)
        #expect(try await reopened.accounts().count == 1)
    }

    @Test func missingParentDirectoryIsCreatedPrivate() async throws {
        let root = try StoreFixture.temporaryDirectory("parent")
        let path = root.appending(path: "nested/home/mergecue.sqlite").path(percentEncoded: false)
        _ = try MergeCueDatabase(path: path)
        let parent = (path as NSString).deletingLastPathComponent
        #expect(DatabaseFile.permissions(atPath: parent) == 0o700)
        #expect(DatabaseFile.permissions(atPath: path) == 0o600)
    }

    @Test func symlinkedDatabaseFileIsRefused() throws {
        let root = try StoreFixture.temporaryDirectory("symlink")
        let target = root.appending(path: "elsewhere.sqlite").path(percentEncoded: false)
        FileManager.default.createFile(atPath: target, contents: nil)
        let link = root.appending(path: "mergecue.sqlite").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(throws: StoreError.self) {
            _ = try MergeCueDatabase(path: link)
        }
    }

    /// Runs every write path with a fake token in the places a careless store could leak it, then scans the raw
    /// database, WAL and export bytes.
    @Test func noCredentialEverReachesTheDatabaseFile() async throws {
        let token = "ghp_FAKEtokenFAKEtoken0123456789abcdefXYZ"
        let path = try StoreFixture.temporaryDatabasePath("secrets")
        let database = try MergeCueDatabase(path: path)
        let key = StoreFixture.githubAccount
        try await database.upsertAccount(StoreFixture.account(key))

        // Settings refuse credentials and secret-shaped values.
        await #expect(throws: StoreError.self) {
            try await database.setSetting("credential", Credential(secret: .bearer(token)))
        }
        await #expect(throws: StoreError.self) {
            try await database.setSetting("basic", Credential.Secret.basic(username: "mona", password: token))
        }
        await #expect(throws: StoreError.self) { try await database.setSetting("raw", "token: \(token)") }

        // Mapping remotes are sanitized; audit, activities and artifacts are redacted.
        try await database.upsertMapping(RepoMapping(
            id: "map_0000000001", repo: StoreFixture.repoKey(), repoFullPath: "acme/payments-api", checkoutPath: "/tmp/api",
            confidence: .exact, matchedRemote: "https://x-access-token:\(token)@github.com/acme/payments-api.git",
            createdAt: StoreFixture.date
        ))
        let task = StoreFixture.task()
        try await database.insertTask(task)
        try await database.appendActivity(StoreFixture.activity(message: "Authorization: Bearer \(token)"))
        try await database.insertArtifact(Artifact(
            id: "art_0000000001", taskID: task.id, kind: .logExcerpt, createdAt: StoreFixture.date, title: "CI log",
            content: "export GITHUB_TOKEN=\(token)\nerror: build failed", metadata: ["header": "Bearer \(token)"], reportedBy: .agent
        ))
        try await database.appendAudit(StoreFixture.audit("aud_1", detail: "request failed with Authorization: token \(token)"))
        try await database.insertApproval(ApprovalRecord(
            id: "apr_1", taskID: task.id, action: .postReply, decision: .approved, decidedAt: StoreFixture.date,
            previewFingerprint: "fp", note: "pasted \(token) by mistake"
        ))

        let needle = Data(token.utf8)
        let exportPath = try StoreFixture.temporaryDirectory("secrets-export").appending(path: "copy.sqlite").path(percentEncoded: false)
        try await database.exportCopy(to: exportPath)
        for file in [path, path + "-wal", path + "-shm", exportPath] {
            #expect(StoreFixture.bytes(atPath: file).range(of: needle) == nil, "token found in \(file)")
        }

        // After a checkpoint (everything folded into the main file) the token is still nowhere.
        try await database.executeForTesting("PRAGMA wal_checkpoint(TRUNCATE)")
        #expect(StoreFixture.bytes(atPath: path).range(of: needle) == nil)
        #expect(StoreFixture.bytes(atPath: path).count > 0)

        // Sanity check that the scan can see stored text at all.
        #expect(StoreFixture.bytes(atPath: path).range(of: Data("acme/payments-api".utf8)) != nil)
    }
}
