import Foundation
import MergeCueCore
import MergeCueNetworking

/// Pure GitLab JSON → Core mappings (no I/O).
enum GitLabMapping {
    // MARK: People

    static func person(_ user: GLUser) -> Person {
        Person(
            remoteID: String(user.id),
            username: user.username,
            displayName: user.name,
            avatarURL: user.avatarUrl.flatMap(URL.init(string:)),
            isBot: user.bot ?? isBotUsername(user.username)
        )
    }

    /// GitLab project/group access tokens and service accounts: `project_123_bot_<hash>`, `group_9_bot`, `*_bot`,
    /// `*-bot` (used when the payload has no `bot` flag).
    static func isBotUsername(_ username: String) -> Bool {
        let lower = username.lowercased()
        if lower.hasSuffix("_bot") || lower.hasSuffix("-bot") || lower.hasSuffix("[bot]") { return true }
        for prefix in ["project_", "group_"] where lower.hasPrefix(prefix) {
            let rest = lower.dropFirst(prefix.count)
            let digits = rest.prefix(while: \.isNumber)
            if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix("_bot") { return true }
        }
        return false
    }

    static func providerUser(_ user: GLUser, scopes: [String]) -> ProviderUser {
        ProviderUser(
            remoteID: String(user.id),
            username: user.username,
            displayName: user.name,
            avatarURL: user.avatarUrl.flatMap(URL.init(string:)),
            grantedScopes: scopes,
            email: user.email ?? user.publicEmail.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: Namespaces and repositories

    static func namespace(_ group: GLGroup) -> Namespace {
        Namespace(id: "group:\(group.id)", path: group.fullPath, displayName: group.fullName ?? group.name, kind: .group)
    }

    static func userNamespace(_ user: GLUser) -> Namespace {
        Namespace(id: "user:\(user.id)", path: user.username, displayName: user.name ?? user.username, kind: .user)
    }

    static func repository(_ project: GLProject, account: AccountKey) -> Repository {
        let fullPath = project.pathWithNamespace
        return Repository(
            key: RepoKey(account: account, remoteRepoID: String(project.id)),
            namespacePath: project.namespace?.fullPath ?? parentPath(of: fullPath),
            name: project.path,
            fullPath: fullPath,
            webURL: URL(string: project.webUrl) ?? account.fallbackWebURL(path: fullPath),
            cloneURLs: [project.httpUrlToRepo, project.sshUrlToRepo].compactMap { $0 }.filter { !$0.isEmpty }
                .map(CanonicalRemote.sanitizedURL),
            defaultBranch: project.defaultBranch,
            isPrivate: project.visibility.map { $0 != "public" } ?? true
        )
    }

    /// Repository derived from a merge request list item without an extra request: the path comes from
    /// `references.full` (`group/sub/project!42`) or the MR `web_url`; clone URLs are filled in by `hydrate`.
    static func repository(forListItem mr: GLMergeRequest, account: AccountKey, instance: ProviderInstance) -> Repository {
        let fullPath = projectPath(of: mr, instance: instance) ?? "project-\(mr.projectId)"
        let webURL = projectWebURL(of: mr) ?? instance.webURL.appending(path: fullPath)
        return Repository(
            key: RepoKey(account: account, remoteRepoID: String(mr.projectId)),
            namespacePath: parentPath(of: fullPath),
            name: fullPath.split(separator: "/").last.map(String.init) ?? fullPath,
            fullPath: fullPath,
            webURL: webURL
        )
    }

    /// `group/sub/project` from `references.full` (`group/sub/project!42`), else from `web_url` (minus the
    /// instance's relative URL root, e.g. `https://host/gitlab/…`).
    static func projectPath(of mr: GLMergeRequest, instance: ProviderInstance) -> String? {
        if let full = mr.references?.full, let bang = full.lastIndex(of: "!") {
            let path = String(full[..<bang])
            if path.contains("/") { return path }
        }
        guard let url = URL(string: mr.webUrl), let marker = url.path.range(of: "/-/merge_requests/") else { return nil }
        var path = String(url.path[..<marker.lowerBound])
        let root = instance.webURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !root.isEmpty, path.hasPrefix(root + "/") {
            path = String(path.dropFirst(root.count + 1))
        }
        return path.isEmpty ? nil : path
    }

    /// Project web URL: the MR `web_url` without `/-/merge_requests/<iid>`.
    static func projectWebURL(of mr: GLMergeRequest) -> URL? {
        guard let range = mr.webUrl.range(of: "/-/merge_requests/") else { return nil }
        return URL(string: String(mr.webUrl[..<range.lowerBound]))
    }

    static func parentPath(of fullPath: String) -> String {
        guard let slash = fullPath.lastIndex(of: "/") else { return "" }
        return String(fullPath[..<slash])
    }

    // MARK: Merge requests

    static func state(_ gitlabState: String) -> ChangeRequestState {
        switch gitlabState {
        case "merged": .merged
        case "closed": .closed
        default: .open  // `opened`, `locked` (a transient state while merging)
        }
    }

    /// `draft` (GitLab ≥ 13.x), the deprecated `work_in_progress`, or a draft/WIP title prefix.
    static func isDraft(_ mr: GLMergeRequest) -> Bool {
        if let draft = mr.draft { return draft }
        if let wip = mr.workInProgress { return wip }
        return hasDraftTitlePrefix(mr.title)
    }

    static func hasDraftTitlePrefix(_ title: String) -> Bool {
        let lower = title.trimmingCharacters(in: .whitespaces).lowercased()
        return ["draft:", "[draft]", "(draft)", "wip:", "[wip]"].contains { lower.hasPrefix($0) }
    }

    static func headSHA(_ mr: GLMergeRequest) -> String? {
        mr.diffRefs?.headSha ?? mr.sha
    }

    static func summary(
        _ mr: GLMergeRequest,
        repository: Repository,
        involvement: Set<Involvement>,
        currentUserID: String?
    ) -> ChangeRequestSummary {
        var involvement = involvement
        if let currentUserID {
            if String(mr.author.id) == currentUserID { involvement.insert(.authored) }
            if mr.reviewers?.contains(where: { String($0.id) == currentUserID }) == true { involvement.insert(.reviewRequested) }
            if mr.assignees?.contains(where: { String($0.id) == currentUserID }) == true { involvement.insert(.assigned) }
        }
        let updatedAt = ProviderDateParser.parse(mr.updatedAt) ?? mr.createdAt
        return ChangeRequestSummary(
            key: ChangeRequestKey(repo: repository.key, remoteID: String(mr.id), number: mr.iid),
            repository: repository,
            title: mr.title,
            author: person(mr.author),
            state: state(mr.state),
            isDraft: isDraft(mr),
            sourceBranch: mr.sourceBranch,
            targetBranch: mr.targetBranch,
            headSHA: headSHA(mr),
            createdAt: mr.createdAt,
            updatedAt: updatedAt,
            webURL: URL(string: mr.webUrl) ?? repository.webURL,
            involvement: involvement,
            versionToken: mr.updatedAt
        )
    }

    // MARK: Reviews and approvals

    static func reviewState(_ gitlabState: String?) -> ReviewState {
        switch gitlabState {
        case "approved": .approved
        case "requested_changes": .changesRequested
        case "reviewed": .commented
        case "unapproved": .dismissed
        default: .pending  // `unreviewed`, `review_started`, unknown
        }
    }

    static func reviewers(_ entries: [GLReviewerEntry]) -> [Reviewer] {
        entries.map { Reviewer(person: person($0.user), state: reviewState($0.state)) }
    }

    static func approvals(_ approvals: GLApprovals?) -> ApprovalStatus {
        guard let approvals else { return .unknown }
        let satisfied: Bool? = approvals.approvalsLeft.map { $0 <= 0 }
        return ApprovalStatus(
            approvedBy: (approvals.approvedBy ?? []).map { person($0.user) },
            requiredCount: approvals.approvalsRequired,
            isSatisfied: satisfied
        )
    }

    /// GitLab has no review objects: approvals and `requested_changes` reviewer states become `Review`s so Sync
    /// can derive `approval` / `change_requested` events.
    static func reviews(approvals: GLApprovals?, reviewers: [GLReviewerEntry], headSHA: String?) -> [Review] {
        var result: [Review] = []
        for approval in approvals?.approvedBy ?? [] {
            result.append(Review(
                remoteID: "approved:\(approval.user.id)",
                author: person(approval.user),
                state: .approved,
                submittedAt: approval.approvedAt
            ))
        }
        for entry in reviewers where entry.state == "requested_changes" {
            result.append(Review(
                remoteID: "requested_changes:\(entry.user.id)",
                author: person(entry.user),
                state: .changesRequested,
                commitSHA: headSHA
            ))
        }
        return result
    }

    // MARK: Commits and files

    static func commit(_ commit: GLCommit) -> CommitInfo {
        CommitInfo(sha: commit.id, title: commit.title, author: commit.authorName, authoredAt: commit.authoredDate)
    }

    static func changedFile(_ file: GLDiffFile) -> ChangedFile {
        let status: FileChangeStatus = if file.newFile { .added }
            else if file.deletedFile { .removed }
            else if file.renamedFile { .renamed }
            else { .modified }
        let counts = file.diff.map(lineCounts)
        let truncatedDiff = file.tooLarge == true || file.collapsed == true
        return ChangedFile(
            path: file.newPath,
            oldPath: file.oldPath != file.newPath ? file.oldPath : nil,
            status: status,
            additions: truncatedDiff ? nil : counts?.additions,
            deletions: truncatedDiff ? nil : counts?.deletions
        )
    }

    static func lineCounts(_ diff: String) -> (additions: Int, deletions: Int) {
        var additions = 0
        var deletions = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { additions += 1 } else if line.hasPrefix("-") { deletions += 1 }
        }
        return (additions, deletions)
    }
}

extension AccountKey {
    /// `https://<host>/<path>` used only when GitLab omits a web URL.
    func fallbackWebURL(path: String) -> URL {
        URL(string: "https://\(host)/\(path)") ?? URL(staticString: "https://gitlab.com")
    }
}
