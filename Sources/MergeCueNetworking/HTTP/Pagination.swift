import Foundation

/// RFC 8288 (formerly RFC 5988) `Link` header parsing.
///
/// Handles several link-values per header, commas and semicolons inside `<…>` and inside quoted parameter values,
/// quoted or bare `rel` values, several space-separated relation types (`rel="next last"`), case-insensitive
/// names/relations and arbitrary whitespace. Only `http`/`https` targets are returned; relative targets are
/// resolved against `relativeTo` when given and dropped otherwise.
public enum Pagination {
    /// One parsed link-value.
    public struct Link: Sendable, Hashable {
        /// The raw target inside `<…>`.
        public var target: String
        /// Lower-cased relation types.
        public var relations: [String]
        /// Lower-cased parameter names → values (unquoted).
        public var parameters: [String: String]
    }

    /// The `rel="next"` target, if any.
    public static func nextLink(fromLinkHeader header: String?) -> URL? {
        nextLink(fromLinkHeader: header, relativeTo: nil)
    }

    /// The `rel="next"` target, resolving relative references against `base`.
    public static func nextLink(fromLinkHeader header: String?, relativeTo base: URL?) -> URL? {
        link(relation: "next", fromLinkHeader: header, relativeTo: base)
    }

    /// The `next` link of a response's `Link` header, resolved against the response URL.
    public static func nextLink(from response: HTTPResponse) -> URL? {
        nextLink(fromLinkHeader: response.header("link"), relativeTo: response.url)
    }

    /// The first target whose relation types include `relation` (case-insensitive).
    public static func link(relation: String, fromLinkHeader header: String?, relativeTo base: URL? = nil) -> URL? {
        guard let header else { return nil }
        let wanted = relation.lowercased()
        for link in parse(header) where link.relations.contains(wanted) {
            if let url = resolve(link.target, relativeTo: base) {
                return url
            }
        }
        return nil
    }

    /// All link-values of a header, in order. Malformed link-values are skipped.
    public static func parse(_ header: String) -> [Link] {
        var scanner = LinkScanner(Array(header.unicodeScalars))
        var links: [Link] = []
        while !scanner.isAtEnd {
            if let link = scanner.nextLink() {
                links.append(link)
            }
        }
        return links
    }

    static func resolve(_ target: String, relativeTo base: URL?) -> URL? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let reference = URL(string: trimmed, relativeTo: base) else { return nil }
        let absolute = reference.absoluteURL
        guard let scheme = absolute.scheme?.lowercased(), scheme == "https" || scheme == "http",
              absolute.host() != nil
        else { return nil }
        return absolute
    }
}

/// A small hand-written scanner: link-values are separated by commas that are **outside** `<…>` and quotes.
private struct LinkScanner {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    var isAtEnd: Bool { index >= scalars.count }

    private var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    private mutating func skipWhitespace() {
        while let scalar = current, scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n" {
            index += 1
        }
    }

    /// Skips to just after the next top-level comma (or the end).
    private mutating func skipToNextLinkValue() {
        var inQuotes = false
        var inBrackets = false
        while let scalar = current {
            index += 1
            if inQuotes {
                if scalar == "\\" { index += 1 } else if scalar == "\"" { inQuotes = false }
            } else if inBrackets {
                if scalar == ">" { inBrackets = false }
            } else if scalar == "\"" {
                inQuotes = true
            } else if scalar == "<" {
                inBrackets = true
            } else if scalar == "," {
                return
            }
        }
    }

    mutating func nextLink() -> Pagination.Link? {
        skipWhitespace()
        while current == "," {
            index += 1
            skipWhitespace()
        }
        guard current == "<" else {
            skipToNextLinkValue()
            return nil
        }
        index += 1
        var target = ""
        while let scalar = current, scalar != ">" {
            target.unicodeScalars.append(scalar)
            index += 1
        }
        guard current == ">" else { return nil }  // unterminated target
        index += 1

        var parameters: [String: String] = [:]
        while true {
            skipWhitespace()
            guard let scalar = current else { break }
            if scalar == "," {
                index += 1
                break
            }
            guard scalar == ";" else {
                // Garbage after the target: drop this link-value.
                skipToNextLinkValue()
                return nil
            }
            index += 1
            skipWhitespace()
            var name = ""
            while let scalar = current, scalar != "=", scalar != ";", scalar != ",", scalar != " ", scalar != "\t" {
                name.unicodeScalars.append(scalar)
                index += 1
            }
            skipWhitespace()
            var value = ""
            if current == "=" {
                index += 1
                skipWhitespace()
                if current == "\"" {
                    index += 1
                    while let scalar = current, scalar != "\"" {
                        if scalar == "\\" {
                            index += 1
                            if let escaped = current { value.unicodeScalars.append(escaped) }
                        } else {
                            value.unicodeScalars.append(scalar)
                        }
                        index += 1
                    }
                    if current == "\"" { index += 1 }
                } else {
                    while let scalar = current, scalar != ";", scalar != ",", scalar != " ", scalar != "\t" {
                        value.unicodeScalars.append(scalar)
                        index += 1
                    }
                }
            }
            let key = name.lowercased()
            // RFC 8288 §3.3: only the first occurrence of `rel` counts.
            if !key.isEmpty, parameters[key] == nil {
                parameters[key] = value
            }
        }
        let relations = (parameters["rel"] ?? "")
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        return Pagination.Link(target: target, relations: relations, parameters: parameters)
    }
}
