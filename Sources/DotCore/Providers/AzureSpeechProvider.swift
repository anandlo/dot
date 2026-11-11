import Foundation

/// Microsoft Azure Cognitive Services Speech-to-Text API.
///
/// Azure accepts raw 16 kHz 16-bit mono WAV audio (`Content-Type: audio/wav; codecs=audio/pcm; samplerate=16000`),
/// authenticates via `Ocp-Apim-Subscription-Key`, configures language, format, and profanity filtering via query
/// parameters, and returns transcripts in simple or detailed JSON structures.
///
/// By default every request carries `storeAudio=false`, which asks the service
/// not to keep the audio. It is a request in the query string, not a guarantee:
/// what the service does with the audio is governed by its own retention policy.
public struct AzureSpeechProvider: Provider {
    public let id: String = ProviderIdentifier.azure
    public let displayName: String = "Azure Speech"

    /// Default region for Azure Speech service.
    public static let defaultRegion = "eastus"
    /// The endpoint of one region and recognition mode.
    ///
    /// Every request URL and the endpoint a preset advertises are built here, so
    /// the host and the path cannot disagree between the two.
    ///
    /// - Parameters:
    ///   - region: the datacenter region, e.g. `eastus`.
    ///   - mode: the recognition mode, e.g. `conversation`.
    /// - Returns: the REST endpoint, without query parameters.
    public static func endpointURL(region: String, mode: String) -> URL {
        URL(string: "https://\(region).stt.speech.microsoft.com/speech/recognition/\(mode)/cognitiveservices/v1")!
    }
    /// Default recognition mode for conversational dialogue.
    public static let defaultRecognitionMode = "conversation"
    /// The endpoint Dot ships: the default region in conversation mode.
    public static let defaultBaseURL = endpointURL(
        region: defaultRegion,
        mode: defaultRecognitionMode
    )
    /// Default profanity filtering mode: masked with asterisks.
    public static let defaultProfanityFilter = "masked"
    /// Default output format: detailed with capitalization and punctuation.
    public static let defaultOutputFormat = "detailed"

    /// Supported Azure Speech regions with user-friendly descriptions.
    public static let supportedRegions: [(id: String, title: String)] = [
        ("eastus", "East US (Virginia)"),
        ("eastus2", "East US 2 (Virginia)"),
        ("westus", "West US (California)"),
        ("westus2", "West US 2 (Washington)"),
        ("westus3", "West US 3 (Phoenix)"),
        ("centralus", "Central US (Iowa)"),
        ("northcentralus", "North Central US (Illinois)"),
        ("southcentralus", "South Central US (Texas)"),
        ("westeurope", "West Europe (Netherlands)"),
        ("northeurope", "North Europe (Ireland)"),
        ("eastasia", "East Asia (Hong Kong)"),
        ("southeastasia", "Southeast Asia (Singapore)"),
        ("japaneast", "Japan East (Tokyo)"),
        ("japanwest", "Japan West (Osaka)"),
        ("australiaeast", "Australia East (Sydney)"),
        ("centralindia", "Central India (Pune)"),
        ("uksouth", "UK South (London)"),
        ("canadacentral", "Canada Central (Toronto)"),
        ("brazilsouth", "Brazil South (São Paulo)"),
    ]

    /// Supported recognition modes.
    public static let supportedModes: [(id: String, title: String, detail: String)] = [
        ("conversation", "Conversation", "Multi-turn natural dialogue with pause tolerance"),
        ("dictation", "Dictation", "Continuous dictation and long-form speech"),
        ("interactive", "Interactive", "Short queries and fast command execution"),
    ]

    /// Supported profanity filtering modes.
    public static let supportedProfanityModes: [(id: String, title: String, detail: String)] = [
        ("masked", "Masked (***)", "Replace profane words with asterisks"),
        ("removed", "Removed", "Remove profane words completely from the transcript"),
        ("raw", "Raw", "Preserve words exactly as spoken without filtering"),
    ]

    /// Supported output formats.
    public static let supportedOutputFormats: [(id: String, title: String, detail: String)] = [
        ("detailed", "Detailed", "Includes casing, punctuation, and high-confidence display text"),
        ("simple", "Simple", "Standard recognized text output"),
    ]

    /// The base URL of the service, or `nil` to construct dynamically from region and mode.
    public let baseURL: URL?
    /// The Azure datacenter region (e.g. `eastus`, `westeurope`).
    public let region: String
    /// The recognition mode (`conversation`, `dictation`, `interactive`).
    public let recognitionMode: String
    /// Profanity filter mode (`masked`, `removed`, `raw`).
    public let profanityFilter: String
    /// Output format (`detailed`, `simple`).
    public let outputFormat: String
    /// Whether Azure is permitted to store audio (`storeAudio=true/false`).
    public let storeAudio: Bool?
    /// Whether Zero Data Retention (ZDR) is requested.
    public let zeroDataRetention: Bool
    /// The Azure subscription key.
    public let apiKey: String?

    /// Azure requires a subscription key.
    public var requiresCredential: Bool { true }
    /// Azure Speech REST accepts up to 60 seconds of audio per request.
    public var maxSegmentSeconds: Int { 60 }

    private let session: URLSession
    private let timeout: TimeInterval

    /// Creates an Azure Speech provider.
    public init(
        baseURL: URL? = nil,
        region: String = AzureSpeechProvider.defaultRegion,
        recognitionMode: String = AzureSpeechProvider.defaultRecognitionMode,
        profanityFilter: String = AzureSpeechProvider.defaultProfanityFilter,
        outputFormat: String = AzureSpeechProvider.defaultOutputFormat,
        storeAudio: Bool? = nil,
        zeroDataRetention: Bool = true,
        apiKey: String? = nil,
        timeout: TimeInterval = 120,
        session: URLSession = OpenAICompatibleProvider.makeSession()
    ) {
        self.baseURL = baseURL
        self.region = region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AzureSpeechProvider.defaultRegion
            : region.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recognitionMode = recognitionMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AzureSpeechProvider.defaultRecognitionMode
            : recognitionMode.trimmingCharacters(in: .whitespacesAndNewlines)
        self.profanityFilter = profanityFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AzureSpeechProvider.defaultProfanityFilter
            : profanityFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        self.outputFormat = outputFormat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AzureSpeechProvider.defaultOutputFormat
            : outputFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        self.storeAudio = storeAudio
        self.zeroDataRetention = zeroDataRetention
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session
    }

    /// Whether the service is ready: an API key must be provided.
    public func isAvailable() async -> Bool {
        apiKey?.isEmpty == false
    }

    /// Builds the endpoint URL for Azure Speech REST API.
    ///
    /// A stored endpoint keeps the query parameters it already carries; the one
    /// built from the region gets the configured ones. Either way the request
    /// carries `storeAudio=false` unless the configuration asked otherwise.
    ///
    /// - Parameter language: the language the request is recognised in.
    /// - Returns: the URL to post the audio to.
    public func endpointURL(language: String?) -> URL {
        let base = baseURL ?? Self.endpointURL(region: region, mode: recognitionMode)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "language" }) {
            items.append(URLQueryItem(name: "language", value: Self.normalizedLanguage(language)))
        }
        if !items.contains(where: { $0.name == "format" }) {
            items.append(URLQueryItem(name: "format", value: outputFormat))
        }
        if !items.contains(where: { $0.name == "profanity" }) {
            items.append(URLQueryItem(name: "profanity", value: profanityFilter))
        }
        if let store = storeAudio ?? (zeroDataRetention ? false : nil),
           !items.contains(where: { $0.name == "storeAudio" }) {
            items.append(URLQueryItem(name: "storeAudio", value: store ? "true" : "false"))
        }
        components.queryItems = items
        return components.url ?? base
    }

    /// Builds the `URLRequest` to post audio to Azure Speech.
    public func buildRequest(
        apiKey: String,
        wav: Data,
        language: String?
    ) -> URLRequest {
        let url = endpointURL(language: language)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("audio/wav; codecs=audio/pcm; samplerate=16000", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.timeoutInterval = timeout
        request.httpBody = wav
        return request
    }

    /// Transcribes audio via Azure Speech.
    public func transcribe(wav: Data, model: String?, language: String?) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else {
            throw ProviderError.rejected(status: 401, message: "Azure Speech requires an API key.")
        }

        let request = buildRequest(apiKey: apiKey, wav: wav, language: language)

        let answer = try await HTTPTransport.send(request, session: session)
        let data = answer.data
        let response = answer.response

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("no HTTP status")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.errorMessage(in: data) ?? "HTTP \(http.statusCode)"
            throw ProviderError.rejected(status: http.statusCode, message: message)
        }

        let text = try Self.transcript(in: data)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderError.noSpeech
        }
        return trimmed
    }

    /// Parses the transcript text from Azure Speech response JSON.
    public static func transcript(in data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse("Azure returned non-JSON data")
        }

        let status = (json["RecognitionStatus"] as? String) ?? ""
        switch status {
        case "Success":
            if let nbest = json["NBest"] as? [[String: Any]],
               let first = nbest.first,
               let display = first["Display"] as? String,
               !display.isEmpty {
                return display
            }
            if let display = json["DisplayText"] as? String, !display.isEmpty {
                return display
            }
            throw ProviderError.noSpeech
        case "NoMatch", "InitialSilenceTimeout", "BabbleTimeout":
            throw ProviderError.noSpeech
        default:
            let message = (json["DisplayText"] as? String)
                ?? (json["error"] as? [String: Any])?["message"] as? String
                ?? "Azure recognition status: \(status)"
            throw ProviderError.rejected(status: 200, message: message)
        }
    }

    /// Normalizes language tags to Azure BCP-47 locale format (e.g. `en-US`, `zh-CN`).
    public static func normalizedLanguage(_ language: String?) -> String {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !language.isEmpty,
              language.lowercased() != "auto"
        else {
            return "en-US"
        }
        let tag = language.replacingOccurrences(of: "_", with: "-")
        if tag.contains("-") { return tag }
        switch tag.lowercased() {
        case "en": return "en-US"
        case "zh": return "zh-CN"
        case "es": return "es-ES"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "ja": return "ja-JP"
        case "it": return "it-IT"
        case "ko": return "ko-KR"
        case "pt": return "pt-BR"
        case "ru": return "ru-RU"
        case "nl": return "nl-NL"
        case "pl": return "pl-PL"
        case "tr": return "tr-TR"
        case "sv": return "sv-SE"
        case "da": return "da-DK"
        case "fi": return "fi-FI"
        case "nb", "no": return "nb-NO"
        case "ar": return "ar-SA"
        case "hi": return "hi-IN"
        default: return "\(tag)-\(tag.uppercased())"
        }
    }

    /// Extracts an error message from an Azure error response.
    public static func errorMessage(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // A proxy or a captive portal answers with a page, not a message:
            // the head of it is the only part that can be read.
            return ProviderErrorText.sanitized(String(data: data, encoding: .utf8))
        }
        if let message = (json["error"] as? [String: Any])?["message"] as? String {
            return ProviderErrorText.sanitized(message)
        }
        if let message = json["message"] as? String {
            return ProviderErrorText.sanitized(message)
        }
        if let message = json["DisplayText"] as? String {
            return ProviderErrorText.sanitized(message)
        }
        return nil
    }
}
