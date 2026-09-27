import Foundation

/// Pure rule matching. Idempotency (per rule+event) and firing counts are persisted by the engine/store.
public enum RuleEvaluator {
    /// Outcome of `decide`.
    public enum Decision: Sendable, Hashable {
        case fire
        case skip(SkipReason)
    }

    public enum SkipReason: String, Sendable, Hashable, CaseIterable {
        case inactive
        case baseline
        case notMatching = "not_matching"
        case quietHours = "quiet_hours"
        case rateLimited = "rate_limited"
    }

    /// Filter match only (does not look at `isActive`, quiet hours or rate limits).
    ///
    /// Honors provider kinds, accounts, event types, repo include/exclude globs, involvement, excluded authors and
    /// comment kinds (all "empty = any"). Events caused by the current user never match.
    public static func matches(_ rule: Rule, event: ChangeEvent, involvement: Set<Involvement>) -> Bool {
        if event.isFromCurrentUser { return false }
        if !rule.providerKinds.isEmpty, !rule.providerKinds.contains(event.providerKind) { return false }
        if !rule.accounts.isEmpty, !rule.accounts.contains(event.account) { return false }
        if !rule.eventTypes.isEmpty, !rule.eventTypes.contains(event.type) { return false }
        if !rule.repoInclude.isEmpty, !rule.repoInclude.contains(where: { glob($0, matches: event.repoFullPath) }) {
            return false
        }
        if rule.repoExclude.contains(where: { glob($0, matches: event.repoFullPath) }) { return false }
        if !rule.involvement.isEmpty, rule.involvement.isDisjoint(with: involvement) { return false }
        if !rule.commentKinds.isEmpty {
            guard let kind = event.commentKind, rule.commentKinds.contains(kind) else { return false }
        }
        if let actor = event.actor, !rule.excludeAuthors.isEmpty {
            let username = normalizeAuthor(actor.username)
            if rule.excludeAuthors.contains(where: { normalizeAuthor($0) == username }) { return false }
        }
        return true
    }

    /// Full firing decision: active, not a baseline event, matching, outside quiet hours and under the hourly cap.
    public static func decide(
        _ rule: Rule,
        event: ChangeEvent,
        involvement: Set<Involvement>,
        now: Date,
        firesInLastHour: Int
    ) -> Decision {
        guard rule.isActive else { return .skip(.inactive) }
        guard !event.isBaseline else { return .skip(.baseline) }
        guard matches(rule, event: event, involvement: involvement) else { return .skip(.notMatching) }
        if let quiet = rule.quietHours, quiet.contains(now) { return .skip(.quietHours) }
        guard firesInLastHour < rule.maxFiresPerHour else { return .skip(.rateLimited) }
        return .fire
    }

    /// Case-insensitive glob on repository paths: `*` = any run of characters except `/`, `**` = anything
    /// including `/`, `**/` = zero or more whole path segments, `?` = one character except `/`.
    public static func glob(_ pattern: String, matches candidate: String) -> Bool {
        let tokens = tokenize(Array(pattern.lowercased()))
        let text = Array(candidate.lowercased())
        var memo = [Int8](repeating: -1, count: (tokens.count + 1) * (text.count + 1))
        return match(tokens, 0, text, 0, &memo)
    }

    // MARK: Glob internals

    private enum Token: Equatable {
        case literal(Character)
        case single
        case star
        case globstar
        case globstarSlash
    }

    private static func tokenize(_ pattern: [Character]) -> [Token] {
        var tokens: [Token] = []
        var index = 0
        while index < pattern.count {
            let char = pattern[index]
            switch char {
            case "*":
                var end = index
                while end < pattern.count, pattern[end] == "*" { end += 1 }
                if end - index == 1 {
                    tokens.append(.star)
                } else if end < pattern.count, pattern[end] == "/" {
                    tokens.append(.globstarSlash)
                    end += 1
                } else {
                    tokens.append(.globstar)
                }
                index = end
            case "?":
                tokens.append(.single)
                index += 1
            default:
                tokens.append(.literal(char))
                index += 1
            }
        }
        return tokens
    }

    private static func match(_ tokens: [Token], _ ti: Int, _ text: [Character], _ si: Int, _ memo: inout [Int8]) -> Bool {
        let slot = ti * (text.count + 1) + si
        if memo[slot] != -1 { return memo[slot] == 1 }
        let result: Bool
        if ti == tokens.count {
            result = si == text.count
        } else {
            switch tokens[ti] {
            case .literal(let char):
                result = si < text.count && text[si] == char && match(tokens, ti + 1, text, si + 1, &memo)
            case .single:
                result = si < text.count && text[si] != "/" && match(tokens, ti + 1, text, si + 1, &memo)
            case .star:
                var k = si
                var found = false
                while true {
                    if match(tokens, ti + 1, text, k, &memo) { found = true; break }
                    if k >= text.count || text[k] == "/" { break }
                    k += 1
                }
                result = found
            case .globstar:
                result = (si...text.count).contains { match(tokens, ti + 1, text, $0, &memo) }
            case .globstarSlash:
                if match(tokens, ti + 1, text, si, &memo) {
                    result = true
                } else {
                    result = (si..<text.count).contains { text[$0] == "/" && match(tokens, ti + 1, text, $0 + 1, &memo) }
                }
            }
        }
        memo[slot] = result ? 1 : 0
        return result
    }

    private static func normalizeAuthor(_ username: String) -> String {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        return (trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed).lowercased()
    }
}
