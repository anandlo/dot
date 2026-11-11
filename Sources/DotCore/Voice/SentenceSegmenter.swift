import Foundation

/// Cuts a streamed answer into sentences as it arrives.
///
/// Speech cannot start until there is a sentence to speak, so the segmenter is
/// on the critical path of time to first audio: it must emit a sentence the
/// moment the model has finished writing one, and it must never emit a cut that
/// is not a sentence. Getting that wrong is audible. "Dr. Smith" spoken as two
/// utterances inserts a pause after the title; "3.14" cut at the dot says "three"
/// and then "fourteen"; a URL cut at its dots is read as a list of words.
///
/// The rules are therefore conservative. A dot only ends a sentence when it is
/// followed by whitespace, it is not part of an abbreviation or an initial, and
/// the token before it does not look like an identifier, a path or an address.
/// A cut at the end of the buffer is never made on a dot alone, because the next
/// chunk may carry the rest of "e.g." or of "example.com"; the tail is emitted by
/// ``flush()`` when the model has finished.
///
/// A run-on answer with no punctuation would otherwise wait forever, so two caps
/// exist: a clause break is taken once a segment passes
/// ``clauseCharacters``, and a space break once it passes
/// ``maximumSegmentCharacters``. Neither cap can land inside a number.
public struct SentenceSegmenter: Sendable {
    /// The length past which a segment is cut at the last space.
    public static let maximumSegmentCharacters = 240
    /// The length past which a segment is cut at a clause break.
    public static let clauseCharacters = 120
    /// The shortest prefix a clause or space cut is allowed to leave.
    public static let minimumClauseCharacters = 40

    /// The text that has arrived but is not a complete sentence yet.
    private var buffer = ""

    /// Creates an empty segmenter.
    public init() {}

    /// The text waiting for its ending.
    public var pendingText: String { buffer }

    /// Adds streamed text and returns every sentence it completed.
    ///
    /// - Parameter text: the delta the model just produced.
    /// - Returns: the sentences that are ready to speak, in order.
    public mutating func append(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        buffer += text
        var sentences: [String] = []
        while let cut = nextCut() {
            guard cut > buffer.startIndex else {
                // A cut that consumes nothing would loop forever; drop the byte
                // that produced it instead.
                buffer.removeFirst()
                continue
            }
            let sentence = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cut...])
            if Self.isSpeakable(sentence) { sentences.append(sentence) }
        }
        return sentences
    }

    /// Returns the text left over when the answer is complete.
    ///
    /// - Returns: the tail, when it has anything speakable in it.
    public mutating func flush() -> [String] {
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard Self.isSpeakable(tail) else { return [] }
        return [tail]
    }

    /// Forgets the buffered text, e.g. when a turn is cancelled.
    public mutating func reset() {
        buffer = ""
    }

    /// Whether a piece of text is worth synthesising.
    ///
    /// Punctuation alone, a lone bullet or a line of markup has no sound; asking
    /// a vendor to speak it costs a request and produces silence or a click.
    ///
    /// - Parameter text: the candidate.
    public static func isSpeakable(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// The end of the first sentence in the buffer, and where the next one
    /// starts.
    private func nextCut() -> String.Index? {
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            if Self.hardTerminators.contains(character) {
                return skipWhitespace(from: skipClosers(from: buffer.index(after: index)))
            }
            if character == "\n" {
                var end = buffer.index(after: index)
                var blank = false
                while end < buffer.endIndex, buffer[end] == "\n" {
                    blank = true
                    end = buffer.index(after: end)
                }
                if blank { return end }
                index = end
                continue
            }
            guard Self.softTerminators.contains(character) else {
                index = buffer.index(after: index)
                continue
            }
            var end = buffer.index(after: index)
            var runLength = 1
            while end < buffer.endIndex, Self.softTerminators.contains(buffer[end]) {
                end = buffer.index(after: end)
                runLength += 1
            }
            // The space comes after any closing quote or bracket: `"go." Then`
            // ends after the quote, not before it.
            let afterClosers = skipClosers(from: end)
            guard afterClosers < buffer.endIndex else {
                // The chunk ends on the punctuation: hold it, the next delta
                // decides whether it was a sentence or an abbreviation. A very
                // long run-on still gets capped.
                return clauseCut() ?? lengthCut()
            }
            guard buffer[afterClosers].isWhitespace else {
                index = end
                continue
            }
            let singleDot = runLength == 1 && character == "."
            if singleDot, !dotEndsSentence(at: index) {
                index = end
                continue
            }
            return skipWhitespace(from: afterClosers)
        }
        return clauseCut() ?? lengthCut()
    }
}

// MARK: - The rules

extension SentenceSegmenter {
    /// Punctuation that ends a sentence on its own, with no space required.
    private static let hardTerminators: Set<Character> = ["…", "。", "！", "？"]

    /// Punctuation that needs whitespace after it before it counts.
    private static let softTerminators: Set<Character> = [".", "!", "?"]

    /// Characters that may sit between a terminator and the space after it.
    private static let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}"]

    /// Titles, months, units and Latin abbreviations that end in a dot without
    /// ending a sentence.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "messrs", "dr", "prof", "rev", "hon", "pres", "supt",
        "sr", "jr", "st", "mt", "ft", "vs", "etc", "approx", "fig", "figs",
        "inc", "ltd", "co", "corp", "llc", "dept", "est", "gov", "univ",
        "ave", "blvd", "rd", "sq", "vol", "vols", "pp", "cf", "ed", "eds", "al",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
        "hr", "hrs", "min", "mins", "sec", "secs", "oz", "lb", "lbs", "kg", "km",
        "cm", "mm", "mph", "kmh", "tbsp", "tsp",
        "u.s", "u.k", "e.g", "i.e", "a.m", "p.m", "ph.d", "b.c", "a.d",
    ]

    /// Whether the dot at `dot` ends a sentence rather than a token.
    ///
    /// - Parameter dot: the index of the dot that is followed by whitespace.
    private func dotEndsSentence(at dot: String.Index) -> Bool {
        let token = buffer[tokenStart(before: dot)..<dot]
        if token.isEmpty { return true }
        // An initial: "J. K. Rowling" is one sentence, not three.
        if token.count == 1, let only = token.first, only.isLetter { return false }
        // An identifier, a path, an address or a version number: the part of
        // the token before any bracket still carries a dot, a slash, a colon or
        // an underscore, and the token has letters in it. A bare number such as
        // "3.14" is a quantity, not an identifier, so it still ends a sentence.
        let head = token.prefix { !"([{<".contains($0) }
        let structural: Set<Character> = [".", ":", "/", "_", "\\", "@", "=", "#", "$", "&", "*", "`"]
        if head.contains(where: { structural.contains($0) }),
           token.contains(where: { $0.isLetter }) {
            return false
        }
        return !Self.abbreviations.contains(token.lowercased())
    }

    /// Where the token before `index` starts.
    private func tokenStart(before index: String.Index) -> String.Index {
        var start = index
        while start > buffer.startIndex {
            let previous = buffer[buffer.index(before: start)]
            if previous.isWhitespace { break }
            start = buffer.index(before: start)
        }
        return start
    }
}

// MARK: - Caps

extension SentenceSegmenter {
    /// The end of a clause once the buffer has grown past the clause limit.
    ///
    /// A comma, a semicolon or a colon followed by a space is a place where
    /// speech can pause without changing the meaning. It is only taken once the
    /// segment is long enough to be worth speaking and short enough to still be
    /// one utterance.
    private func clauseCut() -> String.Index? {
        guard buffer.count > Self.clauseCharacters else { return nil }
        let limit = buffer.index(
            buffer.startIndex,
            offsetBy: Self.maximumSegmentCharacters,
            limitedBy: buffer.endIndex
        ) ?? buffer.endIndex
        var index = buffer.index(
            buffer.startIndex,
            offsetBy: Self.minimumClauseCharacters,
            limitedBy: limit
        ) ?? limit
        while index < limit {
            let character = buffer[index]
            if character == "," || character == ";" || character == ":" {
                let after = buffer.index(after: index)
                if after < buffer.endIndex, buffer[after] == " " {
                    return skipWhitespace(from: after)
                }
            }
            index = buffer.index(after: index)
        }
        return nil
    }

    /// The end of a segment cut at the last safe space, for text with no
    /// punctuation at all.
    private func lengthCut() -> String.Index? {
        guard buffer.count > Self.maximumSegmentCharacters else { return nil }
        let limit = buffer.index(buffer.startIndex, offsetBy: Self.maximumSegmentCharacters)
        var index = limit
        while index > buffer.startIndex {
            if buffer[index].isWhitespace,
               buffer.distance(from: buffer.startIndex, to: index) >= Self.minimumClauseCharacters,
               isSafeBreak(at: index) {
                return skipWhitespace(from: index)
            }
            index = buffer.index(before: index)
        }
        return nil
    }

    /// Whether a whitespace position is not inside a number.
    ///
    /// "3 000" written with a space, or a thousands separator, must not be cut
    /// in half: the number would be spoken as two.
    private func isSafeBreak(at space: String.Index) -> Bool {
        guard space > buffer.startIndex else { return false }
        let before = buffer[buffer.index(before: space)]
        var after = buffer.index(after: space)
        while after < buffer.endIndex, buffer[after].isWhitespace {
            after = buffer.index(after: after)
        }
        guard after < buffer.endIndex else { return false }
        return !(before.isNumber && buffer[after].isNumber)
    }

    /// Steps over closing quotes and brackets after a terminator.
    private func skipClosers(from index: String.Index) -> String.Index {
        var end = index
        while end < buffer.endIndex, Self.closers.contains(buffer[end]) {
            end = buffer.index(after: end)
        }
        return end
    }

    /// Steps over the whitespace after a terminator.
    private func skipWhitespace(from index: String.Index) -> String.Index {
        var end = index
        while end < buffer.endIndex, buffer[end].isWhitespace {
            end = buffer.index(after: end)
        }
        return end
    }
}
