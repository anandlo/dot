import Foundation
import Security

/// The Keychain service and account of the one item that holds every API key.
///
/// One item is deliberate. macOS partitions file Keychain items by cdhash, so a
/// self-signed build that changed since an item was written fails the partition
/// check and SecurityAgent asks about every item separately. One item makes that
/// at most one question, and the question is asked only when a key is used.
public enum CredentialBundle {
    /// The service of the bundle item.
    public static let service = "DOT_API_KEYS"

    /// The service of the attributes-only item that records finished migrations.
    ///
    /// It holds no key: the migrated provider ids are kept in `kSecAttrGeneric`.
    public static let migrationService = "DOT_CREDENTIAL_MIGRATION"

    /// The account of the bundle item.
    ///
    /// There is no bundle identifier in DotCore: `Bundle.main` supplies it in a
    /// packaged build, and the fallback is the identifier a `swift run` binary
    /// would have. Tests inject their own account through the store.
    public static var account: String {
        Bundle.main.bundleIdentifier ?? "com.anandlo.dot"
    }
}

/// One Keychain query, as seen by an injected recorder.
public struct CredentialQuery: Equatable, Sendable {
    /// The SecItem function that made the query.
    public let operation: String
    /// Whether the query was made on the main thread.
    public let onMainThread: Bool
    /// The service named in the query, when there is one.
    public let service: String?
    /// The account named in the query, when there is one.
    public let account: String?
    /// Whether the query asked for the item's data.
    public let returnsData: Bool
    /// Whether the query asked for the item's attributes.
    public let returnsAttributes: Bool
}

/// One answer to a Keychain copy query, as returned by an injected handler.
public struct CredentialCopyResult {
    /// The OSStatus the Keychain would have returned.
    public let status: OSStatus
    /// The item, when the status is `errSecSuccess`.
    public let item: CFTypeRef?

    public init(status: OSStatus, item: CFTypeRef? = nil) {
        self.status = status
        self.item = item
    }
}

/// Records Keychain queries without recording any secret.
public final class CredentialQueryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [CredentialQuery] = []

    /// Creates an empty recorder.
    public init() {}

    /// Records one query.
    public func record(_ query: CredentialQuery) {
        lock.lock()
        entries.append(query)
        lock.unlock()
    }

    /// Every query made so far, in order.
    public var calls: [CredentialQuery] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Whether any query asked to decrypt an item.
    public var hasDataRead: Bool { calls.contains { $0.returnsData } }
}

/// The Keychain a credential store talks to.
///
/// The default is the user's login Keychain. Tests inject handlers backed by an
/// in-memory store, so no test can read or write the login Keychain, and a
/// recorder, so a test can prove which queries were made and on which thread.
public final class CredentialKeychainContext: @unchecked Sendable {
    /// The context the app uses.
    public static let `default` = CredentialKeychainContext()

    /// The keychain to use, or `nil` for the default search list.
    public let keychain: SecKeychain?
    private let recorder: CredentialQueryRecorder?
    private let copyHandler: (@Sendable ([String: Any]) -> CredentialCopyResult)?
    private let addHandler: (@Sendable ([String: Any]) -> OSStatus)?
    private let updateHandler: (@Sendable ([String: Any], [String: Any]) -> OSStatus)?
    private let deleteHandler: (@Sendable ([String: Any]) -> OSStatus)?

    /// Creates a context.
    ///
    /// Pass every handler when injecting a store; leaving one out falls back to
    /// the real Keychain for that operation.
    public init(
        keychain: SecKeychain? = nil,
        recorder: CredentialQueryRecorder? = nil,
        copyHandler: (@Sendable ([String: Any]) -> CredentialCopyResult)? = nil,
        addHandler: (@Sendable ([String: Any]) -> OSStatus)? = nil,
        updateHandler: (@Sendable ([String: Any], [String: Any]) -> OSStatus)? = nil,
        deleteHandler: (@Sendable ([String: Any]) -> OSStatus)? = nil
    ) {
        self.keychain = keychain
        self.recorder = recorder
        self.copyHandler = copyHandler
        self.addHandler = addHandler
        self.updateHandler = updateHandler
        self.deleteHandler = deleteHandler
    }

    func scoped(_ query: [String: Any]) -> [String: Any] {
        guard let keychain else { return query }
        var result = query
        result[kSecUseKeychain as String] = keychain
        result[kSecMatchSearchList as String] = [keychain]
        return result
    }

    func note(
        _ operation: String,
        _ query: [String: Any],
        returnsData: Bool = false,
        returnsAttributes: Bool = false
    ) {
        recorder?.record(CredentialQuery(
            operation: operation,
            onMainThread: Thread.isMainThread,
            service: query[kSecAttrService as String] as? String,
            account: query[kSecAttrAccount as String] as? String,
            returnsData: returnsData,
            returnsAttributes: returnsAttributes
        ))
    }

    func copy(_ query: [String: Any], operation: String = "copy") -> (OSStatus, CFTypeRef?) {
        let scoped = self.scoped(query)
        note(
            operation,
            scoped,
            returnsData: scoped[kSecReturnData as String] as? Bool == true,
            returnsAttributes: scoped[kSecReturnAttributes as String] as? Bool == true
        )
        if let copyHandler {
            let answer = copyHandler(scoped)
            return (answer.status, answer.status == errSecSuccess ? answer.item : nil)
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(scoped as CFDictionary, &item)
        return (status, status == errSecSuccess ? item : nil)
    }

    func add(_ query: [String: Any]) -> OSStatus {
        let scoped = self.scoped(query)
        note("add", scoped)
        if let addHandler { return addHandler(scoped) }
        return SecItemAdd(scoped as CFDictionary, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        let scoped = self.scoped(query)
        note("update", scoped)
        if let updateHandler { return updateHandler(scoped, attributes) }
        return SecItemUpdate(scoped as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        let scoped = self.scoped(query)
        note("delete", scoped)
        if let deleteHandler { return deleteHandler(scoped) }
        return SecItemDelete(scoped as CFDictionary)
    }
}

/// The one Keychain item and the in-memory copy of its keys.
///
/// The bundle is read once, on the first call that actually needs a key. All
/// later calls answer from memory. A key that turns up in an older per-provider
/// item is copied into the bundle on that first use; the older per-provider items
/// are then removed, while the item of the older Xiaomi tool is left for it.
public final class CredentialBundleStore: @unchecked Sendable {
    /// The store the app uses.
    public static let shared = CredentialBundleStore()

    /// The status behind a denial, kept so a caller can distinguish it.
    private enum Refusal {
        case denied(OSStatus)
        case unavailable(OSStatus)
    }

    /// An immutable view of the in-memory state.
    private struct Snapshot {
        let keys: [String: String]?
        let refusal: Refusal?
        let unreadable: Bool
    }

    private let context: CredentialKeychainContext
    private let account: String
    private let legacyAccount: String
    /// Guards only the in-memory snapshot. Never held across Keychain work.
    private let state = NSLock()
    /// Serialises every synchronous backend data path: load, read, migrate,
    /// write, delete and the migration marker read-modify-write.
    private let transaction = NSLock()
    /// One in-flight read for this store, shared by every async caller.
    private let flights = CredentialFlightBook()
    private var keys: [String: String]?
    private var refusal: Refusal?
    /// A bundle whose data cannot be decoded is never replaced by a save.
    private var unreadable = false

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - context: the Keychain and an optional query recorder.
    ///   - account: the bundle item's account.
    ///   - legacyAccount: the account of the older Xiaomi tool's item.
    public init(
        context: CredentialKeychainContext = .default,
        account: String = CredentialBundle.account,
        legacyAccount: String = NSUserName()
    ) {
        self.context = context
        self.account = account
        self.legacyAccount = legacyAccount
    }

    /// The service of the one item.
    public var service: String { CredentialBundle.service }

    private func snapshot() -> Snapshot {
        state.lock()
        defer { state.unlock() }
        return Snapshot(keys: keys, refusal: refusal, unreadable: unreadable)
    }

    private func updateKeys(_ updated: [String: String]?) {
        state.lock()
        keys = updated
        state.unlock()
    }

    private func setRefusal(_ value: Refusal?) {
        state.lock()
        refusal = value
        state.unlock()
    }

    /// The key of a provider, reading the bundle on first use.
    public func key(for providerID: String) throws -> String? {
        transaction.lock()
        defer { transaction.unlock() }
        return try keyLocked(for: providerID)
    }

    private func keyLocked(for providerID: String) throws -> String? {
        let before = snapshot()
        if let key = before.keys?[providerID], !key.isEmpty { return key }
        try ensureLoadedLocked(allowRetry: false)
        let after = snapshot()
        if let key = after.keys?[providerID], !key.isEmpty { return key }
        return try migrateLegacyLocked(for: providerID)
    }

    /// The key of a provider, awaited to the real answer off the caller's actor.
    ///
    /// One task per provider and generation serves every caller. A Keychain
    /// prompt can outlast any deadline, so there is no timeout here.
    public func resolvedKey(for providerID: String, generation: UInt64 = 0) async throws -> String? {
        let flight = flights.task(for: providerID, generation: generation) {
            try self.key(for: providerID)
        }
        do {
            let key = try await flight.task.value
            flights.remove(id: flight.id, for: providerID)
            return key
        } catch {
            flights.remove(id: flight.id, for: providerID)
            throw error
        }
    }

    /// Drops an in-flight read so a newer generation cannot join it.
    public func invalidateFlights(for providerID: String) {
        flights.removeAll(for: providerID)
    }

    /// Whether a provider has a key, without decrypting anything.
    ///
    /// A short snapshot decides whether an attribute probe is needed; the
    /// state lock is never held across that probe. A provider whose legacy
    /// migration already finished is not reported as keyed by an old item.
    public func hasKey(for providerID: String) -> Bool {
        let snapshot = self.snapshot()
        if snapshot.unreadable { return false }
        if let keys = snapshot.keys, keys[providerID] != nil { return true }
        if bundleProviderIDs().contains(providerID) { return true }
        if migrationMarkerIDs(for: providerID).contains(providerID) { return false }
        return hasLegacyItem(for: providerID)
    }

    /// Writes one key into the bundle, off the caller's actor.
    public func writeAsync(_ secret: String, providerID: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.write(secret, providerID: providerID)
        }.value
    }

    /// Removes one key from the bundle, off the caller's actor.
    public func deleteAsync(providerID: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.delete(providerID: providerID)
        }.value
    }

    /// Writes one key into the bundle.
    public func write(_ secret: String, providerID: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transaction.lock()
        defer { transaction.unlock() }
        try writeLocked(trimmed, providerID: providerID)
    }

    private func writeLocked(_ trimmed: String, providerID: String) throws {
        // An explicit save is a new decision and may retry a refusal; it must
        // never bypass an unreadable bundle.
        try ensureLoadedLocked(allowRetry: true)
        var updated = snapshot().keys ?? [:]
        updated[providerID] = trimmed
        try saveLocked(updated)
    }

    /// Removes one key from the bundle and from the older per-provider items.
    public func delete(providerID: String) throws {
        transaction.lock()
        defer { transaction.unlock() }
        try deleteLocked(providerID: providerID)
    }

    private func deleteLocked(providerID: String) throws {
        // Corrupt bytes still throw here and are never replaced. Once the bundle
        // is readable, suppression must be durable before this key or any legacy
        // item is removed.
        try ensureLoadedLocked(allowRetry: true)
        try markMigratedLocked(for: providerID)
        var updated = snapshot().keys ?? [:]
        if updated.removeValue(forKey: providerID) != nil {
            try saveLocked(updated)
        }
        deleteLegacyItemsLocked(for: providerID)
    }

    /// Forgets a refusal so an explicit action can try again.
    public func allowRetry() {
        state.lock()
        refusal = nil
        state.unlock()
    }

    /// Forgets everything held in memory, including the refusal.
    public func reset() {
        state.lock()
        keys = nil
        refusal = nil
        unreadable = false
        state.unlock()
        flights.removeAll()
    }

    /// Whether this store still has a key read waiting on the Keychain.
    public func isKeyReadInFlight(_ providerID: String) -> Bool {
        flights.contains(providerID)
    }

    // MARK: - Internals

    /// Called with the transaction gate held. The snapshot lock is only held
    /// for the short reads and writes of the in-memory copy.
    private func ensureLoadedLocked(allowRetry: Bool) throws {
        let before = snapshot()
        if before.unreadable { throw CredentialError.unreadable }
        if before.keys != nil {
            if !allowRetry, let refusal = before.refusal { try throwRefusal(refusal) }
            return
        }
        if !allowRetry, let refusal = before.refusal { try throwRefusal(refusal) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let (status, item) = context.copy(query)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw CredentialError.unexpectedStatus(status)
            }
            guard let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                Log.shared.warn("credential.bundle.unreadable")
                state.lock()
                unreadable = true
                state.unlock()
                throw CredentialError.unreadable
            }
            updateKeys(decoded)
            setRefusal(nil)
        case errSecItemNotFound:
            updateKeys([:])
            setRefusal(nil)
        case errSecUserCanceled, errSecAuthFailed:
            Log.shared.info("credential.read.denied", ["scope": .string("bundle")])
            let refusal = Refusal.denied(status)
            setRefusal(refusal)
            try throwRefusal(refusal)
        case errSecInteractionNotAllowed:
            let refusal = Refusal.unavailable(status)
            setRefusal(refusal)
            try throwRefusal(refusal)
        default:
            throw CredentialError.unexpectedStatus(status)
        }
    }

    private func throwRefusal(_ refusal: Refusal) throws {
        switch refusal {
        case .denied(let status): throw CredentialError.denied(status)
        case .unavailable(let status): throw CredentialError.unavailable(status)
        }
    }

    private func bundleProviderIDs() -> Set<String> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let (status, item) = context.copy(query)
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let list = attributes[kSecAttrGeneric as String] as? Data
        else { return [] }
        let text = String(data: list, encoding: .utf8) ?? ""
        return Set(text.split(separator: ",").map(String.init))
    }

    private func legacyServices(for providerID: String) -> [String] {
        var services = [
            CredentialStore.serviceName(for: providerID),
            DotMigration.legacyKeychainPrefix + providerID.uppercased(),
        ]
        if providerID == ProviderIdentifier.xiaomi {
            services.append(LegacyCredentialMigration.xiaomiService)
        }
        return services
    }

    private func hasLegacyItem(for providerID: String) -> Bool {
        for serviceName in legacyServices(for: providerID) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: legacyAccount(for: serviceName),
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            let (status, item) = context.copy(query)
            if status == errSecSuccess, item != nil { return true }
        }
        return false
    }

    private func legacyAccount(for serviceName: String) -> String {
        guard serviceName != LegacyCredentialMigration.xiaomiService else { return legacyAccount }
        let suffix = serviceName.split(separator: "_").last ?? ""
        return CredentialStore.account(for: String(suffix))
    }

    /// The ids whose legacy items have already been examined.
    ///
    /// Only `itemNotFound` answers an empty set. A refusal keeps its status and
    /// malformed data is rejected, because a failed read must never be treated
    /// as permission to replace the marker.
    private func readMigrationMarkerIDs() throws -> Set<String> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CredentialBundle.migrationService,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let (status, item) = context.copy(query)
        switch status {
        case errSecItemNotFound:
            return []
        case errSecSuccess:
            guard let attributes = item as? [String: Any],
                  let list = attributes[kSecAttrGeneric as String] as? Data,
                  let text = String(data: list, encoding: .utf8)
            else { throw CredentialError.unexpectedStatus(errSecParam) }
            return Set(text.split(separator: ",").map(String.init))
        case errSecUserCanceled, errSecAuthFailed:
            throw CredentialError.denied(status)
        case errSecInteractionNotAllowed:
            throw CredentialError.unavailable(status)
        default:
            throw CredentialError.unexpectedStatus(status)
        }
    }

    /// The nonthrowing view used only by a status probe.
    ///
    /// A failed probe suppresses the one provider being asked about instead of
    /// pretending a retained legacy item is a usable key.
    private func migrationMarkerIDs(for providerID: String? = nil) -> Set<String> {
        do {
            return try readMigrationMarkerIDs()
        } catch {
            if let providerID { return [providerID] }
            return []
        }
    }

    private func keychainWriteError(_ status: OSStatus) -> CredentialError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed: return .denied(status)
        case errSecInteractionNotAllowed: return .unavailable(status)
        default: return .unexpectedStatus(status)
        }
    }

    /// Records that a provider's legacy items have been examined.
    ///
    /// A Keychain that refuses interaction (-25308) gets no marker: the work did
    /// not finish, and the next use must be free to try again.
    private func markMigratedLocked(for providerID: String) throws {
        var ids = try readMigrationMarkerIDs()
        guard ids.insert(providerID).inserted else { return }
        let generic = Data(ids.sorted().joined(separator: ",").utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CredentialBundle.migrationService,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(),
            kSecAttrGeneric as String: generic,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let updateStatus = context.update(base, attributes: attributes)
        if updateStatus == errSecItemNotFound {
            var insert = base
            insert.merge(attributes) { _, new in new }
            let addStatus = context.add(insert)
            // A refused marker write never reports success and never writes a
            // partial marker.
            if addStatus != errSecSuccess { throw keychainWriteError(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw keychainWriteError(updateStatus)
        }
    }

    private func migrateLegacyLocked(for providerID: String) throws -> String? {
        if try readMigrationMarkerIDs().contains(providerID) { return nil }
        // Only a genuine absence or a finished copy earns a done-marker. An
        // unusable item or any status Dot did not expect leaves the work open.
        var sawUnusableLegacyItem = false
        for serviceName in legacyServices(for: providerID) {
            let itemAccount = legacyAccount(for: serviceName)
            let probe: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: itemAccount,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            let (probeStatus, probeItem) = context.copy(probe)
            switch probeStatus {
            case errSecSuccess:
                guard probeItem != nil else {
                    sawUnusableLegacyItem = true
                    continue
                }
            case errSecItemNotFound:
                continue
            case errSecUserCanceled, errSecAuthFailed:
                Log.shared.info("credential.read.denied", ["provider": .string(providerID)])
                let refusal = Refusal.denied(probeStatus)
                setRefusal(refusal)
                try throwRefusal(refusal)
            case errSecInteractionNotAllowed:
                let refusal = Refusal.unavailable(probeStatus)
                setRefusal(refusal)
                try throwRefusal(refusal)
            default:
                throw CredentialError.unexpectedStatus(probeStatus)
            }

            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: itemAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            let (status, item) = context.copy(query)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data,
                      let secret = String(data: data, encoding: .utf8),
                      !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    sawUnusableLegacyItem = true
                    continue
                }
                var updated = snapshot().keys ?? [:]
                updated[providerID] = secret
                // The merged key map is durable before any legacy item is removed.
                try saveLocked(updated)
                try markMigratedLocked(for: providerID)
                if serviceName != LegacyCredentialMigration.xiaomiService {
                    deleteLegacyLocked(service: serviceName, account: itemAccount)
                }
                Log.shared.info("credential.bundle.migrated", ["provider": .string(providerID)])
                return secret
            case errSecItemNotFound:
                continue
            case errSecUserCanceled, errSecAuthFailed:
                Log.shared.info("credential.read.denied", ["provider": .string(providerID)])
                let refusal = Refusal.denied(status)
                setRefusal(refusal)
                try throwRefusal(refusal)
            case errSecInteractionNotAllowed:
                let refusal = Refusal.unavailable(status)
                setRefusal(refusal)
                try throwRefusal(refusal)
            default:
                throw CredentialError.unexpectedStatus(status)
            }
        }
        guard !sawUnusableLegacyItem else { return nil }
        try markMigratedLocked(for: providerID)
        return nil
    }

    private func deleteLegacyLocked(service: String, account itemAccount: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: itemAccount,
        ]
        let status = context.delete(query)
        // -25244 (errSecInvalidOwnerEdit) is a legacy item this process cannot
        // remove; the key is already in the bundle, so the take still succeeds.
        guard status == errSecSuccess || status == errSecItemNotFound ||
              status == errSecInvalidOwnerEdit else {
            Log.shared.warn("credential.legacy.deleteFailed", ["status": .int(Int(status))])
            return
        }
    }

    private func deleteLegacyItemsLocked(for providerID: String) {
        for serviceName in legacyServices(for: providerID) where
            serviceName != LegacyCredentialMigration.xiaomiService {
            deleteLegacyLocked(service: serviceName, account: legacyAccount(for: serviceName))
        }
    }

    /// Called with the transaction gate held. The map is already normalised.
    private func saveLocked(_ updated: [String: String]) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys])
        } catch {
            throw CredentialError.unexpectedStatus(errSecParam)
        }
        let generic = Data(updated.keys.sorted().joined(separator: ",").utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrGeneric as String: generic,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let updateStatus = context.update(base, attributes: attributes)
        if updateStatus == errSecItemNotFound {
            var insert = base
            insert.merge(attributes) { _, new in new }
            let addStatus = context.add(insert)
            guard addStatus == errSecSuccess else {
                throw keychainWriteError(addStatus)
            }
        } else {
            guard updateStatus == errSecSuccess else {
                throw keychainWriteError(updateStatus)
            }
        }
        state.lock()
        keys = updated
        refusal = nil
        unreadable = false
        state.unlock()
    }
}

/// The Keychain service names of the old layout.
///
/// The helpers stay because the service names are part of the app's naming
/// contract and because the migration still has to find the old items.
public enum CredentialStore {
    /// The prefix every legacy service name starts with.
    public static let servicePrefix = "DOT_API_KEY_"

    /// The legacy service name of one provider.
    public static func serviceName(for providerID: String) -> String {
        servicePrefix + providerID.uppercased()
    }

    /// The legacy account name of one provider.
    public static func account(for providerID: String) -> String {
        providerID.lowercased()
    }

    /// The store the app uses.
    public static let bundle = CredentialBundleStore.shared

    /// Reads a key from the bundle, first use only.
    public static func read(providerID: String) throws -> String? {
        try bundle.key(for: providerID)
    }

    /// Writes a key into the bundle, off the main actor.
    public static func write(_ secret: String, providerID: String) async throws {
        try await bundle.writeAsync(secret, providerID: providerID)
    }

    /// Removes a key from the bundle, off the main actor.
    public static func delete(providerID: String) async throws {
        try await bundle.deleteAsync(providerID: providerID)
    }

    /// Whether a provider has a key, answered without decrypting one.
    public static func hasKey(for providerID: String) -> Bool {
        bundle.hasKey(for: providerID)
    }

    /// Reads a legacy item's data. Used only by the legacy migration.
    public static func readSecret(
        service: String,
        account: String,
        context: CredentialKeychainContext = .default
    ) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let (status, item) = context.copy(query)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw credentialStatus(status)
        }
    }

    /// Writes a legacy item. Used by tests of the legacy migration.
    public static func writeSecret(
        _ secret: String,
        service: String,
        account: String,
        context: CredentialKeychainContext = .default
    ) throws {
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
        let updateStatus = context.update(query, attributes: attributes)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            let status = context.add(insert)
            guard status == errSecSuccess else { throw credentialStatus(status) }
            return
        }
        guard updateStatus == errSecSuccess else { throw credentialStatus(updateStatus) }
    }

    /// Probes a legacy item's attributes. Never decrypts.
    public static func hasSecret(
        service: String,
        account: String,
        context: CredentialKeychainContext = .default
    ) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let (status, item) = context.copy(query)
        return status == errSecSuccess && item != nil
    }

    private static func credentialStatus(_ status: OSStatus) -> CredentialError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed: .denied(status)
        case errSecInteractionNotAllowed: .unavailable(status)
        default: .unexpectedStatus(status)
        }
    }
}

/// The two Keychain questions, kept apart on purpose.
///
/// ``hasKey`` is answered from attributes; ``readKey`` decrypts. Code that only
/// needs to know whether a key exists may call ``hasKey``. A provider being
/// built for a real request calls ``readKey``, which reads the bundle once.
public struct CredentialProbe {
    /// Whether a provider has a key, answered from the item's attributes.
    public let hasKey: (String) -> Bool
    /// The key itself, decrypting the bundle on first use.
    public let readKey: (String) -> String?

    /// Creates a probe.
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
/// The copy happens once: when Dot already holds a key, the legacy item is not
/// read. Existence is answered from attributes, so a missing Dot key does not
/// decrypt anything. The legacy Xiaomi item is deliberately left in place, so
/// the other tool keeps working. No key is ever logged or printed.
public enum LegacyCredentialMigration {
    /// The service the Xiaomi tool used before Dot kept its own keys.
    public static let xiaomiService = "XIAOMI_API_KEY"

    /// What the migration found and did.
    public struct Result: Equatable, Sendable {
        /// Whether the legacy key was copied into Dot's item.
        public let migrated: Bool
        /// Whether Dot has a Xiaomi key after the attempt.
        public let keyAvailable: Bool

        public init(migrated: Bool, keyAvailable: Bool) {
            self.migrated = migrated
            self.keyAvailable = keyAvailable
        }
    }

    /// Copies the legacy Xiaomi key when it is absent.
    ///
    /// The injected closures keep this helper testable without a Keychain.
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

/// The shared in-flight reads of one bundle store.
///
/// The store is the unit of sharing: two caches built around the same store must
/// not start two decryptions of it. Reads never carry a deadline, so a prompt
/// answered late still resolves every waiter.
private final class CredentialFlightBook: @unchecked Sendable {
    private struct Entry {
        let id: UUID
        let generation: UInt64
        let task: Task<String?, Error>
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func task(
        for providerID: String,
        generation: UInt64,
        create: @escaping @Sendable () throws -> String?
    ) -> (id: UUID, task: Task<String?, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[providerID], entry.generation == generation {
            return (entry.id, entry.task)
        }
        let id = UUID()
        let task = Task.detached(priority: .userInitiated, operation: create)
        entries[providerID] = Entry(id: id, generation: generation, task: task)
        return (id, task)
    }

    func contains(_ providerID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[providerID] != nil
    }

    func remove(id: UUID, for providerID: String) {
        lock.lock()
        if entries[providerID]?.id == id { entries.removeValue(forKey: providerID) }
        lock.unlock()
    }

    func removeAll(for providerID: String) {
        lock.lock()
        entries.removeValue(forKey: providerID)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

/// The Keychain refused an operation.
public enum CredentialError: Error, Equatable, LocalizedError {
    /// The bundle holds data that is not a key map.
    case unreadable
    /// The person denied the read or the Keychain refused it.
    case denied(OSStatus)
    /// The Keychain could not be interacted with, for example while locked.
    case unavailable(OSStatus)
    /// The Keychain answered with a status Dot does not understand.
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The stored API keys could not be read. Nothing was changed."
        case .denied(let status), .unavailable(let status), .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "The Keychain refused the request: \(message)"
        }
    }
}
