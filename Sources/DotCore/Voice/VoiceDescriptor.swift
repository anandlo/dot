import Foundation

/// One voice a provider can speak with.
///
/// The catalogue is what makes a vendor's voice list usable: an id such as
/// `aura-2-thalia-en` says nothing, while its name, language and quality do.
/// Providers that publish adjectives for their voices put them in ``detail``,
/// so a person can choose "warm and calm" instead of an opaque string.
public struct VoiceDescriptor: Sendable, Equatable, Codable, Identifiable {
    /// How good the voice is, as far as the provider says and the platform
    /// exposes.
    ///
    /// The order is the order the catalogue is offered in: a premium voice
    /// first, then the person's own Personal Voice, then the enhanced tier, then
    /// the default one. It is the product rule that a better voice is never
    /// buried under a worse one.
    public enum QualityTier: String, Sendable, Codable, CaseIterable, Comparable {
        /// A voice Dot could not classify.
        case unknown
        /// The provider's baseline voice.
        case standard
        /// A downloaded or higher-fidelity voice.
        case enhanced
        /// The person's own Personal Voice, trained on their speech.
        case personal
        /// The best tier the provider offers.
        case premium

        /// Where the tier sits in the catalogue order.
        public var rank: Int {
            switch self {
            case .unknown: 0
            case .standard: 1
            case .enhanced: 2
            case .personal: 3
            case .premium: 4
            }
        }

        /// Sorts the better tier first.
        public static func < (lhs: QualityTier, rhs: QualityTier) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    /// The vendor the voice belongs to.
    public let providerID: String
    /// The voice's id in the vendor's own naming.
    public let id: String
    /// The name a person reads, e.g. "Thalia".
    public let name: String
    /// The language as the vendor states it, e.g. `en-US` or `en`.
    public let language: String
    /// How good the voice is.
    public let quality: QualityTier
    /// A short description: the vendor's adjectives, the model's tier, or the
    /// accent.
    public let detail: String?

    /// Creates a voice entry.
    public init(
        providerID: String,
        id: String,
        name: String,
        language: String,
        quality: QualityTier = .standard,
        detail: String? = nil
    ) {
        self.providerID = providerID
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
        self.detail = detail
    }
}

/// The rules a catalogue is offered by.
///
/// They live here rather than in a view so the ordering is testable: "premium
/// and enhanced voices first" is a promise the product makes, not a detail of
/// one picker.
public enum VoiceCatalogue {
    /// Filters and orders a provider's voices.
    ///
    /// - Parameters:
    ///   - voices: the provider's catalogue, in any order.
    ///   - language: a BCP-47 prefix to keep, e.g. `en`; `nil` keeps everything.
    ///   - floor: the lowest quality tier to keep; `nil` keeps every tier.
    ///   - locale: the person's language, whose exact matches sort first among
    ///     voices of the same quality.
    /// - Returns: the voices worth showing, best first.
    public static func select(
        _ voices: [VoiceDescriptor],
        language: String? = nil,
        floor: VoiceSettings.QualityFloor? = nil,
        locale: String? = nil
    ) -> [VoiceDescriptor] {
        let wantedLanguage = normalizedLanguage(language)
        let wantedLocale = normalizedLanguage(locale)
        return voices
            .filter { voice in
                guard !wantedLanguage.isEmpty else { return true }
                let tag = normalizedLanguage(voice.language)
                // A voice the vendor calls multilingual speaks the language
                // Dot is filtering for, so hiding it would lose the best rows.
                return tag == "multi" || tag.hasPrefix(wantedLanguage)
            }
            .filter { voice in
                guard let floor else { return true }
                return voice.quality.rank >= minimumRank(of: floor)
            }
            .sorted { lhs, rhs in
                if lhs.quality.rank != rhs.quality.rank {
                    return lhs.quality.rank > rhs.quality.rank
                }
                let leftMatchesLocale = !wantedLocale.isEmpty
                    && normalizedLanguage(lhs.language) == wantedLocale
                let rightMatchesLocale = !wantedLocale.isEmpty
                    && normalizedLanguage(rhs.language) == wantedLocale
                if leftMatchesLocale != rightMatchesLocale { return leftMatchesLocale }
                if lhs.language != rhs.language { return lhs.language < rhs.language }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// The rank a quality floor requires.
    ///
    /// - Parameter floor: the floor.
    /// - Returns: the smallest accepted ``VoiceDescriptor/QualityTier/rank``.
    public static func minimumRank(of floor: VoiceSettings.QualityFloor) -> Int {
        switch floor {
        case .standard: VoiceDescriptor.QualityTier.standard.rank
        case .enhanced: VoiceDescriptor.QualityTier.enhanced.rank
        case .premium: VoiceDescriptor.QualityTier.premium.rank
        }
    }

    /// A language tag reduced to the form two tags are compared in.
    ///
    /// - Parameter language: `en-US`, `en_US`, `EN` or `nil`.
    /// - Returns: a lowercase tag with a dash separator, or an empty string.
    public static func normalizedLanguage(_ language: String?) -> String {
        let trimmed = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
