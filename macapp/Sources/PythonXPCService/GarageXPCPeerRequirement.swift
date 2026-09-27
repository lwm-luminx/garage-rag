import Foundation
import OSLog
import Security

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "XPCPeerRequirement")

/// The code-signing requirement every XPC service puts on the processes that connect to it.
///
/// A bundled XPC service can only be looked up by processes in its own app bundle, but that is all
/// that stood between the services and anything else able to run code as the user. With this, a
/// connection's messages are only delivered when the peer is signed by the same team as this
/// service: the app, its other XPC services and the launcher helpers, all signed together.
///
/// The requirement is `anchor apple generic and certificate leaf[subject.OU] = "<team>"`, with the
/// team read from this process's own signature. It is used only when this process satisfies it
/// itself, which is what makes it safe: the app and every service are signed the same way, so a
/// requirement this service meets is one its siblings meet too. An ad-hoc or locally signed build
/// (no team) and any signature the check cannot read go without one, as before, and say so in the log.
public enum GarageXPCPeerRequirement {
    /// The requirement to set on incoming connections, or nil when this build cannot use one.
    public static let current: String? = {
        guard let team = ownTeamIdentifier() else {
            logger.notice("No team identifier in this process's signature; XPC peers are not checked")
            return nil
        }
        let requirement = GarageXPCPeerRequirement.requirement(forTeam: team)
        guard selfSatisfies(requirement) else {
            logger.error("This process does not satisfy \(requirement, privacy: .public); XPC peers are not checked")
            return nil
        }
        logger.info("XPC peers must satisfy \(requirement, privacy: .public)")
        return requirement
    }()

    /// `anchor apple generic and certificate leaf[subject.OU] = "<team>"`. The team is validated
    /// first (ten upper-case letters and digits), so it cannot change the requirement's meaning.
    public static func requirement(forTeam team: String) -> String {
        precondition(isTeamIdentifier(team), "not a team identifier: \(team)")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    public static func isTeamIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    private static func ownCode() -> SecCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess else { return nil }
        return code
    }

    private static func ownTeamIdentifier() -> String? {
        guard let code = ownCode() else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              isTeamIdentifier(team) else {
            return nil
        }
        return team
    }

    private static func selfSatisfies(_ text: String) -> Bool {
        guard let code = ownCode() else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
