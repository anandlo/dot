import Foundation

/// The styles a person chose, and whether the card offers them after dictation.
///
/// It is one block of the assistant's configuration. Every field decodes the
/// tolerant way the rest of the file does: a bad value resets only its own
/// field, and a style id this build does not know is dropped rather than being
/// fatal.
public struct RewriteConfiguration: Codable, Sendable, Equatable {
    /// Whether the card offers the chips at all.
    public var enabled: Bool
    /// The built-in styles that are offered, in the order the person kept them.
    public var styles: [RewriteStyleID]
    /// The styles the person wrote.
    public var custom: [CustomRewriteStyle]

    /// A fresh configuration: every built-in style, no custom ones.
    public static let `default` = RewriteConfiguration()

    public init(
        enabled: Bool = true,
        styles: [RewriteStyleID] = RewriteStyleID.allCases,
        custom: [CustomRewriteStyle] = []
    ) {
        self.enabled = enabled
        self.styles = styles
        self.custom = custom
    }

    /// The styles the chips show: the built-ins first, then the custom ones.
    ///
    /// A custom style without a name or an instruction is not a style that can
    /// be run, so it is not offered.
    public var choices: [RewriteStyle] {
        styles.map(RewriteStyle.init) + custom.filter(\.isUsable).map(RewriteStyle.init)
    }

    /// The style under an id, when it is offered.
    public func style(for id: String) -> RewriteStyle? {
        choices.first { $0.id == id }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case styles
        case custom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = RewriteConfiguration.default
        enabled = ((try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil)
            ?? fallback.enabled
        // A style id this build does not know is dropped: a file written by a
        // newer build still opens, and the styles it kept still run. The array
        // is read as text first for exactly that reason: decoding it as ids
        // would throw on the one id it does not know and lose the rest.
        if let stored = ((try? container.decodeIfPresent([String].self, forKey: .styles)) ?? nil) {
            var seen = Set<RewriteStyleID>()
            styles = stored
                .compactMap(RewriteStyleID.init(rawValue:))
                .filter { seen.insert($0).inserted }
        } else {
            styles = fallback.styles
        }
        let storedCustom = ((try? container.decodeIfPresent([CustomRewriteStyle].self, forKey: .custom)) ?? nil)
            ?? []
        custom = Array(storedCustom.map(\.sanitized).prefix(CustomRewriteStyle.maximumCount))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(styles, forKey: .styles)
        if !custom.isEmpty {
            try container.encode(custom, forKey: .custom)
        }
    }
}

/// Whether a finished take gets the chips.
///
/// The rule is one function so the card, the paste path that captures the
/// anchor and Settings cannot disagree about when a rewrite is offered. None of
/// it touches the Accessibility API: an ineligible take never captures an
/// anchor, which is what keeps an install without a chat service identical to
/// the build before this feature.
public enum RewriteOffer {
    /// The most characters a take may have and still be offered.
    public static let maximumInputCharacters = RewritePrompt.maximumInputCharacters
    /// The shortest take that is worth rewriting.
    public static let minimumInputCharacters = 1

    /// Whether an assistant service can answer right now.
    ///
    /// A service on this Mac asks for no key, so it is usable without one.
    public static func serviceIsUsable(providerID: String, hasKey: Bool) -> Bool {
        let row = AssistantProviderCatalogue.row(for: providerID)
        return !row.requiresKey || hasKey
    }

    /// Whether the card should carry the chip row.
    ///
    /// - Parameters:
    ///   - rewrite: the person's rewrite settings.
    ///   - providerID: the assistant's catalogue id.
    ///   - hasKey: whether a key is stored for it.
    ///   - text: the transcript.
    ///   - delivery: how the words were delivered. A failed take is not
    ///     rewritten, and a copy is still offered: its rewrite goes to the
    ///     clipboard.
    public static func shouldOffer(
        rewrite: RewriteConfiguration,
        providerID: String,
        hasKey: Bool,
        text: String,
        delivery: HUDDelivery
    ) -> Bool {
        guard rewrite.enabled, !rewrite.choices.isEmpty else { return false }
        guard delivery != .failed else { return false }
        guard serviceIsUsable(providerID: providerID, hasKey: hasKey) else { return false }
        let length = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        return (minimumInputCharacters ... maximumInputCharacters).contains(length)
    }
}
