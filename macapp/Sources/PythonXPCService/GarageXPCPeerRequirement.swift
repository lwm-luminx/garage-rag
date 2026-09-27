import Foundation
import OSLog
import Security

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "GarageXPCPeerRequirement")

/// The code-signing requirement every Garage XPC listener puts on the processes that connect to it.
///
/// A bundled XPC service can only be looked up from inside the app bundle, but nothing checked who
/// was on the other end once a connection existed: code injected into the app, or a debugger's
/// target, got every service. The requirement pins the peer to Apple-issued signing (Developer ID,
/// App Store or Apple Development) with this process's own team, so only the app, its sibling
/// services and the launcher helpers, all signed by the same team, get through.
///
/// A process signed without a team (ad hoc, `local_signed`, tests) has nothing to pin, so its
/// listeners take no requirement and behave as before.
public enum GarageXPCPeerRequirement {
    /// The requirement string, or nil when this process carries no team identifier.
    public static let requirement: String? = {
        guard let team = teamIdentifier(), isPlainTeamIdentifier(team) else {
            logger.info("No team identifier in this process's signature; XPC peers are not checked")
            return nil
        }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }()

    /// Puts `requirement` on a connection a listener has just been offered, before it is resumed, so
    /// a peer that does not satisfy it has its messages refused and the connection invalidated.
    ///
    /// It goes on each connection rather than on the listener: `NSXPCListener.service()` has no
    /// underlying connection until it is resumed, and `setConnectionCodeSigningRequirement(_:)` on it
    /// crashes the service at launch (SIGSEGV inside the setter).
    public static func apply(to connection: NSXPCConnection, serviceName: String) {
        guard let requirement else { return }
        connection.setCodeSigningRequirement(requirement)
        logger.debug("\(serviceName, privacy: .public): XPC peer pid \(connection.processIdentifier, privacy: .public) must satisfy \(requirement, privacy: .public)")
    }

    /// The team identifier in this process's code signature, when it has one.
    static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Team identifiers are ten uppercase letters and digits; anything else is not quoted into a requirement.
    static func isPlainTeamIdentifier(_ team: String) -> Bool {
        !team.isEmpty && team.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }
}
