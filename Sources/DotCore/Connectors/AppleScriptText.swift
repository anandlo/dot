import Foundation

/// Turns model-supplied text into an AppleScript string literal.
///
/// A script is never built by pasting model text into source. Every tool that
/// scripts another app composes a fixed template and hands its values to
/// ``literal(_:)``, which returns source that is inside a quote no matter what
/// the text contained. That removes the whole class of bug where `"` or `¬` in
/// a reminder title changes what the script does.
///
/// The escapes used here are the ones the AppleScript language defines inside a
/// literal: `\\`, `\"`, `\n`, `\r` and `\t`. A character with no escape (a
/// control character, a Unicode line separator) is emitted as a
/// `(character id N)` expression joined with `&`, which the language evaluates
/// as data, never as syntax.
public enum AppleScriptText {
    /// The longest value a script accepts.
    ///
    /// Scripts are compiled synchronously before they run, and the compile cost
    /// grows with the source. A megabyte of text would turn a tool call into a
    /// stall, so a value past this length is cut. The tools reject longer input
    /// in their schema first; this is the second line of defence.
    public static let maximumCharacters = 4000

    /// Returns an AppleScript expression that evaluates to `value`.
    ///
    /// The result is always a single line, always a single expression, and never
    /// relies on the caller adding quotes.
    ///
    /// - Parameter value: text of any kind, including quotes, backslashes,
    ///   newlines, tabs and control characters.
    /// - Returns: source such as `"a\"b"`, or `"a" & (character id 11) & "b"` for
    ///   text with no literal escape.
    public static func literal(_ value: String) -> String {
        var parts: [String] = []
        var current = ""
        var remaining = maximumCharacters

        for scalar in value.unicodeScalars {
            guard remaining > 0 else { break }
            remaining -= 1
            switch scalar {
            case "\\":
                current += "\\\\"
            case "\"":
                current += "\\\""
            case "\n":
                current += "\\n"
            case "\r":
                current += "\\r"
            case "\t":
                current += "\\t"
            default:
                if needsCharacterExpression(scalar) {
                    if !current.isEmpty {
                        parts.append("\"\(current)\"")
                        current = ""
                    }
                    parts.append("(character id \(scalar.value))")
                } else {
                    current.unicodeScalars.append(scalar)
                }
            }
        }
        if !current.isEmpty {
            parts.append("\"\(current)\"")
        }
        if parts.isEmpty { return "\"\"" }
        return parts.joined(separator: " & ")
    }

    /// Whether a scalar has to be built with `character id`.
    ///
    /// A control character has no escape in the language, and the two Unicode
    /// line separators would end the line the literal sits on. Every other
    /// character, including `¬`, is ordinary data inside a single-line literal.
    private static func needsCharacterExpression(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x20 || scalar.value == 0x7F { return true }
        return scalar.value == 0x2028 || scalar.value == 0x2029
    }
}
