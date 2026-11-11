import Foundation

/// What a faithfulness check found.
///
/// An error blocks the automatic apply and the card asks before replacing the
/// text; a warning is shown but the rewrite is applied. That split is the whole
/// point of the check: a dropped number is a wrong dictation, a missing capital
/// letter is not.
public struct FaithfulnessReport: Equatable, Sendable {
    /// What changed and must not be applied without asking.
    public var errors: [String]
    /// What may have changed and is only reported.
    public var warnings: [String]

    public init(errors: [String] = [], warnings: [String] = []) {
        self.errors = errors
        self.warnings = warnings
    }

    /// Whether nothing at all was found.
    public var isFaithful: Bool { errors.isEmpty && warnings.isEmpty }

    /// Whether the rewrite has to be confirmed before it is applied.
    public var blocksApply: Bool { !errors.isEmpty }

    public var firstError: String? { errors.first }
    public var firstWarning: String? { warnings.first }
}

/// Checks that a rewrite still says what the transcript said.
///
/// The check is deliberately narrow and mechanical. Each rule here is one way a
/// rewrite can be wrong that a person cannot see by skimming the card: a number
/// that changed, a negation that vanished, something that was not said, a name
/// that moved, and a length that is no longer a rewrite of the same words.
public enum FaithfulnessCheck {
    /// A number of the transcript did not survive.
    public static let numberChanged = "A number changed"
    /// A negation of the transcript did not survive.
    public static let negationDropped = "A negation was dropped"
    /// The rewrite carries a URL, an address or a path the transcript did not.
    public static let somethingAdded = "Something was added"
    /// A name of the transcript is not in the rewrite.
    public static let nameChanged = "A name may have changed"
    /// The rewrite is much shorter or much longer than its style allows.
    public static let lengthChanged = "Length changed a lot"

    /// Runs every rule.
    ///
    /// - Parameters:
    ///   - original: the transcript.
    ///   - rewrite: what the model produced.
    ///   - style: the style that was asked for, which decides the allowed
    ///     length and whether names are checked.
    public static func check(
        original: String,
        rewrite: String,
        style: RewriteStyle
    ) -> FaithfulnessReport {
        var errors: [String] = []
        var warnings: [String] = []

        let originalNumbers = numbers(in: original)
        let rewriteNumbers = Set(numbers(in: rewrite))
        let rewriteWords = Set(words(in: rewrite))
        let missingNumbers = originalNumbers.filter { number in
            if rewriteNumbers.contains(number) { return false }
            guard let value = Int(number), (0 ... 20).contains(value) else { return true }
            return !rewriteWords.contains(spelled(value))
        }
        if !missingNumbers.isEmpty { errors.append(numberChanged) }

        if negations(in: rewrite).count < negations(in: original).count {
            errors.append(negationDropped)
        }

        let originalArtefacts = Set(artefacts(in: original))
        let added = artefacts(in: rewrite).filter { !originalArtefacts.contains($0) }
        if !added.isEmpty { errors.append(somethingAdded) }

        if style.checksNames {
            let missing = names(in: original).filter { !rewriteWords.contains($0.lowercased()) }
            if !missing.isEmpty { warnings.append(nameChanged) }
        }

        if !original.isEmpty {
            let ratio = Double(rewrite.count) / Double(original.count)
            if !style.lengthRatio.contains(ratio) { warnings.append(lengthChanged) }
        }

        return FaithfulnessReport(errors: errors, warnings: warnings)
    }

    /// The English words the check accepts for a digit, zero through twenty.
    static func spelled(_ value: Int) -> String {
        let words = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
            "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
            "seventeen", "eighteen", "nineteen", "twenty",
        ]
        guard (0 ..< words.count).contains(value) else { return String(value) }
        return words[value]
    }
}
