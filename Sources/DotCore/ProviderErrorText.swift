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

    /// A message that fits on the card and in one log line.
    ///
    /// One pass over the scalars, with the length counted as it goes: the body
    /// this is called with can be megabytes, and asking a `String` for its
    /// count on every character would make the cap itself the slow part.
    ///
    /// - Parameter text: the message the service sent, when it sent one.
    /// - Returns: the message with its whitespace flattened and its length
    ///   capped, or `nil` when there is nothing to say.
    public static func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        var flattened = ""
        flattened.reserveCapacity(maximumCharacters + 1)
        var length = 0
        var lastWasSpace = true
        var truncated = false
        for scalar in text.unicodeScalars {
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
}
