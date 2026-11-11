import Foundation

/// A model a voice provider can speak with.
public struct VoiceModelOption: Sendable, Equatable, Codable, Identifiable {
    /// The model id the vendor's API takes.
    public let id: String
    /// The name shown in a picker.
    public let name: String
    /// One line about what the model is for.
    public let detail: String
    /// Whether the vendor has announced that this model goes away.
    public let isDeprecated: Bool

    /// Creates a model option.
    public init(id: String, name: String, detail: String, isDeprecated: Bool = false) {
        self.id = id
        self.name = name
        self.detail = detail
        self.isDeprecated = isDeprecated
    }
}

/// A vendor's shutdown notice for the models Dot calls.
///
/// The date is stored as three numbers rather than a `Date` so the value is the
/// same in every time zone and in every locale, which is what a test can assert
/// and what a warning in Settings can count down to.
public struct VoiceDeprecation: Sendable, Equatable {
    /// The shutdown year.
    public let year: Int
    /// The shutdown month, 1 through 12.
    public let month: Int
    /// The shutdown day of the month.
    public let day: Int
    /// What happens and what to migrate to, in the vendor's own terms.
    public let message: String

    /// Creates a shutdown notice.
    public init(year: Int, month: Int, day: Int, message: String) {
        self.year = year
        self.month = month
        self.day = day
        self.message = message
    }

    /// The moment the models stop answering, at midnight UTC.
    public var shutdownDate: Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components) ?? Date.distantFuture
    }

    /// The date as `yyyy-MM-dd`.
    public var isoDate: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Whether the vendor has already switched the models off.
    ///
    /// - Parameter date: the moment to ask about, normally now.
    public func isShutDown(asOf date: Date) -> Bool {
        date >= shutdownDate
    }

    /// Whole days left, ceilinged, so the last day reads `1` and not `0`.
    ///
    /// - Parameter date: the moment to ask about, normally now.
    public func daysRemaining(asOf date: Date) -> Int {
        let seconds = shutdownDate.timeIntervalSince(date)
        guard seconds > 0 else { return 0 }
        return Int((seconds / 86_400).rounded(.up))
    }
}

/// One row of the voice-provider matrix.
///
/// A preset is what Settings shows and what the audio path chooses from. It is
/// a separate list from ``ProviderPreset`` on purpose: a voice provider has
/// models and a shutdown date, a speech provider has segment limits, and adding
/// a voice row must not change which provider dictation selects.
public struct VoiceProviderPreset: Sendable, Equatable, Identifiable {
    /// The vendor id, e.g. `cartesia`.
    public let id: String
    /// The name shown in Settings.
    public let displayName: String
    /// One line about what the row is.
    public let detail: String
    /// Whether the row needs an API key.
    public let requiresCredential: Bool
    /// The models the row offers, best first.
    public let models: [VoiceModelOption]
    /// The model Dot calls when none is chosen.
    public let defaultModel: String?
    /// The voice Dot calls when none is chosen, in the vendor's naming.
    public let defaultVoiceID: String?
    /// The PCM shape the vendor is asked for.
    public let audioFormat: VoiceAudioFormat
    /// How well the wiring is confirmed.
    public let verification: VoiceVerification
    /// The vendor's shutdown notice, when there is one.
    public let deprecation: VoiceDeprecation?
    /// Where the row sits in the recommended order, `1` first.
    public let rank: Int

    /// Creates a preset.
    public init(
        id: String,
        displayName: String,
        detail: String,
        requiresCredential: Bool,
        models: [VoiceModelOption] = [],
        defaultModel: String? = nil,
        defaultVoiceID: String? = nil,
        audioFormat: VoiceAudioFormat = .pcm24k,
        verification: VoiceVerification,
        deprecation: VoiceDeprecation? = nil,
        rank: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.requiresCredential = requiresCredential
        self.models = models
        self.defaultModel = defaultModel
        self.defaultVoiceID = defaultVoiceID
        self.audioFormat = audioFormat
        self.verification = verification
        self.deprecation = deprecation
        self.rank = rank
    }

    /// Whether the vendor has announced that this row's models go away.
    public var isDeprecated: Bool { deprecation != nil }

    /// The warning a picker shows for the row, when there is one.
    ///
    /// - Parameter date: the moment to ask about, normally now.
    public func deprecationWarning(asOf date: Date) -> String? {
        guard let deprecation else { return nil }
        if deprecation.isShutDown(asOf: date) { return deprecation.message }
        let days = deprecation.daysRemaining(asOf: date)
        return "\(deprecation.message) (\(days) days left)"
    }
}
