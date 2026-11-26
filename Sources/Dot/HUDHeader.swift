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
            .font: DotType.nsFont(HUDTheme.labelFontSize, .semibold),
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

    /// The title of a transcript card that carries a rewrite.
    ///
    /// The header names what is on the card, not what happened to the take. An
    /// original version keeps the delivery title it has always had until an
    /// explicit Copy or Paste names its own outcome. A generated version says
    /// `PREVIEW` until it has been explicitly delivered; Copy and Paste report
    /// their own outcome, and a stream or a refused draft reports its state. A
    /// delivery recorded for another version never describes the version on
    /// screen, and a paste names only the field it actually wrote into.
    ///
    /// - Parameters:
    ///   - card: the rewrite layer.
    ///   - delivery: how the transcript was delivered.
    ///   - destination: the application the transcript went into.
    /// - Returns: `"PREVIEW"`, `"REWRITING"`, `"REVIEW"`, `"COPIED"`,
    ///   `"PASTED"`, `"PASTED INTO <app>"`, `"REWRITTEN"`,
    ///   `"REWRITTEN INTO <app>"`, or the original delivery title.
    static func title(
        for card: RewriteCard,
        delivery: HUDDelivery,
        destination: String?
    ) -> String {
        switch card.phase {
        case .rewriting:
            return "REWRITING"
        case .failed:
            // The card's own failure, named rather than left as a version
            // preview: the selected words are still there and still deliverable,
            // but the request that was meant to add to them did not finish.
            return "REWRITE FAILED"
        case .blocked:
            return "REVIEW"
        case .applied(let versionID):
            guard card.selectedVersionID == versionID else {
                return fallbackTitle(card, delivery: delivery, destination: destination)
            }
            return pastedTitle(
                original: card.selectedVersion.isOriginal,
                target: card.deliveryDestination
            )
        case .copied(let versionID):
            guard card.selectedVersionID == versionID else {
                return fallbackTitle(card, delivery: delivery, destination: destination)
            }
            return "COPIED"
        case .offered:
            return fallbackTitle(card, delivery: delivery, destination: destination)
        }
    }

    /// What VoiceOver reads for a rewritten header.
    ///
    /// It follows the same rule as ``title(for:delivery:destination:)`` in
    /// sentence case, so the screen reader never announces a delivery for a
    /// version that was only selected.
    static func accessibilityLabel(
        for card: RewriteCard,
        delivery: HUDDelivery,
        destination: String?
    ) -> String {
        switch card.phase {
        case .rewriting:
            return "Rewriting"
        case .failed:
            return "Rewrite failed"
        case .blocked:
            return "Review"
        case .applied(let versionID):
            guard card.selectedVersionID == versionID else {
                return fallbackAccessibilityLabel(card, delivery: delivery, destination: destination)
            }
            return pasteAccessibilityLabel(
                original: card.selectedVersion.isOriginal,
                target: card.deliveryDestination
            )
        case .copied(let versionID):
            guard card.selectedVersionID == versionID else {
                return fallbackAccessibilityLabel(card, delivery: delivery, destination: destination)
            }
            return "Copied"
        case .offered:
            return fallbackAccessibilityLabel(card, delivery: delivery, destination: destination)
        }
    }

    /// The title of a version that has no delivery of its own.
    private static func fallbackTitle(
        _ card: RewriteCard,
        delivery: HUDDelivery,
        destination: String?
    ) -> String {
        if card.selectedVersion.isOriginal {
            return title(delivery: delivery, destination: destination)
        }
        return "PREVIEW"
    }

    /// The accessibility label of a version that has no delivery of its own.
    private static func fallbackAccessibilityLabel(
        _ card: RewriteCard,
        delivery: HUDDelivery,
        destination: String?
    ) -> String {
        if card.selectedVersion.isOriginal {
            return accessibilityLabel(delivery: delivery, destination: destination)
        }
        return "Preview"
    }

    /// The title of a version that an explicit paste wrote at the cursor.
    ///
    /// Only the target recorded by that write is named. The take's original
    /// destination is deliberately ignored: an explicit paste may have gone to
    /// another application, and naming the old one would be a false report.
    /// When no target could be resolved, the neutral word is the honest one.
    private static func pastedTitle(original: Bool, target: String?) -> String {
        let base = original ? "PASTED" : "REWRITTEN"
        guard let name = normalized(target) else { return base }
        let prefix = base + (original ? " INTO " : " IN ")
        guard width(of: prefix) < maximumTitleWidth else { return base }
        return truncated(prefix + name.uppercased(), to: maximumTitleWidth)
    }

    /// What VoiceOver reads for a version written at the cursor.
    private static func pasteAccessibilityLabel(original: Bool, target: String?) -> String {
        let base = original ? "Pasted" : "Rewritten"
        guard let name = normalized(target) else { return base }
        return "\(base) into \(name)"
    }

    /// The name of the application, or `nil` when there is none to show.
    private static func normalized(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
