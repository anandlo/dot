import Foundation

/// A short, safe way to name a key on screen.
///
/// The app shows which service is active so a person can tell at a glance what
/// their dictation is being sent to. It must never print the key itself: enough
/// to recognise a key, not enough to use one.
public enum MaskedKey {
    /// How many characters of the key are kept at each end.
    public static let visible = 4

    /// The shortest key that can be shown at all; anything shorter is hidden
    /// entirely, because four characters from each end of a short key would be
    /// the whole key.
    public static let minimumLength = 16

    /// A masked form of `key`, or `nil` when there is no key to describe.
    ///
    /// - Parameter key: the secret, as it came out of the Keychain.
    /// - Returns: `abcd…wxyz` for a long key, a fixed placeholder for a short one,
    ///   and `nil` when there is no key.
    public static func describe(_ key: String?) -> String? {
        guard let key else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count >= minimumLength else { return String(repeating: "•", count: 4) }
        let head = trimmed.prefix(visible)
        let tail = trimmed.suffix(visible)
        return "\(head)…\(tail)"
    }
}
