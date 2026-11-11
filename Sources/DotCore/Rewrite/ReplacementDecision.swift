import Foundation

/// What the Accessibility API saw when Dot pasted a transcript.
///
/// It is a value so the decision below can be a pure function: the element
/// reference itself never leaves the app layer, and a test compares a record
/// with a plain struct.
public struct InsertionRecord: Sendable, Equatable {
    /// The process Dot typed into.
    public var processIdentifier: Int32
    /// The application's bundle id, for the card's header.
    public var bundleIdentifier: String?
    /// Where the inserted text starts, in UTF-16 units.
    public var location: Int
    /// How long the inserted text is, in UTF-16 units.
    public var length: Int
    /// The text that was inserted, for the read-back comparison.
    public var insertedText: String
    /// When it was inserted.
    public var capturedAt: Date

    public init(
        processIdentifier: Int32,
        bundleIdentifier: String?,
        location: Int,
        length: Int,
        insertedText: String,
        capturedAt: Date
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.location = location
        self.length = length
        self.insertedText = insertedText
        self.capturedAt = capturedAt
    }

    /// The record of the same range after a rewrite was written into it.
    public func replacing(length newLength: Int, text: String, at date: Date) -> InsertionRecord {
        InsertionRecord(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            location: location,
            length: newLength,
            insertedText: text,
            capturedAt: date
        )
    }
}

/// Why a rewrite cannot be written where the transcript went.
///
/// Every case ends the same way: the rewrite goes on the clipboard and the card
/// says so. The distinctions exist because the log has to be able to explain a
/// refusal that the card describes with one sentence.
public enum ReplacementReason: String, Sendable, Equatable, CaseIterable {
    /// Another application is frontmost now.
    case appChanged
    /// The paste is too old to trust what is at the range.
    case tooLate
    /// The range could not be read at all.
    case unreadable
    /// The same application has focus, but on another field.
    case focusMoved
    /// The text at the range is no longer the transcript.
    case textChanged
    /// The replacement was written but could not be read back.
    case readBackFailed
}

/// What to do with a rewrite.
public enum ReplacementOutcome: Sendable, Equatable {
    /// The range still holds the transcript, so the rewrite replaces it.
    case replace
    /// The rewrite goes to the clipboard.
    case clipboardOnly(ReplacementReason)
}

/// Decides whether a rewrite may replace the pasted transcript.
///
/// The check is deliberately conservative. A paste is the only record of where
/// the words went, and anything that changed since then means the range may
/// hold someone else's sentence: the rewrite then goes to the clipboard, which
/// is a loss of one click and never a loss of text.
public enum ReplacementDecision {
    /// How long a pasted range is trusted, in seconds.
    public static let maximumAge: TimeInterval = 20

    /// Decides for one attempt.
    ///
    /// - Parameters:
    ///   - anchor: the insertion Dot made, or `nil` when the Accessibility API
    ///     could not be read.
    ///   - now: the moment of the attempt.
    ///   - processIdentifier: the frontmost application's process, when it is
    ///     known.
    ///   - focusedIsAnchor: whether the focused element is the one the text
    ///     went into, compared with `CFEqual` by the caller.
    ///   - textInRange: the text the range holds now, when it could be read.
    public static func decide(
        anchor: InsertionRecord?,
        now: Date,
        processIdentifier: Int32?,
        focusedIsAnchor: Bool,
        textInRange: String?
    ) -> ReplacementOutcome {
        guard let anchor else { return .clipboardOnly(.unreadable) }
        guard let processIdentifier, processIdentifier == anchor.processIdentifier else {
            return .clipboardOnly(.appChanged)
        }
        let age = now.timeIntervalSince(anchor.capturedAt)
        guard age.isFinite, age >= 0 else { return .clipboardOnly(.unreadable) }
        guard age <= maximumAge else { return .clipboardOnly(.tooLate) }
        guard focusedIsAnchor else { return .clipboardOnly(.focusMoved) }
        guard matches(inserted: anchor.insertedText, live: textInRange) else {
            return .clipboardOnly(.textChanged)
        }
        return .replace
    }

    /// Whether the range still holds what was inserted.
    ///
    /// Whitespace, curly quotes and the leading capital are ignored: an app
    /// that applies its own capitalisation or rewraps the paragraph has not
    /// changed the words, and refusing there would make the feature useless in
    /// exactly the editors people dictate into.
    public static func matches(inserted: String, live: String?) -> Bool {
        guard let live else { return false }
        return normalised(inserted) == normalised(live)
    }

    /// The comparison form of a text.
    public static func normalised(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "\u{201C}", with: "'")
            .replacingOccurrences(of: "\u{201D}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if let first = value.first {
            value.replaceSubrange(value.startIndex ... value.startIndex, with: String(first).lowercased())
        }
        return value
    }
}
