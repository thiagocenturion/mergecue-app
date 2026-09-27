import Foundation
import MergeCueCore
import Testing
@testable import MergeCueNetworking

@Suite("Provider JSON decoding")
struct ProviderDecodingTests {
    private struct Stamped: Decodable {
        var at: Date
    }

    /// 2024-01-01T12:00:00Z
    private static let noon = Date(timeIntervalSince1970: 1_704_110_400)

    @Test(arguments: [
        ("2024-01-01T12:00:00Z", 0.0),
        ("2024-01-01T12:00:00.123Z", 0.123),
        ("2024-01-01T12:00:00.123456+00:00", 0.123456),
        ("2024-01-01T12:00:00.5+00:00", 0.5),
        ("2024-01-01T13:00:00+01:00", 0.0),
        ("2024-01-01T13:00:00.250+01:00", 0.25),
        ("2024-01-01T04:00:00-08:00", 0.0),
        ("2024-01-01T04:00:00-0800", 0.0),
        ("2024-01-01T17:30:00.000+05:30", 0.0),
        ("2024-01-01T12:00:00.000000000Z", 0.0),
        ("2024-01-01 12:00:00Z", 0.0),
        ("2024-01-01t12:00:00z", 0.0),
        ("2024-01-01T14:00:00+02", 0.0),
    ])
    func decodesProviderTimestamps(text: String, fraction: Double) throws {
        let json = Data(#"{"at":"\#(text)"}"#.utf8)
        let decoded = try JSONDecoder.mergeCueProvider.decode(Stamped.self, from: json)
        let expected = Self.noon.addingTimeInterval(fraction)
        #expect(abs(decoded.at.timeIntervalSince(expected)) < 0.000_001, "\(text) → \(decoded.at)")
    }

    @Test func millisecondTimestampsAreExact() throws {
        let decoded = try JSONDecoder.mergeCueProvider.decode(Stamped.self, from: Data(#"{"at":"2024-01-01T12:00:00.123Z"}"#.utf8))
        #expect(MergeCueCoding.formatWireDate(decoded.at) == "2024-01-01T12:00:00.123Z")
    }

    @Test func dateOnlyValuesAreMidnightUTC() throws {
        let decoded = try JSONDecoder.mergeCueProvider.decode(Stamped.self, from: Data(#"{"at":"2024-01-01"}"#.utf8))
        #expect(decoded.at == Date(timeIntervalSince1970: 1_704_067_200))
    }

    @Test(arguments: ["", "yesterday", "2024-01-01T12:00", "2024-13-01T12:00:00Z", "1704110400", "2024-01-01T12:00:00.Z"])
    func rejectsGarbage(text: String) {
        let json = Data(#"{"at":"\#(text)"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder.mergeCueProvider.decode(Stamped.self, from: json)
        }
    }

    @Test func eachAccessIsAFreshInstance() {
        let first = JSONDecoder.mergeCueProvider
        first.keyDecodingStrategy = .convertFromSnakeCase
        let second = JSONDecoder.mergeCueProvider
        #expect(first !== second)
        if case .useDefaultKeys = second.keyDecodingStrategy {} else {
            Issue.record("the shared configuration must not be mutated through an earlier instance")
        }
    }

    @Test func clientDecodesJSONAndMapsDecodingFailures() async throws {
        let stub = StubTransport(
            routes: [
                .getJSON("/projects/1", #"{"id": 1, "name": "api", "updated_at": "2024-01-01T12:00:00.123456+00:00"}"#),
                .getJSON("/projects/2", #"{"id": "two", "name": "api", "updated_at": "2024-01-01T12:00:00Z"}"#),
                .getJSON("/projects/3", "not json"),
            ],
            baseURL: NetFixture.gitlabAPI
        )
        let client = NetFixture.client(transport: stub)
        let repo = try await client.getJSON(Repo.self, "/projects/1")
        #expect(repo.id == 1)
        #expect(abs(repo.updatedAt.timeIntervalSince(Self.noon) - 0.123456) < 0.000_001)

        await #expect(throws: ProviderError.self) { try await client.getJSON(Repo.self, "/projects/2") }
        do {
            _ = try await client.getJSON(Repo.self, "/projects/2")
        } catch let error as ProviderError {
            guard case .decoding(let message) = error else {
                Issue.record("expected decoding, got \(error)")
                return
            }
            #expect(message.contains("id"))
            #expect(message.contains("Repo"))
        }
        do {
            _ = try await client.getJSON(Repo.self, "/projects/3")
            Issue.record("expected a decoding error")
        } catch let error as ProviderError {
            #expect(error.code == "decoding_error")
        }
    }
}
