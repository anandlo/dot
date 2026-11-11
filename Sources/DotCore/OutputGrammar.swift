import Foundation

/// The deterministic rewrite a transcript gets on its way into an app.
///
/// There is no model and no network here: every rule is a statement about text
/// that can be stated once, applied to any input, and tested. The rules are
/// deliberately few and non-destructive. Dot does not rephrase, summarise or
/// re-punctuate what a person said; it removes the things a dictation adds that
/// the surface does not want — a double space, a full stop at the end of a code
/// line, a paragraph break in a commit subject.
public enum OutputGrammar {
    /// The dials of the rewrite.
    public struct Options: Sendable, Equatable {
        /// The length past which a commit subject is considered long.
        ///
        /// Git's own convention is 72 characters. Past it the text is
        /// *reported*, never shortened: cutting a person's words is not a
        /// rewrite.
        public var commitSubjectLimit: Int

        /// Creates options.
        public init(commitSubjectLimit: Int = 72) {
            self.commitSubjectLimit = commitSubjectLimit
        }

        /// The shipped options.
        public static let `default` = Options()
    }

    /// What the rewrite produced.
    public struct Result: Equatable, Sendable {
        /// The text to insert.
        public let text: String
        /// The surface it was written for.
        public let target: DictationTarget
        /// Whether a commit subject is longer than the limit.
        ///
        /// The text is complete either way; the flag exists so the card can say
        /// the subject is long instead of silently cutting it.
        public let wasLong: Bool

        /// Creates a result.
        public init(text: String, target: DictationTarget, wasLong: Bool) {
            self.text = text
            self.target = target
            self.wasLong = wasLong
        }
    }

    /// The rewrite for one target.
    ///
    /// - Parameters:
    ///   - text: the transcript, as the provider returned it.
    ///   - target: the surface the text is going into.
    ///   - options: the dials; the defaults are the shipped ones.
    /// - Returns: the text to insert, and whether it was flagged as long.
    public static func result(
        for text: String,
        target: DictationTarget,
        options: Options = .default
    ) -> Result {
        let normalized = normalize(text, target: target)
        var output: String
        var wasLong = false
        switch target {
        case .plain:
            output = normalized
        case .chat:
            output = normalized
            if isSingleSentence(output) {
                output = stripTrailingPeriod(output)
            }
        case .code:
            output = stripTrailingPeriod(singleLine(normalized))
        case .commit:
            let subject = stripTrailingPeriod(singleLine(normalized))
            wasLong = subject.count > max(1, options.commitSubjectLimit)
            // The subject is returned whole. A long one is reported, not cut.
            output = subject
        case .document:
            output = ensureTerminalPunctuation(sentenceCased(normalized))
        }
        return Result(text: output, target: target, wasLong: wasLong)
    }

    /// The rewrite for one target, as plain text.
    ///
    /// - Parameters:
    ///   - text: the transcript.
    ///   - target: the surface the text is going into.
    ///   - options: the dials.
    /// - Returns: the text to insert.
    public static func apply(
        _ text: String,
        target: DictationTarget,
        options: Options = .default
    ) -> String {
        result(for: text, target: target, options: options).text
    }

    // MARK: - Rules

    /// Collapses the whitespace a dictation adds and trims the ends.
    ///
    /// Every target gets this. A line-based target keeps its line breaks and a
    /// one-line target loses them; inside a line, a run of spaces becomes one,
    /// because no provider and no keyboard produces two on purpose.
    ///
    /// - Parameters:
    ///   - text: the transcript.
    ///   - target: whether the surface keeps line breaks.
    /// - Returns: the normalised text.
    public static func normalize(_ text: String, target: DictationTarget) -> String {
        switch target {
        case .code, .commit:
            return stripStraySpaceBeforePunctuation(singleLine(text))
        case .plain, .chat, .document:
            let lines = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    let collapsed = line.split(
                        omittingEmptySubsequences: true,
                        whereSeparator: { $0 == " " || $0 == "\t" }
                    ).joined(separator: " ")
                    return collapsed
                }
            // Three or more blank lines are two paragraph breaks, whatever the
            // person's hand did; the ends of the whole text are trimmed.
            var blocks: [String] = []
            var blankRun = 0
            for line in lines {
                if line.isEmpty {
                    blankRun += 1
                    if blankRun == 1 { blocks.append("") }
                } else {
                    blankRun = 0
                    blocks.append(line)
                }
            }
            while blocks.first?.isEmpty == true { blocks.removeFirst() }
            while blocks.last?.isEmpty == true { blocks.removeLast() }
            return stripStraySpaceBeforePunctuation(blocks.joined(separator: "\n"))
        }
    }

    /// Collapses every run of whitespace, newlines included, to one space.
    public static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Removes a space that sits directly before a mark of punctuation.
    ///
    /// A dictation hears "hello , world" when the person pauses; no surface
    /// wants the space.
    public static func stripStraySpaceBeforePunctuation(_ text: String) -> String {
        // Only sentence punctuation: a space before a closing bracket is
        // ordinary code formatting, and stripping it would rewrite a brace.
        let marks: Set<Character> = [",", ".", "!", "?", ";", ":", "…"]
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            if marks.contains(character), output.last == " " {
                output.removeLast()
            }
            output.append(character)
        }
        return output
    }

    /// Removes one full stop at the end of the text.
    ///
    /// Only a single one: an ellipsis is a decision the person made, not a
    /// sentence ending a surface wants gone.
    public static func stripTrailingPeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix("..") else { return trimmed }
        return String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the text holds one sentence.
    ///
    /// A mark of punctuation inside the text means the person said more than
    /// one, and the last full stop is then part of what they said.
    public static func isSingleSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let body = trimmed.dropLast()
        let marks: Set<Character> = [".", "!", "?", "…"]
        return !body.contains { marks.contains($0) }
    }

    /// Capitalises the first letter of each paragraph.
    ///
    /// Paragraphs are preserved, so each one is treated as the start of a
    /// sentence: a transcribed paragraph otherwise begins in the middle of a
    /// thought, in lower case.
    public static func sentenceCased(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var characters = Array(String(line))
                guard let index = characters.firstIndex(where: \.isLetter) else {
                    return String(characters)
                }
                let upper = String(characters[index]).uppercased()
                characters.replaceSubrange(index...index, with: Array(upper))
                return String(characters)
            }
            .joined(separator: "\n")
    }

    /// Ends the text in a full stop when it does not already end in punctuation.
    ///
    /// A closing quote or bracket stays closed: the full stop goes after it,
    /// which is where English puts it.
    public static func ensureTerminalPunctuation(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        // A colon ends a lead-in, and "Note:." is worse than "Note:". Every
        // other mark that ends a sentence counts as already finished.
        let terminal: Set<Character> = [".", "!", "?", "…", ":", "。", "！", "？"]
        guard let last = trimmed.last else { return trimmed }
        if terminal.contains(last) { return trimmed }
        return trimmed + "."
    }
}

/// What one delivery puts at the cursor, and what stays on the clipboard.
///
/// The two are deliberately different values: the grammar is allowed to change
/// what is inserted and is never allowed to change what is kept. Splitting them
/// here makes that a property of a value that can be tested, instead of a rule
/// the delivery code has to remember.
public struct TranscriptDelivery: Equatable, Sendable {
    /// The text posted into the frontmost application.
    public let insertion: String
    /// The text that ends up on the clipboard and in the history.
    public let clipboard: String

    /// Plans one delivery.
    ///
    /// - Parameters:
    ///   - transcript: the transcript the provider returned, which is what the
    ///     history and the clipboard keep.
    ///   - grammar: the rewrite to insert, or `nil` when the rewrite is off. A
    ///     missing value inserts the transcript unchanged.
    public static func plan(transcript: String, grammar: OutputGrammar.Result?) -> TranscriptDelivery {
        TranscriptDelivery(
            insertion: grammar?.text ?? transcript,
            clipboard: transcript
        )
    }
}
