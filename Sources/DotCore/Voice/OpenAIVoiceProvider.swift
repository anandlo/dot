import Foundation

/// OpenAI's text-to-speech endpoint (`/v1/audio/speech`).
///
/// The endpoint works, and it is scheduled to stop. OpenAI's TTS guide says the
/// `tts-1`, `tts-1-hd` and `gpt-4o-mini-tts` models shut down on 6 January 2027
/// and that text to speech moves to the Realtime API. ``deprecation`` carries
/// that date so Settings can count down to it instead of discovering it on the
/// day, and the row is ranked last in ``VoicePresets`` for the same reason.
///
/// The request asks for `response_format: "pcm"`: the player wants samples, not
/// a file, and every other format would need a decoder in the audio path.
public struct OpenAIVoiceProvider: VoiceProvider {
    public let id: String = VoiceProviderID.openAI
    public let displayName: String = "OpenAI"
    public let requiresCredential: Bool = true
    public let audioFormat: VoiceAudioFormat = .pcm24k

    /// The default endpoint of OpenAI's API.
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!
    /// The model Dot asks for when the setting names none.
    public static let defaultModel = "gpt-4o-mini-tts"
    /// The voice Dot asks for when the setting names none. OpenAI recommends
    /// `marin` and `cedar` for quality; `marin` is the one it lists first.
    public static let defaultVoiceID = "marin"
    /// The most text one request may carry, from OpenAI's API reference.
    public static let maximumInputCharacters = 4096
    /// The speed multiplier range the endpoint accepts.
    public static let speedRange = 0.25...4.0
    /// The models Dot offers for this endpoint.
    public static let models: [VoiceModelOption] = VoicePresets.openAI.models
    /// The vendor's shutdown notice, shared with ``VoicePresets`` so the row and
    /// the provider cannot disagree.
    public static var deprecation: VoiceDeprecation? { VoicePresets.openAI.deprecation }

    /// The built-in voices OpenAI documents.
    ///
    /// The guide says there are thirteen. `tts-1` and `tts-1-hd` support only the
    /// first nine of these; the other four arrived with `gpt-4o-mini-tts`.
    public static let catalogue: [VoiceDescriptor] = [
        VoiceDescriptor(providerID: VoiceProviderID.openAI, id: "marin", name: "Marin", language: "multi", quality: .enhanced, detail: "Recommended for quality"),
        VoiceDescriptor(providerID: VoiceProviderID.openAI, id: "cedar", name: "Cedar", language: "multi", quality: .enhanced, detail: "Recommended for quality"),
        VoiceDescriptor(providerID: VoiceProviderID.openAI, id: "alloy", name: "Alloy", language: "multi", quality: .enhanced, detail: "Neutral"),
        VoiceDescriptor(providerID: VoiceProviderID.openAI, id: "ash", name: "Ash", language: "multi", quality: .enhanced, detail: "Warm"),
        VoiceDescriptor(providerID: VoiceProviderID.openAI, id: "ballad", name: "Ballad", language: "multi", quality: .enhanced, detail: "Expressive"),
        VoiceDescriptor(providerID: VoiceProviderID.openAI, id: "coral", name: "Coral", language: "multi", quality: .enhanced, detail: "Bright"),
        VoiceDescriptor(providerID: VoiceProviderID.openAI, id: "echo", name: "Echo", language: "multi", quality: .enhanced, detail: "Even"),
        VoiceDescriptor(providerID: VoiceProviderID.openAI, id: "fable", name: "Fable", language: "multi", quality: .enhanced, detail: "Storytelling"),
        VoiceDescriptor(providerID: VoiceProviderID.openAI, id: "nova", name: "Nova", language: "multi", quality: .enhanced, detail: "Lively"),
        VoiceDescriptor(providerID: VoiceProviderID.openAI, id: "onyx", name: "Onyx", language: "multi", quality: .enhanced, detail: "Deep"),
        VoiceDescriptor(providerID: VoiceProviderID.openAI, id: "sage", name: "Sage", language: "multi", quality: .enhanced, detail: "Calm"),
        VoiceDescriptor(providerID: VoiceProviderID.openAI, id: "shimmer", name: "Shimmer", language: "multi", quality: .enhanced, detail: "Soft"),
        VoiceDescriptor(providerID: VoiceProviderID.openAI, id: "verse", name: "Verse", language: "multi", quality: .enhanced, detail: "Versatile"),
    ]

    /// The endpoint, e.g. `https://api.openai.com/v1`.
    public let baseURL: URL
    /// The API key, when the Keychain has one.
    public let apiKey: String?
    /// The base URL with `/audio/speech` on it.
    public var speechURL: URL {
        baseURL.lastPathComponent == "speech" ? baseURL : baseURL.appendingPathComponent("audio/speech")
    }

    private let session: URLSession
    private let timeout: TimeInterval

    /// Creates an OpenAI voice provider.
    public init(
        baseURL: URL = OpenAIVoiceProvider.defaultBaseURL,
        apiKey: String? = nil,
        timeout: TimeInterval = 60,
        session: URLSession = OpenAICompatibleProvider.makeSession()
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session
    }

    /// Whether a key is present.
    public func isAvailable() async -> Bool {
        guard let apiKey else { return false }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The built-in voices, best first.
    public func voices(language: String?) async throws -> [VoiceDescriptor] {
        VoiceCatalogue.select(Self.catalogue, language: language)
    }
}

// MARK: - The request

extension OpenAIVoiceProvider {
    /// The JSON body of one synthesis request.
    struct SpeechBody: Encodable, Equatable {
        let model: String
        let input: String
        let voice: String
        let response_format: String
        let speed: Double
        let instructions: String?
    }

    /// Builds the body for one sentence.
    ///
    /// - Parameters:
    ///   - text: the sentence to speak.
    ///   - settings: the chosen voice and model.
    /// - Returns: the body that goes on the wire.
    /// - Throws: ``ProviderError`` when the request cannot be formed.
    func body(for text: String, settings: VoiceSettings) throws -> SpeechBody {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.unavailable("There is nothing to speak.") }
        guard trimmed.count <= Self.maximumInputCharacters else {
            throw ProviderError.unavailable(
                "OpenAI accepts at most \(Self.maximumInputCharacters) characters in one request."
            )
        }
        guard let voice = settings.resolvedVoiceID(fallback: Self.defaultVoiceID) else {
            throw ProviderError.unavailable("OpenAI needs a voice. Choose one in Settings.")
        }
        let model = settings.resolvedModel(fallback: Self.defaultModel)
        // OpenAI documents that style instructions do nothing on the two legacy
        // models, so they are not sent there.
        let styled = model != "tts-1" && model != "tts-1-hd"
        let instructions = styled ? settings.instructions?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return SpeechBody(
            model: model,
            input: trimmed,
            voice: voice,
            response_format: "pcm",
            speed: settings.speed(within: Self.speedRange),
            instructions: (instructions?.isEmpty == false) ? instructions : nil
        )
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
        var request = URLRequest(url: try VoiceEndpoint.validate(speechURL))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/pcm", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body(for: text, settings: settings))
        return request
    }

    /// Speaks one sentence.
    public func speech(
        text: String,
        settings: VoiceSettings
    ) async throws -> AsyncThrowingStream<VoiceChunk, Error> {
        let request = try request(for: text, settings: settings)
        return try await VoiceByteStream.chunks(request, session: session, format: audioFormat)
    }
}
