import Foundation

extension FaithfulnessCheck {
    /// The digit runs of a text, canonicalised.
    ///
    /// A thousands separator is formatting, not a value: `1,000` and `1000` are
    /// the same number, and a rewrite that writes it the other way has not
    /// changed anything. A decimal point is kept, so `3.5` never matches `35`.
    static func numbers(in text: String) -> [String] {
        let pattern = #"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).replacingOccurrences(of: ",", with: "")
        }
    }

    /// The words of a text, lowercased, apostrophes kept.
    ///
    /// Splitting into words rather than matching regular expressions is what
    /// makes `don't` one word and `isn't` another: a negation is counted as a
    /// word, not as a substring of one.
    static func words(in text: String) -> [String] {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .lowercased()
            .split { character in
                !(character.isLetter || character == "'")
            }
            .map(String.init)
    }

    /// The negations of a text, in order.
    static func negations(in text: String) -> [String] {
        let plain: Set<String> = ["not", "no", "never", "without", "except"]
        return words(in: text).filter { word in
            plain.contains(word) || word.hasSuffix("n't")
        }
    }

    /// The URLs, email addresses and file paths a text carries.
    ///
    /// The three are one list because they are one failure: the model wrote
    /// something concrete the speaker never said, and a rewrite may not do that
    /// even when the added thing looks helpful.
    static func artefacts(in text: String) -> [String] {
        let edge = CharacterSet(charactersIn: "()[]{}<>,.;:!?'\"")
        return text.split(whereSeparator: { $0.isWhitespace }).compactMap { chunk in
            var token = String(chunk)
            while let first = token.first, edge.contains(first.unicodeScalars.first!) {
                token.removeFirst()
            }
            while let last = token.last, edge.contains(last.unicodeScalars.first!) {
                token.removeLast()
            }
            guard !token.isEmpty else { return nil }
            let lower = token.lowercased()
            if lower.contains("://") { return lower }
            if let at = lower.firstIndex(of: "@"), lower[at...].contains(".") { return lower }
            if lower.hasPrefix("~/") || lower.hasPrefix("/") { return lower }
            guard lower.contains("/") else { return nil }
            let lastComponent = lower.split(separator: "/").last.map(String.init) ?? ""
            let parts = lastComponent.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count > 1, parts.first?.isEmpty == false, parts.last?.isEmpty == false else {
                return nil
            }
            return lower
        }
    }

    /// The capitalised words that are not the first word of a sentence.
    ///
    /// A capital at the start of a sentence is grammar, not a name. One letter
    /// is skipped as well: `I` is a pronoun, and the casual style is allowed to
    /// lowercase it.
    static func names(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z'\\-]*") else {
            return []
        }
        let ns = text as NSString
        var found: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range)
            guard word.count >= 2, let first = word.first, first.isUppercase else { continue }
            let prefix = ns.substring(to: match.range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // The first word of the text is sentence-initial too.
            if prefix.isEmpty { continue }
            if let last = prefix.last, ".!?\n".contains(last) { continue }
            found.append(word)
        }
        return found
    }
}
