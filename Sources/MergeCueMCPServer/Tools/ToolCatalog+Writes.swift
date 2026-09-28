import Foundation
import MCP
import MergeCueCore
import MergeCueIPC

extension MergeCueToolCatalog {
    /// Tools that change MergeCue's local task/rule state (`readOnlyHint: false`, `destructiveHint: false`). None of
    /// them touches a provider: remote actions only happen after the owner approves them in the app.
    static let writes: [MergeCueToolDefinition] = [
        MergeCueToolDefinition(
            ClaimTaskParams.self,
            title: "Claim task",
            description: """
                Claim a task that is waiting_for_agent (or stale) before working on it; the task becomes working. \
                Pass the version from get_task as expected_version. Returns {task_id, state, version, lease_id, \
                lease_expires_at, heartbeat_interval_seconds, checkout?}: keep the lease_id for every later write and \
                renew it with heartbeat/update_task before it expires. Errors: version_conflict (the task changed or \
                another agent claimed it — re-read with get_task), terminal_state (finished tasks cannot be \
                resurrected), invalid_transition.
                """,
            inputSchema: JSONSchema.object([
                "task_id": SchemaFields.taskID(),
                "agent_name": JSONSchema.string("Who is claiming, e.g. \"Claude Code\" or \"Codex\" (shown to the owner).", minLength: 1, maxLength: IPCLimits.maxAgentNameLength),
                "run_id": JSONSchema.string("Your session/run id, if you have one.", minLength: 1, maxLength: IPCLimits.maxRunIDLength),
                "expected_version": SchemaFields.expectedVersion,
            ], required: ["task_id", "agent_name", "expected_version"])
        ),
        MergeCueToolDefinition(
            HeartbeatParams.self,
            title: "Heartbeat",
            description: """
                Renew your lease on a claimed task (at least every heartbeat_interval_seconds while you work). An \
                expired lease turns the task stale, never done. Returns {version, lease_expires_at}.
                """,
            inputSchema: JSONSchema.object([
                "task_id": SchemaFields.taskID(),
                "lease_id": SchemaFields.leaseID,
            ], required: ["task_id", "lease_id"]),
            idempotent: true
        ),
        MergeCueToolDefinition(
            UpdateTaskParams.self,
            title: "Update task progress",
            description: """
                Report a real progress milestone on a claimed task: phase and a short message the owner sees. Renews \
                the lease. Returns {version, lease_expires_at}; use the returned version as your next \
                expected_version. Updates are rate limited — report milestones, not every step.
                """,
            inputSchema: JSONSchema.object([
                "task_id": SchemaFields.taskID(),
                "lease_id": SchemaFields.leaseID,
                "expected_version": SchemaFields.expectedVersion,
                "phase": JSONSchema.string("Current phase.", enumValues: Enums.phases),
                "message": JSONSchema.string("Short progress note (plain text).", minLength: 1, maxLength: IPCLimits.maxProgressMessageLength),
            ], required: ["task_id", "lease_id", "expected_version", "phase", "message"])
        ),
        MergeCueToolDefinition(
            ReportChangesParams.self,
            title: "Report changes",
            description: """
                Record the code changes you made in the task's worktree. MergeCue recomputes the diff itself from \
                worktree_path (must be the task's checkout.worktree_path) against base_sha (must equal \
                checkout.base_sha) and compares it with changed_paths (paths relative to the worktree root; paths \
                outside the checkout are rejected with path_outside_checkout). Returns {artifact_id, version, \
                verified_changed_paths, unexpected_paths, missing_paths}. Nothing is committed, pushed or published.
                """,
            inputSchema: JSONSchema.object([
                "task_id": SchemaFields.taskID(),
                "lease_id": SchemaFields.leaseID,
                "expected_version": SchemaFields.expectedVersion,
                "worktree_path": JSONSchema.string("Absolute path of the task worktree (checkout.worktree_path).", minLength: 1, maxLength: IPCLimits.maxPathLength),
                "base_sha": JSONSchema.string("Base commit the worktree was prepared from (checkout.base_sha).", minLength: 1, maxLength: IPCLimits.maxSHALength),
                "head_sha": JSONSchema.string("Worktree HEAD after your edits, if you committed locally.", minLength: 1, maxLength: IPCLimits.maxSHALength),
                "changed_paths": JSONSchema.array(
                    "Files you changed, relative to the worktree root.",
                    items: .object(["type": "string", "minLength": 1, "maxLength": .int(IPCLimits.maxPathLength)]),
                    maxItems: IPCLimits.maxChangedPaths
                ),
                "note": JSONSchema.string("Optional note about the change for the owner.", maxLength: IPCLimits.maxNoteLength),
            ], required: ["task_id", "lease_id", "expected_version", "worktree_path", "base_sha", "changed_paths"])
        ),
        MergeCueToolDefinition(
            ReportTestsParams.self,
            title: "Report tests",
            description: """
                Record a test command you actually ran in the worktree: command, its real exit_code, status, \
                optional counts and bounded output (at most 16 KiB of UTF-8). status passed is rejected \
                (validation_failed) with a non-zero exit code or failed > 0; use not_run when you could not run \
                tests — never self-certify tests you did not run. Returns {artifact_id, version}.
                """,
            inputSchema: JSONSchema.object([
                "task_id": SchemaFields.taskID(),
                "lease_id": SchemaFields.leaseID,
                "expected_version": SchemaFields.expectedVersion,
                "command": JSONSchema.string("The exact command you ran.", minLength: 1, maxLength: IPCLimits.maxCommandLength),
                "exit_code": JSONSchema.integer("The command's real exit code."),
                "status": JSONSchema.string("Outcome of the run.", enumValues: Enums.testStatuses),
                "passed": JSONSchema.integer("Number of passing tests.", minimum: 0),
                "failed": JSONSchema.integer("Number of failing tests.", minimum: 0),
                "skipped": JSONSchema.integer("Number of skipped tests.", minimum: 0),
                "duration_ms": JSONSchema.integer("Wall-clock duration in milliseconds.", minimum: 0),
                "output": JSONSchema.string("Relevant tail of the output (at most 16 KiB of UTF-8; empty string if none).", maxLength: IPCLimits.maxTestOutputBytes),
            ], required: ["task_id", "lease_id", "expected_version", "command", "exit_code", "status", "output"])
        ),
        MergeCueToolDefinition(
            SubmitResultParams.self,
            title: "Submit result",
            description: """
                Hand your finished work to the owner for review; the task becomes ready_for_review. summary is \
                required. Code tasks need the diff artifact from report_changes in artifact_ids, or \
                no_changes_reason; draft_reply tasks need proposed_reply (a draft the owner may post after \
                approval). artifact_ids must belong to this task. Returns {version, state}. This does not publish \
                anything: the owner reviews and approves any push, reply, thread resolution or merge in MergeCue.
                """,
            inputSchema: JSONSchema.object([
                "task_id": SchemaFields.taskID(),
                "lease_id": SchemaFields.leaseID,
                "expected_version": SchemaFields.expectedVersion,
                "summary": JSONSchema.string("What you did and why (plain text or Markdown).", minLength: 1, maxLength: IPCLimits.maxSummaryLength),
                "proposed_reply": JSONSchema.string("Draft reply to the reviewer, posted only if the owner approves it.", minLength: 1, maxLength: IPCLimits.maxProposedReplyLength),
                "artifact_ids": JSONSchema.array(
                    "Artifacts supporting the result (art_… ids from report_changes / report_tests); may be empty.",
                    items: .object(["type": "string", "minLength": 1, "maxLength": 64]),
                    maxItems: IPCLimits.maxArtifactIDs,
                    uniqueItems: true
                ),
                "known_risks": JSONSchema.array(
                    "Risks or follow-ups the owner should know about.",
                    items: .object(["type": "string", "minLength": 1, "maxLength": .int(IPCLimits.maxKnownRiskLength)]),
                    maxItems: IPCLimits.maxKnownRisks
                ),
                "no_changes_reason": JSONSchema.string("Why no code change was needed (instead of a diff artifact).", minLength: 1, maxLength: IPCLimits.maxReasonLength),
            ], required: ["task_id", "lease_id", "expected_version", "summary", "artifact_ids"])
        ),
        MergeCueToolDefinition(
            FailTaskParams.self,
            title: "Fail task",
            description: """
                Stop working on a claimed task and release the lease. blocked: true means you need the owner \
                (missing access, ambiguous request, unsafe checkout) and moves the task to blocked; otherwise it \
                becomes failed. retryable tells the owner whether retrying could help. Returns {version, state}.
                """,
            inputSchema: JSONSchema.object([
                "task_id": SchemaFields.taskID(),
                "lease_id": SchemaFields.leaseID,
                "expected_version": SchemaFields.expectedVersion,
                "reason": JSONSchema.string("Why you stopped (shown to the owner).", minLength: 1, maxLength: IPCLimits.maxReasonLength),
                "retryable": JSONSchema.boolean("Whether a retry could succeed."),
                "blocked": JSONSchema.boolean("You need the owner to act before anyone can continue.", defaultValue: false),
            ], required: ["task_id", "lease_id", "expected_version", "reason", "retryable"])
        ),
        MergeCueToolDefinition(
            ProposeRuleParams.self,
            title: "Propose rule",
            description: """
                Propose an automation rule, e.g. "create a fix_review task when changes are requested on acme/*". \
                The rule is stored inactive with status pending_activation; only the owner can activate it in the \
                MergeCue app, and rules can never bypass approval of remote actions. create_task and \
                request_execution need task_type; notify must not have one. Returns {rule_id, status, preview} — \
                show the preview to the user.
                """,
            inputSchema: JSONSchema.object([
                "name": JSONSchema.string("Short rule name.", minLength: 1, maxLength: ProposeRuleParams.maxNameLength),
                "providers": JSONSchema.array("Limit to these providers (omit for any).", items: JSONSchema.enumItem(Enums.providers), minItems: 1, uniqueItems: true),
                "event_types": JSONSchema.array("Events that trigger the rule.", items: JSONSchema.enumItem(Enums.eventTypes), minItems: 1, uniqueItems: true),
                "repo_include": JSONSchema.array(
                    "Repository path globs to include (* within a segment, ** across segments), e.g. acme/*.",
                    items: .object(["type": "string", "minLength": 1, "maxLength": .int(ProposeRuleParams.maxPatternLength)]),
                    maxItems: ProposeRuleParams.maxPatterns
                ),
                "repo_exclude": JSONSchema.array(
                    "Repository path globs to exclude.",
                    items: .object(["type": "string", "minLength": 1, "maxLength": .int(ProposeRuleParams.maxPatternLength)]),
                    maxItems: ProposeRuleParams.maxPatterns
                ),
                "action": JSONSchema.string("What the rule does when it fires.", enumValues: Enums.ruleActions),
                "task_type": JSONSchema.string("Task to create (required for create_task and request_execution).", enumValues: Enums.taskTypes),
                "quiet_hours": JSONSchema.object([
                    "start": JSONSchema.string("Start time, 24-hour HH:MM.", pattern: SchemaFields.clockTimePattern),
                    "end": JSONSchema.string("End time, 24-hour HH:MM (may be earlier than start for overnight windows).", pattern: SchemaFields.clockTimePattern),
                    "time_zone": JSONSchema.string("IANA time zone, e.g. Europe/Lisbon.", minLength: 1, maxLength: 64),
                ], required: ["start", "end", "time_zone"], description: "Window in which the rule does not fire."),
                "max_fires_per_hour": JSONSchema.integer(
                    "Rate limit for the rule.",
                    minimum: ProposeRuleParams.maxFiresPerHourRange.lowerBound,
                    maximum: ProposeRuleParams.maxFiresPerHourRange.upperBound
                ),
            ], required: ["name", "event_types", "action"])
        ),
    ]
}
