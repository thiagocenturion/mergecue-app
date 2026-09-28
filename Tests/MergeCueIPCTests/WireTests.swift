import Foundation
import MergeCueCore
import Testing
@testable import MergeCueIPC

@Suite("Wire envelope, coding helpers and validation")
struct WireTests {
    // MARK: IPCMethod

    @Test func methodWireNamesMatchContract() {
        let names = IPCMethod.allCases.map(\.rawValue).sorted()
        #expect(names == [
            "claim_task", "fail_task", "get_change_context", "get_ci_failure", "get_diff", "get_task", "get_thread",
            "heartbeat", "list_attention", "list_rules", "list_tasks", "ping", "propose_rule", "report_changes",
            "report_tests", "submit_result", "update_task",
        ])
    }

    @Test func mutatingMethods() {
        let mutating = Set(IPCMethod.allCases.filter(\.isMutating))
        #expect(mutating == [.claimTask, .heartbeat, .updateTask, .reportChanges, .reportTests, .submitResult, .failTask, .proposeRule])
        #expect(IPCMethod.allCases.filter { $0.requiresLease }.allSatisfy { $0.isMutating })
        #expect(!IPCMethod.claimTask.requiresLease)
    }

    @Test func paramsTypesAreBoundToTheirMethods() {
        #expect(PingParams.method == .ping)
        #expect(ListAttentionParams.method == .listAttention)
        #expect(ListTasksParams.method == .listTasks)
        #expect(GetTaskParams.method == .getTask)
        #expect(GetChangeContextParams.method == .getChangeContext)
        #expect(GetThreadParams.method == .getThread)
        #expect(GetCIFailureParams.method == .getCIFailure)
        #expect(GetDiffParams.method == .getDiff)
        #expect(ClaimTaskParams.method == .claimTask)
        #expect(HeartbeatParams.method == .heartbeat)
        #expect(UpdateTaskParams.method == .updateTask)
        #expect(ReportChangesParams.method == .reportChanges)
        #expect(ReportTestsParams.method == .reportTests)
        #expect(SubmitResultParams.method == .submitResult)
        #expect(FailTaskParams.method == .failTask)
        #expect(ProposeRuleParams.method == .proposeRule)
        #expect(ListRulesParams.method == .listRules)
    }

    // MARK: Envelope

    @Test func requestEnvelopeGoldenAndDefaults() throws {
        let request = IPCRequest(id: "req_1", token: "secret-token", client: IPCClientInfo(name: "mergecue-mcp", version: "1.0", pid: 42), method: .listAttention, params: ["limit": 5])
        let text = String(decoding: try IPCCoding.encoder().encode(request), as: UTF8.self)
        #expect(text == #"{"client":{"name":"mergecue-mcp","pid":42,"version":"1.0"},"id":"req_1","method":"list_attention","params":{"limit":5},"token":"secret-token","v":1}"#)

        let withoutParams = try IPCCoding.decoder().decode(IPCRequest.self, from: Data(#"{"client":{"name":"n","pid":1,"version":"v"},"id":"1","method":"ping","token":"t","v":1}"#.utf8))
        #expect(withoutParams.params == .object([:]))
        let nullParams = try IPCCoding.decoder().decode(IPCRequest.self, from: Data(#"{"client":{"name":"n","pid":1,"version":"v"},"id":"1","method":"ping","params":null,"token":"t","v":1}"#.utf8))
        #expect(nullParams.params == .object([:]))
    }

    @Test func requestDescriptionAndMirrorHideToken() {
        let request = IPCRequest(id: "1", token: "super-secret-token", client: IPCClientInfo(name: "n", version: "v", pid: 1), method: .ping)
        #expect(!request.description.contains("super-secret-token"))
        #expect(!String(reflecting: request).contains("super-secret-token"))
        var dumped = ""
        dump(request, to: &dumped)
        #expect(!dumped.contains("super-secret-token"))
        #expect(!"\(request)".contains("super-secret-token"))
    }

    @Test func responseEnvelopeGolden() throws {
        let success = IPCResponse.success(id: "1", result: ["ok": true])
        #expect(String(decoding: try IPCCoding.encoder().encode(success), as: UTF8.self) == #"{"id":"1","result":{"ok":true},"v":1}"#)
        let failure = IPCResponse.failure(id: "2", error: IPCError(.leaseExpired, "Lease expired; claim the task again.", retryable: true))
        #expect(String(decoding: try IPCCoding.encoder().encode(failure), as: UTF8.self)
            == #"{"error":{"code":"lease_expired","message":"Lease expired; claim the task again.","retryable":true},"id":"2","v":1}"#)
        #expect(try success.outcome.get() == ["ok": true])
        #expect(IPCResponse(id: "3").outcome == .failure(.internalError("MergeCue sent a response without a result or an error.", reason: "malformed_response")))
    }

    @Test func errorCodesRoundTripAndUnknownCodesDegrade() throws {
        for code in IPCErrorCode.allCases {
            let error = IPCError(code, "m", retryable: true, data: ["k": 1])
            #expect(try JSONValue(ipc: error).decode(IPCError.self, decoder: IPCCoding.decoder()) == error)
        }
        let future = try IPCCoding.decoder().decode(IPCError.self, from: Data(#"{"code":"quota_exceeded","message":"m"}"#.utf8))
        #expect(future.code == .internalError)
        #expect(future.message == "m")
        #expect(future.retryable == false)
        #expect(future.data == nil)
    }

    @Test func appUnavailableShape() {
        let error = IPCError.appUnavailable()
        #expect(error.code == .appUnavailable)
        #expect(error.message == "MergeCue app is not running. Open MergeCue and retry.")
        #expect(error.retryable)
        #expect(IPCError(.appUnavailable, IPCError.appUnavailableMessage, retryable: true) == error)
    }

    @Test func errorsAreRedactedAtTheBoundary() {
        let error = IPCError(.internalError, "failed with token ghp_abcdefghijklmnopqrstuvwxyz0123456789")
        #expect(!error.redacted.message.contains("ghp_abcdef"))
    }

    // MARK: JSONValue ⇄ DTO

    @Test func jsonValueHelpersRoundTrip() throws {
        let params = GetDiffParams(changeRef: Fixtures.changeRef, maxBytes: 1024)
        let value = try JSONValue(ipc: params)
        #expect(value == ["change_ref": "github:github.com/acme/payments-api#42", "max_bytes": 1024])
        #expect(try value.ipcParams(as: GetDiffParams.self) == params)
        #expect(try IPCCoding.result(params).get() == value)
    }

    @Test func decodeParamsReportsTheOffendingField() {
        func message(_ params: JSONValue) -> String? {
            do throws(IPCError) {
                _ = try IPCCoding.decodeParams(ClaimTaskParams.self, from: params)
                return nil
            } catch {
                #expect(error.code == .invalidParams)
                #expect(!error.retryable)
                return error.message
            }
        }
        #expect(message(["agent_name": "a", "expected_version": 1])?.contains("'task_id'") == true)
        #expect(message(["task_id": "mc_abc123", "agent_name": "a", "expected_version": "one"])?.contains("'expected_version' must be an integer") == true)
        #expect(message(["task_id": "bogus", "agent_name": "a", "expected_version": 1])?.contains("'task_id'") == true)
        #expect(message(["task_id": "mc_abc123", "agent_name": .null, "expected_version": 1])?.contains("'agent_name'") == true)
        #expect(message([1, 2]) == "Parameters must be a JSON object.")

        let badRef = try? IPCCoding.decodeParams(GetChangeContextParams.self, from: ["change_ref": "github:#42"])
        #expect(badRef == nil)
        let emptyObject = try? IPCCoding.decodeParams(PingParams.self, from: .null)
        #expect(emptyObject != nil)
    }

    @Test func decodeResultMismatchIsInternalError() {
        do throws(IPCError) {
            _ = try IPCCoding.decodeResult(PingResult.self, from: ["app_version": 1], method: .ping)
            Issue.record("expected a failure")
        } catch {
            #expect(error.code == .internalError)
            #expect(error.message.contains("ping"))
        }
    }

    // MARK: Validation

    @Test func boundsValidation() {
        func code<P: IPCMethodParams>(_ params: P) -> IPCErrorCode? {
            do throws(IPCError) {
                try params.validate()
                return nil
            } catch {
                return error.code
            }
        }
        #expect(code(ListAttentionParams(limit: 100)) == nil)
        #expect(code(ListAttentionParams(limit: 101)) == .invalidParams)
        #expect(code(ListAttentionParams(limit: 0)) == .invalidParams)
        #expect(ListAttentionParams(limit: 500).resolvedLimit == 100)
        #expect(code(ListTasksParams(limit: 101)) == .invalidParams)
        #expect(code(GetChangeContextParams(changeRef: Fixtures.changeRef, maxFiles: 301)) == .invalidParams)
        #expect(GetChangeContextParams(changeRef: Fixtures.changeRef).resolvedIncludeFiles)
        #expect(code(GetCIFailureParams(checkID: "chk_1", maxBytes: 65_537)) == .invalidParams)
        #expect(GetCIFailureParams(checkID: "chk_1").resolvedMaxBytes == 16_384)
        #expect(code(GetDiffParams()) == .invalidParams)
        #expect(code(GetDiffParams(taskID: Fixtures.taskID, maxBytes: 262_145)) == .invalidParams)
        #expect(code(GetDiffParams(changeRef: Fixtures.changeRef)) == nil)
        #expect(code(ClaimTaskParams(taskID: Fixtures.taskID, agentName: "  ", expectedVersion: 1)) == .invalidParams)
        #expect(code(UpdateTaskParams(taskID: Fixtures.taskID, leaseID: "l", expectedVersion: 1, phase: .planning, message: String(repeating: "a", count: 280))) == nil)
        #expect(code(UpdateTaskParams(taskID: Fixtures.taskID, leaseID: "l", expectedVersion: 1, phase: .planning, message: String(repeating: "a", count: 281))) == .invalidParams)
        #expect(code(HeartbeatParams(taskID: Fixtures.taskID, leaseID: "")) == .invalidParams)
        #expect(code(SubmitResultParams(taskID: Fixtures.taskID, leaseID: "l", expectedVersion: 1, summary: "")) == .invalidParams)
        #expect(code(SubmitResultParams(taskID: Fixtures.taskID, leaseID: "l", expectedVersion: 1, summary: String(repeating: "s", count: 4001))) == .invalidParams)
        #expect(code(FailTaskParams(taskID: Fixtures.taskID, leaseID: "l", expectedVersion: 1, reason: "", retryable: true)) == .invalidParams)
        #expect(code(ReportChangesParams(taskID: Fixtures.taskID, leaseID: "l", expectedVersion: 1, worktreePath: "/w", baseSHA: "", changedPaths: [])) == .invalidParams)
    }

    /// S5: lengths count Unicode scalars; control characters and bidi overrides are rejected; agent_name/run_id
    /// use a strict charset.
    @Test func agentTextIsBoundedByScalarsAndSanitized() {
        func code<P: IPCMethodParams>(_ params: P) -> IPCErrorCode? {
            do throws(IPCError) {
                try params.validate()
                return nil
            } catch {
                return error.code
            }
        }
        func submit(_ summary: String, reply: String? = nil) -> SubmitResultParams {
            SubmitResultParams(taskID: Fixtures.taskID, leaseID: "l", expectedVersion: 1, summary: summary, proposedReply: reply)
        }
        // One grapheme cluster, 5 001 scalars: counted as 5 001.
        let graphemeBomb = "a" + String(repeating: "\u{0301}", count: 5_000)
        #expect(graphemeBomb.count == 1)
        #expect(code(submit(graphemeBomb)) == .invalidParams)
        #expect(code(submit("Fixed.\nAll tests pass.\tok")) == nil)
        #expect(code(submit("Fixed \u{1B}]52;c;ZXZpbA==\u{07}")) == .invalidParams)
        #expect(code(submit("ok \u{9B}31m")) == .invalidParams)
        #expect(code(submit("ok \u{202E}evil")) == .invalidParams)
        #expect(code(submit("ok", reply: "Thanks \u{2066}hidden\u{2069}")) == .invalidParams)
        #expect(code(UpdateTaskParams(taskID: Fixtures.taskID, leaseID: "l\n", expectedVersion: 1, phase: .planning, message: "x")) == .invalidParams)

        func claim(_ name: String, run: String? = nil) -> ClaimTaskParams {
            ClaimTaskParams(taskID: Fixtures.taskID, agentName: name, runID: run, expectedVersion: 1)
        }
        #expect(code(claim("Claude Code")) == nil)
        #expect(code(claim("codex-cli/0.153 (gpt)", run: "0f4c2a9e-7b1d-4c3e-9a55-1d2f3b4c5d6e")) == nil)
        #expect(code(claim("Claude\nCode")) == .invalidParams)
        #expect(code(claim("Claude\u{202E}edoC")) == .invalidParams)
        #expect(code(claim("Clàude")) == .invalidParams)
        #expect(code(claim("Claude", run: "run 1")) == .invalidParams)
        #expect(code(claim("Claude", run: "run\u{0}")) == .invalidParams)
    }

    @Test func reportTestsCannotSelfCertify() {
        func code(status: TestRunStatus, exitCode: Int, failed: Int? = nil, output: String = "") -> IPCErrorCode? {
            let params = ReportTestsParams(taskID: Fixtures.taskID, leaseID: "l", expectedVersion: 1, command: "swift test", exitCode: exitCode, status: status, failed: failed, output: output)
            do throws(IPCError) {
                try params.validate()
                return nil
            } catch {
                return error.code
            }
        }
        #expect(code(status: .passed, exitCode: 0) == nil)
        #expect(code(status: .passed, exitCode: 1) == .validationFailed)
        #expect(code(status: .passed, exitCode: 0, failed: 2) == .validationFailed)
        #expect(code(status: .failed, exitCode: 1, failed: 2) == nil)
        #expect(code(status: .passed, exitCode: 0, output: String(repeating: "é", count: 8193)) == .invalidParams)
        #expect(code(status: .passed, exitCode: 0, output: String(repeating: "a", count: 16_384)) == nil)
    }

    @Test func proposeRuleValidation() {
        func code(_ params: ProposeRuleParams) -> IPCErrorCode? {
            do throws(IPCError) {
                try params.validate()
                return nil
            } catch {
                return error.code
            }
        }
        #expect(code(ProposeRuleParams(name: "n", eventTypes: [.ciFailed], action: .notify)) == nil)
        #expect(code(ProposeRuleParams(name: "n", eventTypes: [], action: .notify)) == .invalidParams)
        #expect(code(ProposeRuleParams(name: "n", eventTypes: [.ciFailed], action: .createTask)) == .invalidParams)
        #expect(code(ProposeRuleParams(name: "n", eventTypes: [.ciFailed], action: .notify, taskType: .fixReview)) == .invalidParams)
        #expect(code(ProposeRuleParams(name: "n", eventTypes: [.ciFailed], action: .notify, maxFiresPerHour: 0)) == .invalidParams)
        #expect(code(ProposeRuleParams(name: "n", eventTypes: [.ciFailed], action: .notify, quietHours: QuietHoursDTO(start: "24:00", end: "07:00", timeZone: "UTC"))) == .invalidParams)
        #expect(code(ProposeRuleParams(name: "n", eventTypes: [.ciFailed], action: .notify, quietHours: QuietHoursDTO(start: "22:00", end: "07:00", timeZone: "Mars/Olympus"))) == .invalidParams)
        #expect(code(ProposeRuleParams(name: "n", eventTypes: [.ciFailed], action: .notify, quietHours: QuietHoursDTO(start: "9:00", end: "07:00", timeZone: "UTC"))) == .invalidParams)
    }

    @Test func quietHoursFormatting() {
        #expect(QuietHoursDTO(QuietHours(startMinute: 1320, endMinute: 5, timeZoneID: "UTC")) == QuietHoursDTO(start: "22:00", end: "00:05", timeZone: "UTC"))
        #expect(QuietHoursDTO.parse("07:30") == 450)
        #expect(QuietHoursDTO.parse("7:30") == nil)
        #expect(QuietHoursDTO.parse("12:60") == nil)
        #expect(QuietHoursDTO.parse("+1:00") == nil)
    }

    // MARK: Token comparison

    @Test func tokenComparison() {
        let token = IPCFileSecurity.generateToken()
        #expect(token.count == 64)
        #expect(IPCFileSecurity.isWellFormedToken(token))
        #expect(IPCRequestProcessor.tokensMatch(token, token))
        #expect(!IPCRequestProcessor.tokensMatch(String(token.dropLast()), token))
        #expect(!IPCRequestProcessor.tokensMatch(token + "0", token))
        #expect(!IPCRequestProcessor.tokensMatch("", token))
        #expect(!IPCRequestProcessor.tokensMatch("", ""))
        var flipped = Array(token.utf8)
        flipped[31] = flipped[31] == UInt8(ascii: "a") ? UInt8(ascii: "b") : UInt8(ascii: "a")
        #expect(!IPCRequestProcessor.tokensMatch(String(decoding: flipped, as: UTF8.self), token))
        #expect(IPCFileSecurity.generateToken() != token)
        #expect(!IPCFileSecurity.isWellFormedToken("zz" + String(token.dropFirst(2))))
    }
}
