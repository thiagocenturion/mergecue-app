import Foundation

/// A compiled `StubTransport` route pattern.
struct RoutePattern {
    enum Segment: Equatable {
        case literal(String)
        /// `{name}` with an optional literal prefix/suffix inside the same segment.
        case param(name: String, prefix: String, suffix: String)
        /// `*`: exactly one segment.
        case wildcard
        /// Trailing `**`: any remainder.
        case glob
    }

    /// Ordering of matching routes: more literal segments, exact length over `**`, affixed params, more query
    /// constraints, then later registration.
    struct Score: Comparable {
        var literals: Int
        var exact: Int
        var affixed: Int
        var queryConstraints: Int
        var order: Int

        static func < (lhs: Score, rhs: Score) -> Bool {
            (lhs.literals, lhs.exact, lhs.affixed, lhs.queryConstraints, lhs.order)
                < (rhs.literals, rhs.exact, rhs.affixed, rhs.queryConstraints, rhs.order)
        }
    }

    let segments: [Segment]
    let query: [String: String]

    init(_ pattern: String, extraQuery: [String: String] = [:]) {
        var path = pattern
        var query: [String: String] = [:]
        if let questionMark = pattern.firstIndex(of: "?") {
            path = String(pattern[..<questionMark])
            for (name, value) in Self.parseQuery(String(pattern[pattern.index(after: questionMark)...])) {
                query[name] = value ?? ""
            }
        }
        query.merge(extraQuery) { _, explicit in explicit }
        self.query = query

        let raw = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        self.segments = raw.enumerated().map { index, segment in
            if segment == "**" { return index == raw.count - 1 ? .glob : .wildcard }
            if segment == "*" { return .wildcard }
            if let open = segment.firstIndex(of: "{"), let close = segment[open...].firstIndex(of: "}"),
               segment.index(after: open) < close
            {
                let name = String(segment[segment.index(after: open)..<close])
                return .param(
                    name: name,
                    prefix: Self.decode(String(segment[..<open])),
                    suffix: Self.decode(String(segment[segment.index(after: close)...]))
                )
            }
            return .literal(Self.decode(segment))
        }
    }

    func score(order: Int) -> Score {
        var score = Score(literals: 0, exact: 1, affixed: 0, queryConstraints: query.count, order: order)
        for segment in segments {
            switch segment {
            case .literal: score.literals += 1
            case .param(_, let prefix, let suffix) where !prefix.isEmpty || !suffix.isEmpty: score.affixed += 1
            case .glob: score.exact = 0
            case .param, .wildcard: break
            }
        }
        return score
    }

    // MARK: Matching

    /// Captures for a request URL: host must match `base`; the path is matched relative to `base`'s path first,
    /// then as a whole (for patterns written with the API prefix).
    func captures(in url: URL, base: URL) -> [String: String]? {
        if let baseHost = base.host(percentEncoded: false), !baseHost.isEmpty {
            guard url.host(percentEncoded: false)?.lowercased() == baseHost.lowercased() else { return nil }
        }
        if let relative = Self.relativeSegments(of: url, base: base), let params = captures(inSegments: relative) {
            return params
        }
        return captures(inSegments: Self.segments(of: url.path(percentEncoded: true)))
    }

    /// Captures against the longest matching suffix of the URL's path (used when no base URL is known).
    func capturesInAnySuffix(of url: URL) -> [String: String]? {
        let all = Self.segments(of: url.path(percentEncoded: true))
        for start in all.indices {
            if let params = captures(inSegments: Array(all[start...])) { return params }
        }
        return captures(inSegments: [])
    }

    func captures(inSegments request: [String]) -> [String: String]? {
        var params: [String: String] = [:]
        var index = 0
        for segment in segments {
            if case .glob = segment {
                params["**"] = request[min(index, request.count)...].joined(separator: "/")
                return params
            }
            guard index < request.count else { return nil }
            let value = request[index]
            switch segment {
            case .literal(let literal):
                guard literal == value else { return nil }
            case .param(let name, let prefix, let suffix):
                guard value.count > prefix.count + suffix.count, value.hasPrefix(prefix), value.hasSuffix(suffix) else {
                    return nil
                }
                params[name] = String(value.dropFirst(prefix.count).dropLast(suffix.count))
            case .wildcard:
                break
            case .glob:
                break
            }
            index += 1
        }
        return index == request.count ? params : nil
    }

    func queryMatches(_ requestQuery: [String: [String]]) -> Bool {
        query.allSatisfy { name, expected in
            guard let values = requestQuery[name] else { return false }
            return expected == "*" || values.contains(expected)
        }
    }

    // MARK: URL helpers

    /// Percent-decoded, non-empty segments of a percent-encoded path.
    static func segments(of percentEncodedPath: String) -> [String] {
        var path = percentEncodedPath
        if let questionMark = path.firstIndex(of: "?") { path = String(path[..<questionMark]) }
        return path.split(separator: "/", omittingEmptySubsequences: true).map { decode(String($0)) }
    }

    /// Segments of `url` after `base`'s path prefix, or nil when the URL is outside it.
    static func relativeSegments(of url: URL, base: URL) -> [String]? {
        let baseSegments = segments(of: base.path(percentEncoded: true))
        let requestSegments = segments(of: url.path(percentEncoded: true))
        guard requestSegments.starts(with: baseSegments) else { return nil }
        return Array(requestSegments.dropFirst(baseSegments.count))
    }

    /// Decoded query, `+` treated as space; repeated names keep all values in order.
    static func decodedQuery(of url: URL) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (name, value) in queryPairs(of: url) {
            result[name, default: []].append(value ?? "")
        }
        return result
    }

    static func queryPairs(of url: URL) -> [(String, String?)] {
        guard let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery else { return [] }
        return parseQuery(query)
    }

    static func parseQuery(_ query: String) -> [(String, String?)] {
        query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            if let equals = pair.firstIndex(of: "=") {
                return (formDecode(String(pair[..<equals])), formDecode(String(pair[pair.index(after: equals)...])))
            }
            return (formDecode(String(pair)), nil)
        }
    }

    private static func formDecode(_ text: String) -> String {
        decode(text.replacingOccurrences(of: "+", with: " "))
    }

    static func decode(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }
}
