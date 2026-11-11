import AppKit
import DotCore

/// The title of the transcript card: what happened to the words, and where.
///
/// A pasted transcript names the application it was delivered into, in the same
/// letter-spaced caps as the rest of the label. The name is measured here rather
/// than left to the layout: an application is free to call itself anything, and
/// the clock and the buttons have to stay where they are.
enum HUDHeader {
    /// The widest the title may be before it is cut, in points.
    ///
    /// The transcript card is 560 points wide. The header keeps 16 points of
    /// padding on each side, a 20 point badge with a 10 point gap, at least 8
    /// points before the clock, the 28 point clock with its gaps, the divider of
    /// the controls and five 24 point buttons with their gaps. What is left for
    /// the title is 268 points.
    static let maximumTitleWidth: CGFloat = 268

    /// The title of the transcript header.
    ///
    /// A paste names the application it went into. A copy keeps the wording it
    /// has always had: the clipboard is not an application, and naming one would
    /// claim a delivery that did not happen. A name that is missing, empty or
    /// only spaces leaves the plain word.
    ///
    /// - Parameters:
    ///   - delivery: how the words were delivered.
    ///   - destination: the localized name of the application they went into.
    /// - Returns: `"PASTED INTO MAIL"`, `"PASTED"` when there is no name, or the
    ///   delivery's own word for a copy or a failure.
    static func title(delivery: HUDDelivery, destination: String?) -> String {
        let base = delivery.title
        guard delivery == .pasted, let name = normalized(destination) else { return base }
        let prefix = "\(base) INTO "
        guard width(of: prefix) < maximumTitleWidth else { return base }
        return truncated(prefix + name.uppercased(), to: maximumTitleWidth)
    }

    /// What VoiceOver reads for the title.
    ///
    /// The header is drawn in capitals, and a screen reader may spell a short
    /// word that looks like an initialism. The label says it as a sentence
    /// instead, with the application's name as it is written.
    ///
    /// - Parameters:
    ///   - delivery: how the words were delivered.
    ///   - destination: the localized name of the application they went into.
    /// - Returns: `"Pasted into Mail"`, or just the delivery's own word.
    static func accessibilityLabel(delivery: HUDDelivery, destination: String?) -> String {
        let base: String = switch delivery {
        case .copied: "Copied"
        case .pasted: "Pasted"
        case .failed: "Failed"
        }
        guard delivery == .pasted, let name = normalized(destination) else { return base }
        return "\(base) into \(name)"
    }

    /// The width of a title in the header's own type.
    ///
    /// - Parameter text: the title, as it is drawn.
    static func width(of text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: HUDTheme.labelFontSize, weight: .semibold),
            .kern: HUDTheme.labelTracking,
        ]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    }

    /// Cuts a title with an ellipsis, at a word boundary when there is one.
    private static func truncated(_ text: String, to width: CGFloat) -> String {
        guard self.width(of: text) > width else { return text }
        let ellipsis = "…"
        let characters = Array(text)
        var length = characters.count
        while length > 0, self.width(of: String(characters[0 ..< length]) + ellipsis) > width {
            length -= 1
        }
        var cut = String(characters[0 ..< length])
        if length < characters.count, characters[length] != " ",
           let space = cut.lastIndex(of: " ") {
            let candidate = String(cut[..<space])
            if self.width(of: candidate + ellipsis) <= width {
                cut = candidate
            }
        }
        while cut.hasSuffix(" ") {
            cut.removeLast()
        }
        return cut + ellipsis
    }

    /// The name of the application, or `nil` when there is none to show.
    private static func normalized(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension HUDHeader {
    /// The title of the assistant's answer card.
    ///
    /// It keeps the transcript's cap: the answer card is the transcript card's
    /// width, and an application name is as free to be long here as it is there.
    ///
    /// - Parameter state: what became of the answer.
    /// - Returns: `"PASTED INTO MAIL"`, `"COPIED"`, `"SPEAKING"` or `"ANSWER"`.
    static func title(for state: AssistantAnswerState) -> String {
        switch state {
        case .pasted(let name):
            guard let name = normalized(name) else { return "PASTED" }
            return truncated("PASTED INTO " + name.uppercased(), to: maximumTitleWidth)
        case .copied: return "COPIED"
        case .speaking: return "SPEAKING"
        case .streaming, .spoken: return "ANSWER"
        }
    }

    /// What VoiceOver reads for the assistant's header.
    ///
    /// - Parameter state: what became of the answer.
    static func accessibilityLabel(for state: AssistantAnswerState) -> String {
        switch state {
        case .pasted(let name):
            guard let name = normalized(name) else { return "Pasted" }
            return "Pasted into \(name)"
        case .copied: return "Copied"
        case .speaking: return "Speaking"
        case .streaming, .spoken: return "Answer"
        }
    }
}
