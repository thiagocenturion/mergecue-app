import Foundation

/// Masks credentials in text that may be displayed, copied, logged or returned over MCP.
///
/// Covers GitHub (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`), GitLab (`glpat-`, `gloas-`, `glrt-`
/// and related prefixes), Atlassian (`ATATT…`, `ATCTT…`, `ATBB…`), Slack (`xox?-`, webhook URLs), OpenAI
/// (`sk-proj-`, `sk-…`), Anthropic (`sk-ant-`), Stripe (`sk_live_`, `rk_live_`, test keys), npm (`npm_`), Docker
/// Hub (`dckr_pat_`), Google API keys (`AIza…`), AWS access key ids, JWTs,
/// `Authorization:` / `Bearer` / `Basic` values, secret-bearing headers (`PRIVATE-TOKEN`, `X-…-Token`, `Cookie`),
/// `password=` / `token: …` / `"secret": …` / `:api_key => …` pairs, `--password value` CLI flags, PEM and PGP
/// private keys and URL userinfo credentials. Ordinary prose is left untouched: bare words such as "token",
/// "bearer" or "basic" are only masked when followed by something that looks like a secret.
///
/// Every rule runs in time linear in the input: matches may only start at the beginning of a token run
/// (look-behind anchors instead of `\b`), and key prefixes are bounded, so hostile input (minified code,
/// base64 blobs, `a-a-a-…` runs) cannot trigger quadratic backtracking.
public enum SecretRedactor {
    /// Replacement marker.
    public static let marker = "[REDACTED]"

    /// Returns `text` with every recognized secret replaced by `[REDACTED]` (keeping a non-secret prefix such as
    /// `ghp_` or `password=` for context). Idempotent.
    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        if text.utf8.contains(0x1B), let ansiTokenBoundary {
            // Redact the pieces between "ESC[…m" and a token prefix separately, so the prefix rules see a boundary.
            let ns = text as NSString
            let cuts = ansiTokenBoundary.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { $0.range.upperBound }
            if !cuts.isEmpty {
                var pieces: [String] = []
                var start = 0
                for cut in cuts {
                    pieces.append(ns.substring(with: NSRange(location: start, length: cut - start)))
                    start = cut
                }
                pieces.append(ns.substring(from: start))
                return pieces.map(applyRules).joined()
            }
        }
        return applyRules(text)
    }

    private static func applyRules(_ text: String) -> String {
        var result = text
        for rule in rules {
            result = rule.apply(to: result)
        }
        return result
    }

    /// Whether `text` contains anything `redact` would mask.
    public static func containsSecret(_ text: String) -> Bool {
        redact(text) != text
    }

    // MARK: Rules

    private struct Match {
        let string: NSString
        let result: NSTextCheckingResult

        func group(_ index: Int) -> String {
            let range = result.range(at: index)
            guard range.location != NSNotFound else { return "" }
            return string.substring(with: range)
        }
    }

    private struct Rule: Sendable {
        let regex: NSRegularExpression
        /// Replacement for a match, or nil to keep the original text.
        let replace: @Sendable (Match) -> String?

        init(_ pattern: String, options: NSRegularExpression.Options = [], replace: @escaping @Sendable (Match) -> String?) {
            do {
                regex = try NSRegularExpression(pattern: pattern, options: options)
            } catch {
                preconditionFailure("Invalid redaction pattern \(pattern): \(error)")
            }
            self.replace = replace
        }

        func apply(to text: String) -> String {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return text }
            var output = ""
            var cursor = 0
            for result in matches {
                guard let replacement = replace(Match(string: ns, result: result)) else { continue }
                output += ns.substring(with: NSRange(location: cursor, length: result.range.location - cursor))
                output += replacement
                cursor = result.range.location + result.range.length
            }
            output += ns.substring(from: cursor)
            return output
        }
    }

    /// Characters that make up a key "run" (`GITHUB_TOKEN`, `client-secret`, `db.password`).
    private static let keyRunClass = #"A-Za-z0-9_.\-"#

    /// A match may only start where the previous character is not part of the same key run.
    private static let runStart = #"(?<![\#(keyRunClass)])"#

    /// Distinctive token prefixes: not preceded by an alphanumeric character, or right after a percent-escape
    /// (`%3Aghs_…` in URL-encoded text). A token right after an ANSI SGR/CSI sequence (`ESC[1mghp_…`, where the
    /// `m` counts as a preceding letter) is handled by `redact` splitting the text there (`ansiTokenBoundary`).
    private static let prefixStart = #"(?:(?<![A-Za-z0-9])|(?<=%[0-9A-Fa-f]{2}))"#

    /// End of a CSI sequence immediately followed by a distinctive token prefix. Anchored on the ESC byte, so it
    /// costs nothing on text without escapes.
    private static let ansiTokenBoundary: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\x{1B}\[[0-9;:?<=>]{0,32}[A-Za-z@~](?=gh[pousr]_|github_pat_|gl[a-z]{2,7}-|AT[AC]TT|ATBB|sk-|[sr]k_(?:live|test)_|npm_|dckr_pat_|AIza|xox[a-z]-|A[A-Z]{3}[A-Z0-9]{16})"#
    )

    /// `prefixStart`, evaluated only where the next character can start the token (`firstCharacters` is a regex
    /// character-class body). The cheap look-ahead fails at almost every position, so the bounded look-behinds run
    /// rarely and redaction stays fast on large logs.
    private static func gate(_ firstCharacters: String) -> String {
        #"(?=[\#(firstCharacters)])\#(prefixStart)"#
    }

    /// Key names whose values are secrets. The key must *end* with one of these words, so `max_tokens=5` or
    /// `tokenizer=bert` are not touched. The prefix before the word is bounded (≤ 64 characters).
    private static let secretKey =
        #"[\#(keyRunClass)]{0,64}?(?:password|passwd|passphrase|token|secret|api[_\-]?key|apikey|access[_\-]?key|private[_\-]?key|credentials?)"#

    /// A secret value: a double-quoted string (with escapes), a single-quoted string, or a bare run.
    private static let secretValue = #"("(?:[^"\\\r\n]|\\.)*"|'[^'\r\n]*'|[^\s&,;"'<>{}]+)"#

    private static let rules: [Rule] = [
        // PEM / PGP private keys (terminated or cut off at the end of the text).
        Rule(#"-----BEGIN[ A-Z0-9]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END[ A-Z0-9]*PRIVATE KEY(?: BLOCK)?-----|\z)"#) { _ in
            "[REDACTED PRIVATE KEY]"
        },
        // URL userinfo with a password: scheme://user:secret@host (the password may itself contain "@").
        Rule(#"(?<![A-Za-z0-9+.\-])([A-Za-z][A-Za-z0-9+.\-]{0,31}://)([^/\s:@?#]+):([^/\s?#]+)@"#) { m in
            m.group(3) == marker ? nil : "\(m.group(1))\(m.group(2)):\(marker)@"
        },
        // URL userinfo that is a bare token: https://<token>@host.
        Rule(#"(?<![A-Za-z0-9+.\-])(https?://)([^/\s:@?#]{16,})@"#, options: [.caseInsensitive]) { m in
            looksLikeSecret(m.group(2)) ? "\(m.group(1))\(marker)@" : nil
        },
        // Authorization headers (any scheme). Without a scheme the value must look like a secret, so
        // "authorization: required" stays readable.
        Rule(
            #"(?<![A-Za-z0-9_\-])((?:proxy-)?authorization)([ \t]*[:=][ \t]*)(?:(bearer|basic|token|bot|digest|negotiate|bearer-token)[ \t]+)?("?)([^\s"',;]+)"#,
            options: [.caseInsensitive]
        ) { m in
            let value = m.group(5)
            guard !isMasked(value) else { return nil }
            let hasScheme = !m.group(3).isEmpty
            guard hasScheme || looksLikeSecret(value) else { return nil }
            let scheme = hasScheme ? m.group(3) + " " : ""
            return "\(m.group(1))\(m.group(2))\(scheme)\(m.group(4))\(marker)"
        },
        // Token headers used by GitLab and others.
        Rule(
            #"(?<![A-Za-z0-9_\-])(private-token|job-token|deploy-token|x-api-key|x-auth-token|x-gitlab-token|x-vault-token|x-[A-Za-z0-9\-]{0,40}-token)([ \t]*:[ \t]*)([^\s"',;]+)"#,
            options: [.caseInsensitive]
        ) { m in
            isMasked(m.group(3)) ? nil : "\(m.group(1))\(m.group(2))\(marker)"
        },
        // Cookies: the whole header value.
        Rule(#"(?<![A-Za-z0-9_\-])((?:set-)?cookie)([ \t]*:[ \t]*)([^\r\n]+)"#, options: [.caseInsensitive]) { m in
            isMasked(m.group(3)) ? nil : "\(m.group(1))\(m.group(2))\(marker)"
        },
        // GitHub tokens.
        Rule(#"\#(gate("g"))(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}"#) { m in "\(m.group(1))_\(marker)" },
        Rule(#"\#(gate("g"))github_pat_[A-Za-z0-9_]{20,}"#) { _ in "github_pat_\(marker)" },
        // GitLab tokens.
        Rule(#"\#(gate("g"))(glpat|gloas|glrt|glptt|gldt|glft|glsoat|glcbt|glimt|glagent|glffct)-[A-Za-z0-9_\-]{16,}(?:\.[A-Za-z0-9_\-]+)*"#) { m in
            "\(m.group(1))-\(marker)"
        },
        // Atlassian API tokens / Bitbucket app passwords.
        Rule(#"\#(gate("A"))(ATATT|ATCTT|ATBB)[A-Za-z0-9_\-=]{16,}"#) { m in "\(m.group(1))\(marker)" },
        // OpenAI (`sk-proj-`, `sk-svcacct-`, `sk-admin-`, legacy `sk-` + 32+ alphanumerics), Anthropic
        // (`sk-ant-api03-…`), Stripe secret/restricted keys, npm, Docker Hub and Google API keys — one pass.
        Rule(
            #"\#(gate("snrdA"))(?:(sk-(?:proj|svcacct|admin|ant(?:-[a-z]{3,8}[0-9]{2})?)-)[A-Za-z0-9_\-]{20,}|((?:sk|rk)_(?:live|test)_)[A-Za-z0-9]{10,}|(npm_)[A-Za-z0-9]{30,}|(dckr_pat_)[A-Za-z0-9_\-]{20,}|(AIza)[0-9A-Za-z_\-]{35}|(sk-)[A-Za-z0-9]{32,}(?![A-Za-z0-9_\-]))"#
        ) { m in
            let prefix = (1...6).lazy.map { m.group($0) }.first { !$0.isEmpty } ?? ""
            return "\(prefix)\(marker)"
        },
        // Slack incoming-webhook / workflow URLs: the path is the secret.
        Rule(#"(https?://hooks\.slack(?:-gov)?\.com/(?:services|workflows|triggers)/)[A-Za-z0-9_/\-]+"#, options: [.caseInsensitive]) { m in
            "\(m.group(1))\(marker)"
        },
        // Slack tokens.
        Rule(#"\#(gate("x"))(xox[a-z]-)[A-Za-z0-9\-]{8,}"#) { m in "\(m.group(1))\(marker)" },
        // AWS access key ids.
        Rule(#"\#(gate("A"))(AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[A-Z0-9]{16}(?![A-Za-z0-9])"#) { m in "\(m.group(1))\(marker)" },
        // JWTs (header and payload are base64url JSON objects: "eyJ"). Anchored at the start of a base64url run.
        Rule(#"(?<![A-Za-z0-9_\-])eyJ[A-Za-z0-9_\-]{5,}\.eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*"#) { _ in marker },
        // Standalone "Bearer <token>".
        Rule(#"(?<![A-Za-z0-9_\-])(bearer)[ \t]+([A-Za-z0-9_~+/\-]+(?:\.[A-Za-z0-9_~+/\-]+)*=*)"#, options: [.caseInsensitive]) { m in
            let token = m.group(2)
            return token.count >= 8 && looksLikeSecret(token) ? "\(m.group(1)) \(marker)" : nil
        },
        // Standalone "Basic <base64>".
        Rule(#"(?<![A-Za-z0-9_\-])(Basic|BASIC)[ \t]+([A-Za-z0-9+/]{12,}={0,2})(?![A-Za-z0-9+/=])"#) { m in
            looksLikeSecret(m.group(2)) ? "\(m.group(1)) \(marker)" : nil
        },
        // key/value pairs: `password=x`, `token: x`, `"secret": "x"`, `'api_key': 1234`, `:password => "x"`
        // (env vars, query strings, YAML, JSON, Ruby/Python literals). Separators never cross a line break.
        Rule(
            #"\#(runStart)(['"]?)(\#(secretKey))(['"]?)([ \t]*(?:=>|:|=)[ \t]*)\#(secretValue)"#,
            options: [.caseInsensitive]
        ) { m in
            maskedPair(prefix: m.group(1) + m.group(2) + m.group(3) + m.group(4), key: m.group(2), value: m.group(5))
        },
        // CLI flags with a separate value: `--password hunter2`, `-token abc123`.
        Rule(
            #"(?<![\#(keyRunClass)])(--?\#(secretKey))([ \t]+)("(?:[^"\\\r\n]|\\.)*"|'[^'\r\n]*'|[^\s"'\-][^\s]*)"#,
            options: [.caseInsensitive]
        ) { m in
            maskedPair(prefix: m.group(1) + m.group(2), key: m.group(1), value: m.group(3))
        },
    ]

    /// Replacement for a key/value match, or nil when the value is empty, already masked, or a harmless numeric
    /// limit (`max_token=128`, `num_tokens: 5`).
    private static func maskedPair(prefix: String, key: String, value: String) -> String? {
        guard !value.isEmpty, value != "\"\"", value != "''", !isMasked(value) else { return nil }
        if isNumericLimit(key: key, value: value) { return nil }
        let quote = value.first == "\"" || value.first == "'" ? String(value.prefix(1)) : ""
        return "\(prefix)\(quote)\(marker)\(quote)"
    }

    /// Whether a captured value already starts with the marker (possibly quoted). Keeps `redact` idempotent and
    /// leaves text after an earlier rule's marker alone (`x-access-token:[REDACTED]@github.com`).
    private static func isMasked(_ value: String) -> Bool {
        value.hasPrefix(marker) || value.hasPrefix("\"" + marker) || value.hasPrefix("'" + marker)
    }

    /// `max_token=128`, `min-tokens: 1`, `num_token=3`, `total_tokens: 40`: counts, not credentials.
    private static func isNumericLimit(key: String, value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 12, value.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            return false
        }
        let normalized = key.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return ["max", "min", "num", "total", "count"].contains { normalized.hasPrefix($0) }
    }

    /// Heuristic for bare `Bearer`/`Basic`/userinfo values: random-looking strings contain a digit, a base64/url
    /// symbol, or an uppercase letter after the first character. Ordinary words ("authentication", "Instrument")
    /// do not.
    private static func looksLikeSecret(_ value: String) -> Bool {
        var hasDigit = false
        var hasSymbol = false
        var hasInnerUpper = false
        for (index, scalar) in value.unicodeScalars.enumerated() {
            switch scalar {
            case "0"..."9": hasDigit = true
            case "+", "/", "=", "_": hasSymbol = true
            case "A"..."Z" where index > 0: hasInnerUpper = true
            default: break
            }
        }
        return hasDigit || hasSymbol || hasInnerUpper
    }
}
