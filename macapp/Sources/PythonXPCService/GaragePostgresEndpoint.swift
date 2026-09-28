import Darwin
import Foundation
import Security

/// Where the app's private Postgres listens and where its password lives. Shared by
/// the app, which owns the cluster, and the bundled `garage` / `garage-mcp`
/// launchers, which connect to it from processes the app did not start (a terminal,
/// an MCP client spawning `garage-mcp`).
///
/// The password is a generic-password item in the data-protection keychain, in the
/// team-prefixed App Group as its access group (`keychainAccessGroup`). Every process
/// signed into that group with an application identifier backed by a provisioning
/// profile (the app, the launcher helper bundles, in the Developer ID and App Store
/// builds) reads it without a Keychain prompt: access there is decided by entitlements,
/// not by the per-application ACL of the login keychain, which asked "GarageApp wants to
/// access key…" for every new signature. Where the data-protection keychain is not
/// usable — a locally signed or ad-hoc build carries no application identifier, and
/// `SecItem` answers `errSecMissingEntitlement` — the item lives in the login keychain
/// as before (`legacy` below).
public enum GaragePostgresEndpoint {
    /// Fixed, non-default port so this never collides with a system Postgres on 5432.
    public static let port = 14824
    public static let databaseName = "garage-rag"
    public static let keychainService = "com.rickmark.garage.postgres"
    /// The access group of the shared item: the App Group, which macOS accepts as a keychain
    /// access group (`keychain-access-groups` in the entitlements names it too).
    public static let keychainAccessGroup = GarageAppGroup.identifier
    /// Where the password lives instead when the data folder is overridden (UI tests): inside that
    /// throwaway folder, so an isolated cluster never reads or replaces the real database's password,
    /// and a rebuilt (newly ad-hoc signed) app never waits on a Keychain access prompt at launch.
    public static var isolatedPasswordFile: URL? {
        GarageAppGroup.dataDirectoryOverride?.appendingPathComponent("postgres-password", isDirectory: false)
    }
    public static var keychainAccount: String { NSUserName() }
    public static var username: String { NSUserName() }

    public enum EndpointError: LocalizedError {
        case keychain(OSStatus)
        case keychainWrite(OSStatus)
        case encoding

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return "could not read the Garage database password from the Keychain: \(Self.describe(status))"
            case .keychainWrite(let status):
                return "could not save the Garage database password in the Keychain: \(Self.describe(status))"
            case .encoding:
                return "could not encode the Garage database connection URL"
            }
        }

        public static func describe(_ status: OSStatus) -> String {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "\(reason) (\(status))"
        }
    }

    /// Which keychain holds, or would hold, the item.
    public enum KeychainStore: String, Sendable {
        /// The data-protection keychain, in the App Group: no prompt for any process entitled to the group.
        case group
        /// The login keychain, with a per-application access list: where builds without an
        /// application identifier keep it, and where every build kept it before the group keychain.
        case legacy
    }

    /// What `migrateLegacyPassword` did.
    public enum Migration: Equatable, Sendable {
        /// The group keychain is not usable by this process; nothing was touched.
        case groupKeychainUnavailable
        /// The group keychain already holds the password.
        case alreadyInGroupKeychain
        /// Neither keychain holds a password (the cluster has not been created yet).
        case nothingToMigrate
        /// The login-keychain item was copied into the group keychain. The old item stays, so a
        /// build from before 1.5, which reads only the login keychain, can still open the database.
        case migrated
    }

    /// The password the app stored, or nil if the app has never created the cluster. The group
    /// keychain first, then the login keychain: a password the app has not migrated yet is still
    /// found there (with the prompt that keychain asks for).
    public static func readPassword() throws -> String? {
        if let file = isolatedPasswordFile {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try String(contentsOf: file, encoding: .utf8)
        }
        switch try readGroupPassword() {
        case .found(let password):
            return password
        case .notFound, .unavailable:
            return try readLegacyPassword()
        }
    }

    /// Stores the password where this process can: the group keychain, else the login keychain.
    /// Returns which one took it. Updates an existing item rather than adding a second.
    @discardableResult
    public static func savePassword(_ password: String) throws -> KeychainStore {
        let attributes: [CFString: Any] = [kSecValueData: Data(password.utf8)]
        let groupQuery = groupItemQuery()
        let groupUpdate = SecItemUpdate(groupQuery as CFDictionary, attributes as CFDictionary)
        switch groupUpdate {
        case errSecSuccess:
            return .group
        case errSecItemNotFound:
            var item = groupQuery
            item[kSecValueData] = Data(password.utf8)
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            if added == errSecSuccess {
                return .group
            }
            guard added == errSecMissingEntitlement else { throw EndpointError.keychainWrite(added) }
        case errSecMissingEntitlement:
            break
        default:
            throw EndpointError.keychainWrite(groupUpdate)
        }
        try saveLegacyPassword(password, attributes: attributes)
        return .legacy
    }

    /// Copies the login-keychain item into the group keychain, so the launchers stop prompting.
    /// The app calls this before its first read. The old item is left in place: a build from
    /// before 1.5 reads only the login keychain, and deleting it would lock that build out of the
    /// database after a downgrade. Reads prefer the group copy, so the old one is never consulted
    /// again by this build. Reading the old item can show the login keychain's access prompt one
    /// last time.
    public static func migrateLegacyPassword() throws -> Migration {
        if isolatedPasswordFile != nil {
            return .groupKeychainUnavailable
        }
        switch try readGroupPassword() {
        case .unavailable:
            return .groupKeychainUnavailable
        case .found:
            return .alreadyInGroupKeychain
        case .notFound:
            break
        }
        guard let password = try readLegacyPassword() else {
            return .nothingToMigrate
        }
        guard try savePassword(password) == .group else {
            // The probe said the group keychain was usable and the write disagreed; leave the item alone.
            return .groupKeychainUnavailable
        }
        return .migrated
    }

    /// The folder the server puts its socket in (`unix_socket_directories`), or nil when the socket's
    /// path would be too long to bind and the server listens on loopback TCP instead (`GarageSockets`).
    public static var socketDirectory: String? {
        let directory = GarageSockets.directory
        guard GarageSockets.path(for: GarageSockets.postgresName, in: directory) != nil else { return nil }
        return directory.path
    }

    /// `postgresql+psycopg://…` (SQLAlchemy, what garage_rag reads) or `postgresql://…`.
    ///
    /// Over the socket: `…@/garage-rag?host=<socket folder>&port=14824` (libpq names the socket file
    /// after the port, so the port still matters). Otherwise `…@localhost:14824/garage-rag`.
    public static func connectionURL(
        password: String,
        scheme: String = "postgresql+psycopg",
        socketDirectory: String? = GaragePostgresEndpoint.socketDirectory
    ) throws -> String {
        guard let user = percentEncode(username), let secret = percentEncode(password) else {
            throw EndpointError.encoding
        }
        guard let socketDirectory else {
            return "\(scheme)://\(user):\(secret)@localhost:\(port)/\(databaseName)"
        }
        guard let host = percentEncode(socketDirectory) else {
            throw EndpointError.encoding
        }
        return "\(scheme)://\(user):\(secret)@/\(databaseName)?host=\(host)&port=\(port)"
    }

    /// The `-h` and `-p` arguments of the bundled Postgres command-line tools.
    public static func clientArguments(socketDirectory: String? = GaragePostgresEndpoint.socketDirectory) -> [String] {
        ["-h", socketDirectory ?? "localhost", "-p", String(port)]
    }

    /// True when the server accepts connections: on its socket, or on the TCP port when it has none.
    /// A refused connection returns at once, so this is cheap to poll.
    public static func isAcceptingConnections() -> Bool {
        if let socketDirectory {
            return GarageSockets.isAcceptingConnections(
                at: URL(fileURLWithPath: socketDirectory).appendingPathComponent(GarageSockets.postgresName).path
            )
        }
        return isAcceptingTCPConnections()
    }

    private static func isAcceptingTCPConnections() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // MARK: - Keychain items

    enum GroupRead {
        case found(String)
        case notFound
        /// `errSecMissingEntitlement`: this process has no application identifier the data-protection
        /// keychain accepts (no provisioning profile), or is not entitled to the access group.
        case unavailable
    }

    /// The item that identifies the password in the group keychain. `kSecUseDataProtectionKeychain`
    /// is what selects that keychain on macOS; the access group and "never synchronize" are part of
    /// the identity, so reads and writes name the same item.
    static func groupItemQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecAttrAccessGroup: keychainAccessGroup,
            kSecAttrSynchronizable: false,
            kSecUseDataProtectionKeychain: true,
        ]
    }

    /// The item in the login keychain: what every build stored before the group keychain, and what
    /// builds without an application identifier still store.
    static func legacyItemQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
    }

    static func readGroupPassword() throws -> GroupRead {
        var query = groupItemQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            return .notFound
        case errSecMissingEntitlement:
            return .unavailable
        case errSecSuccess:
            guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
                throw EndpointError.keychain(status)
            }
            return .found(password)
        default:
            throw EndpointError.keychain(status)
        }
    }

    static func readLegacyPassword() throws -> String? {
        var query = legacyItemQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw EndpointError.keychain(status)
        }
        return password
    }

    private static func saveLegacyPassword(_ password: String, attributes: [CFString: Any]) throws {
        let query = legacyItemQuery()
        var attributes = attributes
        attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw EndpointError.keychainWrite(updateStatus)
        }
        var newItem = query
        for (key, value) in attributes {
            newItem[key] = value
        }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw EndpointError.keychainWrite(addStatus)
        }
    }

    private static func percentEncode(_ value: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}

/// How the launchers start the app when its database is not running.
public enum GarageAppLaunch {
    /// Start the services and stay in the menu bar without opening the main window.
    public static let backgroundArgument = "--background"

    /// `--after-database-reset <pid>`: the app instance `pid` deleted the database and launched this
    /// one to create a new one. This instance starts nothing until `pid` has quit.
    public static let databaseResetArgument = "--after-database-reset"

    /// `--data-directory <path>`: run on this data folder instead of the real one, with no migration,
    /// no link and a separate Keychain item. For UI tests, which reset the database.
    public static let dataDirectoryArgument = "--data-directory"

    /// `--appearance light|dark`: draw the app in this appearance whatever the system's is. For the
    /// App Store screenshot tests, which shoot every page in both.
    public static let appearanceArgument = "--appearance"

    /// `--window-size <width>x<height>`: open the main window at this frame size in points, title bar
    /// included, at the top left of its screen. For the App Store screenshot tests, which need an exact
    /// store size and cannot count on dragging the window's corner.
    public static let windowSizeArgument = "--window-size"

    /// `--client-home <path>`: look for the assistants' MCP configs under this folder instead of the
    /// home folder, and show their paths relative to it. Only with `--data-directory`; for the App
    /// Store screenshot tests, which show made-up assistants rather than the ones on the Mac.
    public static let clientHomeArgument = "--client-home"

    /// Posted by `garage quit` as a distributed notification: every running Garage quits as its Quit
    /// menu item would. A notification rather than an Apple event, which the sandboxed App Store
    /// launcher may not send and which would ask for Automation consent.
    public static let quitNotification = "me.rickmark.garage-rag.quit"
}
