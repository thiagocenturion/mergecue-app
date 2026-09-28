import Foundation
import MergeCueCore
import MergeCueNetworking
import Synchronization

/// The HTTP transport of one demo provider: a `StubTransport` serving the provider's fixture routes, with the
/// fixture commit SHAs of change request #42 rewritten to the SHAs of the synthetic local repository
/// (`DemoRepository`), so isolated worktrees can be fetched at the "PR head" the fixtures report.
///
/// Responses have every fixture SHA replaced by its real counterpart; requests get the reverse rewrite before
/// routing, so SHA-keyed fixture routes keep matching. `stub.requests` records what the adapter sent in fixture
/// terms (tests assert provider writes on it). **Demo data only — never live.**
public final class DemoScenarioTransport: HTTPTransport {
    /// A fixture ↔ real replacement. Longer strings are applied first (a 40-character SHA before its 12-character
    /// abbreviation).
    public struct Substitution: Sendable, Hashable {
        public var fixture: String
        public var real: String

        public init(fixture: String, real: String) {
            self.fixture = fixture
            self.real = real
        }
    }

    public let stub: StubTransport
    private let substitutions: Mutex<[Substitution]>

    public init(stub: StubTransport, substitutions: [Substitution] = []) {
        self.stub = stub
        self.substitutions = Mutex(Self.ordered(substitutions))
    }

    /// Replaces the substitution table (e.g. after a simulated force-push moved the head).
    public func setSubstitutions(_ substitutions: [Substitution]) {
        self.substitutions.withLock { $0 = Self.ordered(substitutions) }
    }

    public var currentSubstitutions: [Substitution] {
        substitutions.withLock { $0 }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let table = currentSubstitutions
        guard !table.isEmpty else { return try await stub.send(request) }
        var rewritten = request
        let urlText = Self.replace(request.url.absoluteString, table, toFixture: true)
        if let url = URL(string: urlText) { rewritten.url = url }
        if let body = request.body, let text = String(data: body, encoding: .utf8) {
            rewritten.body = Data(Self.replace(text, table, toFixture: true).utf8)
        }
        var response = try await stub.send(rewritten)
        if let text = String(data: response.body, encoding: .utf8) {
            response.body = Data(Self.replace(text, table, toFixture: false).utf8)
        }
        response.url = request.url
        return response
    }

    // MARK: Helpers

    private static func ordered(_ substitutions: [Substitution]) -> [Substitution] {
        substitutions
            .filter { !$0.fixture.isEmpty && !$0.real.isEmpty && $0.fixture != $0.real }
            .sorted { max($0.fixture.count, $0.real.count) > max($1.fixture.count, $1.real.count) }
    }

    static func replace(_ text: String, _ table: [Substitution], toFixture: Bool) -> String {
        var result = text
        for entry in table {
            let (from, to) = toFixture ? (entry.real, entry.fixture) : (entry.fixture, entry.real)
            if result.contains(from) {
                result = result.replacingOccurrences(of: from, with: to)
            }
        }
        return result
    }
}
