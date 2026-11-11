import Foundation

/// Deepgram's hosted speech-to-text API (`/v1/listen`).
///
/// Deepgram accepts raw WAV audio (`Content-Type: audio/wav`), authenticates
/// via `Authorization: Token <key>`, configures model/language/formatting via
/// URL query parameters, and returns the transcript at
/// `results.channels[0].alternatives[0].transcript`.
public struct DeepgramProvider: Provider {
    public let id: String = ProviderIdentifier.deepgram
    public let displayName: String = "Deepgram"

    /// The default endpoint of Deepgram's API.
    public static let defaultBaseURL = URL(string: "https://api.deepgram.com/v1")!
    /// The flagship model Dot asks for when the configuration names none.
    public static let defaultModel = "nova-3"

    /// Selectable Deepgram speech-to-text models.
    public static let supportedModels: [(id: String, title: String, detail: String)] = [
        ("nova-3", "Nova-3 (Latest Flagship)", "Highest accuracy, multilingual & keyterm support"),
        ("nova-3-general", "Nova-3 General", "Optimized for everyday conversational speech"),
        ("nova-3-medical", "Nova-3 Medical", "Clinical & medical terminology specialist"),
        ("nova-2", "Nova-2", "Fast, low-latency universal speech model"),
        ("nova-2-meeting", "Nova-2 Meeting", "Multi-speaker meetings & room audio"),
        ("nova-2-phonecall", "Nova-2 Phonecall", "Narrowband & telephony audio"),
        ("nova-2-finance", "Nova-2 Finance", "Financial & earnings terminology"),
        ("nova-2-conversationalai", "Nova-2 Conversational AI", "Voice agents & turn-taking"),
        ("enhanced", "Enhanced", "High-accuracy legacy tier"),
        ("base", "Base", "Standard lightweight tier"),
    ]

    /// The base URL of the service, e.g. `https://api.deepgram.com/v1`.
    public let baseURL: URL
    /// The Deepgram API key, when the Keychain has one.
    public let apiKey: String?
    /// Provider-level Deepgram formatting/filtering options.
    public let smartFormat: Bool
    public let punctuate: Bool
    public let paragraphs: Bool
    public let fillerWords: Bool
    public let profanityFilter: Bool
    public let numerals: Bool
    public let diarize: Bool
    public let keyterms: String?
    /// Whether Zero Data Retention (ZDR) is requested (Model Improvement Program opt-out).
    public let zeroDataRetention: Bool

    /// Deepgram requires an API key.
    public var requiresCredential: Bool { true }
    /// One request carries at most thirty seconds of audio by default.
    public var maxSegmentSeconds: Int { 30 }

    private let session: URLSession
    private let timeout: TimeInterval

    /// Creates a Deepgram provider.
    public init(
        baseURL: URL = DeepgramProvider.defaultBaseURL,
        apiKey: String? = nil,
        smartFormat: Bool = true,
        punctuate: Bool = true,
        paragraphs: Bool = false,
        fillerWords: Bool = false,
        profanityFilter: Bool = false,
        numerals: Bool = false,
        diarize: Bool = false,
        keyterms: String? = nil,
        zeroDataRetention: Bool = true,
        timeout: TimeInterval = 120,
        session: URLSession = OpenAICompatibleProvider.makeSession()
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.smartFormat = smartFormat
        self.punctuate = punctuate
        self.paragraphs = paragraphs
        self.fillerWords = fillerWords
        self.profanityFilter = profanityFilter
        self.numerals = numerals
        self.diarize = diarize
        self.keyterms = keyterms
        self.zeroDataRetention = zeroDataRetention
        self.timeout = timeout
        self.session = session
    }

    /// Builds the `/listen` endpoint URL with query parameters for the given model and language.
    public func listenURL(model: String?, language: String?) -> URL {
        let baseEndpoint = baseURL.lastPathComponent == "listen"
            ? baseURL
            : baseURL.appendingPathComponent("listen")
        guard var components = URLComponents(url: baseEndpoint, resolvingAgainstBaseURL: false) else {
            return baseEndpoint
        }
        let resolvedModel = model.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? Self.defaultModel
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model", value: resolvedModel),
            URLQueryItem(name: "smart_format", value: smartFormat ? "true" : "false"),
            URLQueryItem(name: "punctuate", value: punctuate ? "true" : "false"),
        ]
        if paragraphs {
            items.append(URLQueryItem(name: "paragraphs", value: "true"))
        }
        if fillerWords {
            items.append(URLQueryItem(name: "filler_words", value: "true"))
        }
        if profanityFilter {
            items.append(URLQueryItem(name: "profanity_filter", value: "true"))
        }
        if numerals {
            items.append(URLQueryItem(name: "numerals", value: "true"))
        }
        if diarize {
            items.append(URLQueryItem(name: "diarize", value: "true"))
        }
        if zeroDataRetention {
            items.append(URLQueryItem(name: "mip_opt_out", value: "true"))
        }
        let trimmedLang = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLang.isEmpty, trimmedLang.lowercased() != "auto" {
            items.append(URLQueryItem(name: "language", value: Self.normalizedLanguage(trimmedLang)))
        } else {
            items.append(URLQueryItem(name: "detect_language", value: "true"))
        }
        if let keyterms, !keyterms.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let paramName = resolvedModel.lowercased().hasPrefix("nova-3") ? "keyterm" : "keywords"
            let terms = keyterms
                .split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for term in terms {
                items.append(URLQueryItem(name: paramName, value: term))
            }
        }
        components.queryItems = (components.queryItems ?? []) + items
        return components.url ?? baseEndpoint
    }

    private static func normalizedLanguage(_ tag: String) -> String {
        let cleaned = tag.replacingOccurrences(of: "_", with: "-")
        if cleaned.lowercased().hasPrefix("zh") { return "zh" }
        if cleaned.lowercased().hasPrefix("en") { return "en" }
        return cleaned
    }

    public func isAvailable() async -> Bool {
        apiKey?.isEmpty == false
    }

    public func transcribe(wav: Data, model: String?, language: String?) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else {
            throw ProviderError.missingCredential("No API key is set for this service. Add one in Settings.")
        }

        let url = listenURL(model: model, language: language)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        request.httpBody = wav

        let answer = try await HTTPTransport.send(request, session: session)
        let data = answer.data
        let response = answer.response

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("no HTTP status")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.rejected(
                status: http.statusCode,
                message: Self.errorMessage(in: data)
            )
        }

        let text = try Self.transcript(in: data)
        guard !text.isEmpty else {
            throw ProviderError.noSpeech
        }
        return text
    }

    // MARK: - Response parsing

    static func transcript(in data: Data) throws -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = payload as? [String: Any]
        else {
            throw ProviderError.invalidResponse("not JSON")
        }
        if let results = object["results"] as? [String: Any],
           let channels = results["channels"] as? [[String: Any]],
           let firstChannel = channels.first,
           let alternatives = firstChannel["alternatives"] as? [[String: Any]],
           let firstAlt = alternatives.first {
            if let paragraphsObj = firstAlt["paragraphs"] as? [String: Any],
               let paraTranscript = paragraphsObj["transcript"] as? String,
               !paraTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return paraTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let transcript = firstAlt["transcript"] as? String {
                return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let text = object["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw ProviderError.invalidResponse("no transcript in the answer")
    }

    static func errorMessage(in data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = payload as? [String: Any]
        else { return nil }
        if let errMsg = object["err_msg"] as? String, !errMsg.isEmpty {
            return ProviderErrorText.sanitized(errMsg)
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return ProviderErrorText.sanitized(message)
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return ProviderErrorText.sanitized(message)
        }
        return nil
    }
}
