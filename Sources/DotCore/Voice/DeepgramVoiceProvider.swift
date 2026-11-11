import Foundation

/// Deepgram's Aura-2 text-to-speech endpoint (`/v1/speak`).
///
/// Deepgram names a voice and a model in one string: `aura-2-thalia-en` is model
/// `aura-2`, voice `thalia`, language `en`. The vendor's roster is the widest of
/// the cloud rows and the voices come with adjectives, which is why
/// ``catalogue`` carries them: choosing "warm and calm" is a better question
/// than choosing an opaque id.
///
/// The auth scheme is `Token`, not `Bearer`, which is the one thing a generic
/// OpenAI-shaped request would get wrong. Dot already stores a Deepgram key for
/// dictation, so the row costs no second key.
public struct DeepgramVoiceProvider: VoiceProvider {
    public let id: String = VoiceProviderID.deepgram
    public let displayName: String = "Deepgram"
    public let requiresCredential: Bool = true
    public let audioFormat: VoiceAudioFormat = .pcm24k

    /// The default endpoint of Deepgram's API.
    public static let defaultBaseURL = URL(string: "https://api.deepgram.com/v1")!
    /// The voice Dot asks for when the setting names none.
    public static let defaultModel = "aura-2-thalia-en"
    /// The models Dot offers for this endpoint.
    public static let models: [VoiceModelOption] = VoicePresets.deepgram.models

    /// The Aura-2 voices quoted from Deepgram's model table.
    ///
    /// The full roster is more than forty English voices. These are the ones the
    /// research set quotes verbatim; a person can still use any other id by
    /// typing it, because the voice field is a string and not a closed list.
    public static let catalogue: [VoiceDescriptor] = models.map { model in
        VoiceDescriptor(
            providerID: VoiceProviderID.deepgram,
            id: model.id,
            name: model.name,
            language: languageSuffix(of: model.id),
            quality: .enhanced,
            detail: model.detail
        )
    }

    /// The endpoint, e.g. `https://api.deepgram.com/v1`.
    public let baseURL: URL
    /// The API key, when the Keychain has one.
    public let apiKey: String?
    /// Whether the request opts out of Deepgram's model improvement programme.
    public let zeroDataRetention: Bool

    private let session: URLSession
    private let timeout: TimeInterval

    /// Creates a Deepgram voice provider.
    public init(
        baseURL: URL = DeepgramVoiceProvider.defaultBaseURL,
        apiKey: String? = nil,
        zeroDataRetention: Bool = true,
        timeout: TimeInterval = 60,
        session: URLSession = OpenAICompatibleProvider.makeSession()
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.zeroDataRetention = zeroDataRetention
        self.timeout = timeout
        self.session = session
    }

    /// Whether a key is present.
    public func isAvailable() async -> Bool {
        VoiceKey.isPresent(apiKey)
    }

    /// The voices Dot knows, best first.
    public func voices(language: String?) async throws -> [VoiceDescriptor] {
        VoiceCatalogue.select(Self.catalogue, language: language)
    }

    /// The language a Deepgram model name ends with.
    ///
    /// - Parameter model: e.g. `aura-2-thalia-en`.
    /// - Returns: `en`, or `multi` when the name has no language suffix.
    public static func languageSuffix(of model: String) -> String {
        guard let suffix = model.split(separator: "-").last, suffix.count == 2 else { return "multi" }
        return String(suffix).lowercased()
    }
}

// MARK: - The request

extension DeepgramVoiceProvider {
    /// The JSON body of one synthesis request.
    struct SpeechBody: Encodable, Equatable {
        let text: String
    }

    /// The `POST /speak` endpoint for one voice.
    ///
    /// `encoding=linear16` and `sample_rate` are the vendor's own query
    /// parameters for raw PCM, which is what the player wants; the default
    /// answer is a WAV file. Neither parameter is in the verified set, so a
    /// request that comes back as a WAV is the first thing to check.
    ///
    /// - Parameter model: the voice and model in one string.
    /// - Returns: the URL, with every parameter in the query string.
    func speakURL(model: String) -> URL {
        let endpoint = baseURL.lastPathComponent == "speak"
            ? baseURL
            : baseURL.appendingPathComponent("speak")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }
        var items = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(Int(audioFormat.sampleRate))),
        ]
        if zeroDataRetention {
            items.append(URLQueryItem(name: "mip_opt_out", value: "true"))
        }
        components.queryItems = items
        return components.url ?? endpoint
    }

    /// The voice and model a request uses.
    ///
    /// A voice chosen in the picker wins over the model field, because in
    /// Deepgram's naming they are the same string and the picker is what a
    /// person actually touched.
    ///
    /// - Parameter settings: the chosen voice and model.
    public func resolvedVoiceModel(_ settings: VoiceSettings) -> String {
        if let voice = settings.voiceID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !voice.isEmpty {
            return voice
        }
        return settings.resolvedModel(fallback: Self.defaultModel)
    }

    /// Builds the request for one sentence.
    ///
    /// - Parameters:
    ///   - text: the sentence to speak.
    ///   - settings: the chosen voice and model.
    /// - Returns: the request to send.
    /// - Throws: ``ProviderError`` when there is no key.
    func request(for text: String, settings: VoiceSettings) throws -> URLRequest {
        let key = try VoiceKey.required(apiKey, provider: displayName)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.unavailable("There is nothing to speak.") }
        var request = URLRequest(url: try VoiceEndpoint.validate(speakURL(model: resolvedVoiceModel(settings))))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/pcm", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(SpeechBody(text: trimmed))
        return request
    }

    /// Speaks one sentence.
    ///
    /// Speed is not sent: Aura-2 has no documented rate control, and a field a
    /// service ignores is worse than one Dot never claims to use.
    public func speech(
        text: String,
        settings: VoiceSettings
    ) async throws -> AsyncThrowingStream<VoiceChunk, Error> {
        let request = try request(for: text, settings: settings)
        return try await VoiceByteStream.chunks(request, session: session, format: audioFormat)
    }
}
