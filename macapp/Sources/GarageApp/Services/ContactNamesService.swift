import Contacts
import Foundation
import OSLog

/// Names for the phone numbers and email addresses Messages and Mail know people by, read from the
/// user's Contacts and handed to each ingest (`IngestOptions.contactNames`). The ingest names an author
/// known only by a handle, and a Messages thread's title and sender lines, with them.
///
/// The app reads Contacts, not the ingest service: the app holds the Contacts permission in both builds
/// (`com.apple.security.personal-information.addressbook`), and the names stay on this Mac, in the
/// corpus's communications. macOS asks once, before the first ingest; a refusal leaves handles as they are.
enum ContactNamesService {
    private static let logger = Logger(subsystem: "me.rickmark.garage-rag", category: "ContactNames")

    /// `defaults write me.rickmark.garage-rag garage.contactNames.disabled -bool YES` (or the same as a
    /// launch argument, as UI tests pass it) turns the lookup off without touching the permission.
    static let disabledDefaultsKey = "garage.contactNames.disabled"

    /// `[handle, name]` pairs for every phone number and email address in Contacts, or none when the
    /// lookup is off or the user has not allowed it. Asks for access the first time.
    static func namesForIngest() async -> [[String]] {
        if isRunningInTestEnvironment || UserDefaults.standard.bool(forKey: disabledDefaultsKey) {
            return []
        }
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            break
        case .notDetermined:
            do {
                guard try await CNContactStore().requestAccess(for: .contacts) else {
                    logger.info("Contacts access declined; handles keep their numbers and addresses")
                    return []
                }
            } catch {
                logger.warning("Contacts access request failed: \(error.localizedDescription, privacy: .public)")
                return []
            }
        default:
            return []
        }
        return await Task.detached(priority: .utility) { readNames(from: CNContactStore()) }.value
    }

    /// Enumerating Contacts blocks, so this runs off the main actor.
    private static func readNames(from store: CNContactStore) -> [[String]] {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var pairs: [[String]] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                guard let name = displayName(of: contact) else { return }
                for phone in contact.phoneNumbers {
                    pairs.append([phone.value.stringValue, name])
                }
                for email in contact.emailAddresses {
                    pairs.append([email.value as String, name])
                }
            }
        } catch {
            logger.warning("Could not read Contacts: \(error.localizedDescription, privacy: .public)")
            return []
        }
        // A count only: the names themselves never reach the log.
        logger.info("Read \(pairs.count) handle names from Contacts")
        return pairs
    }

    private static func displayName(of contact: CNContact) -> String? {
        let full = CNContactFormatter.string(from: contact, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let full, !full.isEmpty {
            return full
        }
        let organization = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return organization.isEmpty ? nil : organization
    }
}
