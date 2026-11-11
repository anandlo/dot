import Foundation

/// Cartesia's Sonic text-to-speech endpoint (`/tts/bytes`).
///
/// This is the fast cloud path: the vendor publishes about 90 ms of model
/// latency for Sonic 3.x, and `output_format.container: "raw"` returns samples
/// with no container at all, which is exactly what the player schedules. The
/// `Cartesia-Version` header is required and is part of the contract, so it is a
/// named constant rather than a literal in the request.
///
/// The vendor's reference names `APIKeyAuth` and `AccessTokenAuth` but the
/// research set does not quote the header that carries an API key. `X-API-Key`
/// is what Cartesia's own examples send; if the first real request comes back
/// 401, that is the line to check.
public struct CartesiaVoiceProvider: VoiceProvider {
    public let id: String = VoiceProviderID.cartesia
    public let displayName: String = "Cartesia"
    public let requiresCredential: Bool = true
    public let audioFormat: VoiceAudioFormat = .pcm24k

    /// The default endpoint of Cartesia's API.
    public static let defaultBaseURL = URL(string: "https://api.cartesia.ai")!
    /// The API version the request is written against.
    public static let apiVersion = "2026-08-14"
    /// The model Dot asks for when the setting names none.
    public static let defaultModel = "sonic-3.6"
    /// The speed range `generation_config.speed` accepts.
    public static let speedRange = 0.6...1.5
    /// The models Dot offers for this endpoint.
    public static let models: [VoiceModelOption] = VoicePresets.cartesia.models

    /// The endpoint, e.g. `https://api.cartesia.ai`.
    public let baseURL: URL
    /// The API key, when the Keychain has one.
    public let apiKey: String?
    /// The language of the answer.
    public let language: String

    private let session: URLSession
    private let timeout: TimeInterval

    /// Creates a Cartesia voice provider.
    public init(
        baseURL: URL = CartesiaVoiceProvider.defaultBaseURL,
        apiKey: String? = nil,
        language: String = "en",
        timeout: TimeInterval = 60,
        session: URLSession = OpenAICompatibleProvider.makeSession()
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = trimmed.isEmpty ? "en" : trimmed
        self.timeout = timeout
        self.session = session
    }

    /// Whether a key is present.
    public func isAvailable() async -> Bool {
        VoiceKey.isPresent(apiKey)
    }

    /// The voices in the Cartesia workspace.
    ///
    /// The list endpoint's shape is not in the verified set, so the parser
    /// accepts either a bare array or the paginated object the vendor's other
    /// list endpoints use.
    public func voices(language: String?) async throws -> [VoiceDescriptor] {
        let key = try VoiceKey.required(apiKey, provider: displayName)
        let endpoint = baseURL.appendingPathComponent("voices")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ProviderError.invalidResponse("the voice list address is not a URL")
        }
        components.queryItems = [URLQueryItem(name: "limit", value: "100")]
        guard let url = components.url else {
            throw ProviderError.invalidResponse("the voice list address is not a URL")
        }
        var request = URLRequest(url: try VoiceEndpoint.validate(url))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Cartesia-Version")
        let answer = try await HTTPTransport.send(request, session: session)
        try VoiceHTTP.validate(answer)
        return VoiceCatalogue.select(
            try CartesiaVoiceParser.catalogue(in: answer.data),
            language: language
        )
    }
}

/// Parses Cartesia's voice list.
public enum CartesiaVoiceParser {
    /// Turns a `/voices` answer into descriptors.
    ///
    /// - Parameter data: the answer body.
    /// - Returns: the voices it holds.
    /// - Throws: ``ProviderError/invalidResponse(_:)`` when the body is neither
    ///   shape the vendor uses.
    public static func catalogue(in data: Data) throws -> [VoiceDescriptor] {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []) else {
            throw ProviderError.invalidResponse("the voice list was not JSON")
        }
        let rows: [[String: Any]]
        if let array = payload as? [[String: Any]] {
            rows = array
        } else if let object = payload as? [String: Any],
                  let array = object["data"] as? [[String: Any]] {
            rows = array
        } else {
            throw ProviderError.invalidResponse("the voice list had no rows")
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let language = (row["language"] as? String)
                ?? (row["locale"] as? String)
                ?? "multi"
            let detail = (row["description"] as? String)
                ?? (row["gender"] as? String)
                ?? ((row["is_public"] as? Bool) == true ? "Public library voice" : nil)
            return VoiceDescriptor(
                providerID: VoiceProviderID.cartesia,
                id: id,
                name: name,
                language: language,
                quality: (row["is_public"] as? Bool) == true ? .enhanced : .premium,
                detail: detail
            )
        }
    }
}

// MARK: - The request

extension CartesiaVoiceProvider {
    /// The output shape Dot asks for: raw little-endian 16-bit PCM.
    struct OutputFormat: Encodable, Equatable {
        let container: String
        let encoding: String
        let sample_rate: Int
    }

    /// The generation controls Dot sends.
    struct GenerationConfig: Encodable, Equatable {
        let speed: Double
    }

    /// The voice selector.
    struct VoiceSelector: Encodable, Equatable {
        let id: String
    }

    /// The JSON body of one synthesis request.
    struct SpeechBody: Encodable, Equatable {
        let model_id: String
        let transcript: String
        let voice: VoiceSelector
        let language: String
        let output_format: OutputFormat
        let generation_config: GenerationConfig
    }

    /// The `POST /tts/bytes` endpoint.
    public var speechURL: URL {
        baseURL.lastPathComponent == "bytes" ? baseURL : baseURL.appendingPathComponent("tts/bytes")
    }

    /// Builds the body for one sentence.
    ///
    /// `language` and `locale` are mutually exclusive in the vendor's schema and
    /// a request that sets both is refused with a 400, so only `language` is
    /// ever written.
    ///
    /// - Parameters:
    ///   - text: the sentence to speak.
    ///   - settings: the chosen voice and model.
    /// - Returns: the body that goes on the wire.
    func body(for text: String, settings: VoiceSettings) -> SpeechBody {
        SpeechBody(
            model_id: settings.resolvedModel(fallback: Self.defaultModel),
            transcript: text.trimmingCharacters(in: .whitespacesAndNewlines),
            voice: VoiceSelector(id: settings.voiceID ?? ""),
            language: language,
            output_format: OutputFormat(
                container: "raw",
                encoding: VoiceAudioFormat.Encoding.pcm16LittleEndian.rawValue,
                sample_rate: Int(audioFormat.sampleRate)
            ),
            generation_config: GenerationConfig(speed: settings.speed(within: Self.speedRange))
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
        guard let voice = settings.resolvedVoiceID(fallback: nil), !voice.isEmpty else {
            throw ProviderError.unavailable(
                "Cartesia needs a voice. Add one from its catalogue in Settings."
            )
        }
        var resolved = settings
        resolved.voiceID = voice
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.unavailable("There is nothing to speak.") }
        var request = URLRequest(url: try VoiceEndpoint.validate(speechURL))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Cartesia-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/pcm", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body(for: text, settings: resolved))
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
