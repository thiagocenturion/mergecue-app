import Foundation
import MergeCueCore
import Testing

@Suite("SecretRedactor")
struct SecretRedactorTests {
    /// (input, secret that must disappear, text that must remain)
    static let positives: [(String, String, String)] = [
        ("token ghp_1234567890abcdefghijABCDEFGHIJ1234 leaked", "ghp_1234567890abcdefghij", "leaked"),
        ("gho_abcdefghijklmnopqrstuvwxyz0123456789", "abcdefghijklmnop", "gho_"),
        ("ghu_ABCDEFGHIJKLMNOPQRSTUV123456", "ABCDEFGHIJKLMNOP", "ghu_"),
        ("using ghs_0123456789abcdefABCDEF0123 for app", "0123456789abcdef", "for app"),
        ("github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz", "11ABCDEFG0123456789", "github_pat_"),
        ("GitLab glpat-AbCdEfGhIjKlMnOpQrSt works", "AbCdEfGhIjKlMnOpQrSt", "works"),
        ("glpat-xYz123-_AbCdEfGhIjKl.01.1a2b3c4d5 end", "xYz123-_AbCdEfGhIjKl", "end"),
        ("oauth gloas-0123456789abcdefghijABCDEF", "0123456789abcdefghij", "oauth"),
        ("runner glrt-t1_AbCdEfGhIjKlMnOpQrStUv", "AbCdEfGhIjKlMnOp", "runner"),
        ("ATATT3xFfGF0AbCdEfGhIjKlMnOpQrStUvWxYz0123456789=ABCD1234", "3xFfGF0AbCdEfGhIjKl", "ATATT"),
        ("ATCTT3xFfGF0-AbCdEfGhIjKlMnOp_QrSt=", "3xFfGF0-AbCdEfGhIjKl", "ATCTT"),
        ("slack xoxb-123456789012-1234567890123-AbCdEfGhIjKl", "123456789012-1234567890123", "slack"),
        ("xoxp-1234567890-abcdefghij", "1234567890-abcdefghij", "xoxp-"),
        ("aws AKIAIOSFODNN7EXAMPLE key", "IOSFODNN7EXAMPLE", "aws"),
        ("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U ok",
         "dozjgNryP4J3jVmNHl0w5N", "ok"),
        ("Authorization: Bearer abc.def.ghi-123", "abc.def.ghi-123", "Authorization: Bearer"),
        ("authorization: token 0123456789abcdef", "0123456789abcdef", "authorization: token"),
        ("Authorization: Basic dXNlcjpwYXNzd29yZA==", "dXNlcjpwYXNzd29yZA", "Authorization: Basic"),
        ("-H 'Authorization=sk_live_123'", "sk_live_123", "Authorization"),
        ("curl -H \"Bearer Zm9vYmFyYmF6cXV4\"", "Zm9vYmFyYmF6cXV4", "Bearer"),
        ("header Basic dXNlcjpwYXNzd29yZA== sent", "dXNlcjpwYXNzd29yZA", "sent"),
        ("PRIVATE-TOKEN: abc123def456", "abc123def456", "PRIVATE-TOKEN"),
        ("password=hunter2 user=mona", "hunter2", "user=mona"),
        ("export GITHUB_TOKEN=abc123", "abc123", "export GITHUB_TOKEN="),
        ("AWS_SECRET_ACCESS_KEY='wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'", "wJalrXUtnFEMI", "AWS_SECRET_ACCESS_KEY="),
        ("https://api.example.com/v1?access_token=s3cr3t&page=2", "s3cr3t", "page=2"),
        ("--client-secret=\"quoted value\"", "quoted value", "--client-secret="),
        (#"{"api_key": "sk-abcdef123456", "name": "demo"}"#, "sk-abcdef123456", #""name": "demo""#),
        (#"{"refresh_token":"r-123"}"#, "r-123", "refresh_token"),
        ("clone https://oauth2:glpat-secretsecretsecret12@gitlab.com/g/p.git", "secretsecretsecret12", "gitlab.com/g/p.git"),
        ("https://mona:pa55word@example.com/path", "pa55word", "https://mona:"),
        ("""
        key:
        -----BEGIN RSA PRIVATE KEY-----
        MIIEpAIBAAKCAQEA7bq1
        abcdef
        -----END RSA PRIVATE KEY-----
        done
        """, "MIIEpAIBAAKCAQEA7bq1", "done"),
        ("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAA (truncated log", "b3BlbnNzaC1rZXktdjEAAAA", "[REDACTED PRIVATE KEY]"),
    ]

    @Test(arguments: positives)
    func masksSecrets(_ input: String, secret: String, kept: String) {
        let output = SecretRedactor.redact(input)
        #expect(!output.contains(secret), "not redacted: \(output)")
        #expect(output.contains("[REDACTED"), "no marker: \(output)")
        #expect(output.contains(kept), "context lost: \(output)")
        #expect(SecretRedactor.containsSecret(input))
    }

    static let negatives: [String] = [
        "The token expired yesterday; please reconnect.",
        "Use a Bearer token for authentication.",
        "the bearer instrument was signed",
        "A basic understanding of JavaScript is required.",
        "Basic authentication is deprecated.",
        "Password reset link sent to your email.",
        "max_tokens=128 temperature=0.2",
        "tokenizer=bert secretary=alice",
        "https://github.com/acme/payments-api.git",
        "git@github.com:acme/payments-api.git",
        "ssh://git@github.com:22/acme/repo",
        "commit 3f786850e387550fdab836ed7e6dc881de23001b",
        "uuid 123e4567-e89b-12d3-a456-426614174000",
        "The secret sauce is testing.",
        "AKIA is an AWS prefix",
        "ghp_ is the classic PAT prefix",
        "eyJ is how base64 JSON starts",
        "Authorization header is missing",
        "error: expected 'token' but found '}' at line 3",
        "Build #42 failed: 3 tests failed, 120 passed.",
        "func authorize(user: String) -> Bool { user == \"mona\" }",
        "[REDACTED] was already masked",
        "Merged !42 into main; see gitlab.com/group/sub/project!42",
        "",
        "résumé naïve café — ✅ 🚀 日本語",
    ]

    @Test(arguments: negatives)
    func leavesOrdinaryTextAlone(_ input: String) {
        #expect(SecretRedactor.redact(input) == input)
        #expect(!SecretRedactor.containsSecret(input))
    }

    @Test(arguments: positives.map(\.0))
    func isIdempotent(_ input: String) {
        let once = SecretRedactor.redact(input)
        #expect(SecretRedactor.redact(once) == once)
    }

    @Test func masksMultipleSecretsInOneLog() {
        let log = """
        Run actions/checkout@v4
          token: ***
        + git remote add origin https://x-access-token:ghs_16C7e42F292c6912E7710c838347Ae178B4a@github.com/acme/api
        + curl -H "PRIVATE-TOKEN: glpat-abcdefghijklmnopqrst" https://gitlab.com/api/v4/projects
        Error: Process completed with exit code 1.
        """
        let output = SecretRedactor.redact(log)
        #expect(!output.contains("ghs_16C7e42F292c6912E7710c838347Ae178B4a"))
        #expect(!output.contains("glpat-abcdefghijklmnopqrst"))
        #expect(output.contains("Error: Process completed with exit code 1."))
        #expect(output.contains("Run actions/checkout@v4"))
        #expect(output.contains("github.com/acme/api"))
    }

    @Test func largeInputStaysLinear() {
        let chunk = "INFO step ok token count 42 bearer of news basic idea\n"
        let big = String(repeating: chunk, count: 5_000) + "password=topsecret\n"
        let output = SecretRedactor.redact(big)
        #expect(!output.contains("topsecret"))
        #expect(output.hasPrefix(chunk))
    }
}
