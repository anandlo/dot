import Foundation

/// The pure half of the dictation palette.
///
/// The palette is a panel and a list, but what it *does* is a filter, a ranking
/// and a key map. All three live here so they can be tested without a window,
/// a keyboard or a history file.
public enum TranscriptSearch {
    /// The most rows a query returns.
    ///
    /// The palette is a picker, not a browser: a search that returns everything
    /// is the same as no search at all.
    public static let maximumResults = 50

    /// One transcript that matches a query.
    public struct Match: Equatable, Sendable {
        /// Where the transcript sits in the list it was searched in, newest
        /// first, so the caller can post the right entry back.
        public let index: Int
        /// The transcript.
        public let text: String
        /// How well it matches. Bigger is better; the number is only meaningful
        /// against another score from the same query.
        public let score: Int

        /// Creates a match.
        public init(index: Int, text: String, score: Int) {
            self.index = index
            self.text = text
            self.score = score
        }
    }

    /// The words of a query, folded and split.
    ///
    /// Every word has to appear somewhere in the transcript, so "fig tree"
    /// finds "water the fig tree" and not the other way round. Matching whole
    /// words only would fail on the way people actually type — a prefix of a
    /// word they half remember — so each word is matched as a substring.
    public static func tokens(_ query: String) -> [String] {
        fold(query)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    /// The transcripts that match a query, best first.
    ///
    /// An empty query returns the list as it arrived: the palette's first
    /// screen is the recent dictations, newest first.
    ///
    /// - Parameters:
    ///   - query: what the person typed.
    ///   - transcripts: the history, newest first.
    /// - Returns: at most ``maximumResults`` matches.
    public static func matches(_ query: String, in transcripts: [String]) -> [Match] {
        let words = tokens(query)
        let foldedQuery = fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [Match] = []
        for (index, text) in transcripts.enumerated() {
            guard let score = rank(text: text, tokens: words, query: foldedQuery) else { continue }
            results.append(Match(index: index, text: text, score: score))
        }
        guard !words.isEmpty else { return Array(results.prefix(maximumResults)) }
        let ordered = results.sorted { first, second in
            if first.score != second.score { return first.score > second.score }
            // A shorter transcript containing the same words is the more
            // specific hit, and the file is newest first, so an older entry
            // never wins a tie against a newer one.
            if first.text.count != second.text.count { return first.text.count < second.text.count }
            return first.index < second.index
        }
        return Array(ordered.prefix(maximumResults))
    }

    /// How well one transcript answers a query, or `nil` when it does not.
    ///
    /// - Parameters:
    ///   - text: the transcript.
    ///   - tokens: the folded words of the query, from ``tokens(_:)``.
    ///   - query: the folded query, used for the whole-phrase prefix bonus.
    public static func rank(text: String, tokens: [String], query: String) -> Int? {
        guard !tokens.isEmpty else { return 0 }
        let foldedText = fold(text)
        guard !foldedText.isEmpty else { return nil }
        var score = 0
        for (position, token) in tokens.enumerated() {
            guard let range = bestRange(of: token, in: foldedText) else { return nil }
            let offset = foldedText.distance(from: foldedText.startIndex, to: range.lowerBound)
            if offset == 0 {
                // A match at the very start of the transcript is what a person
                // means when they type the first words of a dictation.
                score += position == 0 ? 60 : 24
            }
            if startsWord(foldedText, at: range.lowerBound) { score += 12 }
            // Earlier is better, saturating: after forty characters the
            // position stops being a signal.
            score += max(0, 20 - offset / 4)
        }
        if !query.isEmpty, foldedText.hasPrefix(query) { score += 80 }
        return score
    }

    /// Moves a selection by a step, wrapping at both ends.
    ///
    /// Wrapping is what makes the arrow keys usable in a short list: pressing
    /// down on the last row returns to the newest transcript instead of
    /// stopping dead.
    ///
    /// - Parameters:
    ///   - index: the current selection.
    ///   - step: how many rows to move, positive or negative.
    ///   - count: how many rows there are.
    /// - Returns: the new selection, or `0` for an empty list.
    public static func advanced(_ index: Int, by step: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let wrapped = (index + step) % count
        return wrapped < 0 ? wrapped + count : wrapped
    }

    /// One line of a transcript, for a row that only has room for one.
    ///
    /// A dictation may hold paragraphs; a row cannot. The newlines are turned
    /// into spaces rather than kept, so a preview never ends in a blank line.
    public static func preview(of text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Case- and diacritic-insensitive folding for both sides of a comparison.
    static func fold(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    /// Whether an offset sits at the start of a word.
    private static func startsWord(_ text: String, at index: String.Index) -> Bool {
        guard index != text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return !(previous.isLetter || previous.isNumber)
    }

    /// The best place a token appears, preferring a word start and then the
    /// earliest appearance.
    private static func bestRange(of token: String, in text: String) -> Range<String.Index>? {
        var first: Range<String.Index>?
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: token, range: searchStart..<text.endIndex) {
            if first == nil { first = found }
            if startsWord(text, at: found.lowerBound) { return found }
            searchStart = text.index(after: found.lowerBound)
        }
        return first
    }
}

/// What a key press means to the palette.
///
/// The panel translates AppKit key codes into these cases; the mapping to a
/// command is a pure function so the behaviour of Escape and of a Return with
/// nothing selected can be stated once and tested.
public enum PaletteKey: Sendable, Equatable {
    case up
    case down
    case returnKey
    case shiftReturn
    case escape
    /// A key the palette does not use.
    case other
}

/// What the palette should do with a key.
public enum PaletteCommand: Sendable, Equatable {
    case moveUp
    case moveDown
    case insert
    case copyOnly
    case dismiss
    case ignore
}

/// The key map of the palette.
public enum PaletteKeyboard {
    /// The command for a key, given whether a row is selected.
    ///
    /// - Parameters:
    ///   - key: the key that was pressed.
    ///   - hasSelection: whether there is a row to act on.
    /// - Returns: what to do.
    public static func command(for key: PaletteKey, hasSelection: Bool) -> PaletteCommand {
        switch key {
        case .up:
            return .moveUp
        case .down:
            return .moveDown
        case .returnKey:
            // Return with nothing selected must not paste the previous
            // transcript: the palette's job is the row the person is looking at.
            return hasSelection ? .insert : .ignore
        case .shiftReturn:
            return hasSelection ? .copyOnly : .ignore
        case .escape:
            return .dismiss
        case .other:
            return .ignore
        }
    }
}

/// How old a transcript is, in the words a row has room for.
public enum PaletteAge {
    /// The age of an entry, relative to now.
    ///
    /// - Parameters:
    ///   - date: when the transcript was added; `nil` for an entry written
    ///     before the history kept dates.
    ///   - now: the current time.
    /// - Returns: `"2h ago"`, or `nil` when the age is not known.
    public static func string(since date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 60 else { return "just now" }
        if seconds < 3_600 { return "\(max(1, Int(seconds / 60)))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d ago" }
        if seconds < 30 * 86_400 { return "\(Int(seconds / (7 * 86_400)))w ago" }
        return "\(max(1, Int(seconds / (30 * 86_400))))mo ago"
    }
}
