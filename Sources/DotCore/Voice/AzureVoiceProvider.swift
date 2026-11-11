import Foundation

/// Azure Speech neural text-to-speech on the regional endpoint.
///
/// Azure takes SSML, not text, which is an advantage rather than a chore: the
/// rate control is a real `<prosody>` element rather than a black-box
/// instruction, and the answer can be shaped without a second request. The
/// output format Dot asks for is `raw-24khz-16bit-mono-pcm`, one of the formats
/// the REST reference lists, so the audio needs neither a container nor a
/// decoder.
///
/// The key is the same Speech resource key Azure dictation uses, under the same
/// vendor id, so one entry in the Keychain serves both directions.
public struct AzureVoiceProvider: VoiceProvider {
    public let id: String = VoiceProviderID.azure
    public let displayName: String = "Azure Speech"
    public let requiresCredential: Bool = true
    public let audioFormat: VoiceAudioFormat = .pcm24k

    /// The region Dot asks for when none is configured.
    public static let defaultRegion = "eastus"
    /// The voice Dot asks for when the setting names none.
    public static let defaultVoiceID = "en-US-JennyNeural"
    /// The output format the request names in `X-Microsoft-OutputFormat`.
    public static let outputFormat = "raw-24khz-16bit-mono-pcm"
    /// The speed range Dot maps onto SSML `prosody` percentages.
    public static let speedRange = 0.5...2.0

    /// The speech endpoint of one region.
    ///
    /// - Parameter region: the datacenter region, e.g. `westeurope`.
    /// - Returns: the REST endpoint, without query parameters.
    public static func endpointURL(region: String) -> URL {
        let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? defaultRegion : trimmed
        return URL(string: "https://\(resolved).tts.speech.microsoft.com/cognitiveservices/v1")!
    }

    /// The voice list endpoint of one region.
    ///
    /// The regional path is not in the verified set: it is the endpoint Azure's
    /// own samples use, and a failure to reach it only costs the picker its
    /// suggestions, never the ability to speak.
    ///
    /// - Parameter region: the datacenter region.
    /// - Returns: the list endpoint.
    public static func voicesURL(region: String) -> URL {
        let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? defaultRegion : trimmed
        return URL(string: "https://\(resolved).tts.speech.microsoft.com/cognitiveservices/voices/list")!
    }

    /// The region the request goes to.
    public let region: String
    /// The endpoint, when a test or a proxy overrides the regional one.
    public let baseURL: URL?
    /// The subscription key, when the Keychain has one.
    public let apiKey: String?

    private let session: URLSession
    private let timeout: TimeInterval

    /// Creates an Azure voice provider.
    public init(
        region: String = AzureVoiceProvider.defaultRegion,
        baseURL: URL? = nil,
        apiKey: String? = nil,
        timeout: TimeInterval = 60,
        session: URLSession = OpenAICompatibleProvider.makeSession()
    ) {
        let trimmed = region.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = trimmed.isEmpty ? Self.defaultRegion : trimmed
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session
    }

    /// Whether a key is present.
    public func isAvailable() async -> Bool {
        VoiceKey.isPresent(apiKey)
    }

    /// The endpoint the request goes to.
    public var speechURL: URL {
        baseURL ?? Self.endpointURL(region: region)
    }

    /// The neural voices of the region.
    public func voices(language: String?) async throws -> [VoiceDescriptor] {
        let key = try VoiceKey.required(apiKey, provider: displayName)
        let url = baseURL.map { $0.deletingLastPathComponent().appendingPathComponent("voices/list") }
            ?? Self.voicesURL(region: region)
        var request = URLRequest(url: try VoiceEndpoint.validate(url))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("Dot", forHTTPHeaderField: "User-Agent")
        let answer = try await HTTPTransport.send(request, session: session)
        try VoiceHTTP.validate(answer)
        return VoiceCatalogue.select(
            try AzureVoiceParser.catalogue(in: answer.data),
            language: language
        )
    }
}

/// Parses Azure's voice list.
public enum AzureVoiceParser {
    /// Turns a `voices/list` answer into descriptors.
    ///
    /// - Parameter data: the answer body.
    /// - Returns: the voices it holds, neural only.
    /// - Throws: ``ProviderError/invalidResponse(_:)`` when the body is not a
    ///   list of voices.
    public static func catalogue(in data: Data) throws -> [VoiceDescriptor] {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []),
              let rows = payload as? [[String: Any]]
        else {
            throw ProviderError.invalidResponse("the voice list was not JSON")
        }
        return rows.compactMap { row in
            guard let id = row["ShortName"] as? String, !id.isEmpty else { return nil }
            let type = (row["VoiceType"] as? String ?? "").lowercased()
            guard type == "neural" else { return nil }
            let name = (row["DisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            let language = row["Locale"] as? String ?? languagePrefix(of: id)
            let styles = (row["StyleList"] as? [String])?.prefix(3).joined(separator: ", ")
            let detail = styles.flatMap { $0.isEmpty ? nil : "Styles: \($0)" } ?? row["Gender"] as? String
            return VoiceDescriptor(
                providerID: VoiceProviderID.azure,
                id: id,
                name: name,
                language: language,
                quality: quality(ofVoiceID: id),
                detail: detail
            )
        }
    }

    /// The quality tier of a voice id.
    ///
    /// Azure marks its higher-fidelity voices in the name; everything else that
    /// is neural is the enhanced tier.
    static func quality(ofVoiceID id: String) -> VoiceDescriptor.QualityTier {
        id.lowercased().contains("hd") ? .premium : .enhanced
    }

    /// The locale a voice id starts with, e.g. `en-US` in `en-US-JennyNeural`.
    static func languagePrefix(of id: String) -> String {
        let parts = id.split(separator: "-")
        guard parts.count >= 2 else { return "multi" }
        return "\(parts[0])-\(parts[1])"
    }
}

// MARK: - SSML and the request

extension AzureVoiceProvider {
    /// Builds the SSML body for one sentence.
    ///
    /// The document names the voice, the language the voice speaks and the rate;
    /// the sentence is escaped, because a `<` in an answer is text and not
    /// markup. The rate is a percentage relative to the voice's own pace, which
    /// is the only unit Azure accepts in `<prosody>`.
    ///
    /// - Parameters:
    ///   - text: the sentence to speak.
    ///   - settings: the chosen voice and speed.
    /// - Returns: the SSML document.
    public static func ssml(text: String, settings: VoiceSettings) -> String {
        let voice = settings.resolvedVoiceID(fallback: defaultVoiceID) ?? defaultVoiceID
        let language = AzureVoiceParser.languagePrefix(of: voice)
        let rate = Int(((settings.speed(within: speedRange) - 1) * 100).rounded())
        let signedRate = rate >= 0 ? "+\(rate)%" : "\(rate)%"
        return """
        <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" \
        xmlns:mstts="http://www.w3.org/2001/mstts" xml:lang="\(language)">\
        <voice name="\(escape(voice))"><prosody rate="\(signedRate)">\
        \(escape(text.trimmingCharacters(in: .whitespacesAndNewlines)))\
        </prosody></voice></speak>
        """
    }

    /// Builds the request for one sentence.
    ///
    /// - Parameters:
    ///   - text: the sentence to speak.
    ///   - settings: the chosen voice and speed.
    /// - Returns: the request to send.
    /// - Throws: ``ProviderError`` when there is no key or the text is empty.
    func request(for text: String, settings: VoiceSettings) throws -> URLRequest {
        let key = try VoiceKey.required(apiKey, provider: displayName)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.unavailable("There is nothing to speak.") }
        var request = URLRequest(url: try VoiceEndpoint.validate(speechURL))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.outputFormat, forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("Dot", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(Self.ssml(text: text, settings: settings).utf8)
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

    /// Escapes text for an XML text node or attribute value.
    ///
    /// - Parameter text: the text to escape.
    /// - Returns: the text with the five XML entities replaced, in one pass so a
    ///   replacement cannot be escaped twice.
    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
