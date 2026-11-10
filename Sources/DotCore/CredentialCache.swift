import Foundation

/// The API keys Dot has resolved in this session.
///
/// Reading a key is not a cheap getter. ``CredentialStore/read(providerID:)``
/// asks the Keychain for the item's *data*, so macOS has to decrypt it, and a
/// decrypting `SecItemCopyMatching` blocks the calling thread. On a build whose
/// signature has changed since the item was written it can also put a system
/// prompt on screen and wait for an answer; on the launch path of this app a
/// single call was measured at about fourteen seconds, with the whole sample in
/// `SecItemCopyMatching` → `cssm_DecryptDataFinal`.
///
/// So the key is resolved **once per provider per session**, here, and every
/// other caller reads this cache:
///
/// - the provider is built from the cached key, so a transcription never pays
///   for it;
/// - the menu, the availability probe and the twenty-second refresh ask
///   ``CredentialStore/hasKey(for:)``, which is answered from the item's
///   attributes and never decrypts;
/// - a key that is written is put here at the same moment, so the cache cannot
///   disagree with the Keychain;
/// - a failed read is not cached, so a locked Keychain is retried later instead
///   of being remembered as "no key" for the rest of the session.
///
/// The cache also counts its reads and their duration. The number is logged —
/// never the key — so a slow Keychain is visible instead of being felt.
public final class CredentialCache: @unchecked Sendable {
    /// What a read of one key found.
    public enum Outcome: Equatable, Sendable {
        /// The provider has this key.
        case key(String)
        /// The provider has no key. This is an answer, and it is remembered.
        case missing
        /// The read did not happen: the Keychain was locked, refused, or the
        /// item could not be decrypted. It is **not** remembered, so the next
        /// ask tries again instead of leaving the app keyless for the session.
        case failed(String)
    }

    /// Reads a key from wherever keys live.
    public typealias Reader = @Sendable (String) -> Outcome

    /// The cache the app uses.
    public static let shared = CredentialCache()

    /// A cache that never reads anything and holds no key.
    ///
    /// Used to build a provider's *description* (its name, whether it needs a
    /// key) without touching a credential, and by tests so a test run never
    /// decrypts the user's key. Every call makes its own empty cache, so one
    /// caller cannot leave state behind for another.
    ///
    /// It is silent. It answers "missing" to every question, and a description
    /// is built whenever the menu or the twenty-second probe is filled, so
    /// logging its answers wrote `credential.read found:false` into the log
    /// three times a minute. Those lines looked exactly like a real read and
    /// said the opposite of the truth: the key was there the whole time.
    public static var empty: CredentialCache {
        CredentialCache(reader: { _ in .missing }, logsReads: false)
    }

    private let lock = NSLock()
    /// The providers whose key has been resolved, whether or not one was found.
    private var resolved: Set<String> = []
    /// The providers whose key is being read right now.
    ///
    /// One read per provider, not one per caller. A decrypting read can sit
    /// behind a system prompt for ten seconds, and a second caller that waited
    /// for it would take the main actor down with it: that is what made the
    /// first theme change after a re-signed build feel like a ten second hang.
    private var resolving: Set<String> = []
    /// The keys that were found.
    private var values: [String: String] = [:]
    private var reads = 0
    private var durations: [String: Double] = [:]
    private let reader: Reader
    /// Whether an outcome is logged. A cache that never touches the Keychain
    /// has nothing to report about it.
    private let logsReads: Bool

    /// Creates a cache.
    ///
    /// - Parameter reader: the decrypting read. Injected so a test can count
    ///   the reads without a Keychain, and so the app has exactly one place
    ///   that touches one.
    public init(
        reader: @escaping Reader = { CredentialCache.resolve(providerID: $0) },
        logsReads: Bool = true
    ) {
        self.reader = reader
        self.logsReads = logsReads
    }

    /// The key of a provider.
    ///
    /// The first call decrypts the item; every later call answers from memory.
    /// A read that fails throws inside the reader and answers `nil` *without*
    /// being cached.
    ///
    /// - Parameter providerID: the provider id, e.g. `openai`.
    /// - Returns: the key, or `nil` when the provider has none.
    public func key(for providerID: String) -> String? {
        lock.lock()
        if resolved.contains(providerID) {
            let cached = values[providerID]
            lock.unlock()
            return cached
        }
        if resolving.contains(providerID) {
            // Someone else is already inside the read. Answer with what is known
            // now instead of queueing behind a Keychain prompt this caller
            // cannot answer.
            let known = values[providerID]
            lock.unlock()
            return known
        }
        resolving.insert(providerID)
        lock.unlock()

        let started = ProcessInfo.processInfo.systemUptime
        let outcome = reader(providerID)
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let key: String?
        switch outcome {
        case .key(let value):
            key = value
        case .missing, .failed:
            key = nil
        }
        // A read that failed is not an answer: it must not be remembered, or a
        // locked Keychain would leave the app keyless until it is restarted.
        if case .failed = outcome {
            lock.lock()
            resolving.remove(providerID)
            reads += 1
            durations[providerID] = milliseconds
            lock.unlock()
        } else {
            remember(key, for: providerID, milliseconds: milliseconds, countsAsRead: true)
        }
        if logsReads {
            Log.shared.info("credential.read", [
                "provider": .string(providerID),
                "found": .bool(key != nil),
                "failed": .bool({ if case .failed = outcome { return true } else { return false } }()),
                "ms": .double((milliseconds * 10).rounded() / 10),
            ])
        }
        if let key {
            // Defense in depth: a key that passes through the logger is
            // written as stars.
            Log.shared.registerSecret(key)
        }
        return key
    }

    /// What the Keychain says about one provider's key.
    ///
    /// The disambiguation matters: on a build whose signature changed since the
    /// item was written, macOS answers the decrypting query with "not found"
    /// while the item is plainly there. Reporting that as ``Outcome/missing``
    /// made a re-signed build look exactly like a fresh install, and the log
    /// agreed with it. The attribute query needs no decrypt and no permission,
    /// so it can tell the two apart.
    ///
    /// - Parameters:
    ///   - providerID: the provider id.
    ///   - read: the decrypting read.
    ///   - hasKey: the attribute-only existence check.
    public static func resolve(
        providerID: String,
        read: (String) throws -> String? = CredentialStore.read,
        hasKey: (String) -> Bool = CredentialStore.hasKey
    ) -> Outcome {
        do {
            if let key = try read(providerID), !key.isEmpty {
                return .key(key)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
        guard hasKey(providerID) else { return .missing }
        return .failed("The Keychain holds the key but refused to read it.")
    }

    /// The key of a provider, only if it has been resolved already.
    ///
    /// - Parameter providerID: the provider id.
    /// - Returns: the key, or `nil` when it has not been resolved yet.
    public func resolvedKey(for providerID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard resolved.contains(providerID) else { return nil }
        return values[providerID]
    }

    /// Whether the key of a provider has been resolved in this session.
    ///
    /// - Parameter providerID: the provider id.
    public func isResolved(_ providerID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return resolved.contains(providerID)
    }

    /// Puts a key in the cache, after the Keychain accepted it.
    ///
    /// - Parameters:
    ///   - key: the key, or `nil` for "this provider has none".
    ///   - providerID: the provider id.
    public func store(_ key: String?, for providerID: String) {
        remember(key, for: providerID, milliseconds: 0, countsAsRead: false)
        if let key, !key.isEmpty {
            Log.shared.registerSecret(key)
        }
        if logsReads {
            Log.shared.info("credential.cached", ["provider": .string(providerID)])
        }
    }

    /// Forgets what was resolved for a provider, so the next ask decrypts.
    ///
    /// - Parameter providerID: the provider id.
    public func invalidate(_ providerID: String) {
        lock.lock()
        resolved.remove(providerID)
        values.removeValue(forKey: providerID)
        durations.removeValue(forKey: providerID)
        lock.unlock()
    }

    /// Forgets every answer.
    public func invalidateAll() {
        lock.lock()
        resolved.removeAll()
        values.removeAll()
        durations.removeAll()
        lock.unlock()
    }

    /// Resolves every provider the given ids name, once.
    ///
    /// This is the call a launch or a settings change makes on a background
    /// queue: decrypting a Keychain item blocks for as long as the Keychain
    /// takes, and it must never happen on a thread that draws the card.
    ///
    /// - Parameter providerIDs: the providers to resolve.
    public func warm(_ providerIDs: [String]) {
        for id in providerIDs {
            _ = key(for: id)
        }
    }

    /// Whether this cache reports what it finds to the log.
    ///
    /// A description cache answers without touching the Keychain, so its
    /// answers say nothing about the user's key and must not be logged as if
    /// they did.
    public var reportsReads: Bool { logsReads }

    /// How many decryptions this cache has done.
    public var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    /// How long the decryption of a provider took, in milliseconds.
    ///
    /// - Parameter providerID: the provider id.
    public func readMilliseconds(for providerID: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return durations[providerID]
    }

    // MARK: - Internals

    private func remember(
        _ key: String?,
        for providerID: String,
        milliseconds: Double,
        countsAsRead: Bool
    ) {
        lock.lock()
        resolving.remove(providerID)
        resolved.insert(providerID)
        if let key, !key.isEmpty {
            values[providerID] = key
        } else {
            values.removeValue(forKey: providerID)
        }
        if countsAsRead { reads += 1 }
        durations[providerID] = milliseconds
        lock.unlock()
    }
}
