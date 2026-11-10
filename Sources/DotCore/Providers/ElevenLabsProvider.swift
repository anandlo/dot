import Foundation

/// ElevenLabs' hosted Speech-to-Text API (`/v1/speech-to-text`).
///
/// ElevenLabs accepts `multipart/form-data` audio uploads (`file` and `model_id`),
/// authenticates via the `xi-api-key` header, supports rich transcription options
/// (diarization, max speaker count, audio event tagging, verbatim/filler filtering,
/// timestamps granularity, entity detection, keyterms, and custom transcript edit
/// instructions), and returns the transcript in the top-level `text` field.
public struct ElevenLabsProvider: Provider {
    public let id: String = ProviderIdentifier.elevenLabs
    public let displayName: String = "ElevenLabs"

    /// The default endpoint of ElevenLabs' API.
    public static let defaultBaseURL = URL(string: "https://api.elevenlabs.io/v1")!
    /// The flagship model Dot asks for when the configuration names none.
    public static let defaultModel = "scribe_v2"

    /// Selectable ElevenLabs Scribe speech-to-text models.
    public static let supportedModels: [(id: String, title: String, detail: String)] = [
        ("scribe_v2", "Scribe v2 (Latest Flagship)", "Highest accuracy across 90+ languages with keyterm & edit support"),
        ("scribe_v2_medical", "Scribe v2 Medical", "Clinical & medical terminology specialist"),
        ("scribe_v1", "Scribe v1", "First-generation universal speech recognition model"),
        ("scribe_v1_experimental", "Scribe v1 Experimental", "Experimental multilingual recognition model"),
    ]

    /// Selectable timestamp granularity options for ElevenLabs Scribe.
    public static let granularityOptions: [(id: String, title: String)] = [
        ("word", "Word-level"),
        ("character", "Character-level"),
        ("none", "None"),
    ]

    /// Selectable entity detection modes for ElevenLabs Scribe.
    public static let entityDetectionOptions: [(id: String, title: String)] = [
        ("", "Disabled"),
        ("all", "All entities (PII, PHI, PCI, offensive)"),
        ("pii", "Personal identifiable info (PII)"),
        ("phi", "Protected health info (PHI)"),
        ("pci", "Payment card info (PCI)"),
        ("offensive_language", "Offensive language"),
    ]

    /// The base URL of the service, e.g. `https://api.elevenlabs.io/v1`.
    public let baseURL: URL
    /// The ElevenLabs API key (`xi-api-key`), when the Keychain has one.
    public let apiKey: String?
    /// Whether to tag non-speech audio events like `(laughter)` or `(applause)` (`tag_audio_events`).
    public let tagAudioEvents: Bool
    /// Whether to strip filler words, false starts, and non-speech sounds (`no_verbatim`).
    public let noVerbatim: Bool
    /// Whether to annotate which speaker is talking (`diarize`).
    public let diarize: Bool
    /// Optional maximum number of speakers (`num_speakers`, 1...32).
    public let numSpeakers: Int?
    /// Whether to automatically label speakers as `"agent"` and `"customer"` (`detect_speaker_roles`).
    public let detectSpeakerRoles: Bool
    /// Whether to match diarized speakers against registered workspace speaker profiles (`use_speaker_library`).
    public let useSpeakerLibrary: Bool
    /// Timestamp precision (`"word"`, `"character"`, or `"none"`).
    public let timestampsGranularity: String
    /// Optional entity detection mode (`"all"`, `"pii"`, `"phi"`, `"pci"`, `"offensive_language"`).
    public let entityDetection: String?
    /// Optional comma-separated keyterms/phrases to bias Scribe v2 toward (`keyterms`).
    public let keyterms: String?
    /// Optional natural-language instruction to format or normalize the final transcript (`transcript_edit`).
    public let transcriptEdit: String?
    /// Whether Zero Data Retention (ZDR) is requested (`enable_logging: false`).
    public let zeroDataRetention: Bool

    /// ElevenLabs requires an API key.
    public var requiresCredential: Bool { true }
    /// One request carries at most thirty seconds of audio by default.
    public var maxSegmentSeconds: Int { 30 }

    private let session: URLSession
    private let timeout: TimeInterval

    /// Creates an ElevenLabs provider.
    public init(
        baseURL: URL = ElevenLabsProvider.defaultBaseURL,
        apiKey: String? = nil,
        tagAudioEvents: Bool = false,
        noVerbatim: Bool = false,
        diarize: Bool = false,
        numSpeakers: Int? = nil,
        detectSpeakerRoles: Bool = false,
        useSpeakerLibrary: Bool = false,
        timestampsGranularity: String = "word",
        entityDetection: String? = nil,
        keyterms: String? = nil,
        transcriptEdit: String? = nil,
        zeroDataRetention: Bool = true,
        timeout: TimeInterval = 120,
        session: URLSession = OpenAICompatibleProvider.makeSession()
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.tagAudioEvents = tagAudioEvents
        self.noVerbatim = noVerbatim
        self.diarize = diarize
        self.numSpeakers = numSpeakers
        self.detectSpeakerRoles = detectSpeakerRoles
        self.useSpeakerLibrary = useSpeakerLibrary
        self.timestampsGranularity = timestampsGranularity
        self.entityDetection = entityDetection
        self.keyterms = keyterms
        self.transcriptEdit = transcriptEdit
        self.zeroDataRetention = zeroDataRetention
        self.timeout = timeout
        self.session = session
    }

    /// The `/speech-to-text` endpoint URL.
    public var transcriptionURL: URL {
        baseURL.lastPathComponent == "speech-to-text"
            ? baseURL
            : baseURL.appendingPathComponent("speech-to-text")
    }

    public func isAvailable() async -> Bool {
        apiKey?.isEmpty == false
    }

    /// Builds the `URLRequest` for `/v1/speech-to-text` so unit tests can inspect headers and multipart fields.
    public func buildTranscriptionRequest(
        apiKey: String,
        wav: Data,
        model: String?,
        language: String?,
        boundary: String = "dot-elevenlabs-\(UUID().uuidString)"
    ) -> URLRequest {
        let resolvedModel = model.flatMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? Self.defaultModel

        var body = Data()
        body.appendMultipartField(name: "model_id", value: resolvedModel, boundary: boundary)

        if let normalizedLang = Self.normalizedLanguage(language) {
            body.appendMultipartField(name: "language_code", value: normalizedLang, boundary: boundary)
        }

        body.appendMultipartField(
            name: "tag_audio_events",
            value: tagAudioEvents ? "true" : "false",
            boundary: boundary
        )

        if noVerbatim {
            body.appendMultipartField(name: "no_verbatim", value: "true", boundary: boundary)
        }

        body.appendMultipartField(
            name: "enable_logging",
            value: zeroDataRetention ? "false" : "true",
            boundary: boundary
        )

        if diarize {
            body.appendMultipartField(name: "diarize", value: "true", boundary: boundary)
            if let numSpeakers, (1...32).contains(numSpeakers) {
                body.appendMultipartField(name: "num_speakers", value: String(numSpeakers), boundary: boundary)
            }
            if detectSpeakerRoles {
                body.appendMultipartField(name: "detect_speaker_roles", value: "true", boundary: boundary)
            }
            if useSpeakerLibrary {
                body.appendMultipartField(name: "use_speaker_library", value: "true", boundary: boundary)
            }
        }

        let trimmedGranularity = timestampsGranularity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGranularity.isEmpty {
            body.appendMultipartField(name: "timestamps_granularity", value: trimmedGranularity, boundary: boundary)
        }

        if let entityDetection {
            let trimmedEntity = entityDetection.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedEntity.isEmpty {
                body.appendMultipartField(name: "entity_detection", value: trimmedEntity, boundary: boundary)
            }
        }

        if let keyterms, !keyterms.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let terms = keyterms
                .split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for term in terms.prefix(100) {
                body.appendMultipartField(name: "keyterms", value: term, boundary: boundary)
            }
        }

        if let transcriptEdit {
            let trimmedEdit = transcriptEdit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedEdit.isEmpty {
                body.appendMultipartField(name: "transcript_edit", value: trimmedEdit, boundary: boundary)
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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = timeout
        request.httpBody = body
        return request
    }

    public func transcribe(wav: Data, model: String?, language: String?) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else {
            throw ProviderError.missingCredential("No API key is set for this service. Add one in Settings.")
        }

        let request = buildTranscriptionRequest(
            apiKey: apiKey,
            wav: wav,
            model: model,
            language: language
        )

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

        let text = try Self.transcript(in: data)
        guard !text.isEmpty else {
            throw ProviderError.noSpeech
        }
        return text
    }

    // MARK: - Helpers

    static func normalizedLanguage(_ tag: String?) -> String? {
        guard let tag else { return nil }
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "auto" else { return nil }
        let cleaned = trimmed.replacingOccurrences(of: "_", with: "-")
        if let prefix = cleaned.split(separator: "-").first, !prefix.isEmpty {
            return String(prefix).lowercased()
        }
        return cleaned.lowercased()
    }

    static func transcript(in data: Data) throws -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = payload as? [String: Any]
        else {
            throw ProviderError.invalidResponse("not JSON")
        }
        if let text = object["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let transcript = object["transcript"] as? String {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let transcripts = object["transcripts"] as? [[String: Any]] {
            let joined = transcripts
                .compactMap { $0["text"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !joined.isEmpty {
                return joined
            }
        }
        throw ProviderError.invalidResponse("no text in the answer")
    }

    static func errorMessage(in data: Data) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = payload as? [String: Any]
        else { return nil }
        if let detail = object["detail"] as? [String: Any] {
            if let message = detail["message"] as? String, !message.isEmpty {
                return message
            }
            if let status = detail["status"] as? String, !status.isEmpty {
                return status
            }
        }
        if let detailStr = object["detail"] as? String, !detailStr.isEmpty {
            return detailStr
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        return nil
    }
}
