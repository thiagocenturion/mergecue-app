import Foundation

/// A bounded, redacted excerpt of a CI failure log. The text is untrusted input.
public struct LogExcerpt: Codable, Sendable, Hashable {
    public var text: String
    public var truncated: Bool
    public var fullLogURL: URL?
    public var totalBytes: Int?

    public init(text: String, truncated: Bool, fullLogURL: URL? = nil, totalBytes: Int? = nil) {
        self.text = text
        self.truncated = truncated
        self.fullLogURL = fullLogURL
        self.totalBytes = totalBytes
    }

    /// Strips terminal control sequences (`TerminalControlStripper`), redacts secrets, then bounds the result with
    /// `BoundedText.logExcerpt` (error context + tail). A `fullLogURL` that is not http(s) is dropped.
    public static func make(rawLog: String, maxBytes: Int, fullLogURL: URL? = nil) -> LogExcerpt {
        let redacted = SecretRedactor.redact(TerminalControlStripper.strip(rawLog))
        let bounded = BoundedText.logExcerpt(redacted, maxBytes: maxBytes)
        return LogExcerpt(
            text: bounded.text,
            truncated: bounded.isTruncated,
            fullLogURL: WebLinkPolicy.webURL(fullLogURL),
            totalBytes: rawLog.utf8.count
        )
    }
}

/// A bounded unified diff.
public struct DiffPayload: Codable, Sendable, Hashable {
    public var unifiedDiff: String
    public var files: [ChangedFile]
    public var truncated: Bool
    public var baseSHA: String?
    public var headSHA: String?

    public init(unifiedDiff: String, files: [ChangedFile], truncated: Bool, baseSHA: String? = nil, headSHA: String? = nil) {
        self.unifiedDiff = unifiedDiff
        self.files = files
        self.truncated = truncated
        self.baseSHA = baseSHA
        self.headSHA = headSHA
    }
}

/// How to fetch the change request head into a local repository.
public struct FetchHeadSpec: Codable, Sendable, Hashable {
    /// Candidate remote URLs (https/ssh) of the repository that holds `refspec`.
    public var remoteURLs: [String]
    /// "refs/pull/42/head", "refs/merge-requests/7/head", "refs/heads/feature-x".
    public var refspec: String
    public var expectedSHA: String?
    public var isFork: Bool

    public init(remoteURLs: [String], refspec: String, expectedSHA: String? = nil, isFork: Bool = false) {
        self.remoteURLs = remoteURLs
        self.refspec = refspec
        self.expectedSHA = expectedSHA
        self.isFork = isFork
    }
}

/// Target of a provider deep link.
public enum DeepLinkTarget: Sendable, Hashable {
    case changeRequest(ChangeRequestKey)
    case thread(ThreadKey)
    case comment(ThreadKey, commentID: String)
    case check(CheckKey)

    public var changeRequest: ChangeRequestKey {
        switch self {
        case .changeRequest(let key): key
        case .thread(let key), .comment(let key, _): key.changeRequest
        case .check(let key): key.changeRequest
        }
    }
}
