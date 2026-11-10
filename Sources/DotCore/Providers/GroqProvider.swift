import Foundation

/// Groq ultra-fast speech-to-text API provider.
///
/// Groq hosts OpenAI-compatible Whisper models on its LPU hardware for near-instant
/// transcription latency. Calls `POST {baseURL}/audio/transcriptions`.
public struct GroqProvider: Provider {
    public let id: String = ProviderIdentifier.groq
    public let displayName: String = "Groq"

    public static let defaultBaseURL = URL(string: "https://api.groq.com/openai/v1")!
    public static let defaultModel = "whisper-large-v3-turbo"

    public struct SupportedModel: Sendable {
        public let id: String
        public let title: String
        public let detail: String

        public init(id: String, title: String, detail: String) {
            self.id = id
            self.title = title
            self.detail = detail
        }
    }

    public static let supportedModels: [SupportedModel] = [
        SupportedModel(
            id: "whisper-large-v3-turbo",
            title: "Whisper Large V3 Turbo",
            detail: "Fastest multilingual transcription optimized for real-time dictation"
        ),
        SupportedModel(
            id: "whisper-large-v3",
            title: "Whisper Large V3",
            detail: "Flagship high-accuracy multilingual speech recognition"
        ),
        SupportedModel(
            id: "distil-whisper-large-v3-en",
            title: "Distil-Whisper Large V3 (EN)",
            detail: "English-only ultra-low latency transcription"
        ),
    ]

    public let baseURL: URL
    public let apiKey: String?
    public let temperature: Double?
    public let prompt: String?
    public let responseFormat: String
    public let timestampsGranularity: String?
    public let zeroDataRetention: Bool
    public let timeout: TimeInterval
    private let session: URLSession

    public var requiresCredential: Bool { true }
    public var maxSegmentSeconds: Int { 120 }

    public init(
        baseURL: URL = defaultBaseURL,
        apiKey: String? = nil,
        temperature: Double? = nil,
        prompt: String? = nil,
        responseFormat: String = "json",
        timestampsGranularity: String? = nil,
        zeroDataRetention: Bool = true,
        timeout: TimeInterval = 60,
        session: URLSession = GroqProvider.makeSession()
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.temperature = temperature
        self.prompt = prompt
        self.responseFormat = responseFormat
        self.timestampsGranularity = timestampsGranularity
        self.zeroDataRetention = zeroDataRetention
        self.timeout = timeout
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }

    public var transcriptionURL: URL {
        baseURL.appendingPathComponent("audio/transcriptions")
    }

    public var modelsURL: URL {
        baseURL.appendingPathComponent("models")
    }

    public func isAvailable() async -> Bool {
        guard let apiKey, !apiKey.isEmpty else { return false }
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 6
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return (200..<300).contains(http.statusCode)
    }

    public func buildRequest(wav: Data, model: String?, language: String?) throws -> URLRequest {
        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw ProviderError.missingCredential("Groq requires an API key in Keychain.")
        }

        let boundary = "groq-\(UUID().uuidString)"
        var body = Data()

        let chosenModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        body.appendMultipartField(name: "model", value: (chosenModel?.isEmpty == false) ? chosenModel! : Self.defaultModel, boundary: boundary)

        if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            body.appendMultipartField(name: "language", value: language, boundary: boundary)
        }

        let chosenFormat = responseFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chosenFormat.isEmpty {
            body.appendMultipartField(name: "response_format", value: chosenFormat, boundary: boundary)
        }

        if chosenFormat == "verbose_json", let gran = timestampsGranularity?.trimmingCharacters(in: .whitespacesAndNewlines), !gran.isEmpty {
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

        if let temperature {
            body.appendMultipartField(name: "temperature", value: String(format: "%.2f", temperature), boundary: boundary)
        }

        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            body.appendMultipartField(name: "prompt", value: prompt, boundary: boundary)
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
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        request.httpBody = body
        return request
    }

    public func transcribe(wav: Data, model: String?, language: String?) async throws -> String {
        let request = try buildRequest(wav: wav, model: model, language: language)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ProviderError.transport(error.localizedDescription)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("No HTTP response received from Groq.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.errorMessage(in: data)
            if http.statusCode == 401 {
                throw ProviderError.rejected(status: 401, message: "Groq API key is invalid or expired. Check your key in Settings.")
            } else if http.statusCode == 429 {
                throw ProviderError.rejected(status: 429, message: "Groq rate limit exceeded. Please wait a moment.")
            }
            throw ProviderError.rejected(status: http.statusCode, message: message)
        }

        let text = try Self.transcript(in: data, format: responseFormat)
        guard !text.isEmpty else {
            throw ProviderError.noSpeech
        }
        return text
    }

    public static func transcript(in data: Data, format: String = "json") throws -> String {
        if format == "text" {
            guard let text = String(data: data, encoding: .utf8) else {
                throw ProviderError.invalidResponse("Could not decode text response as UTF-8.")
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = json["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let transcript = json["transcript"] as? String {
                return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        throw ProviderError.invalidResponse("No transcript text returned in Groq response.")
    }

    public static func errorMessage(in data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorObj = json["error"] as? [String: Any],
               let message = errorObj["message"] as? String, !message.isEmpty {
                return message
            }
            if let message = json["message"] as? String, !message.isEmpty {
                return message
            }
        }
        return String(data: data, encoding: .utf8) ?? "Unknown Groq error"
    }
}
