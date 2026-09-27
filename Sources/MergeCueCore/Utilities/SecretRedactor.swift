import Foundation

/// Masks credentials in text that may be displayed, copied, logged or returned over MCP.
///
/// Covers GitHub (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`), GitLab (`glpat-`, `gloas-`, `glrt-`
/// and related prefixes), Atlassian (`ATATT…`, `ATCTT…`, `ATBB…`), Slack (`xox?-`), AWS access key ids, JWTs,
/// `Authorization:` / `Bearer` / `Basic` values, `password=` / `token=` / `secret=`-style pairs (also as JSON
/// members), PEM private keys and URL userinfo passwords. Ordinary prose is left untouched: bare words such as
/// "token", "bearer" or "basic" are only masked when followed by something that looks like a secret.
public enum SecretRedactor {
    /// Replacement marker.
    public static let marker = "[REDACTED]"

    /// Returns `text` with every recognized secret replaced by `[REDACTED]` (keeping a non-secret prefix such as
    /// `ghp_` or `password=` for context). Idempotent.
    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
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

    /// Key names whose values are secrets in `key=value` and `"key": "value"` forms. The key must *end* with
    /// one of these words, so `max_tokens=5` or `tokenizer=bert` are not touched.
    private static let secretKey =
        #"[A-Za-z0-9_.\-]*?(?:password|passwd|passphrase|token|secret|api[_\-]?key|apikey|access[_\-]?key|private[_\-]?key|credentials?)"#

    private static let rules: [Rule] = [
        // PEM private keys (terminated or cut off at the end of the text).
        Rule(#"-----BEGIN[ A-Z0-9]*PRIVATE KEY-----[\s\S]*?(?:-----END[ A-Z0-9]*PRIVATE KEY-----|\z)"#) { _ in
            "[REDACTED PRIVATE KEY]"
        },
        // URL userinfo with a password: scheme://user:secret@host
        Rule(#"\b([A-Za-z][A-Za-z0-9+.\-]*://)([^/\s:@]+):([^/\s@]+)@"#) { m in
            m.group(3) == marker ? nil : "\(m.group(1))\(m.group(2)):\(marker)@"
        },
        // Authorization headers (any scheme).
        Rule(
            #"\b((?:proxy-)?authorization)(\s*[:=]\s*)(?:(bearer|basic|token|bot|digest|negotiate|bearer-token)\s+)?("?)([^\s"',;]+)"#,
            options: [.caseInsensitive]
        ) { m in
            guard m.group(5) != marker else { return nil }
            let scheme = m.group(3).isEmpty ? "" : m.group(3) + " "
            return "\(m.group(1))\(m.group(2))\(scheme)\(m.group(4))\(marker)"
        },
        // Token headers used by GitLab and others.
        Rule(#"\b(private-token|job-token|x-api-key|x-auth-token|x-gitlab-token)(\s*:\s*)([^\s"',;]+)"#, options: [.caseInsensitive]) { m in
            m.group(3) == marker ? nil : "\(m.group(1))\(m.group(2))\(marker)"
        },
        // GitHub tokens.
        Rule(#"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}"#) { m in "\(m.group(1))_\(marker)" },
        Rule(#"\bgithub_pat_[A-Za-z0-9_]{20,}"#) { _ in "github_pat_\(marker)" },
        // GitLab tokens.
        Rule(#"\b(glpat|gloas|glrt|glptt|gldt|glft|glsoat|glcbt|glimt|glagent|glffct)-[A-Za-z0-9_\-]{16,}(?:\.[A-Za-z0-9_\-]+)*"#) { m in
            "\(m.group(1))-\(marker)"
        },
        // Atlassian API tokens / Bitbucket app passwords.
        Rule(#"\b(ATATT|ATCTT|ATBB)[A-Za-z0-9_\-=]{16,}"#) { m in "\(m.group(1))\(marker)" },
        // Slack tokens.
        Rule(#"\b(xox[a-z]-)[A-Za-z0-9\-]{8,}"#) { m in "\(m.group(1))\(marker)" },
        // AWS access key ids.
        Rule(#"\b(AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[A-Z0-9]{16}\b"#) { m in "\(m.group(1))\(marker)" },
        // JWTs (header and payload are base64url JSON objects: "eyJ").
        Rule(#"\beyJ[A-Za-z0-9_\-]{5,}\.eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*"#) { _ in marker },
        // Standalone "Bearer <token>".
        Rule(#"\b(bearer)\s+([A-Za-z0-9_~+/\-]+(?:\.[A-Za-z0-9_~+/\-]+)*=*)"#, options: [.caseInsensitive]) { m in
            let token = m.group(2)
            return token.count >= 8 && looksLikeSecret(token) ? "\(m.group(1)) \(marker)" : nil
        },
        // Standalone "Basic <base64>".
        Rule(#"\b(Basic|BASIC)\s+([A-Za-z0-9+/]{12,}={0,2})(?![A-Za-z0-9+/=])"#) { m in
            looksLikeSecret(m.group(2)) ? "\(m.group(1)) \(marker)" : nil
        },
        // key=value pairs (env vars, query strings, CLI flags).
        Rule(#"\b(\#(secretKey))(\s*=\s*)("[^"]*"|'[^']*'|[^\s&,;"'<>]+)"#, options: [.caseInsensitive]) { m in
            let value = m.group(3)
            guard value != marker, value != "\"\(marker)\"", value != "'\(marker)'", value != "\"\"", value != "''" else {
                return nil
            }
            let quote = value.first == "\"" || value.first == "'" ? String(value.prefix(1)) : ""
            return "\(m.group(1))\(m.group(2))\(quote)\(marker)\(quote)"
        },
        // JSON members: "token": "value".
        Rule(#"("\#(secretKey)")(\s*:\s*)"((?:[^"\\]|\\.)*)""#, options: [.caseInsensitive]) { m in
            let value = m.group(3)
            guard !value.isEmpty, value != marker else { return nil }
            return "\(m.group(1))\(m.group(2))\"\(marker)\""
        },
    ]

    /// Heuristic for bare `Bearer`/`Basic` values: random-looking strings contain a digit, a base64/url symbol, or
    /// an uppercase letter after the first character. Ordinary words ("authentication", "Instrument") do not.
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
