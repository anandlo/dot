import Foundation

/// Any service that speaks OpenAI's speech-to-text shape.
///
/// One implementation covers a lot of services: the hosted OpenAI API, Groq,
/// Together, a local `whisper.cpp` server, LM Studio and Ollama all answer
/// `POST {baseURL}/audio/transcriptions` with a multipart body that carries
/// the audio in a `file` part.
///
/// This is what makes Dot provider-agnostic in practice: adding a backend is
/// a matter of pointing the base URL at it.
public struct OpenAICompatibleProvider: Provider {
    public let id: String
    public let displayName: String = "OpenAI-compatible"

    /// The endpoint of the hosted OpenAI API.
    ///
    /// It is the reference shape this provider implements, and the default the
    /// OpenAI row and a fresh configuration both read.
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!

    /// The base URL of the service, e.g. `https://api.openai.com/v1`.
    public let baseURL: URL
    /// The API key, when the service needs one.
    public let apiKey: String?
    /// The header the key travels in.
    public let authStyle: AuthStyle
    /// Optional sampling temperature (0.0 to 1.0).
    public let temperature: Double?
    /// Optional context / prompt hint for vocabulary or dictation style.
    public let prompt: String?
    /// Optional response format, e.g. "json", "verbose_json", "text".
    public let responseFormat: String?
    /// Optional timestamp granularity ("word", "segment", "both") when response_format is "verbose_json".
    public let timestampsGranularity: String?
    /// Whether Zero Data Retention (ZDR) is requested.
    public let zeroDataRetention: Bool

    /// The provider can use an API key.
    public var requiresCredential: Bool { true }

    private let session: URLSession
    private let timeout: TimeInterval

    /// Creates the provider.
    ///
    /// - Parameters:
    ///   - id: the provider id the configuration selects. An endpoint that was
    ///     written by an earlier build keeps showing the id it was stored
    ///     under, so the configuration, the row and the provider agree.
    ///   - baseURL: the base URL of the service, without the trailing path.
    ///   - apiKey: the API key, when the service needs one.
    ///   - authStyle: the header the key travels in.
    ///   - temperature: optional sampling temperature.
    ///   - prompt: optional context / guide text.
    ///   - responseFormat: optional response format.
    ///   - timestampsGranularity: optional timestamp granularity.
    ///   - timeout: how long one request may take.
    public init(
        id: String = ProviderIdentifier.openAI,
        baseURL: URL,
        apiKey: String? = nil,
        authStyle: AuthStyle = .bearer,
        temperature: Double? = nil,
        prompt: String? = nil,
        responseFormat: String? = nil,
        timestampsGranularity: String? = nil,
        zeroDataRetention: Bool = true,
        timeout: TimeInterval = 120,
        session: URLSession = OpenAICompatibleProvider.makeSession()
    ) {
        self.id = id
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.authStyle = authStyle
        self.temperature = temperature
        self.prompt = prompt
        self.responseFormat = responseFormat
        self.timestampsGranularity = timestampsGranularity
        self.zeroDataRetention = zeroDataRetention
        self.timeout = timeout
        self.session = session
    }

    /// The default session: no caching, no cookies.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }

    /// The URL a transcription is posted to.
    public var transcriptionURL: URL {
        baseURL.appendingPathComponent("audio/transcriptions")
    }

    /// The URL the model list is read from.
    public var modelsURL: URL {
        baseURL.appendingPathComponent("models")
    }

    /// Whether the service is reachable and, when it needs a key, whether the
    /// key is there.
    public func isAvailable() async -> Bool {
        if apiKey?.isEmpty == false { return true }
        guard let host = baseURL.host, Self.isLoopback(host) else { return false }
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 5
        if let apiKey, !apiKey.isEmpty {
            request.setValue(authStyle.value(for: apiKey), forHTTPHeaderField: authStyle.header)
        }
        guard let answer = try? await HTTPTransport.send(request, session: session),
              let http = answer.response as? HTTPURLResponse
        else { return false }
        return (200..<300).contains(http.statusCode)
    }

    public func transcribe(wav: Data, model: String?, language: String?) async throws -> String {
        let boundary = "dot-\(UUID().uuidString)"
        var body = Data()
        if let model, !model.isEmpty {
            body.appendMultipartField(name: "model", value: model, boundary: boundary)
        }
        if let language, !language.isEmpty {
            body.appendMultipartField(name: "language", value: language, boundary: boundary)
        }
        if let responseFormat = responseFormat?.trimmingCharacters(in: .whitespacesAndNewlines), !responseFormat.isEmpty {
            body.appendMultipartField(name: "response_format", value: responseFormat, boundary: boundary)
        }
        if let temperature {
            body.appendMultipartField(name: "temperature", value: String(format: "%.2f", temperature), boundary: boundary)
        }
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            body.appendMultipartField(name: "prompt", value: prompt, boundary: boundary)
        }
        if responseFormat == "verbose_json", let gran = timestampsGranularity?.trimmingCharacters(in: .whitespacesAndNewlines), !gran.isEmpty {
            switch gran {
            case "word":
                body.appendMultipartField(name: "timestamp_granularities[]", value: "word", boundary: boundary)
            case "segment":
                body.appendMultipartField(name: "timestamp_granularities[]", value: "segment", boundary: boundary)
            case "both":
                body.appendMultipartField(name: "timestamp_granularities[]", value: "word", boundary: boundary)
                body.appendMultipartField(name: "timestamp_granularities[]", value: "segment", boundary: boundary)
            default:
                body.appendMultipartField(name: "timestamp_granularities[]", value: gran, boundary: boundary)
            }
        }
        body.appendMultipartFile(
            name: "file",
            filename: "audio.wav",
            contentType: "audio/wav",
            data: wav,
            boundary: boundary
        )
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        if let apiKey, !apiKey.isEmpty {
            request.setValue(authStyle.value(for: apiKey), forHTTPHeaderField: authStyle.header)
        }
        request.timeoutInterval = timeout
        request.httpBody = body

        let answer = try await HTTPTransport.send(request, session: session)
        let data = answer.data
        let response = answer.response
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("no HTTP status")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.rejected(status: http.statusCode, message: Self.errorMessage(in: data))
        }
        let text = try Self.transcript(in: data)
        guard !text.isEmpty else {
            throw ProviderError.noSpeech
        }
        return text
    }

    // MARK: - Internals

    /// Whether a host name is the local machine.
    ///
    /// The rule lives in ``EndpointPolicy``, so the address Dot accepts and the
    /// address this provider probes cannot disagree.
    static func isLoopback(_ host: String) -> Bool {
        EndpointPolicy.isLoopback(host)
    }

    /// The transcript in a successful answer.
    ///
    /// The OpenAI shape is `{"text": "..."}`. The other shape, which some
    /// self-hosted servers answer with, is `{"transcript": "..."}`. A service
    /// that answers with plain text is taken at its word.
    static func transcript(in data: Data) throws -> String {
        if let payload = try? JSONSerialization.jsonObject(with: data, options: []),
           let object = payload as? [String: Any] {
            if let text = object["text"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let transcript = object["transcript"] as? String {
                return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            throw ProviderError.invalidResponse("no text in the answer")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProviderError.invalidResponse("the answer is not text")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The message in a failed answer.
    ///
    /// The OpenAI shape is `{"error": {"message": "..."}}`; the Hex shape is
    /// `{"message": "..."}`.
    static func errorMessage(in data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = payload as? [String: Any]
        else { return nil }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return ProviderErrorText.sanitized(message)
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return ProviderErrorText.sanitized(message)
        }
        return nil
    }
}

extension Data {
    /// Appends a text field to a multipart body.
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }

    /// Appends a file part to a multipart body.
    mutating func appendMultipartFile(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String
    ) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8
        ))
        append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        append(data)
        append(Data("\r\n".utf8))
    }
}
