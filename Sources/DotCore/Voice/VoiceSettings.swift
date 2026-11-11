import Foundation

/// The voice Dot speaks an answer with.
///
/// It is a separate value from ``ProviderConfig`` on purpose. A speech-provider
/// record describes an endpoint and a decrypting key read; a voice setting
/// describes a *choice*: which vendor, which voice, which model, how fast. The
/// assistant keeps one of these and can change it without touching the
/// dictation configuration, and one vendor key serves both directions.
///
/// Decoding is tolerant in the same way the configuration file is. A settings
/// file written by a newer build, or one holding a voice quality tier this
/// build does not know, must not reset the person's voice; a key that cannot be
/// decoded falls back to its default instead.
public struct VoiceSettings: Sendable, Equatable, Codable {
    /// The lowest voice quality a catalogue entry may have.
    ///
    /// It only applies to providers whose voices are installed on the machine,
    /// where a premium voice is a download away and the default one is the voice
    /// people recognise as the system's.
    public enum QualityFloor: String, Sendable, Codable, CaseIterable {
        /// Every installed voice.
        case standard
        /// Enhanced or better.
        case enhanced
        /// Premium or better.
        case premium
    }

    /// The vendor, e.g. `elevenlabs`.
    public var providerID: String
    /// The voice, in the vendor's own naming. `nil` means the provider's
    /// default, which is the first entry of its catalogue when it has one.
    public var voiceID: String?
    /// A multiplier on the vendor's normal rate. `1` is the vendor's default.
    public var speed: Double
    /// The model, in the vendor's own naming. `nil` means the provider's
    /// default model.
    public var model: String?
    /// The lowest catalogue quality to offer, when the provider has tiers.
    public var qualityFloor: QualityFloor?
    /// Free-text style direction, sent where the vendor has a field for it.
    public var instructions: String?

    /// The speed a person gets when nothing is chosen.
    public static let defaultSpeed = 1.0
    /// The widest multiplier Dot stores. Each provider narrows it again to its
    /// own accepted range before the value reaches a request.
    public static let speedRange = 0.5...2.0

    /// Creates a voice setting.
    public init(
        providerID: String,
        voiceID: String? = nil,
        speed: Double = VoiceSettings.defaultSpeed,
        model: String? = nil,
        qualityFloor: QualityFloor? = nil,
        instructions: String? = nil
    ) {
        self.providerID = providerID
        self.voiceID = voiceID
        self.speed = speed
        self.model = model
        self.qualityFloor = qualityFloor
        self.instructions = instructions
    }

    /// Reads a setting, keeping every field that can be read.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = (try? container.decodeIfPresent(String.self, forKey: .providerID)) ?? ""
        voiceID = (try? container.decodeIfPresent(String.self, forKey: .voiceID)) ?? nil
        speed = (try? container.decodeIfPresent(Double.self, forKey: .speed)) ?? Self.defaultSpeed
        model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? nil
        // The enum rule: an unknown tier is "no floor", not a decode failure
        // that would reset the rest of the setting.
        qualityFloor = (try? container.decodeIfPresent(QualityFloor.self, forKey: .qualityFloor)) ?? nil
        instructions = (try? container.decodeIfPresent(String.self, forKey: .instructions)) ?? nil
    }

    /// The speed as a number a request can use.
    ///
    /// A hand-edited file can hold zero, a negative number or a NaN; none of
    /// those is a rate. What it cannot hold is a value outside the stored range,
    /// which is clamped rather than rejected.
    public var effectiveSpeed: Double {
        guard speed.isFinite, speed > 0 else { return Self.defaultSpeed }
        return min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
    }

    /// The speed narrowed to what one provider accepts.
    ///
    /// - Parameter range: the vendor's accepted multiplier range.
    /// - Returns: the effective speed, clamped into `range`.
    public func speed(within range: ClosedRange<Double>) -> Double {
        min(max(effectiveSpeed, range.lowerBound), range.upperBound)
    }

    /// The voice id, or the provider's default.
    ///
    /// - Parameter fallback: the id the provider ships when none is chosen.
    public func resolvedVoiceID(fallback: String?) -> String? {
        if let voiceID, !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return voiceID
        }
        return fallback
    }

    /// The model, or the provider's default.
    ///
    /// - Parameter fallback: the model the provider ships when none is chosen.
    public func resolvedModel(fallback: String) -> String {
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return model
        }
        return fallback
    }

    /// Whether the setting names a provider at all.
    public var isConfigured: Bool {
        !providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
