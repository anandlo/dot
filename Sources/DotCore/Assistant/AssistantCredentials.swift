import Foundation

/// The Keychain side of the assistant's chat provider.
///
/// A chat key is the same kind of item a speech key is: service
/// `DOT_API_KEY_<ID>`, account the lowercase id. A vendor that already has a
/// speech key uses the same id here (`openai`, `groq`), so one key serves both
/// capabilities and the person is not asked for it twice.
///
/// The split is the one the rest of the app keeps. "Is there a key?" is
/// answered from the item's attributes and never decrypts
/// (``hasKey(for:)``); the key itself is read through ``CredentialCache``, once
/// per session, off the caller's actor, and registered as a secret the moment
/// it is read.
public enum AssistantCredentials {
    /// Whether a chat provider has a key, without decrypting the item.
    public static func hasKey(for providerID: String) -> Bool {
        CredentialStore.hasKey(for: providerID)
    }

    /// The key of a chat provider, resolved once per session.
    ///
    /// This decrypts on the first call. The main actor must not be the caller;
    /// use ``resolvedKey(for:cache:within:)`` from anything that draws.
    public static func key(for providerID: String, cache: CredentialCache = .shared) -> String? {
        cache.key(for: providerID)
    }

    /// Reads the key off the caller's actor, with a deadline.
    ///
    /// A decrypting Keychain read blocks its thread and, on a re-signed build,
    /// can wait for an answer on screen. The read therefore happens on a global
    /// utility queue and the caller gets the key or `nil` at the deadline
    /// instead of waiting for it.
    ///
    /// - Parameters:
    ///   - providerID: the provider id.
    ///   - cache: the session cache every read goes through.
    ///   - timeout: how long the caller is willing to wait.
    /// - Returns: the key, or `nil` when there is none or the read did not
    ///   finish in time.
    public static func resolvedKey(
        for providerID: String,
        cache: CredentialCache = .shared,
        within timeout: Duration = .seconds(5)
    ) async -> String? {
        let outcome = await BoundedWork.run(within: timeout) {
            cache.key(for: providerID)
        }
        switch outcome {
        case .finished(let key): return key
        case .timedOut: return nil
        }
    }

    /// Stores a key, registers it as a secret, and updates the cache.
    ///
    /// - Parameters:
    ///   - key: the secret. It is written to the Keychain and nowhere else.
    ///   - providerID: the provider id.
    ///   - cache: the session cache, so the next request does not decrypt.
    /// - Throws: ``CredentialError`` when the Keychain refuses the write.
    public static func store(
        _ key: String,
        for providerID: String,
        cache: CredentialCache = .shared
    ) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try CredentialStore.write(trimmed, providerID: providerID)
        Log.shared.registerSecret(trimmed)
        cache.store(trimmed, for: providerID)
    }

    /// Removes a key from the Keychain and forgets the cached one.
    public static func delete(
        for providerID: String,
        cache: CredentialCache = .shared
    ) throws {
        try CredentialStore.delete(providerID: providerID)
        cache.invalidate(providerID)
    }
}
