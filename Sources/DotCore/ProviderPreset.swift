import Foundation

/// One selectable speech-to-text service.
///
/// A preset carries the values a person should not have to know: which provider
/// id to select, which base URL to call and which model to ask for. Presets are
/// pure data: nothing here reads the Keychain, the network or a file, so the
/// same rules run in Settings, in the welcome, in the menu and in a test.
///
/// The list is what makes Dot agnostic. Every service is one row with the same
/// shape, and nothing outside this file decides which service a row means; the
/// views draw the rows and never name a service.
///
/// A row may exist without being offered. ``ProviderPreset/xiaomi`` is the one
/// such row: configurations written by an earlier build still select its
/// provider id, so the id, the endpoint and the key requirement have to keep
/// decoding, but the picker does not draw it. A configuration that selects it
/// is presented as a custom endpoint by ``ProviderPreset/presenting(_:)`` — a
/// stored endpoint the user owns, not a service Dot recommends.
public struct ProviderPreset: Identifiable, Equatable, Sendable {
    /// What a row needs before it can transcribe.
    public enum KeyRequirement: String, Codable, Sendable, CaseIterable {
        /// The service refuses requests without a key.
        case required
        /// The service may work without a key — a local server usually does.
        case optional
        /// Nothing leaves the machine and no key exists.
        case none
    }

    /// The stable id of the row, e.g. `openai`, `groq`, `custom`.
    public let id: String
    /// The name the row shows, e.g. "OpenAI".
    public let name: String
    /// The SF Symbol the row draws.
    public let symbol: String
    /// The provider id the row writes into the configuration.
    public let providerID: String
    /// The base URL of the service, when the row has one.
    public let baseURL: String?
    /// The model id sent with every request, when the row has one.
    public let model: String?
    /// What the row needs before it can transcribe.
    public let key: KeyRequirement
    /// Whether the row has a base URL and a model to edit.
    ///
    /// The on-device row has neither: it runs inside the app. Every other row
    /// is reached over the network, including the one the user fills in by
    /// hand.
    public let hasEndpoint: Bool
    /// Whether the picker draws the row.
    ///
    /// A row that is not offered still describes a provider id Dot can build,
    /// because a configuration written before the row was retired selects it.
    /// Only the presence in the picker goes.
    public let isOffered: Bool

    /// Creates a preset.
    public init(
        id: String,
        name: String,
        symbol: String,
        providerID: String,
        baseURL: String? = nil,
        model: String? = nil,
        key: KeyRequirement,
        hasEndpoint: Bool = true,
        isOffered: Bool = true
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.providerID = providerID
        self.baseURL = baseURL
        self.model = model
        self.key = key
        self.hasEndpoint = hasEndpoint
        self.isOffered = isOffered
    }

    /// Whether the service refuses requests without a key.
    public var needsKey: Bool { key == .required }

    // MARK: - The rows

    /// The transcriber built into macOS: no key, no network, no account.
    public static let apple = ProviderPreset(
        id: "on-device",
        name: "Apple Speech",
        symbol: "apple.logo",
        providerID: ProviderIdentifier.apple,
        key: .none,
        hasEndpoint: false
    )

    /// Microsoft Azure Cognitive Services Speech-to-Text.
    public static let azure = ProviderPreset(
        id: "azure",
        name: "Azure Speech",
        symbol: "cloud.fill",
        providerID: ProviderIdentifier.azure,
        baseURL: "https://eastus.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1",
        model: nil,
        key: .required,
        hasEndpoint: true,
        isOffered: true
    )

    /// Any other service that speaks the OpenAI transcription shape.
    ///
    /// The row deliberately carries no URL or model: the endpoint fields stay
    /// visible and editable, and the user's values are never replaced. The key
    /// is optional because a server on the same Mac usually needs none.
    public static let custom = ProviderPreset(
        id: "custom",
        name: "Custom endpoint",
        symbol: "server.rack",
        providerID: ProviderIdentifier.openAI,
        key: .optional
    )

    /// Deepgram's hosted speech-to-text API (`/v1/listen`).
    public static let deepgram = ProviderPreset(
        id: "deepgram",
        name: "Deepgram",
        symbol: "waveform.path.ecg",
        providerID: ProviderIdentifier.deepgram,
        baseURL: "https://api.deepgram.com/v1",
        model: nil,
        key: .required,
        hasEndpoint: true,
        isOffered: true
    )

    /// ElevenLabs' hosted Scribe speech-to-text API (`/v1/speech-to-text`).
    public static let elevenLabs = ProviderPreset(
        id: "elevenlabs",
        name: "ElevenLabs",
        symbol: "waveform.circle.fill",
        providerID: ProviderIdentifier.elevenLabs,
        baseURL: "https://api.elevenlabs.io/v1",
        model: nil,
        key: .required,
        hasEndpoint: true,
        isOffered: true
    )

    /// Groq's ultra-fast speech-to-text API.
    public static let groq = ProviderPreset(
        id: "groq",
        name: "Groq",
        symbol: "bolt.fill",
        providerID: ProviderIdentifier.groq,
        baseURL: "https://api.groq.com/openai/v1",
        model: nil,
        key: .required,
        hasEndpoint: true,
        isOffered: true
    )

    /// OpenAI's hosted transcription API.
    public static let openAI = ProviderPreset(
        id: "openai",
        name: "OpenAI",
        symbol: "cloud",
        providerID: ProviderIdentifier.openAI,
        baseURL: "https://api.openai.com/v1",
        model: nil,
        key: .required
    )

    /// The hosted speech-to-text model.
    ///
    /// Xiaomi's hosted speech-to-text service via the MiMo API.
    public static let xiaomi = ProviderPreset(
        id: "xiaomi",
        name: "Xiaomi ASR",
        symbol: "waveform.badge.mic",
        providerID: ProviderIdentifier.xiaomi,
        baseURL: "https://api.xiaomimimo.com/v1",
        model: nil,
        key: .required,
        hasEndpoint: true,
        isOffered: false
    )

    /// Every row this file declares, offered or not.
    ///
    /// This is the list a guard test scans and the list the provider migration
    /// consults: a key that exists for a retired-from-the-picker provider still
    /// says which service to use, even though no row draws it.
    public static let declared: [ProviderPreset] = [.apple, .azure, .custom, .deepgram, .elevenLabs, .groq, .openAI, .xiaomi]

    /// The rows the picker draws, in the order Settings, the welcome and the
    /// menu show them.
    ///
    /// Alphabetical by name on purpose: the first row of a list reads as a
    /// recommendation, and no service is one.
    public static let all: [ProviderPreset] = declared.filter(\.isOffered)

    /// The row with an id, when there is one.
    public static func preset(id: String) -> ProviderPreset? {
        all.first { $0.id == id }
    }

    /// The row the picker shows for a configuration.
    ///
    /// Unlike a lookup by id this never comes back empty: a configuration is
    /// always presented as exactly one row. A provider id Dot keeps for an
    /// earlier build — or one it does not know at all — is presented as the
    /// custom endpoint the user already owns, carrying the stored base URL and
    /// model so the fields cannot disagree with it and applying the row writes
    /// the same values back. The switch follows ``ProviderRegistry``: every
    /// provider Dot can build is presented here as well.
    public static func presenting(_ config: DotConfig) -> ProviderPreset {
        switch config.provider {
        case ProviderIdentifier.apple:
            return .apple
        case ProviderIdentifier.azure:
            let base = normalized(config.settings(for: ProviderIdentifier.azure).baseURL ?? "")
            if base.isEmpty || base.contains("stt.speech.microsoft.com") { return .azure }
            return ownedEndpoint(for: config, key: azure.key)
        case ProviderIdentifier.deepgram:
            let base = normalized(config.settings(for: ProviderIdentifier.deepgram).baseURL ?? "")
            if base == normalized(deepgram.baseURL ?? "") { return .deepgram }
            return ownedEndpoint(for: config, key: deepgram.key)
        case ProviderIdentifier.elevenLabs:
            let base = normalized(config.settings(for: ProviderIdentifier.elevenLabs).baseURL ?? "")
            if base == normalized(elevenLabs.baseURL ?? "") { return .elevenLabs }
            return ownedEndpoint(for: config, key: elevenLabs.key)
        case ProviderIdentifier.groq:
            let base = normalized(config.settings(for: ProviderIdentifier.groq).baseURL ?? "")
            if base.isEmpty || base == normalized(groq.baseURL ?? "") { return .groq }
            return ownedEndpoint(for: config, key: groq.key)
        case ProviderIdentifier.xiaomi:
            let base = normalized(config.settings(for: ProviderIdentifier.xiaomi).baseURL ?? "")
            if base == normalized(xiaomi.baseURL ?? "") { return .xiaomi }
            return ownedEndpoint(for: config, key: xiaomi.key)
        case ProviderIdentifier.openAI:
            let base = normalized(config.settings(for: ProviderIdentifier.openAI).baseURL ?? "")
            if base == normalized(openAI.baseURL ?? "") { return .openAI }
            if base == normalized(groq.baseURL ?? "") { return .groq }
            // An OpenAI-shaped endpoint Dot does not ship a row for keeps the
            // custom row's optional key: a server on this Mac usually needs none.
            return ownedEndpoint(for: config, key: custom.key)
        default:
            return ownedEndpoint(for: config)
        }
    }

    /// The rows to draw for a configuration.
    ///
    /// The row a stored provider presents takes the place of the generic row it
    /// stands in for, so the picker shows one selected row and the values it
    /// carries are the stored ones. With a configuration Dot ships a row for,
    /// the answer is simply ``ProviderPreset/all``.
    public static func rows(for config: DotConfig) -> [ProviderPreset] {
        let presented = presenting(config)
        return all.map { $0.id == presented.id ? presented : $0 }
    }

    /// Presents an endpoint Dot owns no offered row for as the custom row.
    ///
    /// It is named after its own host. "Custom endpoint" says what shape the
    /// service is, not which one is running, and a page that carries only that
    /// cannot answer the one question it exists to answer: what is connected.
    private static func ownedEndpoint(
        for config: DotConfig,
        key: KeyRequirement? = nil
    ) -> ProviderPreset {
        let settings = config.settings(for: config.provider)
        let declaredRow = declared.first { $0.providerID == config.provider }
        let base = nonEmpty(settings.baseURL)
        return ProviderPreset(
            id: custom.id,
            name: host(of: base) ?? custom.name,
            symbol: custom.symbol,
            providerID: config.provider,
            baseURL: base,
            model: nonEmpty(settings.model),
            key: key ?? declaredRow?.key ?? custom.key
        )
    }

    /// The host of a stored base URL, when it has one.
    public static func host(of baseURL: String?) -> String? {
        guard let baseURL, let host = URL(string: baseURL)?.host, !host.isEmpty else {
            return nil
        }
        return host
    }

    /// A stored value, or `nil` when there is nothing stored.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    /// Writes the row into a configuration.
    ///
    /// A row that carries an endpoint and model fills both in while keeping the
    /// language the user already chose. The custom row carries neither, so only
    /// the provider changes and the fields are left exactly as they are. The
    /// custom row that presents a stored provider carries that provider's own
    /// endpoint and model, so applying it writes the same values back.
    public func apply(to config: inout DotConfig) {
        config.provider = providerID
        guard baseURL != nil || model != nil else { return }
        var settings = config.settings(for: providerID)
        if let baseURL { settings.baseURL = baseURL }
        if let model { settings.model = model }
        config.providers[providerID] = settings
    }

    /// Compares URLs without a trailing slash.
    private static func normalized(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
