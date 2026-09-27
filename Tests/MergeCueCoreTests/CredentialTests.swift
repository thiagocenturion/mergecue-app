import Foundation
import MergeCueCore
import Testing

@Suite("Credential redaction and encoding")
struct CredentialTests {
    static let bearerSecret = "ghp_S3cretTokenValue1234567890abcdef"
    static let basicPassword = "ATATT3xFfGF0-SuperSecretPassword=="
    static let refresh = "refresh-SECRET-777"

    static var credentials: [Credential] {
        [
            .bearer(bearerSecret, refreshToken: refresh, expiresAt: Fixture.date),
            .basic(username: "mona@example.com", password: basicPassword),
        ]
    }

    private func assertNoSecrets(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for secret in [Self.bearerSecret, Self.basicPassword, Self.refresh, "mona@example.com", "S3cret", "SuperSecret"] {
            #expect(!text.contains(secret), "leaked \(secret) in: \(text)", sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: credentials)
    func descriptionsAreRedacted(_ credential: Credential) {
        #expect(credential.description == "Credential(<redacted>)")
        #expect(credential.debugDescription == "Credential(<redacted>)")
        #expect("\(credential)" == "Credential(<redacted>)")
        #expect(String(describing: credential) == "Credential(<redacted>)")
        #expect(String(reflecting: credential) == "Credential(<redacted>)")
        assertNoSecrets(String(describing: credential.secret))
        assertNoSecrets(String(reflecting: credential.secret))
        assertNoSecrets("\(Optional(credential) as Any)")
        assertNoSecrets(String(describing: [credential]))
    }

    @Test(arguments: credentials)
    func dumpAndMirrorAreRedacted(_ credential: Credential) {
        var dumped = ""
        dump(credential, to: &dumped)
        assertNoSecrets(dumped)
        #expect(dumped.contains("<redacted>"))

        var dumpedSecret = ""
        dump(credential.secret, to: &dumpedSecret)
        assertNoSecrets(dumpedSecret)

        struct Holder { let credential: Credential }
        var dumpedHolder = ""
        dump(Holder(credential: credential), to: &dumpedHolder)
        assertNoSecrets(dumpedHolder)

        #expect(Mirror(reflecting: credential).children.isEmpty)
        #expect(Mirror(reflecting: credential.secret).children.isEmpty)
    }

    @Test func authorizationHeaderValues() {
        #expect(Credential.bearer("abc").authorizationHeaderValue() == "Bearer abc")
        let basic = Credential.basic(username: "user@example.com", password: "p@ss:word")
        let expected = "Basic " + Data("user@example.com:p@ss:word".utf8).base64EncodedString()
        #expect(basic.authorizationHeaderValue() == expected)
        #expect(basic.schemeName == "Basic")
        #expect(Credential.bearer("x").schemeName == "Bearer")
    }

    @Test(arguments: credentials)
    func codableRoundTripForKeychainPayload(_ credential: Credential) throws {
        #expect(try Fixture.roundTrip(credential) == credential)
    }

    @Test func keychainPayloadShapeIsStable() throws {
        let json = try Fixture.json(Credential.bearer("tok", refreshToken: "ref", expiresAt: Fixture.date))
        #expect(json == #"{"expires_at":"2026-01-01T00:00:00Z","refresh_token":"ref","secret":{"token":"tok","type":"bearer"}}"#)
        let basic = try Fixture.json(Credential.basic(username: "u", password: "p"))
        #expect(basic == #"{"secret":{"password":"p","type":"basic","username":"u"}}"#)
        #expect(throws: DecodingError.self) {
            try Fixture.decode(Credential.self, from: #"{"secret":{"type":"cookie","token":"x"}}"#)
        }
    }

    @Test func expiry() {
        let noExpiry = Credential.bearer("x")
        #expect(!noExpiry.isExpired(at: Fixture.date))
        let expiring = Credential.bearer("x", expiresAt: Fixture.date.addingTimeInterval(30))
        #expect(expiring.isExpired(at: Fixture.date))
        #expect(!expiring.isExpired(at: Fixture.date, leeway: 0))
        #expect(expiring.isExpired(at: Fixture.date.addingTimeInterval(30), leeway: 0))
    }

    @Test func accountDefaultsAreSafe() throws {
        let account = Account(
            id: Fixture.githubAccount,
            instance: .githubCom,
            username: "mona-dev",
            authMethod: .personalAccessToken,
            connectedAt: Fixture.date
        )
        #expect(account.writesEnabled == false)
        #expect(account.selectedNamespaces.isEmpty)
        #expect(account.isDemo == false)
        #expect(account.displayLabel == "mona-dev")
        #expect(try Fixture.roundTrip(account) == account)
    }

    @Test func credentialStoreErrorMessagesHaveNoSecrets() {
        let error = CredentialStoreError.storeFailure(status: -25300, message: "item not found")
        #expect(error.errorDescription?.contains("-25300") == true)
    }
}
