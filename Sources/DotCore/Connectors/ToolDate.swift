import Foundation

/// Reads and writes the dates a tool is given.
///
/// A model writes a date as text: `2026-11-13T09:00`, `2026-11-13T09:00:00Z`,
/// or `2026-11-13`. All three are accepted, and a date without a zone is read
/// in the person's own time zone, because "Friday at 9" means nine o'clock
/// where they are. Everything that reaches a calendar or a reminder goes
/// through here first, so no tool invents its own parser.
public enum ToolDate {
    /// The oldest year a date may name.
    public static let earliestYear = 2000
    /// The furthest year a date may name.
    public static let latestYear = 2100

    /// Parses a date the model wrote.
    ///
    /// - Parameter text: an ISO 8601 date, with or without a time and a zone.
    /// - Returns: the date, or `nil` when the text is not one this tool accepts.
    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else { return nil }
        // A date formatter reads a prefix and ignores the rest, so "2026-11-13
        // and more" would parse. The shape is checked first.
        guard isISOStyle(trimmed) else { return nil }

        let withZone = ISO8601DateFormatter()
        withZone.formatOptions = [.withInternetDateTime]
        if let date = withZone.date(from: trimmed), isInRange(date) { return date }

        let withoutSeconds = ISO8601DateFormatter()
        withoutSeconds.formatOptions = [.withInternetDateTime]
        // ISO8601DateFormatter requires seconds; a model habitually omits them,
        // and a fixed format style accepts both.
        let styles = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"]
        for pattern in styles {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = pattern
            formatter.isLenient = false
            if let date = formatter.date(from: trimmed), isInRange(date) { return date }
        }
        return nil
    }

    /// Whether text has the shape of an ISO 8601 date.
    ///
    /// `yyyy-MM-dd`, `yyyy-MM-ddTHH:mm` and `yyyy-MM-ddTHH:mm:ss`, with an
    /// optional `Z` or `+HH:MM` offset on the time, and nothing else. Checking
    /// the shape is what keeps a lenient parser from accepting a sentence.
    ///
    /// - Parameter text: the text from the model.
    /// - Returns: whether it is a date and only a date.
    private static func isISOStyle(_ text: String) -> Bool {
        var body = Substring(text)
        if body.hasSuffix("Z") {
            body = body.dropLast()
        }
        let parts = body.split(separator: "T", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        guard isDatePart(parts[0]) else { return false }
        guard parts.count == 2 else { return true }
        return isTimePart(parts[1])
    }

    /// `yyyy-MM-dd`, and nothing else.
    private static func isDatePart(_ text: Substring) -> Bool {
        let characters = Array(text)
        guard characters.count == 10 else { return false }
        guard characters[4] == "-", characters[7] == "-" else { return false }
        return characters.enumerated().allSatisfy { index, character in
            index == 4 || index == 7 ? true : character.isNumber
        }
    }

    /// `HH:mm`, `HH:mm:ss`, or either followed by `+HH:MM` or `-HH:MM`.
    private static func isTimePart(_ text: Substring) -> Bool {
        var time = text
        if let offset = time.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            let suffix = time[time.index(after: offset)...]
            guard suffix.count == 5 else { return false }
            let offsetCharacters = Array(suffix)
            guard offsetCharacters[2] == ":" else { return false }
            guard offsetCharacters.enumerated().allSatisfy({ index, character in
                index == 2 ? true : character.isNumber
            }) else { return false }
            time = time[..<offset]
        }
        let characters = Array(time)
        guard characters.count == 5 || characters.count == 8 else { return false }
        guard characters[2] == ":" else { return false }
        if characters.count == 8, characters[5] != ":" { return false }
        return characters.enumerated().allSatisfy { index, character in
            index == 2 || index == 5 ? true : character.isNumber
        }
    }

    /// Whether a date is in the window a person could mean.
    private static func isInRange(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let year = calendar.component(.year, from: date)
        return year >= earliestYear && year <= latestYear
    }

    /// Formats a date for a tool result, in the person's time zone.
    ///
    /// - Parameter date: the instant.
    /// - Returns: a short, sortable, unambiguous string.
    public static func describe(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = .current
        formatter.dateFormat = "EEE d MMM yyyy, HH:mm"
        return formatter.string(from: date)
    }

    /// Formats a day, without a time.
    ///
    /// - Parameter date: the instant.
    /// - Returns: a short date string.
    public static func describeDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = .current
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }

    /// The start of the day a date falls in, in the person's time zone.
    ///
    /// - Parameter date: the instant.
    /// - Returns: midnight that morning.
    public static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }
}
