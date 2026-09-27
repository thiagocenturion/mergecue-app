import Foundation
import MergeCueCore

/// Deterministic sample values shared by the Core tests.
enum Fixture {
    /// 2026-01-01T00:00:00Z
    static let date = Date(timeIntervalSince1970: 1_767_225_600)

    static let githubAccount = AccountKey(kind: .github, host: "github.com", remoteUserID: "123")
    static let gitlabAccount = AccountKey(kind: .gitlab, host: "gitlab.com", remoteUserID: "123")
    static let bitbucketAccount = AccountKey(kind: .bitbucketCloud, host: "bitbucket.org", remoteUserID: "{b1c2}")

    static func repoKey(_ account: AccountKey = githubAccount, id: String = "456") -> RepoKey {
        RepoKey(account: account, remoteRepoID: id)
    }

    static func changeRequestKey(_ account: AccountKey = githubAccount, repoID: String = "456", remoteID: String = "789", number: Int = 42) -> ChangeRequestKey {
        ChangeRequestKey(repo: repoKey(account, id: repoID), remoteID: remoteID, number: number)
    }

    static func person(_ username: String = "reviewer", id: String = "900", isBot: Bool = false) -> Person {
        Person(remoteID: id, username: username, displayName: username.capitalized, isBot: isBot)
    }

    static func repository(_ key: RepoKey = repoKey(), fullPath: String = "acme/payments-api") -> Repository {
        Repository(
            key: key,
            namespacePath: String(fullPath.split(separator: "/").dropLast().joined(separator: "/")),
            name: String(fullPath.split(separator: "/").last ?? ""),
            fullPath: fullPath,
            webURL: URL(string: "https://github.com/\(fullPath)")!,
            cloneURLs: ["https://github.com/\(fullPath).git", "git@github.com:\(fullPath).git"],
            defaultBranch: "main",
            isPrivate: true
        )
    }

    static func summary(_ key: ChangeRequestKey = changeRequestKey(), fullPath: String = "acme/payments-api") -> ChangeRequestSummary {
        ChangeRequestSummary(
            key: key,
            repository: repository(key.repo, fullPath: fullPath),
            title: "Add retries",
            author: person("mona-dev", id: "123"),
            sourceBranch: "feature/retries",
            targetBranch: "main",
            headSHA: "abc123",
            createdAt: date,
            updatedAt: date,
            webURL: URL(string: "https://github.com/\(fullPath)/pull/\(key.number)")!,
            involvement: [.authored]
        )
    }

    static func event(
        type: ChangeEventType = .reviewComment,
        account: AccountKey = githubAccount,
        repoFullPath: String = "acme/payments-api",
        actor: Person? = person(),
        isFromCurrentUser: Bool = false,
        isBaseline: Bool = false,
        commentKind: CommentKind? = nil,
        objectID: String = "c1"
    ) -> ChangeEvent {
        ChangeEvent(
            type: type,
            changeRequest: changeRequestKey(account),
            repoFullPath: repoFullPath,
            title: "Add retries",
            objectID: objectID,
            objectVersion: "1",
            occurredAt: date,
            detectedAt: date,
            actor: actor,
            isFromCurrentUser: isFromCurrentUser,
            isBaseline: isBaseline,
            commentKind: commentKind,
            summary: "Reviewer commented"
        )
    }

    /// The production wire coder (golden JSON in these tests is the IPC/MCP representation).
    static func encoder() -> JSONEncoder {
        MergeCueCoding.wireEncoder()
    }

    static func decoder() -> JSONDecoder {
        MergeCueCoding.wireDecoder()
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder().encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try decoder().decode(type, from: Data(json.utf8))
    }

    static func roundTrip<T: Codable>(_ value: T) throws -> T {
        try decoder().decode(T.self, from: try encoder().encode(value))
    }

    /// A fresh, empty temporary directory (never the user's real MergeCue data).
    static func temporaryDirectory(_ name: String = "core") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "mergecue-tests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
