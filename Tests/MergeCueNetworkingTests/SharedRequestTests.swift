import Foundation
import MergeCueCore
import Synchronization
import Testing
@testable import MergeCueNetworking

/// Identical concurrent GETs share one request; `maxConcurrentRequests` caps requests in flight (DECISIONS D36).
@Suite("API client shared requests and concurrency cap")
struct SharedRequestTests {
    /// Holds every request until `release()`; records how many were sent and the peak in flight.
    final class GateTransport: HTTPTransport {
        private struct State {
            var sent: [URL] = []
            var inFlight = 0
            var peak = 0
            var waiting: [CheckedContinuation<Void, Never>] = []
            var open = false
        }

        private let state = Mutex(State())

        var sent: [URL] { state.withLock { $0.sent } }
        var peak: Int { state.withLock { $0.peak } }
        var inFlight: Int { state.withLock { $0.inFlight } }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let open = state.withLock { state -> Bool in
                state.sent.append(request.url)
                state.inFlight += 1
                state.peak = max(state.peak, state.inFlight)
                return state.open
            }
            if !open {
                await withCheckedContinuation { continuation in
                    let resumeNow = state.withLock { state -> Bool in
                        if state.open { return true }
                        state.waiting.append(continuation)
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            }
            state.withLock { $0.inFlight -= 1 }
            return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8), url: request.url)
        }

        func release() {
            let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.open = true
                defer { state.waiting.removeAll() }
                return state.waiting
            }
            waiting.forEach { $0.resume() }
        }
    }

    func client(_ transport: GateTransport, limit: Int? = nil) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!, credential: .bearer("opaque-test-token-1234"),
            transport: transport, rateLimitParser: GenericRateLimitParser(), etagCache: nil, clock: TestClock(),
            maxConcurrentRequests: limit
        )
    }

    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<50_000 where !condition() { await Task.yield() }
    }

    @Test func identicalConcurrentReadsShareOneRequest() async throws {
        let transport = GateTransport()
        let client = client(transport)
        async let first = client.get("/user")
        async let second = client.get("/user")
        async let other = client.get("/user/workspaces")
        await waitUntil { transport.sent.count >= 2 }
        transport.release()
        let responses = try await [first, second, other]
        #expect(responses.allSatisfy { $0.status == 200 })
        #expect(transport.sent.map(\.path).sorted() == ["/user", "/user/workspaces"], "one /user for two callers")
        // Once finished, the same read is sent again (nothing is cached without an ETag).
        _ = try await client.get("/user")
        #expect(transport.sent.count == 3)
    }

    @Test func requestsInFlightAreCapped() async throws {
        let transport = GateTransport()
        let client = client(transport, limit: 2)
        async let a = client.get("/a")
        async let b = client.get("/b")
        async let c = client.get("/c")
        async let d = client.get("/d")
        await waitUntil { transport.sent.count >= 2 }
        for _ in 0..<1_000 { await Task.yield() }
        #expect(transport.sent.count == 2, "the other two wait for a permit")
        transport.release()
        _ = try await [a, b, c, d]
        #expect(transport.sent.count == 4)
        #expect(transport.peak <= 2)
    }
}
