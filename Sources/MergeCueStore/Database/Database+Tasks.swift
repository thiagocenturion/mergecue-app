import Foundation
import MergeCueCore

extension MergeCueDatabase {
    // MARK: Tasks

    /// Inserts a new task. Its account must exist (`StoreError.notFound`). A duplicate id throws a `.sqlite` error
    /// with `isUniqueConstraintViolation == true` — generate a new `TaskID` and retry.
    public func insertTask(_ task: MCTask) throws {
        let data = try json(task)
        try connection.transaction {
            try requireAccount(task.origin.account)
            try connection.run(
                """
                INSERT INTO tasks (id, account_id, cr_id, type, state, is_terminal, version, created_at, updated_at, data)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(task.id.rawValue), .text(task.origin.account.id), .text(task.origin.changeRequest.id),
                    .text(task.type.rawValue), .text(task.state.rawValue), .bool(task.isTerminal), .int(task.version),
                    .date(task.createdAt), .date(task.updatedAt), data,
                ]
            )
        }
    }

    public func task(_ id: TaskID) throws -> MCTask? {
        try connection.queryFirst("SELECT data FROM tasks WHERE id = ?", [.text(id.rawValue)]) {
            try decode(MCTask.self, from: $0, column: 0)
        }
    }

    /// Tasks in `states` (all tasks when nil), most recently updated first.
    public func tasks(states: Set<TaskState>?) throws -> [MCTask] {
        guard let states else {
            return try connection.query("SELECT data FROM tasks ORDER BY updated_at DESC, id") {
                try decode(MCTask.self, from: $0, column: 0)
            }
        }
        guard !states.isEmpty else { return [] }
        let sortedStates = states.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: sortedStates.count).joined(separator: ", ")
        return try connection.query(
            "SELECT data FROM tasks WHERE state IN (\(placeholders)) ORDER BY updated_at DESC, id",
            sortedStates.map(SQLiteValue.text)
        ) { try decode(MCTask.self, from: $0, column: 0) }
    }

    /// Every stored task id (for `TaskID.generate(avoiding:)`).
    public func taskIDs() throws -> Set<TaskID> {
        Set(try connection.query("SELECT id FROM tasks") { TaskID(rawValue: $0.text(0)) }.compactMap { $0 })
    }

    /// Optimistic-concurrency update (compare-and-swap on `version`): succeeds only if the stored version equals
    /// `expectedVersion`; the stored version then becomes `task.version`, which must be greater than
    /// `expectedVersion` (normally `expectedVersion + 1`).
    ///
    /// - Throws: `StoreError.versionConflict(current:)` when another writer got there first, `StoreError.notFound`
    ///   for an unknown task, `StoreError.invalidValue` when `task.version <= expectedVersion`.
    public func updateTask(_ task: MCTask, expectedVersion: Int) throws {
        guard task.version > expectedVersion else {
            throw StoreError.invalidValue(
                "task \(task.id) update must bump the version (got \(task.version), expected > \(expectedVersion))"
            )
        }
        let data = try json(task)
        try connection.transaction {
            let changed = try connection.run(
                """
                UPDATE tasks SET account_id = ?, cr_id = ?, type = ?, state = ?, is_terminal = ?, version = ?,
                    created_at = ?, updated_at = ?, data = ?
                WHERE id = ? AND version = ?
                """,
                [
                    .text(task.origin.account.id), .text(task.origin.changeRequest.id), .text(task.type.rawValue),
                    .text(task.state.rawValue), .bool(task.isTerminal), .int(task.version), .date(task.createdAt),
                    .date(task.updatedAt), data, .text(task.id.rawValue), .int(expectedVersion),
                ]
            )
            guard changed == 0 else { return }
            let current = try connection.queryFirst(
                "SELECT version FROM tasks WHERE id = ?", [.text(task.id.rawValue)]
            ) { $0.int(0) }
            guard let current else { throw StoreError.notFound }
            throw StoreError.versionConflict(current: current)
        }
    }

    // MARK: Activities (append-only)

    /// Appends a history entry. `message` and `data` values are redacted with `SecretRedactor`. The task must
    /// exist. Activities are never updated; they are deleted only by retention or together with their task.
    public func appendActivity(_ activity: TaskActivity) throws {
        var activity = activity
        activity.message = SecretRedactor.redact(activity.message)
        activity.data = activity.data.mapValues(SecretRedactor.redact)
        let data = try json(activity)
        try connection.transaction {
            try requireTask(activity.taskID)
            try connection.run(
                "INSERT INTO task_activities (id, task_id, at, kind, data) VALUES (?, ?, ?, ?, ?)",
                [.text(activity.id), .text(activity.taskID.rawValue), .date(activity.at), .text(activity.kind.rawValue), data]
            )
        }
    }

    /// A task's history, oldest first.
    public func activities(task: TaskID) throws -> [TaskActivity] {
        try connection.query(
            "SELECT data FROM task_activities WHERE task_id = ? ORDER BY at, seq", [.text(task.rawValue)]
        ) { try decode(TaskActivity.self, from: $0, column: 0) }
    }

    // MARK: Artifacts

    /// Stores an artifact (title, content and metadata values are redacted). The task must exist.
    public func insertArtifact(_ artifact: Artifact) throws {
        var artifact = artifact
        artifact.title = SecretRedactor.redact(artifact.title)
        artifact.content = SecretRedactor.redact(artifact.content)
        artifact.metadata = artifact.metadata.mapValues(SecretRedactor.redact)
        let data = try json(artifact)
        try connection.transaction {
            try requireTask(artifact.taskID)
            try connection.run(
                "INSERT INTO artifacts (id, task_id, kind, created_at, data) VALUES (?, ?, ?, ?, ?)",
                [.text(artifact.id), .text(artifact.taskID.rawValue), .text(artifact.kind.rawValue), .date(artifact.createdAt), data]
            )
        }
    }

    public func artifact(id: String) throws -> Artifact? {
        try connection.queryFirst("SELECT data FROM artifacts WHERE id = ?", [.text(id)]) {
            try decode(Artifact.self, from: $0, column: 0)
        }
    }

    /// A task's artifacts, oldest first.
    public func artifacts(task: TaskID) throws -> [Artifact] {
        try connection.query(
            "SELECT data FROM artifacts WHERE task_id = ? ORDER BY created_at, id", [.text(task.rawValue)]
        ) { try decode(Artifact.self, from: $0, column: 0) }
    }

    // MARK: Approvals

    /// Records a user decision on an action preview (the note is redacted). The task must exist.
    public func insertApproval(_ approval: ApprovalRecord) throws {
        var approval = approval
        approval.note = approval.note.map(SecretRedactor.redact)
        let data = try json(approval)
        try connection.transaction {
            try requireTask(approval.taskID)
            try connection.run(
                """
                INSERT INTO approvals (id, task_id, action, decision, decided_at, preview_fingerprint, data)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(approval.id), .text(approval.taskID.rawValue), .text(approval.action.rawValue),
                    .text(approval.decision.rawValue), .date(approval.decidedAt), .text(approval.previewFingerprint), data,
                ]
            )
        }
    }

    /// A task's approval records, oldest first.
    public func approvals(task: TaskID) throws -> [ApprovalRecord] {
        try connection.query(
            "SELECT data FROM approvals WHERE task_id = ? ORDER BY decided_at, id", [.text(task.rawValue)]
        ) { try decode(ApprovalRecord.self, from: $0, column: 0) }
    }

    /// Approval records with this preview fingerprint (idempotency guard for approved actions), oldest first.
    public func approvals(previewFingerprint: String) throws -> [ApprovalRecord] {
        try connection.query(
            "SELECT data FROM approvals WHERE preview_fingerprint = ? ORDER BY decided_at, id", [.text(previewFingerprint)]
        ) { try decode(ApprovalRecord.self, from: $0, column: 0) }
    }
}
