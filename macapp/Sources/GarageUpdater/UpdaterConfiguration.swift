import Foundation

/// Info.plist keys Sparkle reads. Set in `macapp/Sources/GarageApp/Sparkle.plist`,
/// which is merged into the app's Info.plist for Developer ID builds only.
public enum UpdaterInfoPlistKey {
    public static let feedURL = "SUFeedURL"
    public static let publicEDKey = "SUPublicEDKey"
}

/// Value checked into `Sparkle.plist` in place of a real EdDSA public key.
///
/// The key is generated per-developer by `aspect run //ext/sparkle:generate_keys`
/// and its private half lives in the login Keychain, so it can't be committed.
/// A build still carrying the placeholder can't verify anything it downloads —
/// the updater reports itself unconfigured rather than checking the feed and
/// then failing on the signature.
public let updaterPublicKeyPlaceholder = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"

/// The one Sparkle channel the feed uses. An entry with no `sparkle:channel` reaches
/// every install; one tagged `beta` reaches only the installs that opted into betas.
public let updaterBetaChannel = "beta"

/// UserDefaults key for "Receive Beta Updates". Off unless the user turns it on.
public let updaterReceivesBetaUpdatesKey = "garage.updates.beta"

/// The appcast feed and the public key its entries are signed with.
public struct UpdaterConfiguration: Equatable, Sendable {
    public let feedURL: URL
    public let publicEDKey: String

    public init(feedURL: URL, publicEDKey: String) {
        self.feedURL = feedURL
        self.publicEDKey = publicEDKey
    }
}

/// Whether this build is in a position to check for updates — and, when it
/// isn't, a sentence the UI can show instead of a disabled button with no
/// explanation.
public enum UpdaterAvailability: Equatable, Sendable {
    case configured(UpdaterConfiguration)
    case unavailable(reason: String)
}

extension UpdaterAvailability {
    /// Resolves the configuration from a bundle's Info.plist.
    public static func resolve(bundle: Bundle = .main) -> UpdaterAvailability {
        resolve(
            feedURL: bundle.object(forInfoDictionaryKey: UpdaterInfoPlistKey.feedURL) as? String,
            publicEDKey: bundle.object(forInfoDictionaryKey: UpdaterInfoPlistKey.publicEDKey) as? String
        )
    }

    /// The same resolution against raw values, so the rules are testable without
    /// standing up a bundle.
    public static func resolve(feedURL: String?, publicEDKey: String?) -> UpdaterAvailability {
        guard let rawFeedURL = trimmed(feedURL) else {
            return .unavailable(reason: "This build has no update feed configured.")
        }
        // A scheme alone is not enough: `URL(string: "https:appcast.xml")` parses, reports
        // scheme "https" and has no host at all, which would start Sparkle against a feed
        // it can never fetch.
        guard let url = URL(string: rawFeedURL),
              url.scheme?.lowercased() == "https",
              let host = url.host(), !host.isEmpty
        else {
            return .unavailable(reason: "The configured update feed is not a valid HTTPS URL.")
        }
        guard let key = trimmed(publicEDKey) else {
            return .unavailable(reason: "This build has no update signing key configured.")
        }
        guard key != updaterPublicKeyPlaceholder else {
            return .unavailable(
                reason: "This build was made without a Sparkle signing key, so updates can't be verified."
            )
        }
        return .configured(UpdaterConfiguration(feedURL: url, publicEDKey: key))
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
