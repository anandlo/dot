import Foundation

/// The one place a voice provider's key is required and registered.
///
/// A key that reaches a log field must already be known to the logger as a
/// secret. The Keychain helpers register what they decrypt; this does the same
/// for a key that arrives from a factory or a test, so the redaction rule holds
/// no matter how the provider was built.
public enum VoiceKey {
    /// Returns the key, or throws the error the card shows.
    ///
    /// - Parameters:
    ///   - key: the key, when there is one.
    ///   - provider: the provider's display name, for the message.
    /// - Returns: the key without surrounding whitespace.
    /// - Throws: ``ProviderError/missingCredential(_:)`` when there is none.
    public static func required(_ key: String?, provider: String) throws -> String {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw ProviderError.missingCredential("\(provider) needs an API key.")
        }
        Log.shared.registerSecret(trimmed)
        return trimmed
    }

    /// Whether a key is present and usable.
    ///
    /// - Parameter key: the key, when there is one.
    public static func isPresent(_ key: String?) -> Bool {
        !(key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }
}
