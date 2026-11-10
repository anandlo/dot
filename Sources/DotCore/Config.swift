import Foundation

/// What the HUD's card is made of.
public enum HUDMaterial: String, Codable, Sendable, CaseIterable {
    /// Liquid Glass, the modern system material. The default where it exists.
    case glass
    /// The black analytic rounded rectangle. The fallback everywhere else, and
    /// an explicit choice everywhere.
    case black
}

/// How the windows follow the system appearance.
public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
    /// Follow the Mac's current appearance.
    case system
    /// Always use the warm paper palette.
    case light
    /// Always use the deep ink palette.
    case dark
}

/// The visual effect style of incoming audio on the HUD island.
public enum HUDVisualizer: String, Codable, Sendable, CaseIterable {
    /// Resting dots that stretch into organic capsules on springs.
    case stretch
    /// Discrete precision capsule bars scrolling in phase.
    case filament
    /// Multi-frequency harmonic braided ribbons.
    case silk
    /// Real-time dot-matrix spectrogram.
    case matrix
    /// Perimeter conic glow with clear interior for text.
    case haloEdge = "halo-edge"

    /// The human-readable name of the visualizer.
    public var title: String {
        switch self {
        case .stretch: "Stretch"
        case .filament: "Filament"
        case .silk: "Silk"
        case .matrix: "Matrix"
        case .haloEdge: "Halo Edge"
        }
    }

    /// The short summary of what the visualizer looks like.
    public var detail: String {
        switch self {
        case .stretch: "Resting dots that stretch into capsules on springs under speech."
        case .filament: "Discrete precision capsule bars scrolling with sub-pixel phase."
        case .silk: "Braided multi-frequency harmonic ribbons that breathe with voice."
        case .matrix: "Scrolling dot-matrix spectrogram with warm amber hotspots."
        case .haloEdge: "Conic aura circulating the island edge, leaving the center clear."
        }
    }
}

/// How a service expects its key on a request.
///
/// The two spellings cover the OpenAI-compatible services Dot can reach: most
/// document `Authorization: Bearer`, some document a bare `api-key` header. The
/// choice belongs to the endpoint, so it is a setting and not a provider type.
public enum AuthStyle: String, Codable, Sendable, CaseIterable {
    /// `Authorization: Bearer <key>`, what most services document.
    case bearer
    /// `api-key: <key>`, what some services document instead.
    case apiKey = "api-key"

    /// The header the key travels in.
    public var header: String {
        switch self {
        case .bearer: "Authorization"
        case .apiKey: "api-key"
        }
    }

    /// The header value that carries a key.
    ///
    /// - Parameter key: the secret. It is written into one header and nowhere
    ///   else.
    public func value(for key: String) -> String {
        switch self {
        case .bearer: "Bearer \(key)"
        case .apiKey: key
        }
    }
}

/// The settings of one provider.
///
/// Every provider gets the same shape, so switching provider never changes
/// the shape of the configuration file.
public struct ProviderConfig: Codable, Sendable, Equatable {
    /// The model id to ask for. `nil` lets the provider use its own default.
    public var model: String?
    /// The base URL of an OpenAI-compatible service, e.g.
    /// `https://api.openai.com/v1`. Only the OpenAI-compatible provider uses
    /// it.
    public var baseURL: String?
    /// The language hint sent with the audio. `nil` lets the provider decide.
    public var language: String?
    /// How the service expects its key. `nil` means the documented default,
    /// ``AuthStyle/bearer``.
    public var authStyle: AuthStyle?
    /// Optional Deepgram smart formatting (`smart_format=true` by default).
    public var smartFormat: Bool?
    /// Optional Deepgram punctuation & capitalization (`punctuate=true` by default).
    public var punctuate: Bool?
    /// Optional Deepgram paragraph splitting (`paragraphs`).
    public var paragraphs: Bool?
    /// Optional Deepgram filler word retention (`filler_words`: uh, um).
    public var fillerWords: Bool?
    /// Optional Deepgram profanity filter (`profanity_filter`).
    public var profanityFilter: Bool?
    /// Optional Deepgram spoken-number-to-digits conversion (`numerals`).
    public var numerals: Bool?
    /// Optional Deepgram speaker diarization (`diarize`).
    public var diarize: Bool?
    /// Optional comma-separated Deepgram/ElevenLabs keyterms or keywords (`keyterm`/`keywords`/`keyterms`).
    public var keyterms: String?
    /// Optional ElevenLabs non-speech sound event tagging (`tag_audio_events`).
    public var tagAudioEvents: Bool?
    /// Optional ElevenLabs filler/false-start filtering (`no_verbatim`).
    public var noVerbatim: Bool?
    /// Optional ElevenLabs maximum number of speakers (`num_speakers`, 1...32).
    public var numSpeakers: Int?
    /// Optional ElevenLabs automatic agent/customer speaker role detection (`detect_speaker_roles`).
    public var detectSpeakerRoles: Bool?
    /// Optional ElevenLabs workspace speaker library matching (`use_speaker_library`).
    public var useSpeakerLibrary: Bool?
    /// Optional ElevenLabs timestamp precision (`timestamps_granularity`: `"word"`, `"character"`, `"none"`).
    public var timestampsGranularity: String?
    /// Optional ElevenLabs entity detection (`entity_detection`: `"all"`, `"pii"`, `"phi"`, `"pci"`, `"offensive_language"`).
    public var entityDetection: String?
    /// Optional ElevenLabs natural-language post-edit prompt (`transcript_edit`).
    public var transcriptEdit: String?
    /// Optional Azure region, e.g. "eastus", "westus", "westeurope".
    public var azureRegion: String?
    /// Optional Azure recognition mode: "conversation", "dictation", "interactive".
    public var azureRecognitionMode: String?
    /// Optional Azure profanity filter mode: "masked", "removed", "raw".
    public var azureProfanityFilter: String?
    /// Optional Azure output format: "detailed", "simple".
    public var azureOutputFormat: String?
    /// Optional Azure server-side audio storage (`storeAudio=true/false`).
    public var azureStoreAudio: Bool?
    /// Zero data retention (ZDR): opt out of server-side data retention, model training, or logging.
    public var zeroDataRetention: Bool?
    /// Optional temperature (e.g. 0.0 to 1.0 for Groq/OpenAI).
    public var temperature: Double?
    /// Optional context / prompt hint for transcription style or vocabulary.
    public var prompt: String?
    /// Optional response format, e.g. "json", "verbose_json", "text".
    public var responseFormat: String?

    /// Creates the settings of one provider.
    public init(
        model: String? = nil,
        baseURL: String? = nil,
        language: String? = nil,
        authStyle: AuthStyle? = nil,
        smartFormat: Bool? = nil,
        punctuate: Bool? = nil,
        paragraphs: Bool? = nil,
        fillerWords: Bool? = nil,
        profanityFilter: Bool? = nil,
        numerals: Bool? = nil,
        diarize: Bool? = nil,
        keyterms: String? = nil,
        tagAudioEvents: Bool? = nil,
        noVerbatim: Bool? = nil,
        numSpeakers: Int? = nil,
        detectSpeakerRoles: Bool? = nil,
        useSpeakerLibrary: Bool? = nil,
        timestampsGranularity: String? = nil,
        entityDetection: String? = nil,
        transcriptEdit: String? = nil,
        azureRegion: String? = nil,
        azureRecognitionMode: String? = nil,
        azureProfanityFilter: String? = nil,
        azureOutputFormat: String? = nil,
        azureStoreAudio: Bool? = nil,
        zeroDataRetention: Bool? = nil,
        temperature: Double? = nil,
        prompt: String? = nil,
        responseFormat: String? = nil
    ) {
        self.model = model
        self.baseURL = baseURL
        self.language = language
        self.authStyle = authStyle
        self.smartFormat = smartFormat
        self.punctuate = punctuate
        self.paragraphs = paragraphs
        self.fillerWords = fillerWords
        self.profanityFilter = profanityFilter
        self.numerals = numerals
        self.diarize = diarize
        self.keyterms = keyterms
        self.tagAudioEvents = tagAudioEvents
        self.noVerbatim = noVerbatim
        self.numSpeakers = numSpeakers
        self.detectSpeakerRoles = detectSpeakerRoles
        self.useSpeakerLibrary = useSpeakerLibrary
        self.timestampsGranularity = timestampsGranularity
        self.entityDetection = entityDetection
        self.transcriptEdit = transcriptEdit
        self.azureRegion = azureRegion
        self.azureRecognitionMode = azureRecognitionMode
        self.azureProfanityFilter = azureProfanityFilter
        self.azureOutputFormat = azureOutputFormat
        self.azureStoreAudio = azureStoreAudio
        self.zeroDataRetention = zeroDataRetention
        self.temperature = temperature
        self.prompt = prompt
        self.responseFormat = responseFormat
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case baseURL
        case language
        case authStyle
        case smartFormat
        case punctuate
        case paragraphs
        case fillerWords
        case profanityFilter
        case numerals
        case diarize
        case keyterms
        case tagAudioEvents
        case noVerbatim
        case numSpeakers
        case detectSpeakerRoles
        case useSpeakerLibrary
        case timestampsGranularity
        case entityDetection
        case transcriptEdit
        case azureRegion
        case azureRecognitionMode
        case azureProfanityFilter
        case azureOutputFormat
        case azureStoreAudio
        case zeroDataRetention
        case temperature
        case prompt
        case responseFormat
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        self.language = try container.decodeIfPresent(String.self, forKey: .language)
        self.authStyle = try container.decodeIfPresent(AuthStyle.self, forKey: .authStyle)
        self.smartFormat = try container.decodeIfPresent(Bool.self, forKey: .smartFormat)
        self.punctuate = try container.decodeIfPresent(Bool.self, forKey: .punctuate)
        self.paragraphs = try container.decodeIfPresent(Bool.self, forKey: .paragraphs)
        self.fillerWords = try container.decodeIfPresent(Bool.self, forKey: .fillerWords)
        self.profanityFilter = try container.decodeIfPresent(Bool.self, forKey: .profanityFilter)
        self.numerals = try container.decodeIfPresent(Bool.self, forKey: .numerals)
        self.diarize = try container.decodeIfPresent(Bool.self, forKey: .diarize)
        self.keyterms = try container.decodeIfPresent(String.self, forKey: .keyterms)
        self.tagAudioEvents = try container.decodeIfPresent(Bool.self, forKey: .tagAudioEvents)
        self.noVerbatim = try container.decodeIfPresent(Bool.self, forKey: .noVerbatim)
        self.numSpeakers = try container.decodeIfPresent(Int.self, forKey: .numSpeakers)
        self.detectSpeakerRoles = try container.decodeIfPresent(Bool.self, forKey: .detectSpeakerRoles)
        self.useSpeakerLibrary = try container.decodeIfPresent(Bool.self, forKey: .useSpeakerLibrary)
        self.timestampsGranularity = try container.decodeIfPresent(String.self, forKey: .timestampsGranularity)
        self.entityDetection = try container.decodeIfPresent(String.self, forKey: .entityDetection)
        self.transcriptEdit = try container.decodeIfPresent(String.self, forKey: .transcriptEdit)
        self.azureRegion = try container.decodeIfPresent(String.self, forKey: .azureRegion)
        self.azureRecognitionMode = try container.decodeIfPresent(String.self, forKey: .azureRecognitionMode)
        self.azureProfanityFilter = try container.decodeIfPresent(String.self, forKey: .azureProfanityFilter)
        self.azureOutputFormat = try container.decodeIfPresent(String.self, forKey: .azureOutputFormat)
        self.azureStoreAudio = try container.decodeIfPresent(Bool.self, forKey: .azureStoreAudio)
        self.zeroDataRetention = try container.decodeIfPresent(Bool.self, forKey: .zeroDataRetention)
        self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        self.prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        self.responseFormat = try container.decodeIfPresent(String.self, forKey: .responseFormat)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(authStyle, forKey: .authStyle)
        try container.encodeIfPresent(smartFormat, forKey: .smartFormat)
        try container.encodeIfPresent(punctuate, forKey: .punctuate)
        try container.encodeIfPresent(paragraphs, forKey: .paragraphs)
        try container.encodeIfPresent(fillerWords, forKey: .fillerWords)
        try container.encodeIfPresent(profanityFilter, forKey: .profanityFilter)
        try container.encodeIfPresent(numerals, forKey: .numerals)
        try container.encodeIfPresent(diarize, forKey: .diarize)
        try container.encodeIfPresent(keyterms, forKey: .keyterms)
        try container.encodeIfPresent(tagAudioEvents, forKey: .tagAudioEvents)
        try container.encodeIfPresent(noVerbatim, forKey: .noVerbatim)
        try container.encodeIfPresent(numSpeakers, forKey: .numSpeakers)
        try container.encodeIfPresent(detectSpeakerRoles, forKey: .detectSpeakerRoles)
        try container.encodeIfPresent(useSpeakerLibrary, forKey: .useSpeakerLibrary)
        try container.encodeIfPresent(timestampsGranularity, forKey: .timestampsGranularity)
        try container.encodeIfPresent(entityDetection, forKey: .entityDetection)
        try container.encodeIfPresent(transcriptEdit, forKey: .transcriptEdit)
        try container.encodeIfPresent(azureRegion, forKey: .azureRegion)
        try container.encodeIfPresent(azureRecognitionMode, forKey: .azureRecognitionMode)
        try container.encodeIfPresent(azureProfanityFilter, forKey: .azureProfanityFilter)
        try container.encodeIfPresent(azureOutputFormat, forKey: .azureOutputFormat)
        try container.encodeIfPresent(azureStoreAudio, forKey: .azureStoreAudio)
        try container.encodeIfPresent(zeroDataRetention, forKey: .zeroDataRetention)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(responseFormat, forKey: .responseFormat)
    }
}

/// Dot's configuration.
///
/// The file lives at `~/Library/Application Support/Dot/config.json`. Every
/// field has a default, so a missing file — or a file that only sets one
/// field — is perfectly valid.
public struct DotConfig: Codable, Sendable, Equatable {
    /// The id of the provider that is used.
    public var provider: String
    /// The settings of every provider the user has configured.
    public var providers: [String: ProviderConfig]
    /// The shortcut that starts and stops a recording.
    public var hotkey: Hotkey
    /// The shortcut that pastes the last transcript again.
    public var pasteHotkey: Hotkey
    /// Whether the transcript is pasted into the frontmost application.
    public var autoPaste: Bool
    /// Whether single-clicking the menu bar icon starts or stops recording.
    public var fastRecord: Bool
    /// How long the transcript stays on screen, in seconds.
    public var hudDwellSeconds: Double
    /// The revision of the dwell this configuration was written with.
    ///
    /// A file written by a build from before the dwell changed has no revision
    /// at all, which decodes as `0`: that is how
    /// ``HUDDwellMigration/apply(to:)`` tells a stored old default from a value
    /// the user chose.
    public var hudDwellRevision: Int
    /// The longest segment that is sent in one request, in seconds.
    ///
    /// `0` means "use the provider's own capability".
    public var maxSegmentSeconds: Int
    /// The microphone to use; `nil` means the system default input.
    public var microphoneDeviceUID: String?
    /// Whether the transcript itself may be written to the log.
    public var logTranscripts: Bool
    /// What the HUD's card is made of.
    public var hudMaterial: HUDMaterial
    /// How the windows follow the system appearance.
    public var appearance: AppearanceMode
    /// What visualizer the HUD island uses to draw incoming audio.
    public var hudVisualizer: HUDVisualizer

    /// The configuration Dot starts with.
    public static let `default` = DotConfig(
        provider: ProviderIdentifier.openAI,
        providers: DotConfig.defaultProviders,
        hotkey: .defaultRecord,
        pasteHotkey: .defaultPaste,
        autoPaste: true,
        fastRecord: false,
        hudDwellSeconds: HUDDwell.defaultSeconds,
        hudDwellRevision: HUDDwell.revision,
        maxSegmentSeconds: 30,
        microphoneDeviceUID: nil,
        logTranscripts: false,
        hudMaterial: .glass,
        appearance: .system,
        hudVisualizer: .stretch
    )

    /// The settings the providers start with.
    ///
    /// The initial settings for each provider.
    ///
    /// Model selections are not hardcoded: available models are discovered
    /// dynamically when an API key is connected.
    public static let defaultProviders: [String: ProviderConfig] = [
        ProviderIdentifier.openAI: ProviderConfig(
            baseURL: "https://api.openai.com/v1",
            zeroDataRetention: true
        ),
        ProviderIdentifier.groq: ProviderConfig(
            baseURL: "https://api.groq.com/openai/v1",
            zeroDataRetention: true,
            temperature: 0.0,
            responseFormat: "json"
        ),
        ProviderIdentifier.azure: ProviderConfig(
            baseURL: "https://eastus.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1",
            azureRegion: "eastus",
            azureRecognitionMode: "conversation",
            azureProfanityFilter: "masked",
            azureOutputFormat: "detailed",
            zeroDataRetention: true
        ),
        ProviderIdentifier.deepgram: ProviderConfig(
            baseURL: "https://api.deepgram.com/v1",
            zeroDataRetention: true
        ),
        ProviderIdentifier.elevenLabs: ProviderConfig(
            baseURL: "https://api.elevenlabs.io/v1",
            zeroDataRetention: true
        ),
        ProviderIdentifier.xiaomi: ProviderConfig(
            baseURL: "https://api.xiaomimimo.com/v1",
            zeroDataRetention: true
        ),
        ProviderIdentifier.apple: ProviderConfig(),
    ]

    /// Creates a configuration.
    public init(
        provider: String = ProviderIdentifier.openAI,
        providers: [String: ProviderConfig] = DotConfig.defaultProviders,
        hotkey: Hotkey = .defaultRecord,
        pasteHotkey: Hotkey = .defaultPaste,
        autoPaste: Bool = true,
        fastRecord: Bool = false,
        hudDwellSeconds: Double = HUDDwell.defaultSeconds,
        hudDwellRevision: Int = HUDDwell.revision,
        maxSegmentSeconds: Int = 30,
        microphoneDeviceUID: String? = nil,
        logTranscripts: Bool = false,
        hudMaterial: HUDMaterial = .glass,
        appearance: AppearanceMode = .system,
        hudVisualizer: HUDVisualizer = .stretch
    ) {
        self.provider = provider
        self.providers = providers
        self.hotkey = hotkey
        self.pasteHotkey = pasteHotkey
        self.autoPaste = autoPaste
        self.fastRecord = fastRecord
        self.hudDwellSeconds = hudDwellSeconds
        self.hudDwellRevision = hudDwellRevision
        self.maxSegmentSeconds = maxSegmentSeconds
        self.microphoneDeviceUID = microphoneDeviceUID
        self.logTranscripts = logTranscripts
        self.hudMaterial = hudMaterial
        self.appearance = appearance
        self.hudVisualizer = hudVisualizer
    }

    /// The folder the configuration lives in, relative to the home directory.
    ///
    /// The identity migration and the history store both derive their paths
    /// from this one string, so the folder can never be named twice.
    public static let directoryName = "Library/Application Support/Dot"

    /// The directory the configuration lives in.
    public static func directoryURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The full path of the configuration file.
    public static func defaultURL() -> URL {
        directoryURL().appendingPathComponent("config.json")
    }

    /// The settings of one provider, or the defaults for it.
    public func settings(for providerID: String) -> ProviderConfig {
        providers[providerID] ?? DotConfig.defaultProviders[providerID] ?? ProviderConfig()
    }

    /// Reads the configuration, falling back to the defaults.
    ///
    /// A broken file is never fatal: Dot logs it and starts with the defaults
    /// so a typo cannot make the app unusable.
    ///
    /// Decoding is pure: it knows nothing about the Keychain and nothing about
    /// which providers can be built, so a file that names a retired provider
    /// still loads. The selected id is corrected by
    /// ``ProviderMigration/retireDeadProviders(in:probe:)`` at launch, before
    /// anything builds a provider from it.
    public static func load(from url: URL = defaultURL()) -> DotConfig {
        guard let data = try? Data(contentsOf: url) else { return .default }
        do {
            return try JSONDecoder().decode(DotConfig.self, from: data)
        } catch {
            Log.shared.warn("config.unreadable", [
                "path": .string(url.path),
                "error": .string(error.localizedDescription),
            ])
            return .default
        }
    }

    /// The configuration a Mac without a saved configuration starts with.
    ///
    /// Everyone starts on the OpenAI-compatible provider, where one pasted key
    /// is enough to begin.
    public static func firstRun() -> DotConfig {
        .default
    }

    /// Writes the configuration.
    ///
    /// - Throws: ``ConfigError/retiredProvider(_:)`` when the selected provider
    ///   is not one Dot ships. The file is the record of what the next launch
    ///   builds, so an id that cannot be built must never reach it; the launch
    ///   correction runs before the first save, so this refusal only fires on a
    ///   bug.
    public func save(to url: URL = defaultURL()) throws {
        guard ProviderRegistry.knows(provider) else {
            throw ConfigError.retiredProvider(provider)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

/// The configuration refuses to be written.
public enum ConfigError: Error, Equatable, LocalizedError {
    /// The selected provider id is not one Dot ships.
    case retiredProvider(String)

    public var errorDescription: String? {
        switch self {
        case .retiredProvider(let id):
            "The configuration cannot be saved: there is no provider called '\(id)'."
        }
    }
}

extension DotConfig {
    /// Decoding that fills in the defaults for the fields a file does not set.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = DotConfig.default
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? fallback.provider
        self.providers = try container.decodeIfPresent([String: ProviderConfig].self, forKey: .providers)
            ?? fallback.providers
        self.hotkey = try container.decodeIfPresent(Hotkey.self, forKey: .hotkey) ?? fallback.hotkey
        self.pasteHotkey = try container.decodeIfPresent(Hotkey.self, forKey: .pasteHotkey) ?? fallback.pasteHotkey
        self.autoPaste = try container.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? fallback.autoPaste
        self.fastRecord = try container.decodeIfPresent(Bool.self, forKey: .fastRecord) ?? fallback.fastRecord
        self.hudDwellSeconds = try container.decodeIfPresent(Double.self, forKey: .hudDwellSeconds)
            ?? fallback.hudDwellSeconds
        // No revision is a file from before the dwell changed: zero is what
        // makes the migration run once, on that file.
        self.hudDwellRevision = try container.decodeIfPresent(Int.self, forKey: .hudDwellRevision) ?? 0
        self.maxSegmentSeconds = try container.decodeIfPresent(Int.self, forKey: .maxSegmentSeconds)
            ?? fallback.maxSegmentSeconds
        self.microphoneDeviceUID = try container.decodeIfPresent(String.self, forKey: .microphoneDeviceUID)
        self.logTranscripts = try container.decodeIfPresent(Bool.self, forKey: .logTranscripts) ?? fallback.logTranscripts
        self.hudMaterial = try container.decodeIfPresent(HUDMaterial.self, forKey: .hudMaterial)
            ?? fallback.hudMaterial
        self.appearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearance)
            ?? fallback.appearance
        self.hudVisualizer = try container.decodeIfPresent(HUDVisualizer.self, forKey: .hudVisualizer)
            ?? fallback.hudVisualizer
    }
}

/// The ids the built-in providers use.
///
/// They are stable strings: they are written into the configuration file and
/// they never change.
public enum ProviderIdentifier {
    /// Any service that speaks the OpenAI transcription shape.
    public static let openAI = "openai"
    /// Groq ultra-fast speech-to-text API.
    public static let groq = "groq"
    /// Microsoft Azure Cognitive Services Speech-to-Text.
    public static let azure = "azure"
    /// Deepgram's hosted speech-to-text service (`/v1/listen`).
    public static let deepgram = "deepgram"
    /// ElevenLabs' hosted Scribe speech-to-text service (`/v1/speech-to-text`).
    public static let elevenLabs = "elevenlabs"
    /// Xiaomi's hosted MiMo speech-to-text model.
    public static let xiaomi = "xiaomi"
    /// Apple's on-device transcriber.
    public static let apple = "apple"
    /// A retired provider id. Nothing can select it any more; the string is a
    /// tombstone so a configuration file written by an older build still
    /// decodes, and ``ProviderMigration`` can rewrite it.
    public static let bridge = "bridge"
}
