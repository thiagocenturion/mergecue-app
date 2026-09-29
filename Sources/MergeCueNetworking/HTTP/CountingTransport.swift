import Foundation
import MergeCueCore

/// Wraps a transport and reports every response that reached the provider, except `304 Not Modified` (conditional
/// requests do not count against GitHub's rate limit and cost the provider almost nothing). Requests that fail
/// before a response (offline, timeout, cancellation) are not reported.
public struct CountingTransport: HTTPTransport {
    public let base: any HTTPTransport
    private let onResponse: @Sendable (HTTPResponse) -> Void

    public init(_ base: any HTTPTransport, onResponse: @escaping @Sendable (HTTPResponse) -> Void) {
        self.base = base
        self.onResponse = onResponse
    }

    /// Records into `ledger` for `account` at the clock's current time.
    public init(_ base: any HTTPTransport, ledger: ProviderRequestLedger, account: AccountKey, clock: any MCClock) {
        self.init(base) { _ in ledger.record(account, at: clock.now) }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await base.send(request)
        if response.status != 304 { onResponse(response) }
        return response
    }
}
