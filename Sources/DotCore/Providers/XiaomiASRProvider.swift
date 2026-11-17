import Foundation

/// Xiaomi's hosted MiMo speech-to-text model.
///
/// MiMo is not an OpenAI transcription endpoint: it is a chat-completion
/// endpoint that takes the audio as an `input_audio` part and answers with the
/// transcript in `choices[0].message.content`. The key travels in the
/// `api-key` header, which is the spelling the service documents.
///
/// The provider is built only while the stored URL is still this service's. An
/// endpoint that was pointed somewhere else is the user's own, and is built as a
/// generic OpenAI-compatible provider instead, because the `api-key` header and
/// the `input_audio` body are this service's shape and not a general one.
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
    /// One request carries at most sixty seconds of audio.
    ///
    /// The MiMo model handles a 60-second continuous clip natively, so a long
    /// dictation stays one request instead of being cut at a boundary the
    /// model never heard.
    public var maxSegmentSeconds: Int { 60 }

    private let session: URLSession
    private let timeout: TimeInterval
    /// How long the one request that proves the key may take.
    private let verificationTimeout: TimeInterval
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
        systemLanguage: String? = Locale.preferredLanguages.first,
        verificationTimeout: TimeInterval = CredentialVerifier.timeout
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session
        self.systemLanguage = systemLanguage
        self.verificationTimeout = verificationTimeout
    }

    /// The URL a transcription is posted to.
    public var transcriptionURL: URL {
        baseURL.appendingPathComponent("chat/completions")
    }

    /// The URL the model list is read from, and the one a check calls.
    public var modelsURL: URL {
        baseURL.appendingPathComponent("models")
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

    /// Removes what the model puts around a transcript that the person never
    /// said.
    ///
    /// Two shapes of noise reach the text. One is Chinese: the model is
    /// bilingual, and a breathy pause can be answered with a token in the other
    /// language. The other is a number at an edge. The model is a chat model,
    /// and audio that opens on the room tone Dot records from the key press
    /// reads to it as the start of a list, so it numbers the silence - "1. ",
    /// "2. ", "1:00. ". A number is dropped only where it can be nothing else:
    /// a token made of digits and the separators a list number or a timestamp
    /// is written with, at the start of the answer and closed by its own full
    /// stop or colon, at the end of the answer after a sentence has already
    /// ended, or alone in an answer that says nothing else.
    ///
    /// A number that is part of a sentence is speech and is left byte for byte:
    /// "10 is a fair comparison.", "I have 2 cats." and "Meeting at 10." are not
    /// touched, because a number with words after it is not furniture, it is
    /// the sentence.
    static func stripCJKCharacters(_ text: String) -> String {
        var tokens = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && !containsCJK($0) }

        // The head. The model numbered the silence it was given before the
        // first word, so the number carries its own closing mark, or it is the
        // whole answer.
        if let first = tokens.first,
           isListNumber(first),
           tokens.count == 1 || isClosedListNumber(first) {
            tokens.removeFirst()
        }
        // The tail. The same furniture, reached only after a sentence has
        // ended: "the app. 1." is two answers, while "at 10." is one.
        if tokens.count >= 2,
           let last = tokens.last,
           endsSentence(tokens[tokens.count - 2]),
           isListNumber(last),
           isClosedListNumber(last) || isWholeNumber(last) {
            tokens.removeLast()
        }

        let joined = tokens.joined(separator: " ")
        // An answer with no letter in it and almost nothing else is a breath:
        // the model transcribed the room and put a mark on it.
        let hasAnyLetter = joined.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        if !hasAnyLetter && joined.count <= 4 {
            return ""
        }
        return joined
    }

    /// Whether a token carries a Chinese, Japanese or Korean character.
    private static func containsCJK(_ token: String) -> Bool {
        token.unicodeScalars.contains { scalar in
            let value = scalar.value
            return (0x3000...0x303F).contains(value)
                || (0x3400...0x4DBF).contains(value)
                || (0x4E00...0x9FFF).contains(value)
                || (0xF900...0xFAFF).contains(value)
                || (0xFF00...0xFFEF).contains(value)
        }
    }

    /// Whether a token can only be a list number or a timestamp.
    ///
    /// Digits, and the separators they are written with, with at least one
    /// digit among them: "2.", "10", "1:00" and "1,000." are furniture, while
    /// "2nd", "10:30pm" and "-5" carry something the speaker meant.
    private static func isListNumber(_ token: String) -> Bool {
        let digits = CharacterSet(charactersIn: "0123456789")
        let separators = CharacterSet(charactersIn: ":.,")
        var hasDigit = false
        for scalar in token.unicodeScalars {
            if digits.contains(scalar) {
                hasDigit = true
            } else if !separators.contains(scalar) {
                return false
            }
        }
        return hasDigit
    }

    /// Whether a list number is closed the way a numbered item or a timestamp
    /// is written: "2.", "10." or "1:00.".
    private static func isClosedListNumber(_ token: String) -> Bool {
        token.hasSuffix(".") || token.hasSuffix(":")
    }

    /// Whether a token is a plain whole number with nothing around it.
    private static func isWholeNumber(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let digits = CharacterSet(charactersIn: "0123456789")
        return token.unicodeScalars.allSatisfy { digits.contains($0) }
    }

    /// Whether a token ends a sentence, which is what makes a number after it a
    /// fragment of its own rather than part of what was said.
    private static func endsSentence(_ token: String) -> Bool {
        guard let last = token.unicodeScalars.last else { return false }
        return CharacterSet(charactersIn: ".!?:").contains(last)
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
            return ProviderErrorText.sanitized(message)
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return ProviderErrorText.sanitized(message)
        }
        return ProviderErrorText.sanitized(String(data: data, encoding: .utf8))
    }
}

extension XiaomiASRProvider: CredentialVerifying {
    /// The models request that proves the key.
    ///
    /// The service documents `GET {baseURL}/models` with either
    /// `Authorization: Bearer <key>` or `api-key: <key>`; the Bearer spelling is
    /// the one sent here. The base URL is the configuration's, so both the
    /// default `api.xiaomimimo.com` address and a token-plan address are checked
    /// where the audio would go.
    func credentialRequest() -> URLRequest? {
        guard let apiKey = CredentialVerifier.credential(apiKey) else { return nil }
        return CredentialVerifier.request(
            url: modelsURL,
            headers: ["Authorization": "Bearer \(apiKey)"],
            timeout: verificationTimeout
        )
    }

    public func verifyCredentials() async -> CredentialCheck {
        guard let request = credentialRequest() else {
            return CredentialVerifier.missingKey(displayName)
        }
        return await CredentialVerifier.check(request, session: session, providerID: id)
    }
}
