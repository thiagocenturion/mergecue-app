import Foundation
import MergeCueCore
import Security

/// Extra per-connection check after the mandatory `getpeereid` uid check (e.g. the peer's code signature).
///
/// Called once per accepted connection, on a private dispatch queue (never on the Swift concurrency pool), before
/// any request is read. Throw to reject: the peer receives one `unauthorized` response and the connection closes.
public protocol PeerValidator: Sendable {
    func validate(_ peer: IPCPeerCredentials) throws
}

/// Why a peer was rejected.
public struct PeerValidationError: Error, Sendable, Equatable, LocalizedError {
    public var message: String
    /// `OSStatus` from Security.framework, when relevant.
    public var status: Int32?

    public init(_ message: String, status: Int32? = nil) {
        self.message = message
        self.status = status
    }

    public var errorDescription: String? {
        status.map { "\(message) (OSStatus \($0))" } ?? message
    }
}

/// Validates the peer process against a code requirement (`SecCodeCheckValidity`). The guest is looked up by
/// audit token (`LOCAL_PEERTOKEN`, immune to pid reuse) and falls back to `LOCAL_PEERPID`.
///
/// Only enabled when a requirement is supplied: `make(requirement:)` returns nil for a nil/blank requirement, so
/// unsigned development builds keep working with the uid + token checks alone.
public struct CodeSignaturePeerValidator: PeerValidator {
    /// The requirement source text, e.g. `anchor apple generic and certificate leaf[subject.OU] = "TEAMID"`.
    public let requirementText: String
    private let requirement: CompiledRequirement

    /// Compiles `requirement`; throws for invalid requirement syntax.
    public init(requirement: String) throws(PeerValidationError) {
        let trimmed = requirement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PeerValidationError("The code requirement is empty.") }
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(trimmed as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else {
            throw PeerValidationError("Invalid code requirement.", status: status)
        }
        self.requirementText = trimmed
        self.requirement = CompiledRequirement(compiled)
    }

    /// nil when `requirement` is nil or blank (validation disabled).
    public static func make(requirement: String?) throws(PeerValidationError) -> CodeSignaturePeerValidator? {
        guard let requirement, !requirement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try CodeSignaturePeerValidator(requirement: requirement)
    }

    /// Requirement matching any binary signed by `teamIdentifier` (Apple-issued certificate chain).
    public static func requirement(teamIdentifier: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// Team ID of the running process's signature, or nil when unsigned / ad-hoc signed.
    public static func currentTeamIdentifier() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    public func validate(_ peer: IPCPeerCredentials) throws {
        var attributes: [String: Any] = [:]
        if let auditToken = peer.auditToken {
            attributes[kSecGuestAttributeAudit as String] = auditToken as CFData
        } else if let pid = peer.pid {
            attributes[kSecGuestAttributePid as String] = NSNumber(value: pid)
        } else {
            throw PeerValidationError("The peer process could not be identified.")
        }
        var guest: SecCode?
        let lookup = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &guest)
        guard lookup == errSecSuccess, let guest else {
            throw PeerValidationError("The peer's code signature could not be read.", status: lookup)
        }
        let check = SecCodeCheckValidity(guest, [], requirement.value)
        guard check == errSecSuccess else {
            throw PeerValidationError("The peer's code signature does not satisfy the MergeCue requirement.", status: check)
        }
    }
}

/// `SecRequirement` is an immutable, thread-safe CF object once created.
private final class CompiledRequirement: @unchecked Sendable {
    let value: SecRequirement

    init(_ value: SecRequirement) {
        self.value = value
    }
}
