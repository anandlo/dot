import Foundation

/// The provider the configuration asks for could not be built.
public enum ProviderRegistryError: Error, Equatable, LocalizedError {
    /// The configuration names a provider Dot does not know.
    case unknownProvider(String)
    /// The OpenAI-compatible provider has no usable base URL.
    case missingBaseURL(String)
    /// The base URL is not an address Dot will send audio or a key to.
    case refusedEndpoint(String, EndpointPolicy.Rejection)

    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let id):
            "There is no provider called '\(id)'."
        case .missingBaseURL(let id):
            "The provider '\(id)' has no base URL."
        case .refusedEndpoint(let id, let rejection):
            "\(id.capitalized): \(rejection.localizedDescription)"
        }
    }
}

/// Builds the providers out of the configuration.
///
/// The registry is the only place that knows which providers exist; the rest
/// of Dot works with the ``Provider`` interface alone. It is also the only
/// place that turns a provider id into a key, and it does that through
/// ``CredentialCache``: a provider is built from a key that has already been
/// resolved once, so building one is never a Keychain round trip.
public enum ProviderRegistry {
    /// The ids of the providers Dot ships with.
    ///
    /// These are what Dot can build, not what it offers: the picker and the menu
    /// draw ``ProviderPreset`` rows, several of which can select one id here.
    public static let builtInIDs = [
        ProviderIdentifier.openAI,
        ProviderIdentifier.groq,
        ProviderIdentifier.azure,
        ProviderIdentifier.deepgram,
        ProviderIdentifier.elevenLabs,
        ProviderIdentifier.xiaomi,
        ProviderIdentifier.apple,
    ]

    /// Whether Dot ships a provider with this id.
    ///
    /// This is the single answer to "may this id be written into a
    /// configuration?". A configuration that names any other id cannot be built,
    /// so the launch correction retires it and ``DotConfig/save(to:)`` refuses
    /// to write it.
    public static func knows(_ id: String) -> Bool {
        builtInIDs.contains(id)
    }

    /// Builds one provider.
    ///
    /// - Parameters:
    ///   - id: the provider id.
    ///   - config: the configuration the provider's settings come from.
    ///   - credentials: where the key comes from. Pass ``CredentialCache/empty``
    ///     to build the provider without a key.
    /// - Throws: ``ProviderRegistryError/unknownProvider(_:)`` when the id is
    ///   not one Dot knows.
    public static func makeProvider(
        id: String,
        config: DotConfig,
        credentials: CredentialCache = .shared
    ) throws -> any Provider {
        switch id {
        case ProviderIdentifier.openAI:
            let settings = config.settings(for: id)
            let url = try endpoint(settings.baseURL, id: id, fallback: nil)
            return OpenAICompatibleProvider(
                baseURL: url,
                apiKey: apiKey(for: id, credentials: credentials),
                authStyle: settings.authStyle ?? .bearer,
                temperature: settings.temperature,
                prompt: settings.prompt,
                responseFormat: settings.responseFormat,
                timestampsGranularity: settings.timestampsGranularity
            )
        case ProviderIdentifier.groq:
            let settings = config.settings(for: id)
            let url = try endpoint(settings.baseURL, id: id, fallback: GroqProvider.defaultBaseURL)
            return GroqProvider(
                baseURL: url,
                apiKey: apiKey(for: id, credentials: credentials),
                temperature: settings.temperature,
                prompt: settings.prompt,
                responseFormat: settings.responseFormat ?? "json",
                timestampsGranularity: settings.timestampsGranularity
            )
        case ProviderIdentifier.azure:
            let settings = config.settings(for: id)
            let url = try optionalEndpoint(settings.baseURL, id: id)
            let region = settings.azureRegion?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedRegion = (region?.isEmpty == false) ? region! : AzureSpeechProvider.defaultRegion
            let mode = settings.azureRecognitionMode?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedMode = (mode?.isEmpty == false) ? mode! : AzureSpeechProvider.defaultRecognitionMode
            let profanity = settings.azureProfanityFilter?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedProfanity = (profanity?.isEmpty == false) ? profanity! : AzureSpeechProvider.defaultProfanityFilter
            let format = settings.azureOutputFormat?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedFormat = (format?.isEmpty == false) ? format! : AzureSpeechProvider.defaultOutputFormat
            return AzureSpeechProvider(
                baseURL: url,
                region: resolvedRegion,
                recognitionMode: resolvedMode,
                profanityFilter: resolvedProfanity,
                outputFormat: resolvedFormat,
                storeAudio: settings.azureStoreAudio,
                zeroDataRetention: settings.zeroDataRetention ?? true,
                apiKey: apiKey(for: id, credentials: credentials)
            )
        case ProviderIdentifier.deepgram:
            let settings = config.settings(for: id)
            let url = try endpoint(settings.baseURL, id: id, fallback: DeepgramProvider.defaultBaseURL)
            return DeepgramProvider(
                baseURL: url,
                apiKey: apiKey(for: id, credentials: credentials),
                smartFormat: settings.smartFormat ?? true,
                punctuate: settings.punctuate ?? true,
                paragraphs: settings.paragraphs ?? false,
                fillerWords: settings.fillerWords ?? false,
                profanityFilter: settings.profanityFilter ?? false,
                numerals: settings.numerals ?? false,
                diarize: settings.diarize ?? false,
                keyterms: settings.keyterms,
                zeroDataRetention: settings.zeroDataRetention ?? true
            )
        case ProviderIdentifier.elevenLabs:
            let settings = config.settings(for: id)
            let url = try endpoint(settings.baseURL, id: id, fallback: ElevenLabsProvider.defaultBaseURL)
            return ElevenLabsProvider(
                baseURL: url,
                apiKey: apiKey(for: id, credentials: credentials),
                tagAudioEvents: settings.tagAudioEvents ?? false,
                noVerbatim: settings.noVerbatim ?? false,
                diarize: settings.diarize ?? false,
                numSpeakers: settings.numSpeakers,
                detectSpeakerRoles: settings.detectSpeakerRoles ?? false,
                useSpeakerLibrary: settings.useSpeakerLibrary ?? false,
                timestampsGranularity: settings.timestampsGranularity ?? "word",
                entityDetection: settings.entityDetection,
                keyterms: settings.keyterms,
                transcriptEdit: settings.transcriptEdit,
                zeroDataRetention: settings.zeroDataRetention ?? true
            )
        case ProviderIdentifier.xiaomi:
            let settings = config.settings(for: id)
            let endpoint = storedEndpoint(config: config)
            try checkEndpoint(endpoint.url, id: id)
            // An endpoint that was pointed somewhere else is no longer the
            // service this id was written for. It is the user's own endpoint,
            // so it is called with the shape every other custom endpoint gets.
            guard !endpoint.isOwned else {
                return OpenAICompatibleProvider(
                    id: id,
                    baseURL: endpoint.url,
                    apiKey: apiKey(for: id, credentials: credentials),
                    authStyle: settings.authStyle ?? .bearer,
                    temperature: settings.temperature,
                    prompt: settings.prompt,
                    responseFormat: settings.responseFormat,
                    timestampsGranularity: settings.timestampsGranularity
                )
            }
            return XiaomiASRProvider(
                baseURL: endpoint.url,
                apiKey: apiKey(for: id, credentials: credentials)
            )
        case ProviderIdentifier.apple:
            let settings = config.settings(for: id)
            let locale = settings.language ?? "en_US"
            return AppleSpeechProvider(localeIdentifier: locale)
        default:
            throw ProviderRegistryError.unknownProvider(id)
        }
    }

    /// Reads the base URL a provider's settings name, and refuses one Dot will
    /// not send a key or audio to.
    ///
    /// A remote endpoint is only reached over TLS. `http` is accepted for a
    /// loopback address, which is the local whisper.cpp, LM Studio or Ollama
    /// case the OpenAI-compatible provider exists for.
    ///
    /// - Parameters:
    ///   - stored: the base URL as the configuration holds it.
    ///   - id: the provider id, for the error a refusal carries.
    ///   - fallback: the endpoint to use when the configuration names none.
    /// - Returns: the endpoint to call.
    /// - Throws: ``ProviderRegistryError`` when there is no endpoint, or it is
    ///   one Dot refuses.
    private static func endpoint(_ stored: String?, id: String, fallback: URL?) throws -> URL {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            guard let fallback else { throw ProviderRegistryError.missingBaseURL(id) }
            return fallback
        }
        do {
            return try EndpointPolicy.url(from: trimmed)
        } catch let rejection as EndpointPolicy.Rejection {
            throw ProviderRegistryError.refusedEndpoint(id, rejection)
        }
    }

    /// Reads a base URL that may be absent.
    private static func optionalEndpoint(_ stored: String?, id: String) throws -> URL? {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return try endpoint(trimmed, id: id, fallback: nil)
    }

    /// Refuses an endpoint that is already a URL.
    private static func checkEndpoint(_ url: URL, id: String) throws {
        if let rejection = EndpointPolicy.validate(url) {
            throw ProviderRegistryError.refusedEndpoint(id, rejection)
        }
    }

    /// Whether the configured endpoint is called with the OpenAI-compatible
    /// shape.
    ///
    /// The shape belongs to the endpoint, not to the id the configuration was
    /// written under. A stored endpoint whose URL was changed is the user's own
    /// endpoint: it is called the way every other custom endpoint is, and its
    /// key travels in the header the configuration names instead of one its
    /// implementation happens to hardcode.
    ///
    /// The provider factory and the Settings page ask this same question, so
    /// the header control the page shows is the setting the request reads.
    ///
    /// - Parameter config: the configuration to read.
    /// - Returns: whether the endpoint speaks the OpenAI shape.
    public static func isGenericEndpoint(config: DotConfig) -> Bool {
        switch config.provider {
        case ProviderIdentifier.openAI:
            return true
        case ProviderIdentifier.xiaomi:
            return storedEndpoint(config: config).isOwned
        default:
            return false
        }
    }

    /// The endpoint a stored provider id points at.
    ///
    /// - Parameter config: the configuration to read.
    /// - Returns: the URL the endpoint is called at, and whether it is an
    ///   endpoint the user pointed the stored id at rather than the service the
    ///   id was written for.
    private static func storedEndpoint(config: DotConfig) -> (url: URL, isOwned: Bool) {
        let stored = config.settings(for: ProviderIdentifier.xiaomi).baseURL ?? ""
        guard let url = urlOnly(stored) else {
            return (XiaomiASRProvider.defaultBaseURL, false)
        }
        return (url, !sameURL(stored, XiaomiASRProvider.defaultBaseURL.absoluteString))
    }

    /// A URL a stored string names, when it names one.
    private static func urlOnly(_ stored: String) -> URL? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    /// Compares two URLs without a trailing slash, ignoring case.
    private static func sameURL(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ value: String) -> String {
            var value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while value.hasSuffix("/") { value.removeLast() }
            return value
        }
        return normalized(lhs) == normalized(rhs)
    }

    /// Builds the provider the configuration selects.
    ///
    /// - Throws: ``ProviderRegistryError/unknownProvider(_:)`` when the
    ///   configuration names a provider Dot does not know.
    public static func selectedProvider(
        config: DotConfig,
        credentials: CredentialCache = .shared
    ) throws -> any Provider {
        try makeProvider(id: config.provider, config: config, credentials: credentials)
    }

    /// The providers that can be used right now.
    ///
    /// The Settings menu lists exactly these, so a provider that is not
    /// running is never offered.
    public static func availableProviders(
        config: DotConfig,
        credentials: CredentialCache = .shared
    ) async -> [any Provider] {
        var available: [any Provider] = []
        for id in builtInIDs {
            guard let provider = try? makeProvider(id: id, config: config, credentials: credentials)
            else { continue }
            if await provider.isAvailable() {
                available.append(provider)
            }
        }
        return available
    }

    /// The API key of a provider, from the session cache.
    ///
    /// - Parameters:
    ///   - providerID: the provider id.
    ///   - credentials: the cache that owns the one decryption per session.
    public static func apiKey(for providerID: String, credentials: CredentialCache) -> String? {
        guard let key = credentials.key(for: providerID), !key.isEmpty else {
            return nil
        }
        return key
    }
}
