import Foundation
import MergeCueCore

/// Wraps a transport and reports every request that reached the provider: one per response plus one per redirect
/// hop the transport followed (`HTTPHeaders.redirectHops`). `304 Not Modified` answers are skipped unless
/// `countsNotModified` (GitHub and GitLab do not charge conditional requests; Bitbucket does not document that,
/// so its accounts count them, DECISIONS D36). Requests that fail before a response (offline, timeout,
/// cancellation) are not reported.
public struct CountingTransport: HTTPTransport {
    public let base: any HTTPTransport
    public let countsNotModified: Bool
    private let onResponse: @Sendable (HTTPResponse, Int) -> Void

    /// `onResponse` receives the response and the number of provider requests it cost (1 + redirect hops).
    public init(
        _ base: any HTTPTransport, countsNotModified: Bool = false,
        onResponse: @escaping @Sendable (HTTPResponse, Int) -> Void
    ) {
        self.base = base
        self.countsNotModified = countsNotModified
        self.onResponse = onResponse
    }

    /// Records into `ledger` for `account` at the clock's current time (and Bitbucket's near-limit signal).
    public init(
        _ base: any HTTPTransport, ledger: ProviderRequestLedger, account: AccountKey, clock: any MCClock,
        countsNotModified: Bool = false
    ) {
        self.init(base, countsNotModified: countsNotModified) { response, cost in
            let now = clock.now
            for _ in 0..<cost { ledger.record(account, at: now) }
            if response.header("x-ratelimit-nearlimit")?.lowercased() == "true" {
                ledger.recordNearLimit(account, at: now)
            }
        }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await base.send(request)
        if response.status != 304 || countsNotModified {
            let hops = response.header(HTTPHeaders.redirectHops).flatMap(Int.init) ?? 0
            onResponse(response, 1 + max(0, hops))
        }
        return response
    }
}
