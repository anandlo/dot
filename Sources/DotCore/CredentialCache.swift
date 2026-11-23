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
    public static let shared = CredentialCache(bundle: .shared)

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
    /// The providers whose last read failed, so a caller can tell a refusal
    /// from a definite answer.
    ///
    /// A failure is not remembered as "no key": the read did not happen. It is
    /// remembered as "the last attempt failed", which is what a page needs to
    /// stop asking while its window is open rather than putting the same
    /// Keychain prompt on screen again.
    private var failures: Set<String> = []
    /// The providers whose key is being read right now.
    ///
    /// One read per provider, not one per caller. A decrypting read can sit
    /// behind a system prompt for ten seconds, and a second caller that waited
    /// for it would take the main actor down with it: that is what made the
    /// first theme change after a re-signed build feel like a ten second hang.
    private var resolving: Set<String> = []
    /// The keys that were found.
    private var values: [String: String] = [:]
    /// The one read running for each provider, shared by every async caller.
    private let flights = FlightBook()
    /// Incremented whenever a caller discards answers.
    private var globalEpoch: UInt64 = 0
    /// Registered when a read starts, so an invalidation can always identify it.
    private var generations: [String: UInt64] = [:]
    private var reads = 0
    private var durations: [String: Double] = [:]
    private let reader: Reader
    /// Whether an outcome is logged. A cache that never touches the Keychain
    /// has nothing to report about it.
    private let logsReads: Bool

    /// The store behind the default reader.
    private let bundle: CredentialBundleStore?

    /// Creates a cache.
    ///
    /// - Parameters:
    ///   - reader: the decrypting read. Injected so a test can count the reads
    ///     without a Keychain, and so the app has exactly one place that
    ///     touches one.
    ///   - logsReads: whether outcomes are written to the log.
    ///   - bundle: the store whose refusal an explicit action may clear.
    public init(
        reader: @escaping Reader = { CredentialCache.resolve(providerID: $0) },
        logsReads: Bool = true,
        bundle: CredentialBundleStore? = nil
    ) {
        self.reader = reader
        self.logsReads = logsReads
        self.bundle = bundle
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
        let generation = currentGenerationLocked(for: providerID)
        lock.unlock()
        return performRead(providerID, generation: generation)
    }

    private func performRead(_ providerID: String, generation: UInt64) -> String? {
        let started = ProcessInfo.processInfo.systemUptime
        return finish(reader(providerID), for: providerID, started: started, generation: generation)
    }

    private func finish(
        _ outcome: Outcome,
        for providerID: String,
        started: Double,
        generation: UInt64
    ) -> String? {
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
        let committed: Bool
        if case .failed = outcome {
            lock.lock()
            committed = isCurrentGenerationLocked(generation, for: providerID)
            if committed {
                resolving.remove(providerID)
                failures.insert(providerID)
                reads += 1
                durations[providerID] = milliseconds
            }
            lock.unlock()
        } else {
            committed = remember(
                key,
                for: providerID,
                milliseconds: milliseconds,
                countsAsRead: true,
                generation: generation
            )
        }
        guard committed else { return nil }
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
            // An undecodable bundle is a failed read even when the attribute
            // probe says there is no key: the bytes are still there and must
            // never be replaced. Calling that "missing" would cache a definite
            // answer for a read that never happened.
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

    /// Whether the last read of a provider's key failed.
    ///
    /// It answers for a read that returned ``Outcome/failed(_:)``; a key that
    /// was not asked for, an answer in progress and a definite "no key" all
    /// answer `false`. A caller uses it to stop asking: the next attempt can
    /// put the same Keychain prompt on screen again.
    ///
    /// - Parameter providerID: the provider id.
    /// - Returns: whether the last completed read failed.
    public func readFailed(_ providerID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failures.contains(providerID)
    }

    /// Puts a key in the cache, after the Keychain accepted it.
    ///
    /// - Parameters:
    ///   - key: the key, or `nil` for "this provider has none".
    ///   - providerID: the provider id.
    public func store(_ key: String?, for providerID: String) {
        lock.lock()
        // One counter for every answer change. A per-provider count can repeat
        // after an invalidation, and a repeated generation makes the rebuild
        // gate mistake a fresh answer for one it already handled.
        globalEpoch += 1
        let generation = globalEpoch
        generations[providerID] = generation
        lock.unlock()
        _ = remember(
            key,
            for: providerID,
            milliseconds: 0,
            countsAsRead: false,
            generation: generation
        )
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
        globalEpoch += 1
        generations[providerID] = globalEpoch
        resolving.remove(providerID)
        resolved.remove(providerID)
        failures.remove(providerID)
        values.removeValue(forKey: providerID)
        durations.removeValue(forKey: providerID)
        flights.removeAll(for: providerID)
        lock.unlock()
        bundle?.invalidateFlights(for: providerID)
        bundle?.allowRetry()
    }

    /// The generation of the current answer for a provider.
    public func generation(for providerID: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return currentGenerationLocked(for: providerID)
    }

    /// Whether a key read is running for a provider.
    public func isReadInFlight(_ providerID: String) -> Bool {
        lock.lock()
        let local = flights.contains(providerID)
        lock.unlock()
        return local || (bundle?.isKeyReadInFlight(providerID) == true)
    }

    /// A read's admission snapshot, taken under one lock so an invalidation
    /// cannot slip between the cached-key check and the generation check.
    private func admission(for providerID: String) -> (known: Bool, key: String?, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let generation = currentGenerationLocked(for: providerID)
        return (resolved.contains(providerID), values[providerID], generation)
    }

    private func currentGenerationLocked(for providerID: String) -> UInt64 {
        if let generation = generations[providerID] { return generation }
        let generation = globalEpoch
        generations[providerID] = generation
        return generation
    }

    private func isCurrentGenerationLocked(_ generation: UInt64, for providerID: String) -> Bool {
        (generations[providerID] ?? globalEpoch) == generation
    }

    /// Resolves a key off the caller's actor and waits for the answer.
    ///
    /// A SecurityAgent prompt can stay up longer than any deadline. Callers
    /// therefore wait for the real answer. Callers that arrive while a read is
    /// running await the same task instead of starting a second decryption.
    public func resolved(for providerID: String) async -> String? {
        let admission = self.admission(for: providerID)
        if admission.known { return admission.key }
        let generation = admission.generation

        if let bundle {
            // The store owns the shared read. Caches built around the same store
            // and generation wait on one Keychain answer.
            let started = ProcessInfo.processInfo.systemUptime
            let outcome: Outcome
            do {
                if let key = try await bundle.resolvedKey(
                    for: providerID,
                    generation: generation
                ), !key.isEmpty {
                    outcome = .key(key)
                } else {
                    outcome = bundle.hasKey(for: providerID)
                        ? .failed("The Keychain holds the key but refused to read it.")
                        : .missing
                }
            } catch {
                // An unreadable bundle is never a "no key" answer. The store
                // leaves its data untouched and records the read as failed.
                outcome = .failed(error.localizedDescription)
            }
            return finish(outcome, for: providerID, started: started, generation: generation)
        }

        let flight = flights.task(for: providerID, generation: generation) { [self] in
            performRead(providerID, generation: generation)
        }
        let key = await flight.task.value
        flights.remove(id: flight.id, for: providerID)
        // The commit already checked the generation; a stale task must also
        // hand its caller no answer.
        return self.generation(for: providerID) == generation ? key : nil
    }

    /// Lets an explicit action try a read the person denied.
    ///
    /// Nothing is forgotten: keys already in memory stay there, and a provider
    /// whose read failed is still unresolved. Only the refusal is cleared.
    public func retryDenied(for providerID: String? = nil) {
        lock.lock()
        if let providerID {
            failures.remove(providerID)
        } else {
            failures.removeAll()
        }
        lock.unlock()
        bundle?.allowRetry()
    }

    /// Forgets every answer.
    public func invalidateAll() {
        lock.lock()
        globalEpoch += 1
        generations.removeAll()
        resolving.removeAll()
        resolved.removeAll()
        failures.removeAll()
        values.removeAll()
        durations.removeAll()
        flights.removeAll()
        lock.unlock()
        bundle?.reset()
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
        countsAsRead: Bool,
        generation: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrentGenerationLocked(generation, for: providerID) else { return false }
        resolving.remove(providerID)
        failures.remove(providerID)
        resolved.insert(providerID)
        if let key, !key.isEmpty {
            values[providerID] = key
        } else {
            values.removeValue(forKey: providerID)
        }
        if countsAsRead { reads += 1 }
        durations[providerID] = milliseconds
        return true
    }
}
/// The shared reads, kept apart from the cache lock so an async caller can
/// consult them without using a non-async lock in an async context.
private final class FlightBook: @unchecked Sendable {
    private struct Entry {
        let id: UUID
        let generation: UInt64
        let task: Task<String?, Never>
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func task(
        for providerID: String,
        generation: UInt64,
        create: @escaping @Sendable () -> String?
    ) -> (id: UUID, task: Task<String?, Never>) {
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
        if entries[providerID]?.id == id {
            entries.removeValue(forKey: providerID)
        }
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

/// Decides which of several main-actor callers rebuilds a provider after a key
/// was resolved.
///
/// A press callback and the Stop that interrupts it can both arrive after the
/// same resolution. Only the first one for a provider and cache generation may
/// rebuild; an obsolete selected provider or signature rebuilds nothing.
@MainActor
public final class CredentialRebuildGate {
    private var handled: [String: UInt64] = [:]

    /// Creates a gate.
    public init() {}

    /// Runs `rebuild` when this is the current, ready answer for this provider.
    ///
    /// - Returns: whether this caller performed the rebuild.
    @discardableResult
    public func perform(
        providerID: String,
        selectedProviderID: String,
        signatureMatches: Bool,
        ready: Bool,
        generation: UInt64,
        rebuild: () -> Void
    ) -> Bool {
        guard providerID == selectedProviderID, signatureMatches, ready else { return false }
        guard handled[providerID] != generation else { return false }
        handled[providerID] = generation
        rebuild()
        return true
    }

    /// Forgets the decision for one provider, so a new answer can rebuild it.
    public func forget(_ providerID: String) {
        handled.removeValue(forKey: providerID)
    }

    /// Forgets which generations have already been handled.
    public func reset() {
        handled.removeAll()
    }
}

/// The one read a first use makes.
///
/// The launch of a self-signed build must not decrypt a Keychain item: each
/// stale item carries its own SecurityAgent prompt. The read is deferred until
/// a person actually asks for a key, runs off that person's actor and is awaited
/// to its real answer. No deadline turns a slow prompt into "no key".
public enum CredentialFirstUse {
    /// Resolves one provider's key and reports when the answer is in.
    ///
    /// - Parameters:
    ///   - providerID: the provider id.
    ///   - cache: the session cache shared by every caller.
    ///   - onResolved: called after the answer is cached, or immediately for a
    ///     provider that has no key.
    /// - Returns: whether the provider can be built: a keyless provider is
    ///   ready without a credential read.
    @discardableResult
    public static func resolve(
        _ providerID: String,
        cache: CredentialCache = .shared,
        onResolved: @Sendable @escaping () async -> Void = {}
    ) async -> Bool {
        guard ProviderPreset.requiresKey(for: providerID) else {
            await onResolved()
            return true
        }
        let found = await cache.resolved(for: providerID) != nil
        await onResolved()
        return found
    }

    /// Whether a stop has to rebuild a provider before it can finish the take.
    ///
    /// A missing provider is reason enough: the first-use callback may be queued
    /// behind this very stop, and a resolved cache does not mean the provider was
    /// rebuilt yet. An existing provider is stale when a key appeared after it
    /// was built, or when the cache advanced to a newer answer.
    ///
    /// - Parameters:
    ///   - providerAvailable: whether a provider instance exists already.
    ///   - providerID: the provider id.
    ///   - cache: the shared session cache.
    ///   - providerBuiltWithoutKey: whether that instance was built before any
    ///     key for this provider was resolved.
    ///   - buildGeneration: the cache generation the instance was built against.
    public static func takeNeedsRebuild(
        providerAvailable: Bool,
        providerID: String,
        cache: CredentialCache,
        providerBuiltWithoutKey: Bool = false,
        buildGeneration: UInt64? = nil
    ) -> Bool {
        guard providerAvailable else { return true }
        if providerBuiltWithoutKey, cache.resolvedKey(for: providerID) != nil { return true }
        if let buildGeneration, buildGeneration != cache.generation(for: providerID) { return true }
        return false
    }
}
