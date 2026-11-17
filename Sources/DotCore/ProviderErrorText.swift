import Foundation

/// The text of an error a speech service sent back.
///
/// A failed request can answer with anything the service or a proxy in front of
/// it feels like: a short JSON message, a whole HTML page, an empty body. The
/// message is shown on the card and written to the log, so it is capped and
/// flattened first: a page of markup is not an explanation, and a multi
/// kilobyte log line is not a log line.
public enum ProviderErrorText {
    /// The longest message Dot repeats.
    public static let maximumCharacters = 240

    /// What a credential found in a message is replaced with.
    public static let redaction = "[redacted]"

    /// A message that fits on the card and in one log line.
    ///
    /// One pass over the scalars, with the length counted as it goes: the body
    /// this is called with can be megabytes, and asking a `String` for its
    /// count on every character would make the cap itself the slow part.
    ///
    /// A service, or a proxy, can repeat a credential it was sent. The text is
    /// redacted first, so a token in a response body never reaches the card,
    /// the log or the status row.
    ///
    /// - Parameter text: the message the service sent, when it sent one.
    /// - Returns: the message with its credentials redacted, its whitespace
    ///   flattened and its length capped, or `nil` when there is nothing to
    ///   say.
    public static func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        let safeText = redacting(text)
        var flattened = ""
        flattened.reserveCapacity(maximumCharacters + 1)
        var length = 0
        var lastWasSpace = true
        var truncated = false
        for scalar in safeText.unicodeScalars {
            if scalar.properties.isWhitespace || scalar.properties.generalCategory == .control {
                // One space per run, and never at the start of the message.
                guard !lastWasSpace else { continue }
                flattened.unicodeScalars.append(" ")
                lastWasSpace = true
                length += 1
            } else {
                flattened.unicodeScalars.append(scalar)
                lastWasSpace = false
                length += 1
            }
            if length > maximumCharacters {
                truncated = true
                break
            }
        }
        let trimmed = flattened.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard truncated else { return trimmed }
        return String(trimmed.prefix(maximumCharacters - 1)) + "…"
    }

    /// The message the card and the log repeat for an over-sized answer.
    public static var oversizedAnswer: String {
        "the service sent more than Dot accepts"
    }

    /// Replaces a credential the text carries with ``redaction``.
    ///
    /// The shapes are the ones a provider or a proxy repeats back: a key with a
    /// vendor prefix, a `Bearer` token, and a `name=value` or `name: value`
    /// member whose name is one of the handful that hold a secret. It is a
    /// textual guard, not a parser: over-redacting a sentence is harmless,
    /// under-redacting a token is not.
    ///
    /// - Parameter text: the message, before it is flattened.
    /// - Returns: the message with credential-shaped runs replaced.
    public static func redacting(_ text: String) -> String {
        let lowered = text.lowercased()
        let candidates = ["sk-", "pk-", "rk-", "bearer", "key", "token", "secret", "password", "authorization"]
        guard candidates.contains(where: lowered.contains) else { return text }
        guard let regex = credentialPattern else { return text }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: redaction)
    }

    /// One pattern for every credential shape, so the text is walked once.
    private static let credentialPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?i)\b(?:sk|pk|rk)-[A-Za-z0-9_-]{6,}|\bBearer\s+[A-Za-z0-9._~+/=-]{6,}|\b(?:api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|token|secret|password|authorization|x-api-key)\b[\"']?\s*[:=]\s*[\"']?(?:Bearer\s+)?[^\"'\s,;}]{4,}[\"']?"#,
        options: []
    )
}
