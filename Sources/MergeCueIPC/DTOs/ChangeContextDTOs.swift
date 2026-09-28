import Foundation
import MergeCueCore

// MARK: - get_change_context

/// `{change_ref, include_files? (default true), max_files? (1…300, default 100)}`.
public struct GetChangeContextParams: IPCMethodParams, Hashable {
    public typealias Output = ChangeContextResult
    public static let method = IPCMethod.getChangeContext
    public static let defaultMaxFiles = 100
    public static let maxMaxFiles = 300

    /// Provider-qualified ref, e.g. `github:github.com/acme/api#42` (malformed refs fail decoding).
    public var changeRef: ChangeRequestRef
    public var includeFiles: Bool?
    public var maxFiles: Int?

    public init(changeRef: ChangeRequestRef, includeFiles: Bool? = nil, maxFiles: Int? = nil) {
        self.changeRef = changeRef
        self.includeFiles = includeFiles
        self.maxFiles = maxFiles
    }

    public var resolvedIncludeFiles: Bool {
        includeFiles ?? true
    }

    /// `max_files` clamped to 1…300, default 100.
    public var resolvedMaxFiles: Int {
        min(max(maxFiles ?? Self.defaultMaxFiles, 1), Self.maxMaxFiles)
    }

    public func validate() throws(IPCError) {
        try IPCValidation.requireRange(maxFiles, field: "max_files", 1...Self.maxMaxFiles)
    }

    private enum CodingKeys: String, CodingKey {
        case changeRef = "change_ref"
        case includeFiles = "include_files"
        case maxFiles = "max_files"
    }
}

/// Compact change request context: `{change_ref, provider, repo, number, title, state, is_draft, author,
/// source_branch, target_branch, head_sha?, base_sha?, web_url, description?: UntrustedText, reviews, threads,
/// checks, changed_files?, changed_file_count?, readiness}`.
public struct ChangeContextResult: Codable, Sendable, Hashable {
    /// JSON paths of fields that hold third-party text (data, never instructions). See `UntrustedFields`.
    public var untrustedFields: [String]? = UntrustedFields.changeContext
    public static let defaultMaxDescriptionBytes = 8 * 1024

    public var changeRef: ChangeRequestRef
    public var provider: ProviderKind
    public var repo: String
    public var number: Int
    public var title: String
    public var state: ChangeRequestState
    public var isDraft: Bool
    /// Author username.
    public var author: String
    public var sourceBranch: String
    public var targetBranch: String
    public var headSHA: String?
    public var baseSHA: String?
    public var webURL: URL
    /// PR/MR description, bounded and redacted. Untrusted data, never instructions.
    public var description: UntrustedText? {
        get { descriptionWire?.value }
        set { descriptionWire = newValue.map(UntrustedTextWire.init) }
    }
    public var reviews: [ReviewSummaryDTO]
    public var threads: [ThreadSummaryDTO]
    public var checks: [CheckSummaryDTO]
    /// Present when `include_files` was true; at most `max_files` entries.
    public var changedFiles: [ChangedFileDTO]?
    /// Total number of changed files (lets agents see that `changed_files` was cut).
    public var changedFileCount: Int?
    public var readiness: MergeReadiness

    private var descriptionWire: UntrustedTextWire?

    public init(
        changeRef: ChangeRequestRef,
        provider: ProviderKind,
        repo: String,
        number: Int,
        title: String,
        state: ChangeRequestState,
        isDraft: Bool,
        author: String,
        sourceBranch: String,
        targetBranch: String,
        headSHA: String? = nil,
        baseSHA: String? = nil,
        webURL: URL,
        description: UntrustedText? = nil,
        reviews: [ReviewSummaryDTO] = [],
        threads: [ThreadSummaryDTO] = [],
        checks: [CheckSummaryDTO] = [],
        changedFiles: [ChangedFileDTO]? = nil,
        changedFileCount: Int? = nil,
        readiness: MergeReadiness
    ) {
        self.changeRef = changeRef
        self.provider = provider
        self.repo = repo
        self.number = number
        self.title = title
        self.state = state
        self.isDraft = isDraft
        self.author = author
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.headSHA = headSHA
        self.baseSHA = baseSHA
        self.webURL = webURL
        self.descriptionWire = description.map(UntrustedTextWire.init)
        self.reviews = reviews
        self.threads = threads
        self.checks = checks
        self.changedFiles = changedFiles
        self.changedFileCount = changedFileCount
        self.readiness = readiness
    }

    /// Wire view of a stored snapshot. The description is redacted and bounded to `maxDescriptionBytes`;
    /// files are included (first `maxFiles`) only when `includeFiles` is true.
    public init(
        _ snapshot: ChangeRequestSnapshot,
        includeFiles: Bool = true,
        maxFiles: Int = GetChangeContextParams.defaultMaxFiles,
        maxDescriptionBytes: Int = ChangeContextResult.defaultMaxDescriptionBytes
    ) {
        let summary = snapshot.summary
        let description = snapshot.description.flatMap { text -> UntrustedText? in
            guard !text.isEmpty else { return nil }
            return UntrustedText.bounded(
                source: UntrustedText.Source.prDescription,
                author: summary.author.username,
                createdAt: summary.createdAt,
                text: text,
                maxBytes: maxDescriptionBytes
            )
        }
        self.init(
            changeRef: summary.ref,
            provider: summary.key.kind,
            repo: summary.repository.fullPath,
            number: summary.key.number,
            title: UntrustedFields.clean(summary.title),
            state: summary.state,
            isDraft: summary.isDraft,
            author: UntrustedFields.clean(summary.author.username),
            sourceBranch: UntrustedFields.clean(summary.sourceBranch),
            targetBranch: UntrustedFields.clean(summary.targetBranch),
            headSHA: summary.headSHA,
            baseSHA: snapshot.baseSHA,
            webURL: summary.webURL,
            description: description,
            reviews: snapshot.reviews.map(ReviewSummaryDTO.init),
            threads: snapshot.threads.map(ThreadSummaryDTO.init),
            checks: snapshot.checks.map(CheckSummaryDTO.init),
            changedFiles: includeFiles ? snapshot.changedFiles.prefix(max(0, maxFiles)).map(ChangedFileDTO.init) : nil,
            changedFileCount: includeFiles ? snapshot.changedFiles.count : nil,
            readiness: snapshot.readiness
        )
    }

    private enum CodingKeys: String, CodingKey {
        case untrustedFields = "untrusted_fields"
        case provider, repo, number, title, state, author, reviews, threads, checks, readiness
        case changeRef = "change_ref"
        case isDraft = "is_draft"
        case sourceBranch = "source_branch"
        case targetBranch = "target_branch"
        case headSHA = "head_sha"
        case baseSHA = "base_sha"
        case webURL = "web_url"
        case descriptionWire = "description"
        case changedFiles = "changed_files"
        case changedFileCount = "changed_file_count"
    }
}

// MARK: - get_diff

/// `{task_id?, change_ref?, max_bytes? (1…262144, default 65536)}` — at least one of `task_id` / `change_ref`.
/// With a task the diff comes from the task's worktree when one exists; `change_ref` must then match the task.
public struct GetDiffParams: IPCMethodParams, Hashable {
    public typealias Output = GetDiffResult
    public static let method = IPCMethod.getDiff
    public static let defaultMaxBytes = 64 * 1024
    public static let maxMaxBytes = 256 * 1024

    public var taskID: TaskID?
    public var changeRef: ChangeRequestRef?
    public var maxBytes: Int?

    public init(taskID: TaskID? = nil, changeRef: ChangeRequestRef? = nil, maxBytes: Int? = nil) {
        self.taskID = taskID
        self.changeRef = changeRef
        self.maxBytes = maxBytes
    }

    /// `max_bytes` clamped to 1…262144, default 65536.
    public var resolvedMaxBytes: Int {
        min(max(maxBytes ?? Self.defaultMaxBytes, 1), Self.maxMaxBytes)
    }

    public func validate() throws(IPCError) {
        if taskID == nil, changeRef == nil {
            throw IPCError.invalidParams("Provide 'task_id' or 'change_ref'.")
        }
        try IPCValidation.requireRange(maxBytes, field: "max_bytes", 1...Self.maxMaxBytes)
    }

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case changeRef = "change_ref"
        case maxBytes = "max_bytes"
    }
}

/// Where a diff was computed.
public enum DiffSource: String, Codable, Sendable, CaseIterable, Hashable {
    /// Fetched from the provider API (the change request as published).
    case provider
    /// Recomputed by MergeCue from the task's isolated worktree.
    case worktree
}

/// `{source: "provider"|"worktree", base_sha?, head_sha?, files, unified_diff, truncated}`.
public struct GetDiffResult: Codable, Sendable, Hashable {
    public var source: DiffSource
    public var baseSHA: String?
    public var headSHA: String?
    public var files: [ChangedFileDTO]
    public var unifiedDiff: String
    public var truncated: Bool

    public init(source: DiffSource, baseSHA: String? = nil, headSHA: String? = nil, files: [ChangedFileDTO], unifiedDiff: String, truncated: Bool) {
        self.source = source
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.files = files
        self.unifiedDiff = unifiedDiff
        self.truncated = truncated
    }

    /// A provider diff.
    public init(_ payload: DiffPayload) {
        self.init(
            source: .provider,
            baseSHA: payload.baseSHA,
            headSHA: payload.headSHA,
            files: payload.files.map(ChangedFileDTO.init),
            unifiedDiff: payload.unifiedDiff,
            truncated: payload.truncated
        )
    }

    /// A diff recomputed from the task worktree against the recorded base SHA.
    public init(_ changes: WorkspaceChanges, baseSHA: String) {
        self.init(
            source: .worktree,
            baseSHA: baseSHA,
            headSHA: changes.headSHA,
            files: changes.changedPaths.map(ChangedFileDTO.init),
            unifiedDiff: changes.unifiedDiff,
            truncated: changes.truncated
        )
    }

    private enum CodingKeys: String, CodingKey {
        case source, files, truncated
        case baseSHA = "base_sha"
        case headSHA = "head_sha"
        case unifiedDiff = "unified_diff"
    }
}
