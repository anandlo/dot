import Foundation
import Security

/// The Keychain item that holds a provider's API key.
///
/// One item per provider: the service is `DOT_API_KEY_<PROVIDER>` and the
/// account is the provider id. The key never goes into the configuration file,
/// never into a log line and never into a command line.
public enum CredentialStore {
    /// The prefix every service name starts with.
    public static let servicePrefix = "DOT_API_KEY_"

    /// The Keychain service name of one provider.
    public static func serviceName(for providerID: String) -> String {
        servicePrefix + providerID.uppercased()
    }

    /// The Keychain account name of one provider.
    public static func account(for providerID: String) -> String {
        providerID.lowercased()
    }

    /// Reads the API key of a provider.
    ///
    /// - Returns: the key, or `nil` when the provider has none.
    /// - Throws: ``CredentialError/unexpectedStatus(_:)`` when the Keychain
    ///   refuses the query.
    public static func read(providerID: String) throws -> String? {
        try readSecret(service: serviceName(for: providerID), account: account(for: providerID))
    }

    /// Reads a secret by its Keychain service and account.
    public static func readSecret(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialError.unexpectedStatus(status)
        }
    }

    /// Writes the API key of a provider, replacing an older one.
    public static func write(_ secret: String, providerID: String) throws {
        try writeSecret(
            secret,
            service: serviceName(for: providerID),
            account: account(for: providerID)
        )
    }

    /// Writes a secret by its Keychain service and account.
    public static func writeSecret(_ secret: String, service: String, account: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialError.unexpectedStatus(addStatus)
            }
            return
        }
        guard updateStatus == errSecSuccess else {
            throw CredentialError.unexpectedStatus(updateStatus)
        }
    }

    /// Removes the API key of a provider.
    public static func delete(providerID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(for: providerID),
            kSecAttrAccount as String: account(for: providerID),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.unexpectedStatus(status)
        }
    }

    /// Whether a provider has an API key.
    ///
    /// The answer comes from the item's attributes. Reading the data would make
    /// macOS decrypt the item — and decrypting an item whose signature changed
    /// puts a system prompt on screen, which would block whatever thread asks.
    /// "Does a key exist?" must never pay that price.
    public static func hasKey(for providerID: String) -> Bool {
        hasSecret(service: serviceName(for: providerID), account: account(for: providerID))
    }

    /// Whether a secret exists, without reading it.
    ///
    /// The query asks for attributes only (`kSecReturnAttributes`, no
    /// `kSecReturnData`), so the Keychain answers from its index and never has
    /// to decrypt anything.
    public static func hasSecret(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess && item != nil
    }
}

/// The two Keychain questions, kept apart on purpose.
///
/// ``hasKey`` and ``readKey`` are not interchangeable. ``hasKey`` is answered
/// from the item's attributes: the Keychain answers from its index, so the
/// question costs nothing and cannot raise a prompt. ``readKey`` decrypts the
/// item, and decrypting an item whose signature changed makes macOS wait for an
/// answer on screen.
///
/// The distinction is the rule: code that only needs to know whether a key is
/// there — provider retirement, the menu, Settings — may call ``hasKey``.
/// ``readKey`` belongs to the copy of an older build's key and to the moment a
/// provider is built for a real request.
public struct CredentialProbe {
    /// Whether a provider has a key, answered from the item's attributes.
    public let hasKey: (String) -> Bool
    /// The key itself, decrypting the item.
    public let readKey: (String) -> String?

    /// Creates a probe.
    ///
    /// - Parameters:
    ///   - hasKey: the attributes-only probe.
    ///   - readKey: the decrypting read.
    public init(
        hasKey: @escaping (String) -> Bool = { CredentialStore.hasKey(for: $0) },
        readKey: @escaping (String) -> String? = { try? CredentialStore.read(providerID: $0) }
    ) {
        self.hasKey = hasKey
        self.readKey = readKey
    }
}

/// Copies a key that older tools stored under their own service name.
///
/// The copy happens once: when the Dot service already holds a key, the
/// legacy item is not read. Existence is answered from the item's attributes,
/// so a missing Dot key does not decrypt anything either. The legacy item is
/// deliberately left in place, so the other tool keeps working. The key is
/// never logged, printed or put into a configuration file.
public enum LegacyCredentialMigration {
    /// The service the Xiaomi tool used before Dot kept its own keys.
    public static let xiaomiService = "XIAOMI_API_KEY"

    /// What the migration found and did.
    public struct Result: Equatable, Sendable {
        /// Whether the legacy key was copied into Dot's Keychain item.
        public let migrated: Bool
        /// Whether Dot has a Xiaomi key after the attempt.
        public let keyAvailable: Bool

        public init(migrated: Bool, keyAvailable: Bool) {
            self.migrated = migrated
            self.keyAvailable = keyAvailable
        }
    }

    /// Copies the legacy Xiaomi key to `DOT_API_KEY_XIAOMI` when it is absent.
    ///
    /// - Parameters:
    ///   - legacyAccount: the account the legacy item is stored under.
    ///   - hasSecret: probes a secret without reading it; injected so a test
    ///     never touches the Keychain.
    ///   - read: reads a secret; injected for the same reason.
    ///   - write: writes a secret and reports success; injected for the same
    ///     reason.
    /// - Returns: whether a key was copied and whether one is available.
    public static func migrateXiaomiKeyIfNeeded(
        legacyAccount: String = NSUserName(),
        hasSecret: (String, String) -> Bool = { service, account in
            CredentialStore.hasSecret(service: service, account: account)
        },
        read: (String, String) -> String? = { service, account in
            try? CredentialStore.readSecret(service: service, account: account)
        },
        write: (String, String, String) -> Bool = { secret, service, account in
            (try? CredentialStore.writeSecret(secret, service: service, account: account)) != nil
        }
    ) -> Result {
        let destinationService = CredentialStore.serviceName(for: ProviderIdentifier.xiaomi)
        let destinationAccount = CredentialStore.account(for: ProviderIdentifier.xiaomi)

        // Attributes only: an existing key is reported without being decrypted.
        if hasSecret(destinationService, destinationAccount) {
            return Result(migrated: false, keyAvailable: true)
        }
        guard let legacy = read(xiaomiService, legacyAccount),
              !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return Result(migrated: false, keyAvailable: false)
        }
        let written = write(legacy, destinationService, destinationAccount)
        return Result(migrated: written, keyAvailable: written)
    }
}

/// The Keychain refused an operation.
public enum CredentialError: Error, Equatable, LocalizedError {
    /// The Keychain answered with a status Dot does not understand.
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "The Keychain refused the request: \(message)"
        }
    }
}
