import Darwin
import Foundation
import MergeCueCore
import Testing
@testable import MergeCueIPC

@Suite("Client ↔ server round trips", .timeLimit(.minutes(1)))
struct IPCRoundTripTests {
    @Test func pingAndTypedCallsRoundTrip() async throws {
        try await withTestHome { home in
            let engine = FakeEngine()
            try await withServer(home: home, handler: engine) { _ in
                let client = makeClient(home)
                let ping = try await client.ping()
                #expect(ping == PingResult(appVersion: "1.0-test", isDemo: true))

                let claim = try await client.call(ClaimTaskParams(taskID: Fixtures.taskID, agentName: "codex", expectedVersion: 3))
                #expect(claim.taskID == Fixtures.taskID)
                #expect(claim.state == .working)
                #expect(claim.leaseID == "lease_codex")
                #expect(claim.leaseExpiresAt == Fixtures.date)
                #expect(claim.checkout?.worktreePath == "/tmp/wt")

                let raw = try await client.callRaw(.ping)
                #expect(raw == ["app_version": "1.0-test", "is_demo": true, "protocol_version": 1])

                let calls = await engine.recorder.calls
                #expect(calls.map { $0.0 } == [.ping, .claimTask, .ping])
                #expect(calls.allSatisfy { $0.1.name == "mcipc-tests" && $0.1.version == "1.0" })
                // The server replaces the self-declared pid with the kernel-reported peer pid.
                #expect(calls.allSatisfy { $0.1.pid == getpid() })
            }
        }
    }

    @Test func handlerErrorsPassThroughUnchanged() async throws {
        try await withTestHome { home in
            try await withServer(home: home) { _ in
                let client = makeClient(home)
                let conflict = await expectIPCError {
                    try await client.call(ClaimTaskParams(taskID: Fixtures.taskID, agentName: "codex", expectedVersion: 1))
                }
                #expect(conflict == IPCError(.versionConflict, "Task changed; re-read it with get_task.", retryable: true, data: ["current_version": 3]))

                let unsupported = await expectIPCError { try await client.call(ListRulesParams()) }
                #expect(unsupported?.code == .unsupported)
            }
        }
    }

    @Test func undecodableOrInvalidParamsAreInvalidParams() async throws {
        try await withTestHome { home in
            try await withServer(home: home) { _ in
                let client = makeClient(home)
                let missing = await expectIPCError { try await client.call(.claimTask, PingParams(), as: ClaimTaskResult.self) }
                #expect(missing?.code == .invalidParams)
                #expect(missing?.message.hasPrefix("Missing required parameter") == true)

                let wrongType = await expectIPCError { try await client.callRaw(.claimTask, params: ["task_id": 7, "agent_name": "a", "expected_version": 1]) }
                #expect(wrongType?.code == .invalidParams)
                #expect(wrongType?.message.contains("'task_id'") == true)

                let outOfRange = await expectIPCError { try await client.call(ListAttentionParams(limit: 1000)) }
                #expect(outOfRange?.code == .invalidParams)
                #expect(outOfRange?.message.contains("'limit'") == true)

                let notAnObject = await expectIPCError { try await client.callRaw(.ping, params: ["a", "b"]) }
                #expect(notAnObject?.code == .invalidParams)
            }
        }
    }

    @Test func rawProtocolErrorsKeepTheConnectionUsable() async throws {
        try await withTestHome { home in
            try await withServer(home: home) { _ in
                let token = try home.readToken()
                let connection = try await RawConnection.connect(to: home.socketPath)
                defer { connection.close() }

                await connection.writeLine(requestLine(id: "v2", token: token, version: 2))
                let version = try decodeResponse(await connection.readLine())
                #expect(version.id == "v2")
                #expect(version.error?.code == .protocolVersion)
                #expect(version.error?.data == ["supported_versions": [1]])

                await connection.writeLine(requestLine(id: "u1", token: token, method: "do_magic"))
                let unknown = try decodeResponse(await connection.readLine())
                #expect(unknown.id == "u1")
                #expect(unknown.error?.code == .unsupported)

                await connection.writeLine(requestLine(id: "p1", token: token, params: "[1]"))
                let badParams = try decodeResponse(await connection.readLine())
                #expect(badParams.error?.code == .invalidParams)

                await connection.writeLine(#"{"client":{"name":"raw","pid":1,"version":"1"},"method":"ping","params":{},"token":"\#(token)","v":1}"#)
                let noID = try decodeResponse(await connection.readLine())
                #expect(noID.id == "")
                #expect(noID.error?.code == .invalidParams)

                await connection.writeLine(#"{"id":"c1","method":"ping","params":{},"token":"\#(token)","v":1}"#)
                let noClient = try decodeResponse(await connection.readLine())
                #expect(noClient.error?.code == .invalidParams)

                await connection.writeLine(requestLine(id: "ok", token: token))
                let ok = try decodeResponse(await connection.readLine())
                #expect(ok.id == "ok")
                #expect(ok.result?["app_version"] == "1.0-test")
            }
        }
    }

    @Test func requestsOnOneConnectionAreAnsweredInOrder() async throws {
        // The first request is the slowest; responses must still come back in request order.
        let handler = IPCClosureHandler { _, params, _ in
            let index = params["limit"]?.intValue ?? 0
            try? await Task.sleep(for: .milliseconds(max(0, 200 - index * 60)))
            return IPCCoding.result(ListAttentionResult(items: [], total: index))
        }
        try await withTestHome { home in
            try await withServer(home: home, handler: handler) { _ in
                let token = try home.readToken()
                let connection = try await RawConnection.connect(to: home.socketPath)
                defer { connection.close() }
                let batch = (1...4).map { requestLine(id: "r\($0)", token: token, method: "list_attention", params: #"{"limit":\#($0)}"#) }
                await connection.write(Data((batch.joined(separator: "\n") + "\n").utf8))
                for index in 1...4 {
                    let response = try decodeResponse(await connection.readLine())
                    #expect(response.id == "r\(index)")
                    #expect(response.result?["total"] == .number(Double(index)))
                }
            }
        }
    }

    @Test func twentyConcurrentCallsAreRoutedIndependently() async throws {
        try await withTestHome { home in
            try await withServer(home: home, handler: FakeEngine(delay: .milliseconds(30))) { server in
                let shared = makeClient(home)
                let totals = try await withThrowingTaskGroup(of: (Int, Int).self) { group in
                    for index in 0..<20 {
                        // Half the calls share one client actor, half use their own client.
                        let client = index.isMultiple(of: 2) ? shared : makeClient(home)
                        group.addTask {
                            let result = try await client.call(ListAttentionParams(repo: "repo-\(index)"))
                            return (index, result.total)
                        }
                    }
                    var collected: [Int: Int] = [:]
                    for try await (index, total) in group {
                        collected[index] = total
                    }
                    return collected
                }
                #expect(totals.count == 20)
                #expect(totals.allSatisfy { $0.key == $0.value })
                // Every per-call connection is released afterwards.
                #expect(await eventually { await server.connectionCount() == 0 })
            }
        }
    }

    @Test func largeFramesStreamBothWays() async throws {
        try await withTestHome { home in
            try await withServer(home: home) { _ in
                let client = makeClient(home)
                // ~1 MiB response: many partial writes through the 8 KiB Unix socket buffer.
                let thread = try await client.call(GetThreadParams(threadID: "thr_1000000"))
                #expect(thread.comments.first?.body.text.utf8.count == 1_000_000)

                // ~3 MiB request is accepted by the transport (and then rejected by validation).
                let big = await expectIPCError { try await client.call(ListAttentionParams(account: String(repeating: "a", count: 3 * 1024 * 1024))) }
                #expect(big?.code == .invalidParams)
                #expect(big?.message.contains("'account'") == true)
            }
        }
    }

    @Test func oversizeResponsesAndRequestsAreRejected() async throws {
        try await withTestHome { home in
            try await withServer(home: home) { _ in
                let client = makeClient(home)
                let tooLarge = await expectIPCError { try await client.call(GetThreadParams(threadID: "thr_5000000")) }
                #expect(tooLarge?.code == .internalError)
                #expect(tooLarge?.message.contains("4 MiB") == true)

                let hugeRequest = await expectIPCError { try await client.call(ListAttentionParams(account: String(repeating: "a", count: 5 * 1024 * 1024))) }
                #expect(hugeRequest?.code == .invalidParams)
                #expect(hugeRequest?.message.contains("exceeds") == true)

                // The server is still healthy.
                let ping = try await client.ping()
                #expect(ping.isDemo)
            }
        }
    }

    @Test func slowAppTimesOutAsRetryableAppUnavailable() async throws {
        try await withTestHome { home in
            try await withServer(home: home, handler: FakeEngine(delay: .seconds(3))) { _ in
                let client = makeClient(home, timeout: 0.3)
                let error = await expectIPCError { try await client.ping() }
                #expect(error?.code == .appUnavailable)
                #expect(error?.retryable == true)
                #expect(error?.data == ["reason": "timeout"])
            }
        }
    }

    @Test func cancellationEndsTheCall() async throws {
        try await withTestHome { home in
            try await withServer(home: home, handler: FakeEngine(delay: .seconds(3))) { _ in
                let client = makeClient(home)
                let call = Task { await expectIPCError { try await client.ping() } }
                try await Task.sleep(for: .milliseconds(100))
                call.cancel()
                let error = await call.value
                #expect(error?.code == .internalError)
                #expect(error?.data == ["reason": "cancelled"])
            }
        }
    }
}
