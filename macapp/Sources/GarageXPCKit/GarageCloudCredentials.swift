import Foundation

/// Where a cloud source's access token comes from (`garage_ingest.h`'s `access_token`).
///
/// Garage holds no cloud account of its own: a build that can read a cloud source registers a
/// provider here, in the process that runs ingest. The App Store build's extensions register one
/// that keeps the Dropbox or Microsoft connection on this node (signed in through Garage Door, which holds no
/// token) and refreshes it; with none registered a Dropbox source fails as unavailable, with `notConnected`'s
/// message. A provider is called on the ingest thread and may block; it never logs a token.
public enum GarageCloudCredentials {
    /// `service` is the source kind (`dropbox`, `onedrive`), `source` its slug, and `refresh` true after the
    /// service refused the last token. Returns an access token, or throws why there is none.
    public typealias Provider = @Sendable (_ service: String, _ source: String, _ refresh: Bool) throws -> String

    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: Provider?

    /// Installs `provider`, replacing any before it; nil removes it.
    public static func register(_ provider: Provider?) {
        lock.lock()
        defer { lock.unlock() }
        Self.provider = provider
    }

    /// Whether a provider is installed.
    public static var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return provider != nil
    }

    /// An access token for `source`, from the installed provider.
    public static func accessToken(service: String, source: String, refresh: Bool) throws -> String {
        lock.lock()
        let provider = Self.provider
        lock.unlock()
        guard let provider else {
            throw GarageCloudCredentialsError.notConnected(service: service)
        }
        return try provider(service, source, refresh)
    }
}

/// Why no token came.
public enum GarageCloudCredentialsError: Error, LocalizedError, Equatable {
    case notConnected(service: String)

    public var errorDescription: String? {
        switch self {
        case .notConnected(let service):
            let name = ["dropbox": "Dropbox", "onedrive": "OneDrive", "outlook": "Outlook", "google_drive": "Google", "gmail": "Google"][service] ?? service
            return "No \(name) account is connected to Garage; connect one to read this source"
        }
    }
}
