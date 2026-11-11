import Contacts
import DotCore
import Foundation

/// One `CNContactStore`, boxed for the same reason the EventKit store is.
final class ContactsStoreBox: @unchecked Sendable {
    let store = CNContactStore()
}

/// Contacts, through the Contacts framework.
///
/// Read only. The contact store is built on the first lookup and released after
/// two idle minutes, so a dictation-only session never opens `contactsd`.
final class ContactsStore: ContactsDirectory, @unchecked Sendable {
    private let stores: LazyResource<ContactsStoreBox>

    /// Creates the store.
    ///
    /// - Parameter idle: how long the contact store may sit unused.
    init(idle: Duration = .seconds(120)) {
        stores = LazyResource(idle: idle) { ContactsStoreBox() }
    }

    func permission() async -> ConnectorPermission {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            ConnectorPermission(status: .granted, service: "Contacts", settingsURL: ConnectorPermission.Pane.contacts.url)
        case .denied:
            .from(granted: false, denied: true, service: "Contacts", pane: .contacts)
        case .restricted:
            ConnectorPermission(
                status: .restricted,
                service: "Contacts",
                remedy: "Access is controlled by a profile on this Mac.",
                settingsURL: ConnectorPermission.Pane.contacts.url
            )
        default:
            .from(granted: false, denied: false, service: "Contacts", pane: .contacts)
        }
    }

    func requestAccess() async -> ConnectorPermission {
        let box = stores.acquire()
        _ = try? await box.store.requestAccess(for: .contacts)
        return await permission()
    }

    func find(name: String, limit: Int) async throws -> [ContactMatch] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let box = stores.acquire()
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let predicate = CNContact.predicateForContacts(matchingName: trimmed)
        do {
            let contacts = try box.store.unifiedContacts(matching: predicate, keysToFetch: keys)
            return contacts.prefix(max(1, limit)).map { contact in
                let name = [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let display = name.isEmpty ? contact.organizationName : name
                let handles = contact.phoneNumbers.map { $0.value.stringValue }
                let emails = contact.emailAddresses.map { $0.value as String }
                return ContactMatch(
                    id: contact.identifier,
                    name: display,
                    handles: handles,
                    emails: emails
                )
            }
            .filter { !$0.name.isEmpty }
        } catch {
            throw StoreError("Contacts could not be read.")
        }
    }
}
