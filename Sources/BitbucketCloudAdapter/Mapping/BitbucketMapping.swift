import Foundation
import MergeCueCore
import MergeCueNetworking

/// Converts Bitbucket payloads into Core values for one account.
struct BitbucketMapper: Sendable {
    let instance: ProviderInstance
    let account: AccountKey

    // MARK: People

    func person(_ account: BBAccount?) -> Person {
        guard let account else {
            return Person(remoteID: "", username: "unknown", displayName: "Unknown user")
        }
        let uuid = BitbucketIdentifiers.normalizedUUID(account.uuid) ?? account.accountID ?? ""
        let username = account.nickname ?? account.username ?? account.displayName ?? account.accountID ?? "unknown"
        return Person(
            remoteID: uuid,
            username: username,
            displayName: account.displayName,
            avatarURL: account.links?.avatar?.href.flatMap(URL.init(string:)),
            isBot: account.type == "app_user"
        )
    }

    // MARK: Repositories

    /// HTTPS + SSH clone URLs: Bitbucket's `links.clone` when present, otherwise derived from the full name.
    func cloneURLs(fullName: String, links: [BBLink]?) -> [String] {
        let provided = (links ?? []).sorted { ($0.name ?? "") < ($1.name ?? "") }.compactMap(\.href)
        if !provided.isEmpty {
            // Never keep a username embedded by Bitbucket in the HTTPS clone URL (`https://user@bitbucket.org/…`).
            return provided.map(CanonicalRemote.sanitizedURL)
        }
        let host = instance.webURL.host(percentEncoded: false) ?? "bitbucket.org"
        return ["\(instance.webURL.absoluteString.trimmingSuffix("/"))/\(fullName).git", "git@\(host):\(fullName).git"]
    }

    func repositoryWebURL(fullName: String, html: String?) -> URL {
        if let html, let url = URL(string: html) { return url }
        return instance.webURL.appending(path: fullName)
    }

    func repository(_ repo: BBRepository) -> Repository? {
        guard let uuid = BitbucketIdentifiers.normalizedUUID(repo.uuid), let fullName = repo.fullName,
              let path = BitbucketRepoPath(fullName: fullName)
        else { return nil }
        return Repository(
            key: RepoKey(account: account, remoteRepoID: uuid),
            namespacePath: path.workspace,
            name: repo.name ?? path.slug,
            fullPath: fullName,
            webURL: repositoryWebURL(fullName: fullName, html: repo.links?.html?.href),
            cloneURLs: cloneURLs(fullName: fullName, links: repo.links?.clone),
            defaultBranch: repo.mainbranch?.name,
            isPrivate: repo.isPrivate ?? true
        )
    }

    // MARK: Pull requests

    static func state(_ raw: String?) -> ChangeRequestState {
        switch raw?.uppercased() {
        case "MERGED": .merged
        case "DECLINED", "SUPERSEDED": .closed
        default: .open
        }
    }

    func changeRequestKey(repoUUID: String, id: Int) -> ChangeRequestKey {
        ChangeRequestKey(repo: RepoKey(account: account, remoteRepoID: repoUUID), remoteID: String(id), number: id)
    }

    /// Builds a summary from a pull request object (listing or detail). The destination repository owns the PR.
    func summary(_ pr: BBPullRequest, knownRepository: Repository? = nil, currentUserUUID: String?) throws -> ChangeRequestSummary {
        guard let destination = pr.destination?.repository,
              let repoUUID = BitbucketIdentifiers.normalizedUUID(destination.uuid ?? knownRepository?.key.remoteRepoID)
        else {
            throw ProviderError.decoding("Bitbucket pull request \(pr.id) has no destination repository.")
        }
        let repository: Repository
        if let knownRepository, BitbucketIdentifiers.sameUUID(knownRepository.key.remoteRepoID, repoUUID) {
            repository = knownRepository
        } else if let mapped = self.repository(destination) {
            repository = mapped
        } else {
            throw ProviderError.decoding("Bitbucket pull request \(pr.id) has an invalid destination repository.")
        }
        let updatedAt = pr.updatedOn.flatMap(ProviderDateParser.parse) ?? pr.createdOn ?? Date(timeIntervalSince1970: 0)
        let webURL = pr.links?.html?.href.flatMap(URL.init(string:))
            ?? repository.webURL.appending(path: "pull-requests/\(pr.id)")

        var involvement: Set<Involvement> = []
        if let me = currentUserUUID {
            if BitbucketIdentifiers.sameUUID(pr.author?.uuid, me) { involvement.insert(.authored) }
            let reviewerUUIDs = (pr.reviewers ?? []).map(\.uuid)
                + (pr.participants ?? []).filter { $0.role == "REVIEWER" }.map(\.user?.uuid)
            if reviewerUUIDs.contains(where: { BitbucketIdentifiers.sameUUID($0, me) }) {
                involvement.insert(.reviewRequested)
            } else if (pr.participants ?? []).contains(where: { BitbucketIdentifiers.sameUUID($0.user?.uuid, me) }),
                      !involvement.contains(.authored)
            {
                involvement.insert(.participated)
            }
        }
        return ChangeRequestSummary(
            key: changeRequestKey(repoUUID: repoUUID, id: pr.id),
            repository: repository,
            title: pr.title ?? "",
            author: person(pr.author),
            state: Self.state(pr.state),
            isDraft: pr.draft ?? false,
            sourceBranch: pr.source?.branch?.name ?? "",
            targetBranch: pr.destination?.branch?.name ?? "",
            headSHA: pr.source?.commit?.hash,
            createdAt: pr.createdOn ?? updatedAt,
            updatedAt: updatedAt,
            webURL: webURL,
            involvement: involvement,
            versionToken: pr.updatedOn
        )
    }

    func headInfo(_ pr: BBPullRequest) -> HeadInfo {
        HeadInfo(
            headSHA: pr.source?.commit?.hash,
            state: Self.state(pr.state),
            isDraft: pr.draft ?? false,
            updatedAt: pr.updatedOn.flatMap(ProviderDateParser.parse) ?? pr.createdOn ?? Date(timeIntervalSince1970: 0)
        )
    }

    /// The pull request's source repository (a fork when its UUID differs from the destination's).
    func sourceRepository(_ pr: BBPullRequest) -> SourceRepositoryInfo? {
        guard let source = pr.source?.repository, let fullName = source.fullName else { return nil }
        let isFork = !BitbucketIdentifiers.sameUUID(source.uuid, pr.destination?.repository?.uuid)
        return SourceRepositoryInfo(
            fullPath: fullName,
            cloneURLs: cloneURLs(fullName: fullName, links: source.links?.clone),
            remoteID: BitbucketIdentifiers.normalizedUUID(source.uuid),
            isFork: isFork
        )
    }

    // MARK: Reviewers

    /// Reviewers (requested + participants with role REVIEWER) and their verdicts. Bitbucket exposes no required
    /// reviewers through the 2.0 API, so `isRequired` stays nil.
    func reviewers(_ pr: BBPullRequest) -> [Reviewer] {
        var order: [String] = []
        var byUUID: [String: Reviewer] = [:]
        for account in pr.reviewers ?? [] {
            guard let uuid = BitbucketIdentifiers.normalizedUUID(account.uuid) else { continue }
            if byUUID[uuid] == nil { order.append(uuid) }
            byUUID[uuid] = Reviewer(person: person(account), state: .pending)
        }
        for participant in pr.participants ?? [] {
            guard let uuid = BitbucketIdentifiers.normalizedUUID(participant.user?.uuid) else { continue }
            let isReviewer = participant.role == "REVIEWER" || byUUID[uuid] != nil
            let verdict = Self.reviewState(participant)
            guard isReviewer || verdict == .approved || verdict == .changesRequested else { continue }
            if byUUID[uuid] == nil { order.append(uuid) }
            byUUID[uuid] = Reviewer(person: person(participant.user), state: verdict)
        }
        return order.compactMap { byUUID[$0] }
    }

    static func reviewState(_ participant: BBParticipant) -> ReviewState {
        if participant.state == "changes_requested" { return .changesRequested }
        if participant.approved == true || participant.state == "approved" { return .approved }
        return participant.participatedOn == nil ? .pending : .commented
    }

    /// Current approvals / change requests as `Review`s (Bitbucket has no review objects). The id is
    /// `<state>:<user uuid>` so a renewed verdict after a withdrawal is recognised through `submittedAt`.
    func reviews(_ pr: BBPullRequest) -> [Review] {
        (pr.participants ?? []).compactMap { participant in
            let state = Self.reviewState(participant)
            guard state == .approved || state == .changesRequested,
                  let uuid = BitbucketIdentifiers.normalizedUUID(participant.user?.uuid)
            else { return nil }
            return Review(
                remoteID: "\(state.rawValue):\(uuid)",
                author: person(participant.user),
                state: state,
                submittedAt: participant.participatedOn,
                commitSHA: nil
            )
        }
    }

    func approvals(_ pr: BBPullRequest) -> ApprovalStatus {
        let approved = (pr.participants ?? []).filter { $0.approved == true }.map { person($0.user) }
        // Required approval counts live in branch restrictions (admin-only) → unknown.
        return ApprovalStatus(approvedBy: approved, requiredCount: nil, isSatisfied: nil)
    }

    // MARK: Commits and files

    func commit(_ commit: BBCommit) -> CommitInfo {
        let title = (commit.message ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let author = commit.author?.user?.displayName ?? commit.author?.raw
        return CommitInfo(sha: commit.hash, title: title, author: author, authoredAt: commit.date)
    }

    func changedFile(_ stat: BBDiffStat) -> ChangedFile? {
        let newPath = stat.new?.path
        let oldPath = stat.old?.path
        guard let path = newPath ?? oldPath else { return nil }
        let status: FileChangeStatus = switch stat.status {
        case "added": .added
        case "removed": .removed
        case "modified": .modified
        case "renamed": .renamed
        default: .unknown
        }
        return ChangedFile(
            path: path,
            oldPath: status == .renamed ? oldPath : nil,
            status: status,
            additions: stat.linesAdded,
            deletions: stat.linesRemoved
        )
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var value = self
        while !suffix.isEmpty, value.hasSuffix(suffix) { value.removeLast(suffix.count) }
        return value
    }
}
