import Foundation

/// Xiaomi's hosted MiMo speech-to-text model.
///
/// MiMo is not an OpenAI transcription endpoint: it is a chat-completion
/// endpoint that takes the audio as an `input_audio` part and answers with the
/// transcript in `choices[0].message.content`. The key travels in the
/// `api-key` header, which is the spelling the service documents.
///
/// The picker does not offer this provider any more: a configuration written by
/// an earlier build selects it, and the picker presents that configuration as a
/// custom endpoint named by the URL it points at. The provider is only built
/// while the stored URL is still this service's; an endpoint that was pointed
/// somewhere else is built as a generic one.
public struct XiaomiASRProvider: Provider {
    public let id: String = ProviderIdentifier.xiaomi
    public let displayName: String = "Xiaomi ASR"

    /// The default endpoint of the hosted model.
    public static let defaultBaseURL = URL(string: "https://api.xiaomimimo.com/v1")!
    /// The model Dot asks for when the configuration names none.
    public static let defaultModel = "mimo-v2.5-asr"

    /// The base URL of the service, e.g. `https://api.xiaomimimo.com/v1`.
    public let baseURL: URL
    /// The API key, when the Keychain has one.
    public let apiKey: String?

    /// The provider needs a key to be used.
    public var requiresCredential: Bool { true }
    /// One request carries at most thirty seconds of audio.
    public var maxSegmentSeconds: Int { 30 }

    private let session: URLSession
    private let timeout: TimeInterval
    /// The Mac's own language, used when the person did not choose one.
    private let systemLanguage: String?

    /// Creates the provider.
    ///
    /// - Parameters:
    ///   - baseURL: the base URL of the API, without `/chat/completions`.
    ///   - apiKey: the Xiaomi API key.
    ///   - timeout: how long one request may take.
    ///   - session: the session the request is made with.
    public init(
        baseURL: URL = XiaomiASRProvider.defaultBaseURL,
        apiKey: String? = nil,
        timeout: TimeInterval = 120,
        session: URLSession = OpenAICompatibleProvider.makeSession(),
        systemLanguage: String? = Locale.preferredLanguages.first
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session
        self.systemLanguage = systemLanguage
    }

    /// The URL a transcription is posted to.
    public var transcriptionURL: URL {
        baseURL.appendingPathComponent("chat/completions")
    }

    /// Whether a key is configured.
    ///
    /// The hosted model has nothing to download and no local state, so the key
    /// is the only requirement. The upstream's health is reported by a real
    /// request, not by a probe here.
    public func isAvailable() async -> Bool {
        apiKey?.isEmpty == false
    }

    public func transcribe(wav: Data, model: String?, language: String?) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else {
            throw ProviderError.missingCredential("No API key is set for this service. Add one in Settings.")
        }

        let resolvedLanguage = Self.asrLanguage(language, system: systemLanguage)
        let body: Data
        do {
            body = try Self.requestBody(
                wav: wav,
                model: model.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultModel,
                language: resolvedLanguage
            )
        } catch {
            throw ProviderError.invalidResponse("the audio could not be encoded")
        }

        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        request.timeoutInterval = timeout
        request.httpBody = body

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
            throw ProviderError.invalidResponse("no HTTP status")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.rejected(
                status: http.statusCode,
                message: Self.errorMessage(in: data)
            )
        }
        let rawText = try Self.transcript(in: data)
        let text = resolvedLanguage == "en" ? Self.stripCJKCharacters(rawText) : rawText
        guard !text.isEmpty else {
            throw ProviderError.noSpeech
        }
        return text
    }

    // MARK: - The request

    /// The JSON body of one request.
    ///
    /// The audio is base64 inside a `data:audio/wav;base64,…` URL, exactly as
    /// the hosted API documents. A language the service names is sent with the
    /// request; when there is none, the option is left out rather than filled
    /// with a value the API does not define.
    static func requestBody(wav: Data, model: String, language: String?) throws -> Data {
        let audio = "data:audio/wav;base64," + wav.base64EncodedString()
        var payload: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_audio",
                            "input_audio": ["data": audio],
                        ]
                    ],
                ]
            ],
        ]
        if let language {
            payload["asr_options"] = ["language": language]
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// The language hint a request carries, when it carries one.
    ///
    /// `auto` means the person did not choose, and it is resolved to the Mac's
    /// own language when the service names it. Asking the service to guess was
    /// what made the first partial of an English recording come back in
    /// Chinese: a short clip with no hint is answered in the model's own
    /// default language, and it is replaced once real speech arrives.
    ///
    /// A language the service has no name for is sent as no hint at all, never
    /// as a value the API may not define.
    ///
    /// - Parameters:
    ///   - language: the stored setting, or `nil` when nothing was stored.
    ///   - system: the Mac's language tag. Injected so a test is not at the
    ///     mercy of the machine it runs on.
    /// - Returns: `en`, `zh`, or `nil` when the request should carry no hint.
    static func asrLanguage(_ language: String?, system: String? = Locale.preferredLanguages.first) -> String? {
        let stored = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !stored.isEmpty, stored != "auto" {
            return namedLanguage(stored)
        }
        return namedLanguage(system?.lowercased() ?? "")
    }

    /// The service's own name for a language tag, when it has one.
    private static func namedLanguage(_ tag: String) -> String? {
        if tag.hasPrefix("en") { return "en" }
        if tag.hasPrefix("zh") { return "zh" }
        return nil
    }

    // MARK: - The answer

    /// The transcript in a successful answer.
    ///
    /// `content` is either a string or an array of text parts. The model's
    /// control markers are removed before the text is returned.
    static func transcript(in data: Data) throws -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = payload as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else {
            throw ProviderError.invalidResponse("no choices in the answer")
        }
        guard let content = message["content"] else {
            throw ProviderError.invalidResponse("no content in the answer")
        }
        let raw: String
        if let text = content as? String {
            raw = text
        } else if let parts = content as? [[String: Any]] {
            raw = parts.compactMap { part -> String? in
                guard let type = part["type"] as? String else { return part["text"] as? String }
                return type == "text" ? part["text"] as? String : nil
            }.joined()
        } else {
            throw ProviderError.invalidResponse("the transcript is not a string")
        }
        return cleanTranscript(raw)
    }

    /// Removes the model's control markers and collapses whitespace.
    ///
    /// MiMo prefixes the answer with a language tag (`<chinese>`) and may
    /// append control tokens (`<|eot|>`). It also leaks a reasoning marker
    /// (`think>`) or a ` thinking…` block now and then. Only markers are
    /// removed; a real sentence that contains the word "think" is untouched.
    static func cleanTranscript(_ text: String) -> String {
        var cleaned = text
        let patterns = [
            // A whole reasoning block: its content is not the transcript.
            #"<\s*think\s*>[\s\S]*?<\s*/\s*think\s*>"#,
            // Reasoning tags on their own.
            #"<\s*/?\s*(?:think|thinking)\s*>"#,
            // Control tokens such as <|eot|> or <|a|b|>.
            #"<\|[^<>]*\|>"#,
            // Language tags and any other angle-bracket marker.
            #"<[^<>]*>"#,
        ]
        for pattern in patterns {
            cleaned = replacing(pattern, in: cleaned, options: [.caseInsensitive])
        }
        // The plain-text marker is a token: the word immediately followed by
        // a `>`. It is only stripped at the edges, so "I think so" survives.
        cleaned = replacing(
            #"^(?:\s*(?:thinking|reasoning|think)\s*>+)+"#,
            in: cleaned,
            options: [.caseInsensitive]
        )
        cleaned = replacing(
            #"(?:\s*(?:thinking|reasoning|think)\s*>+)+\s*$"#,
            in: cleaned,
            options: [.caseInsensitive]
        )
        cleaned = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes stray CJK tokens and standalone digit-only noise hallucinations (`"1"`, `"10"`)
    /// that the bilingual MiMo ASR model can slip into an English transcript during breathy pauses.
    static func stripCJKCharacters(_ text: String) -> String {
        let tokens = text.components(separatedBy: .whitespacesAndNewlines)
        let filtered = tokens.compactMap { token -> String? in
            guard !token.isEmpty else { return nil }
            let containsCJK = token.unicodeScalars.contains { scalar in
                let v = scalar.value
                return (0x3000...0x303F).contains(v)
                    || (0x3400...0x4DBF).contains(v)
                    || (0x4E00...0x9FFF).contains(v)
                    || (0xF900...0xFAFF).contains(v)
                    || (0xFF00...0xFFEF).contains(v)
            }
            guard !containsCJK else { return nil }
            return token
        }
        var joined = filtered.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading or trailing standalone list-number hallucinations ("1.", "10.") that
        // MiMo ASR sometimes inserts on leading/trailing breath or pause boundaries.
        joined = replacing(#"^\s*(?:1|10)\.(?=\s+[A-Z])"#, in: joined, options: [])
        joined = replacing(#"(?<=[.!?])\s+(?:1|10)\.?$"#, in: joined, options: [])
        joined = joined
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // If an entire segment returned ONLY a short digit/punctuation token (e.g. "1.", "10.", "10")
        // with zero letters, it is a breath/noise hallucination from MiMo ASR; discard it.
        let hasAnyLetter = joined.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        if !hasAnyLetter && joined.count <= 4 {
            return ""
        }
        return joined
    }

    /// Replaces every match of a regular expression.
    private static func replacing(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }

    /// The message in a failed answer.
    static func errorMessage(in data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = payload as? [String: Any]
        else { return nil }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }
}
