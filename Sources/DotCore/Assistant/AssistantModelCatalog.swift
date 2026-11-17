import CryptoKit
import Foundation

/// What a service published about one model's reasoning controls.
///
/// The values are the service's own. A vendor that lists no efforts gets an
/// empty list rather than a guess, because a level Dot invented would be sent
/// to an endpoint that never documented it and refused there, in a request the
/// person cannot see. That is also why ``supportsReasoning`` is a computed
/// property: a model is only ever offered a control it publishes.
public struct ModelReasoningSupport: Codable, Sendable, Equatable {
    /// The effort levels the service accepts, in the order it wrote them.
    public var efforts: [String]
    /// Whether the service lets reasoning be switched on and off.
    public var toggle: Bool
    /// The level the service uses when the person chooses nothing.
    public var defaultEffort: String?
    /// The thinking modes an Anthropic-shaped service lists, e.g. `adaptive`.
    /// Kept beside the efforts because an effort is carried differently on that
    /// shape, and the mode decides whether it can be asked for at all.
    public var thinkingTypes: [String]

    public init(
        efforts: [String] = [],
        toggle: Bool = false,
        defaultEffort: String? = nil,
        thinkingTypes: [String] = []
    ) {
        self.efforts = efforts
        self.toggle = toggle
        self.defaultEffort = defaultEffort
        self.thinkingTypes = thinkingTypes
    }

    /// Whether there is anything to choose.
    public var supportsReasoning: Bool { !efforts.isEmpty || toggle }
}

/// The wire shape and address a discovered model is served at.
///
/// One service can serve its models under more than one shape: OpenCode Go
/// answers chat completions at one address and messages at another. A model
/// that says which one it is served by is posted there, so the request reaches
/// an endpoint the service actually speaks rather than the row's default.
public struct ModelAPIRoute: Codable, Sendable, Equatable {
    /// The shape the endpoint speaks.
    public var style: AssistantAPIStyle
    /// The address the model is served at.
    public var baseURL: URL

    public init(style: AssistantAPIStyle, baseURL: URL) {
        self.style = style
        self.baseURL = baseURL
    }
}

/// One model a service listed, with what it published about it.
///
/// The picker shows ``id``; the request builder reads the rest. Everything but
/// the id is optional because every service lists a different amount: OpenAI
/// answers ids alone, while a gateway answers the reasoning levels, the shape
/// the model is served as and whether it accepts a temperature.
public struct DiscoveredModel: Codable, Sendable, Equatable, Identifiable {
    /// The model id, as the service writes it.
    public var id: String
    /// The vendor's own name for the model, when it published one.
    public var name: String?
    /// The reasoning controls the model publishes, when it publishes any.
    public var reasoning: ModelReasoningSupport?
    /// The shape and address the model is served at, when it named them.
    public var route: ModelAPIRoute?
    /// Whether the model accepts a sampling temperature. `nil` means the
    /// service said nothing, and the stored temperature is sent as before.
    public var supportsTemperature: Bool?

    public init(
        id: String,
        name: String? = nil,
        reasoning: ModelReasoningSupport? = nil,
        route: ModelAPIRoute? = nil,
        supportsTemperature: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.reasoning = reasoning
        self.route = route
        self.supportsTemperature = supportsTemperature
    }
}

/// The model list a chat service publishes about itself.
///
/// No shipped row suggests models any more: a service adds and retires them
/// faster than Dot ships a build. `GET <base>/models` is the request that
/// answers both questions a person asks of a service: whether it works, and
/// what it offers. The status row sends it to check the address and the key,
/// and the model picker sends the same one to fill its list.
public enum AssistantModelCatalog {
    /// The beginnings of the ids that are not a chat model, whichever service
    /// misplaces them.
    ///
    /// A service that lists its speech, image and embedding models beside its
    /// chat models must not offer them in a chat picker, and not every service
    /// labels an entry with what it is.
    static let nonChatModelPrefixes = [
        "whisper-",
        "tts-",
        "dall-e-",
        "text-embedding-",
        "embedding-",
        "omni-moderation-",
        "sora-",
        "gpt-image-",
        "babbage-",
        "davinci-",
        "mistral-embed",
        "voxtral-",
    ]

    /// The most pages one list may take.
    static let maximumPages = 5

    /// The path a list is read at, relative to the base URL.
    ///
    /// - Parameter style: the wire shape the service speaks.
    /// - Returns: the path to append to the base URL.
    public static func path(for style: AssistantAPIStyle) -> String {
        // An OpenAI-compatible base already ends with its version segment
        // (`https://api.openai.com/v1`), while Anthropic's does not: its models
        // live under the same `v1` its messages do.
        style == .anthropic ? "v1/models" : "models"
    }

    /// The address a list is read at.
    ///
    /// A row may serve its inference and its catalogue at different addresses —
    /// OpenCode Go's subscription answers inference under `/openai/v1` and lists
    /// what it offers under `/go/v1` — so the row's ``AssistantProviderRow/modelsURL``
    /// is used as it stands. A person who typed an address is read as having
    /// chosen where the service is, and the path is appended to it.
    ///
    /// - Parameters:
    ///   - settings: the chat settings, which name the service and any typed
    ///     address.
    ///   - row: the catalogue row.
    /// - Returns: the address, or `nil` when the row has none and the person
    ///   typed none.
    /// - Throws: ``EndpointPolicy/Rejection`` when a typed address is refused.
    public static func url(settings: AssistantSettings, row: AssistantProviderRow) throws -> URL? {
        let typed = settings.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let typed, !typed.isEmpty {
            let base = try EndpointPolicy.url(from: typed)
            return AssistantEndpoint.url(
                base: base,
                path: path(for: settings.apiStyle ?? row.style)
            )
        }
        if let modelsURL = row.modelsURL { return modelsURL }
        guard let base = row.defaultBaseURL else { return nil }
        return AssistantEndpoint.url(
            base: base,
            path: path(for: settings.apiStyle ?? row.style)
        )
    }

    /// The request a list is read with, which is also the request the
    /// connection check sends.
    ///
    /// - Parameters:
    ///   - settings: the chat settings.
    ///   - apiKey: the key, when the service needs one.
    /// - Returns: a `GET` for the row's models endpoint.
    /// - Throws: ``ProviderError/unavailable(_:)`` when no address is known,
    ///   ``EndpointPolicy/Rejection`` when the address is refused.
    public static func makeRequest(settings: AssistantSettings, apiKey: String?) throws -> URLRequest {
        let settings = settings.sanitized()
        let row = AssistantProviderCatalogue.row(for: settings.resolvedProviderID)
        guard let catalogueURL = try url(settings: settings, row: row) else {
            throw ProviderError.unavailable("Add the address of the \(row.name) endpoint.")
        }
        let requestURL = url(
            byAdding: row.queryItems
                + AssistantProviderCatalogue.legacyAzureQuery(row: row, baseURL: catalogueURL),
            to: catalogueURL
        )
        if let rejection = EndpointPolicy.validate(requestURL) { throw rejection }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key, !key.isEmpty {
            switch settings.apiStyle ?? row.style {
            case .openAICompatible:
                request.setValue(row.authStyle.value(for: key), forHTTPHeaderField: row.authStyle.header)
            case .anthropic:
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue(AnthropicChatProvider.defaultVersion, forHTTPHeaderField: "anthropic-version")
            }
        }
        // A vendor that asks every request for a header — an attribution, an
        // API revision — asks it of the list too, or the list is the one call
        // the service refuses.
        for (name, value) in row.extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.timeoutInterval = AssistantConnectionVerifier.timeout
        return request
    }

    /// The models a list body names, in the order the service wrote them.
    ///
    /// - Parameters:
    ///   - data: the body the service answered with.
    ///   - prefixes: the beginnings of the ids the row cannot be used with.
    /// - Returns: the ids, without duplicates and without the excluded ones.
    public static func models(in data: Data, excluding prefixes: [String]) -> [String] {
        catalogModels(in: data, excluding: prefixes).map(\.id)
    }

    /// The models a list body names, with what the service published about each.
    ///
    /// Every shape a service in the catalogue answers with is read here: the
    /// OpenAI list, Anthropic's paginated one, OpenRouter's with its reasoning
    /// parameters, DeepSeek's and xAI's effort levels, Mistral's capabilities
    /// and OpenCode Go's per-model API routes. A field a service did not publish
    /// stays `nil`; nothing is filled in from what a model of that name usually
    /// does.
    ///
    /// - Parameters:
    ///   - data: the body the service answered with.
    ///   - prefixes: the beginnings of the ids the row cannot be used with.
    /// - Returns: the models, without duplicates, non-chat entries or the
    ///   excluded ones.
    public static func catalogModels(in data: Data, excluding prefixes: [String]) -> [DiscoveredModel] {
        guard let root = jsonValue(in: data) else { return [] }
        let entries: [JSONValue]
        switch root {
        case .array(let items):
            entries = items
        case .object:
            entries = root["data"]?.arrayValue ?? root["models"]?.arrayValue ?? []
        default:
            entries = []
        }
        let excluded = nonChatModelPrefixes + prefixes
        var seen = Set<String>()
        var models: [DiscoveredModel] = []
        for entry in entries {
            guard let model = model(from: entry, excluding: excluded) else { continue }
            guard seen.insert(model.id).inserted else { continue }
            models.append(model)
        }
        return models
    }

    /// Reads the list from the service.
    ///
    /// - Parameters:
    ///   - settings: the chat settings.
    ///   - apiKey: the key, when the service needs one.
    ///   - session: the session to send with.
    /// - Returns: the models the service lists, or nothing when it refused the
    ///   request or listed none.
    public static func fetch(
        settings: AssistantSettings,
        apiKey: String?,
        session: URLSession
    ) async -> [String] {
        await fetchCatalog(settings: settings, apiKey: apiKey, session: session).models.map(\.id)
    }

    /// Reads the catalogue from the service, following the pages a service
    /// splits it into.
    ///
    /// Anthropic pages its list and an account can hold more models than one
    /// answer carries, so `has_more` is followed with `after_id` for at most
    /// ``maximumPages`` pages. A fresh answer is reused from
    /// ``AssistantModelCache`` so opening the page twice in a minute does not
    /// send the service two lists.
    ///
    /// - Parameters:
    ///   - settings: the chat settings.
    ///   - apiKey: the key, when the service needs one.
    ///   - session: the session to send with.
    /// - Returns: the models, whether the service answered, and whether every
    ///   page was read. A refusal is an empty list with `succeeded` false,
    ///   which is how the page tells "no models" from "no answer"; a list that
    ///   stopped part way is `succeeded` true and `complete` false, so a
    ///   partial page is never mistaken for the whole catalogue.
    public static func fetchCatalog(
        settings: AssistantSettings,
        apiKey: String?,
        session: URLSession
    ) async -> (models: [DiscoveredModel], succeeded: Bool, complete: Bool) {
        await fetchCatalog(settings: settings, apiKey: apiKey, session: session, cache: .shared)
    }

    /// The same read, with the cache the caller supplies, for tests and for a
    /// caller that owns its own.
    static func fetchCatalog(
        settings: AssistantSettings,
        apiKey: String?,
        session: URLSession,
        cache: AssistantModelCache
    ) async -> (models: [DiscoveredModel], succeeded: Bool, complete: Bool) {
        let settings = settings.sanitized()
        let row = AssistantProviderCatalogue.row(for: settings.resolvedProviderID)
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKey = !(key?.isEmpty ?? true)
        let service = AssistantModelCache.serviceKey(settings, hasKey: hasKey, credential: key)
        if let cached = await cache.models(for: service, now: Date()) {
            return (cached, true, true)
        }
        let request: URLRequest
        do {
            request = try makeRequest(settings: settings, apiKey: apiKey)
        } catch {
            return ([], false, false)
        }
        guard let url = request.url else { return ([], false, false) }
        let style = settings.apiStyle ?? row.style
        var models: [DiscoveredModel] = []
        var seen = Set<String>()
        var afterID: String?
        var answered = false
        var complete = false
        for _ in 0 ..< maximumPages {
            guard let pageURL = pageURL(url, style: style, afterID: afterID) else { break }
            var pageRequest = request
            pageRequest.url = pageURL
            guard let answer = try? await HTTPTransport.send(pageRequest, session: session),
                  let response = answer.response as? HTTPURLResponse,
                  (200 ..< 300).contains(response.statusCode),
                  let root = jsonValue(in: answer.data)
            else { break }
            answered = true
            for model in catalogModels(in: answer.data, excluding: row.excludedModelPrefixes)
            where seen.insert(model.id).inserted {
                models.append(model)
            }
            if style == .anthropic,
               let page = root.objectValue,
               page["has_more"]?.boolValue == true {
                // A page that says more follows is only complete once the next
                // one arrives. A missing or blank cursor is a list this build
                // cannot finish, so it is never stored as the whole catalogue.
                guard let lastID = page["last_id"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !lastID.isEmpty
                else { break }
                afterID = lastID
                continue
            }
            complete = true
            break
        }
        guard answered else { return ([], false, false) }
        // Only a list every page answered is cached: a partial one describes
        // the account's first page as if it were all of it.
        if complete {
            await cache.store(models, for: service, at: Date())
        }
        return (models, true, complete)
    }

    // MARK: - The body

    /// The JSON value a service answered with, however it spelled it.
    private static func jsonValue(in data: Data) -> JSONValue? {
        guard let object = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else { return nil }
        return JSONValue(any: object)
    }

    /// One entry of a list, when it is a chat model this build can speak to.
    private static func model(from entry: JSONValue, excluding prefixes: [String]) -> DiscoveredModel? {
        guard let members = entry.objectValue else { return nil }
        guard let id = (members["id"]?.stringValue ?? members["model"]?.stringValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !id.isEmpty
        else { return nil }
        // A list that says what each entry is must name a chat model: OpenAI's
        // entries say "chat", Anthropic's say "model", and an embedding or an
        // image model is not a picker's business whichever word it uses.
        if let type = members["type"]?.stringValue {
            let kind = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard kind == "chat" || kind == "model" else { return nil }
        }
        let lowered = id.lowercased()
        guard !prefixes.contains(where: { lowered.hasPrefix($0.lowercased()) }) else { return nil }
        let capabilities = members["capabilities"]?.objectValue
        // Mistral names completion support per model.
        if capabilities?["completion_chat"]?.boolValue == false { return nil }
        let api: APILookup = apiLookup(in: members)
        let route: ModelAPIRoute?
        switch api {
        case .absent:
            route = nil
        case .unsupported:
            // The service says which shape serves this model, and it is not one
            // this build speaks: offering it would fail on the first request.
            return nil
        case .supported(let style, let baseURL):
            route = baseURL.map { ModelAPIRoute(style: style, baseURL: $0) }
        }
        let reasoning = reasoningSupport(in: members).flatMap { support in
            support.supportsReasoning ? support : nil
        }
        return DiscoveredModel(
            id: id,
            name: (members["name"]?.stringValue ?? members["display_name"]?.stringValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilWhenEmpty,
            reasoning: reasoning,
            route: route,
            supportsTemperature: capabilities?["temperature"]?.boolValue
        )
    }

    // MARK: - The route

    /// What a model's `api` member says about how it is served.
    private enum APILookup {
        /// The service published nothing, so the row's own shape is right.
        case absent
        /// The service published shapes, none of which this build speaks.
        case unsupported
        /// The service published a shape this build speaks.
        case supported(style: AssistantAPIStyle, baseURL: URL?)
    }

    private static func apiLookup(in members: [String: JSONValue]) -> APILookup {
        guard let api = members["api"] else { return .absent }
        var protocols: [String] = []
        var bases: [String: URL] = [:]
        switch api {
        case .string(let text):
            protocols = [text]
        case .array(let items):
            for item in items {
                if let name = item.stringValue {
                    protocols.append(name)
                } else if let object = item.objectValue,
                          let name = object["type"]?.stringValue
                            ?? object["name"]?.stringValue
                            ?? object["protocol"]?.stringValue {
                    protocols.append(name)
                    if let base = url(from: item) { bases[name] = base }
                }
            }
        case .object(let dictionary):
            protocols = Array(dictionary.keys)
            for (name, value) in dictionary {
                if let base = url(from: value) { bases[name] = base }
            }
        default:
            return .unsupported
        }
        guard !protocols.isEmpty else { return .absent }
        let modelBase = url(from: members["base_url"])
            ?? url(from: members["baseURL"])
            ?? url(from: members["url"])
        let openAIProtocols = ["chat-completions", "chat_completions", "chatcompletions"]
        if let match = protocols.first(where: { openAIProtocols.contains($0.lowercased()) }) {
            return .supported(style: .openAICompatible, baseURL: bases[match] ?? modelBase)
        }
        if let match = protocols.first(where: { $0.lowercased() == "messages" }) {
            return .supported(style: .anthropic, baseURL: bases[match] ?? modelBase)
        }
        return .unsupported
    }

    /// The address a member carries, whether it is the address itself or an
    /// object with one inside.
    private static func url(from value: JSONValue?) -> URL? {
        guard let value else { return nil }
        if let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return URL(string: text)
        }
        guard let members = value.objectValue else { return nil }
        for key in ["base_url", "baseURL", "url"] {
            if let text = members[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty,
               let url = URL(string: text) {
                return url
            }
        }
        return nil
    }

    // MARK: - Reasoning

    /// Reads the reasoning controls a model published, from any of the shapes
    /// the catalogue's services use.
    private static func reasoningSupport(in members: [String: JSONValue]) -> ModelReasoningSupport? {
        var efforts: [String] = []
        var toggle = false
        var defaultEffort: String?
        var thinkingTypes: [String] = []
        let capabilities = members["capabilities"]?.objectValue

        // OpenCode Go: capabilities.reasoning.{supported,toggle,effort,default}
        if let reasoning = capabilities?["reasoning"]?.objectValue {
            efforts += effortStrings(reasoning["effort"])
            if reasoning["toggle"]?.boolValue == true { toggle = true }
            defaultEffort = defaultEffort
                ?? string(reasoning["default"])
                ?? string(reasoning["default"]?["value"])
                ?? string(reasoning["default_effort"])
        }

        // Anthropic: capabilities.thinking.types + capabilities.effort flags.
        if let thinking = capabilities?["thinking"]?.objectValue {
            let types = stringList(thinking["types"])
            thinkingTypes += types
            let lowered = types.map { $0.lowercased() }
            if lowered.contains("enabled") || lowered.contains("adaptive") { toggle = true }
        }
        if let flags = capabilities?["effort"]?.objectValue {
            let ordered = ["low", "medium", "high", "xhigh", "max"]
            let published = ordered.filter { flags[$0]?.boolValue == true }
            if !published.isEmpty { efforts += published }
        }

        // DeepSeek: effort.supported_levels and effort.default_level, at the
        // top level or under capabilities.
        for candidate in [members["effort"], capabilities?["effort"]] {
            guard let object = candidate?.objectValue else { continue }
            let levels = stringList(object["supported_levels"])
            guard !levels.isEmpty else { continue }
            efforts += levels
            defaultEffort = defaultEffort ?? string(object["default_level"])
        }

        // xAI: capabilities.reasoning_effort and default_reasoning_effort.
        if let published = capabilities?["reasoning_effort"] ?? members["reasoning_effort"] {
            efforts += effortStrings(published)
        }
        defaultEffort = defaultEffort
            ?? string(capabilities?["default_reasoning_effort"])
            ?? string(members["default_reasoning_effort"])

        // OpenRouter: supported_parameters + reasoning.{supported_efforts, ...}
        let parameters = stringList(members["supported_parameters"]).map { $0.lowercased() }
        if let reasoning = members["reasoning"]?.objectValue {
            efforts += stringList(reasoning["supported_efforts"])
            defaultEffort = defaultEffort ?? string(reasoning["default_effort"])
            if reasoning["default_enabled"]?.boolValue != nil { toggle = true }
        }
        if parameters.contains("reasoning") { toggle = true }

        let support = ModelReasoningSupport(
            efforts: normalized(efforts),
            toggle: toggle,
            defaultEffort: normalized(defaultEffort),
            thinkingTypes: normalized(thinkingTypes)
        )
        return support.supportsReasoning ? support : nil
    }

    /// The effort levels a member names, in the order it names them.
    ///
    /// A level can arrive as a string, as an array of strings or objects, or as
    /// an object of flags — the three shapes the catalogue's services use.
    private static func effortStrings(_ value: JSONValue?) -> [String] {
        guard let value else { return [] }
        if value.stringValue != nil { return [value.stringValue ?? ""] }
        if let items = value.arrayValue {
            return items.map { item in
                if let text = item.stringValue { return text }
                let object = item.objectValue
                return object?["value"]?.stringValue
                    ?? object?["effort"]?.stringValue
                    ?? object?["name"]?.stringValue
                    ?? ""
            }
        }
        guard let object = value.objectValue else { return [] }
        let ordered = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        var flags = ordered.filter { object[$0]?.boolValue == true }
        for key in object.keys.sorted()
        where !ordered.contains(key) && object[key]?.boolValue == true {
            flags.append(key)
        }
        return flags
    }

    /// One string member, when it holds one.
    private static func string(_ value: JSONValue?) -> String? {
        value?.stringValue
    }

    /// The string members of an array, in order.
    private static func stringList(_ value: JSONValue?) -> [String] {
        guard let items = value?.arrayValue else {
            // A single string is a one-item list for every caller here.
            if let text = value?.stringValue { return [text] }
            return []
        }
        return items.compactMap { item in
            if let text = item.stringValue { return text }
            return item.objectValue?["value"]?.stringValue
                ?? item.objectValue?["name"]?.stringValue
        }
    }

    /// Trimmed, lowercased, without blanks or repeats.
    private static func normalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
            result.append(clean)
        }
        return result
    }

    /// A single value cleaned the way a list's members are.
    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        return normalized([value]).first
    }

    // MARK: - Paging

    /// The address of one page.
    ///
    /// Anthropic pages its list with `limit` and `after_id`; every other
    /// service returns its whole list in one answer.
    private static func pageURL(_ url: URL, style: AssistantAPIStyle, afterID: String?) -> URL? {
        guard style == .anthropic,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "limit" || $0.name == "after_id" }
        items.append(URLQueryItem(name: "limit", value: "1000"))
        if let afterID {
            items.append(URLQueryItem(name: "after_id", value: afterID))
        }
        components.queryItems = items
        return components.url ?? url
    }

    /// The address with query items appended, keeping the ones it already had.
    private static func url(byAdding items: [URLQueryItem], to url: URL) -> URL {
        guard !items.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.queryItems = (components.queryItems ?? []) + items
        return components.url ?? url
    }
}

/// The model lists this run of the app has already read.
///
/// Opening the page twice in a minute must not send the service two lists, and
/// a rewrite offer does not need a catalogue of its own. The entries live in
/// memory only: a model list says what a service offers today, so it is never
/// written to the configuration, and a new launch reads it again.
public actor AssistantModelCache {
    /// How long a list is reused.
    public static let lifetime: TimeInterval = 600

    /// The cache the page uses.
    public static let shared = AssistantModelCache()

    private var entries: [String: (models: [DiscoveredModel], at: Date)] = [:]

    public init() {}

    /// The name a list is stored under: the service, the address it was read
    /// at, the wire shape it was asked for, and which credential was sent.
    ///
    /// A service the person moved, a shape they overrode, or a key that was
    /// added, removed or replaced is read again. The credential is reduced to
    /// a digest before it reaches the cache, so the key itself never sits in a
    /// dictionary for the life of the process.
    ///
    /// - Parameters:
    ///   - settings: the chat settings.
    ///   - hasKey: whether the read carried a key.
    ///   - credential: the key, when one was sent. Only its digest is kept.
    /// - Returns: the key a list and its caller share.
    public static func serviceKey(
        _ settings: AssistantSettings,
        hasKey: Bool,
        credential: String? = nil
    ) -> String {
        let address = settings.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let style = settings.apiStyle?.rawValue ?? "auto"
        let identity: String
        if hasKey {
            let clean = credential?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            identity = clean.isEmpty ? "key" : digest(clean)
        } else {
            identity = "no-key"
        }
        return settings.sanitized().providerID + " " + address + " " + style + " " + identity
    }

    /// A short, stable fingerprint of a credential.
    ///
    /// It is an identity, not a secret: the cache only has to tell one key from
    /// another, and a digest cannot be turned back into the key it came from.
    ///
    /// - Parameter credential: the key that was sent.
    /// - Returns: the first twelve bytes of its SHA-256, in hexadecimal.
    private static func digest(_ credential: String) -> String {
        SHA256.hash(data: Data(credential.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The list that is still fresh, when there is one.
    ///
    /// - Parameters:
    ///   - service: the key ``serviceKey(_:hasKey:)`` built.
    ///   - now: the moment the caller asks.
    /// - Returns: the list, or `nil` when none was stored or it is older than
    ///   ``lifetime``.
    public func models(for service: String, now: Date) -> [DiscoveredModel]? {
        guard let stored = entries[service] else { return nil }
        guard now.timeIntervalSince(stored.at) < Self.lifetime else {
            entries[service] = nil
            return nil
        }
        return stored.models
    }

    /// Records what a read found.
    public func store(_ models: [DiscoveredModel], for service: String, at date: Date) {
        entries[service] = (models, date)
    }
}

private extension JSONValue {
    /// The flag this value carries, when it carries one.
    var boolValue: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    /// The items this value carries, when it is an array.
    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }
}

private extension String {
    /// The string, or `nil` when it is only whitespace.
    var nilWhenEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
