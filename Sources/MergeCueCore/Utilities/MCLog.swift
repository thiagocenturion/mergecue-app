import Foundation
import os

/// Thin `os.Logger` wrapper (subsystem `dev.mergecue`) that runs every message through `SecretRedactor`.
///
/// Messages are logged `.public` after redaction by default; pass `isPrivate: true` for text that may contain
/// personal data (it is then hidden in Console unless private data logging is enabled).
public struct MCLog: Sendable {
    public static let subsystem = "dev.mergecue"

    public let category: String
    private let logger: Logger

    public init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: Self.subsystem, category: category)
    }

    public static let core = MCLog(category: "core")
    public static let sync = MCLog(category: "sync")
    public static let engine = MCLog(category: "engine")
    public static let ipc = MCLog(category: "ipc")
    public static let mcp = MCLog(category: "mcp")
    public static let providers = MCLog(category: "providers")
    public static let workspace = MCLog(category: "workspace")
    public static let ui = MCLog(category: "ui")

    public func log(_ message: String, level: OSLogType = .default, isPrivate: Bool = false) {
        let text = SecretRedactor.redact(message)
        if isPrivate {
            logger.log(level: level, "\(text, privacy: .private)")
        } else {
            logger.log(level: level, "\(text, privacy: .public)")
        }
    }

    public func debug(_ message: String, isPrivate: Bool = false) { log(message, level: .debug, isPrivate: isPrivate) }
    public func info(_ message: String, isPrivate: Bool = false) { log(message, level: .info, isPrivate: isPrivate) }
    public func notice(_ message: String, isPrivate: Bool = false) { log(message, level: .default, isPrivate: isPrivate) }
    public func error(_ message: String, isPrivate: Bool = false) { log(message, level: .error, isPrivate: isPrivate) }
    public func fault(_ message: String, isPrivate: Bool = false) { log(message, level: .fault, isPrivate: isPrivate) }

    /// Formats a redacted diagnostic line for stderr (`mergecue-mcp` must keep stdout for protocol messages).
    public static func standardErrorLine(_ message: String, category: String = "mergecue") -> String {
        "[\(category)] \(SecretRedactor.redact(message))\n"
    }

    /// Writes a redacted diagnostic line to stderr.
    public static func writeToStandardError(_ message: String, category: String = "mergecue") {
        FileHandle.standardError.write(Data(standardErrorLine(message, category: category).utf8))
    }
}
