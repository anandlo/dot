import Foundation

/// ElevenLabs' streaming text-to-speech endpoint.
///
/// `POST /v1/text-to-speech/{voice_id}/stream` streams the audio over chunked
/// transfer, which is what makes it usable in a turn-taking assistant: the HTTP
/// endpoint works for every model, while the lower-latency websocket does not
/// accept `eleven_v3` or `eleven_v4`. Dot uses the HTTP stream for that reason,
/// and asks for `pcm_24000` so the audio path needs no decoder.
///
/// The key is the same `xi-api-key` ElevenLabs dictation already stores, which is
/// why the provider id is the shared vendor id and not a new one.
public struct ElevenLabsVoiceProvider: VoiceProvider {
    public let id: String = VoiceProviderID.elevenLabs
    public let displayName: String = "ElevenLabs"
    public let requiresCredential: Bool = true
    public let audioFormat: VoiceAudioFormat = .pcm24k

    /// The default endpoint of ElevenLabs' API.
    public static let defaultBaseURL = URL(string: "https://api.elevenlabs.io/v1")!
    /// The model Dot asks for when the setting names none. Flash v2.5 is the
    /// vendor's low-latency model at about 100 ms median model latency.
    public static let defaultModel = "eleven_flash_v2_5"
    /// The voice id used throughout ElevenLabs' own streaming examples.
    public static let defaultVoiceID = "JBFqnCBsd6RMkjVDRZzb"
    /// The output format Dot asks for.
    public static let defaultOutputFormat = "pcm_24000"
    /// The speed range of `voice_settings.speed` that Dot will send.
    public static let speedRange = 0.7...1.2
    /// The models Dot offers for this endpoint.
    public static let models: [VoiceModelOption] = VoicePresets.elevenLabs.models

    /// The endpoint, e.g. `https://api.elevenlabs.io/v1`.
    public let baseURL: URL
    /// The API key, when the Keychain has one.
    public let apiKey: String?
    /// The speed applied in `voice_settings`.
    public let stability: Double
    /// How closely the model stays to the original voice.
    public let similarityBoost: Double

    private let session: URLSession
    private let timeout: TimeInterval

    /// Creates an ElevenLabs voice provider.
    public init(
        baseURL: URL = ElevenLabsVoiceProvider.defaultBaseURL,
        apiKey: String? = nil,
        stability: Double = 0.5,
        similarityBoost: Double = 0.75,
        timeout: TimeInterval = 60,
        session: URLSession = OpenAICompatibleProvider.makeSession()
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.stability = min(max(stability, 0), 1)
        self.similarityBoost = min(max(similarityBoost, 0), 1)
        self.timeout = timeout
        self.session = session
    }

    /// Whether a key is present.
    public func isAvailable() async -> Bool {
        VoiceKey.isPresent(apiKey)
    }

    /// The voices in the ElevenLabs workspace.
    ///
    /// The path and the field names are not in the verified set for this
    /// build: they are read from ElevenLabs' voices reference, and a failure
    /// here must not stop a person from typing a voice id they already know.
    public func voices(language: String?) async throws -> [VoiceDescriptor] {
        let key = try VoiceKey.required(apiKey, provider: displayName)
        var request = URLRequest(url: try VoiceEndpoint.validate(baseURL.appendingPathComponent("voices")))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let answer = try await HTTPTransport.send(request, session: session)
        try VoiceHTTP.validate(answer)
        return VoiceCatalogue.select(
            try ElevenLabsVoiceParser.catalogue(in: answer.data),
            language: language
        )
    }
}

/// Parses ElevenLabs' voice list.
public enum ElevenLabsVoiceParser {
    /// Turns a `/v1/voices` answer into descriptors.
    ///
    /// The vendor's fields are read defensively: a missing label must degrade
    /// the description, never fail the list, because a workspace with one
    /// untagged cloned voice would otherwise show no voices at all.
    ///
    /// - Parameter data: the answer body.
    /// - Returns: the voices it holds.
    /// - Throws: ``ProviderError/invalidResponse(_:)`` when the body is not the
    ///   documented shape at all.
    public static func catalogue(in data: Data) throws -> [VoiceDescriptor] {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = payload as? [String: Any]
        else {
            throw ProviderError.invalidResponse("the voice list was not JSON")
        }
        let rows = object["voices"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["voice_id"] as? String, !id.isEmpty else { return nil }
            let labels = row["labels"] as? [String: Any] ?? [:]
            let category = (row["category"] as? String ?? "").lowercased()
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let language = labels["language"] as? String
                ?? (labels["accent"] as? String).map(localeGuess(fromAccent:))
                ?? "multi"
            let detail = labels["description"] as? String
                ?? labels["use_case"] as? String
                ?? (category.isEmpty ? nil : category)
            return VoiceDescriptor(
                providerID: VoiceProviderID.elevenLabs,
                id: id,
                name: name,
                language: language,
                quality: quality(forCategory: category),
                detail: detail
            )
        }
    }

    /// The quality tier a category maps to.
    ///
    /// A cloned or professional voice is a recording of a real speaker, which is
    /// the top of what this vendor sells; a premade voice is the stock tier.
    static func quality(forCategory category: String) -> VoiceDescriptor.QualityTier {
        switch category {
        case "cloned", "professional": .premium
        case "premade", "high_quality": .enhanced
        case "generated": .standard
        default: .unknown
        }
    }

    /// A rough language for an accent label, when no language is given.
    static func localeGuess(fromAccent accent: String) -> String {
        let lowered = accent.lowercased()
        if lowered.contains("british") || lowered.contains("english") { return "en" }
        if lowered.contains("american") { return "en" }
        if lowered.contains("australian") { return "en" }
        if lowered.contains("irish") { return "en" }
        return lowered.isEmpty ? "multi" : lowered
    }
}

// MARK: - The request

extension ElevenLabsVoiceProvider {
    /// The voice settings ElevenLabs applies.
    struct VoiceSettingsPayload: Encodable, Equatable {
        let stability: Double
        let similarity_boost: Double
        let speed: Double
    }

    /// The JSON body of one synthesis request.
    struct SpeechBody: Encodable, Equatable {
        let text: String
        let model_id: String
        let voice_settings: VoiceSettingsPayload
    }

    /// The streaming endpoint of one voice.
    ///
    /// - Parameter voiceID: the voice the request speaks with.
    /// - Returns: the URL, with the output format in the query string.
    func streamURL(voiceID: String) -> URL {
        let endpoint = baseURL
            .appendingPathComponent("text-to-speech")
            .appendingPathComponent(voiceID)
            .appendingPathComponent("stream")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }
        components.queryItems = [
            URLQueryItem(name: "output_format", value: Self.defaultOutputFormat)
        ]
        return components.url ?? endpoint
    }

    /// Builds the body for one sentence.
    ///
    /// - Parameters:
    ///   - text: the sentence to speak.
    ///   - settings: the chosen voice and model.
    /// - Returns: the body that goes on the wire.
    func body(for text: String, settings: VoiceSettings) -> SpeechBody {
        SpeechBody(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            model_id: settings.resolvedModel(fallback: Self.defaultModel),
            voice_settings: VoiceSettingsPayload(
                stability: stability,
                similarity_boost: similarityBoost,
                speed: settings.speed(within: Self.speedRange)
            )
        )
    }

    /// Builds the request for one sentence.
    ///
    /// - Parameters:
    ///   - text: the sentence to speak.
    ///   - settings: the chosen voice and model.
    /// - Returns: the request to send.
    /// - Throws: ``ProviderError`` when there is no key or no voice.
    func request(for text: String, settings: VoiceSettings) throws -> URLRequest {
        let key = try VoiceKey.required(apiKey, provider: displayName)
        guard let voice = settings.resolvedVoiceID(fallback: Self.defaultVoiceID) else {
            throw ProviderError.unavailable("ElevenLabs needs a voice. Choose one in Settings.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.unavailable("There is nothing to speak.") }
        var request = URLRequest(url: try VoiceEndpoint.validate(streamURL(voiceID: voice)))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
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
