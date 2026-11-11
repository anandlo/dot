import Foundation

/// A speech-to-text model available from a provider.
public struct AvailableModel: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let detail: String?

    public init(id: String, name: String? = nil, detail: String? = nil) {
        self.id = id
        self.name = name ?? id
        self.detail = detail
    }
}

/// The models each provider offers, read from the provider's own API.
///
/// A model list that ships with the app goes out of date as soon as a service
/// adds one. Everything here is derived from identifiers the service reports, so
/// a model this build has never heard of is still presented and still offered.
public enum ProviderModelCatalog {
    /// The display name of a model identifier.
    ///
    /// Built from the identifier itself — `whisper-large-v3-turbo` becomes
    /// "Whisper Large V3 Turbo" — so a model added by a service after this build
    /// shipped is presented like the ones that were known when it shipped.
    ///
    /// - Parameter id: the identifier the service reports.
    /// - Returns: the words the picker shows for it.
    public static func formattedName(for id: String) -> String {
        let parts = id.split(separator: "-").map { part -> String in
            let lower = part.lowercased()
            if lower == "v1" { return "V1" }
            if lower == "v2" { return "V2" }
            if lower == "v3" { return "V3" }
            if lower == "v4" { return "V4" }
            if lower == "v2.5" { return "V2.5" }
            if lower == "v2.6" { return "V2.6" }
            if lower == "mimo" { return "MiMo" }
            if lower == "en" { return "(EN)" }
            if lower == "turbo" { return "Turbo" }
            if lower == "whisper" { return "Whisper" }
            if lower == "distil" { return "Distil" }
            if lower == "asr" { return "ASR" }
            if lower == "tts" { return "TTS" }
            if lower == "stt" { return "STT" }
            if lower == "base" { return "Base" }
            if lower == "meeting" { return "Meeting" }
            if lower == "phonecall" { return "Phonecall" }
            if lower == "general" { return "General" }
            return part.prefix(1).uppercased() + part.dropFirst()
        }
        return parts.joined(separator: " ")
    }

    /// The one-line description the model picker shows under a model id.
    ///
    /// The answer is derived from the id rather than from a table of known
    /// models: an endpoint may list a model this build has never heard of, and
    /// it still has to be presented as something other than a raw identifier.
    public static func modelDetail(for id: String) -> String {
        let lower = id.lowercased()
        if lower.contains("whisper") {
            return "Whisper speech model"
        }
        if lower.contains("asr") || lower.contains("transcribe") || lower.contains("stt") || lower.contains("speech") {
            return "Speech recognition model"
        }
        return "Endpoint model"
    }

    /// Whether the identifier names something other than a transcriber.
    ///
    /// `/models` on an OpenAI-shaped service lists everything the key may call:
    /// speech synthesis, chat models, embeddings, image models. Offering one of
    /// those as a transcription model would fail on the first press.
    ///
    /// - Parameter id: the identifier the service reports.
    public static func isExplicitNonASRModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        if lower.contains("tts")
            || lower.contains("voiceclone")
            || lower.contains("voicedesign")
            || lower.contains("voice-clone")
            || lower.contains("voice-design")
            || lower.contains("speech-synthesis")
            || lower.contains("embedding")
            || lower.contains("moderation")
            || lower.contains("dall-e")
            || lower.contains("vision")
            || lower.contains("image")
            || lower.contains("video") {
            return true
        }
        if (lower.contains("flash") || lower.contains("pro") || lower.contains("gpt-") || lower.contains("claude-") || lower.contains("llama-") || lower.contains("qwen-") || lower.contains("deepseek-"))
            && !lower.contains("asr") && !lower.contains("whisper") && !lower.contains("transcribe") && !lower.contains("stt") {
            return true
        }
        return false
    }

    /// Whether the identifier is recognisably a transcription model.
    ///
    /// The answer is used to narrow a list that contains both, never to hide an
    /// unknown model: a service whose names do not match any of these tokens
    /// still gets its whole list, filtered only by ``isExplicitNonASRModel(_:)``.
    ///
    /// - Parameter id: the identifier the service reports.
    public static func isSpeechToTextModel(_ id: String) -> Bool {
        if isExplicitNonASRModel(id) { return false }
        let lower = id.lowercased()
        return lower.contains("asr")
            || lower.contains("whisper")
            || lower.contains("transcribe")
            || lower.contains("stt")
            || lower.contains("speech-to-text")
            || lower.contains("sensevoice")
            || lower.contains("paraformer")
            || lower.contains("conformer")
            || lower.contains("zipformer")
            || lower.contains("listen")
    }

    /// Fetches the models a provider lists from its own `/models` endpoint.
    ///
    /// The list is what the service reports, filtered to the models that can
    /// transcribe. Without a key there is nothing to ask with, so the answer is
    /// empty and the caller falls back to its own defaults. The one exception is
    /// Xiaomi, which ships a single ASR model: it is always inserted, so the
    /// picker is never empty for a service that has exactly one thing to offer.
    ///
    /// - Parameters:
    ///   - providerID: the provider whose endpoint to read.
    ///   - baseURL: the endpoint to read, or `nil` for the provider's default.
    ///   - apiKey: the credential to send, when the service needs one.
    ///   - authStyle: how the credential is sent, for the providers that accept
    ///     more than one spelling.
    ///   - session: the session the request is made with.
    /// - Returns: the transcription models the service reports, newest first, or
    ///   an empty list when it could not be asked.
    public static func fetchModels(
        for providerID: String,
        baseURL: URL? = nil,
        apiKey: String? = nil,
        authStyle: AuthStyle? = nil,
        session: URLSession = .shared
    ) async -> [AvailableModel] {
        guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return []
        }

        switch providerID {
        case ProviderIdentifier.groq:
            let base = baseURL ?? GroqProvider.defaultBaseURL
            let url = base.appendingPathComponent("models")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 8

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                return []
            }
            return parseOpenAIModels(data: data, filterSubstring: "whisper")

        case ProviderIdentifier.openAI:
            let base = baseURL ?? URL(string: "https://api.openai.com/v1")!
            let url = base.appendingPathComponent("models")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 8

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                return []
            }
            return parseOpenAIModels(data: data, filterSubstring: "whisper")

        case ProviderIdentifier.deepgram:
            let base = baseURL ?? DeepgramProvider.defaultBaseURL
            let url = base.appendingPathComponent("models")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 8

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                return []
            }
            return parseDeepgramModels(data: data)

        case ProviderIdentifier.elevenLabs:
            let base = baseURL ?? ElevenLabsProvider.defaultBaseURL
            let url = base.appendingPathComponent("models")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 8

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                return []
            }
            return parseElevenLabsModels(data: data)

        case ProviderIdentifier.xiaomi:
            let base = baseURL ?? XiaomiASRProvider.defaultBaseURL
            let url = base.appendingPathComponent("models")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let style = authStyle ?? .bearer
            request.setValue(style.value(for: key), forHTTPHeaderField: style.header)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 8

            var models: [AvailableModel] = []
            if let (data, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                models = parseOpenAIModels(data: data, filterSubstring: "asr")
            }
            // The one model this service offers is always presented: an endpoint
            // that is unreachable, or that lists nothing recognisable, must not
            // leave the picker empty for a service that has exactly one model.
            let asrModelID = "mimo-v2.5-asr"
            let asrTitle = formattedName(for: asrModelID)
            let defaultXiaomi = AvailableModel(
                id: asrModelID,
                name: asrTitle,
                detail: modelDetail(for: asrModelID)
            )
            if !models.contains(where: { $0.id == defaultXiaomi.id }) {
                models.insert(defaultXiaomi, at: 0)
            }
            return models

        default:
            // A custom endpoint or a self-hosted server: only the caller knows
            // where it is, so there is no default to fall back to.
            if let baseURL {
                let url = baseURL.appendingPathComponent("models")
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                let style = authStyle ?? .bearer
                request.setValue(style.value(for: key), forHTTPHeaderField: style.header)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 8

                if let (data, response) = try? await session.data(for: request),
                   let http = response as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode) {
                    let parsed = parseOpenAIModels(data: data, filterSubstring: nil)
                    if !parsed.isEmpty { return parsed }
                }
            }
            return []
        }
    }

    // MARK: - Format parsers

    public static func parseOpenAIModels(data: Data, filterSubstring: String? = nil, fallback: [AvailableModel] = []) -> [AvailableModel] {
        struct ModelList: Decodable {
            struct Item: Decodable {
                let id: String
            }
            let data: [Item]
        }

        guard let decoded = try? JSONDecoder().decode(ModelList.self, from: data) else {
            return fallback
        }

        var ids = decoded.data.map(\.id)

        ids = ids.filter { !isExplicitNonASRModel($0) }

        if let sub = filterSubstring?.lowercased(), !sub.isEmpty {
            ids = ids.filter { $0.lowercased().contains(sub) }
        } else {
            let speechOnly = ids.filter { isSpeechToTextModel($0) }
            if !speechOnly.isEmpty {
                ids = speechOnly
            }
        }

        var seen = Set<String>()
        var results: [AvailableModel] = []
        for id in ids {
            guard seen.insert(id).inserted else { continue }
            results.append(AvailableModel(id: id, name: formattedName(for: id), detail: modelDetail(for: id)))
        }
        return results.isEmpty ? fallback : results
    }

    public static func parseDeepgramModels(data: Data, fallback: [AvailableModel] = []) -> [AvailableModel] {
        struct ArrayModel: Decodable {
            struct ModelObj: Decodable {
                let name: String?
                let canonical_name: String?
                let formatted_name: String?
            }
            let models: [ModelObj]
        }
        struct DictModel: Decodable {
            let models: [String: AnyCodable]
        }
        struct AnyCodable: Decodable {}

        var modelItems: [(id: String, name: String?)] = []
        if let arrayResp = try? JSONDecoder().decode(ArrayModel.self, from: data) {
            modelItems = arrayResp.models.compactMap { obj in
                guard let id = obj.canonical_name ?? obj.name else { return nil }
                return (id: id, name: obj.formatted_name ?? obj.name)
            }
        } else if let dictResp = try? JSONDecoder().decode(DictModel.self, from: data) {
            modelItems = Array(dictResp.models.keys).sorted().map { (id: $0, name: nil) }
        }

        if modelItems.isEmpty { return fallback }

        var seen = Set<String>()
        var results: [AvailableModel] = []
        for item in modelItems {
            guard seen.insert(item.id).inserted else { continue }
            let title = item.name ?? formattedName(for: item.id)
            results.append(AvailableModel(id: item.id, name: title, detail: "Deepgram model"))
        }
        return results.isEmpty ? fallback : results
    }

    public static func parseElevenLabsModels(data: Data, fallback: [AvailableModel] = []) -> [AvailableModel] {
        struct Item: Decodable {
            let model_id: String
            let name: String?
            let can_do_transcription: Bool?
        }
        guard let list = try? JSONDecoder().decode([Item].self, from: data) else {
            return fallback
        }
        let transcriptionModels = list.filter {
            ($0.can_do_transcription == true) || $0.model_id.lowercased().contains("scribe")
        }
        let models = transcriptionModels.map { item in
            AvailableModel(
                id: item.model_id,
                name: item.name ?? formattedName(for: item.model_id),
                detail: "ElevenLabs speech model"
            )
        }
        return models.isEmpty ? fallback : models
    }
}
