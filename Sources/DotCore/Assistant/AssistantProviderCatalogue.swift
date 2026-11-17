import Foundation

/// An address one vendor also serves, chosen by a control on the Assistant page.
///
/// A vendor that sells a subscription beside its pay-as-you-go API answers on a
/// second host and hands out keys under a prefix of its own. The row carries
/// both addresses, so the page offers the choice and the catalogue can read a
/// pasted key back to the address it belongs to.
public struct AssistantProviderPlan: Sendable, Equatable {
    /// The stable id, written nowhere but read by the picker.
    public let id: String
    /// The words the Plan pop-up shows.
    public let title: String
    /// The address this plan answers at, or `nil` for the row's own.
    public let baseURL: URL?
    /// The beginnings of the keys this plan hands out, lowercased.
    public let keyPrefixes: [String]

    public init(id: String, title: String, baseURL: URL?, keyPrefixes: [String] = []) {
        self.id = id
        self.title = title
        self.baseURL = baseURL
        self.keyPrefixes = keyPrefixes
    }
}

/// One chat service Dot can talk to.
///
/// A row is the address, the wire shape and the suggestions for one vendor. The
/// row's ``id`` is also the Keychain provider id, which is what lets a vendor
/// that already has a speech key share it: `openai` and `groq` are the same
/// strings the speech providers use.
///
/// The model list is a *suggestion*. Model names change faster than a build
/// does, so the row never treats one as a requirement: the person can type
/// another id in Settings, and the app can fetch the live list.
public struct AssistantProviderRow: Sendable, Equatable, Identifiable {
    /// The stable id written into the configuration, and the Keychain id.
    public let id: String
    /// The vendor's name. Never a model brand.
    public let name: String
    /// The shape the endpoint speaks unless the settings override it.
    public let style: AssistantAPIStyle
    /// The address the row ships with. `nil` for a row that must be filled in.
    public let defaultBaseURL: URL?
    /// The path the request is posted to, relative to the base URL.
    public let path: String
    /// Suggested models, best first. Every shipped row leaves this empty: a
    /// model list changes faster than a build does, so the list is read from
    /// the service rather than frozen into the catalogue. The property is kept
    /// for the callers that still read it, and so a row can suggest one when
    /// there is a reason to.
    public let defaultModels: [String]
    /// The address a model list is read at, when it is not the request path
    /// appended to the base URL.
    ///
    /// OpenCode Go serves its inference at one address and lists its models at
    /// another, so the row names the list's address rather than deriving it.
    /// `nil` means the address is a base URL plus a path, as every other
    /// vendor's is.
    public let modelsURL: URL?
    /// Whether the service cannot be used without a key.
    public let requiresKey: Bool
    /// The header the key travels in.
    public let authStyle: AuthStyle
    /// Whether the vendor documents a usage chunk on a streamed answer.
    public let includeUsage: Bool
    /// Headers the vendor's documentation asks for that are not the key.
    public let extraHeaders: [String: String]
    /// The header this vendor asks every request of one conversation to carry,
    /// when it asks for one. The value is minted by the provider, never stored
    /// here: a row names the header, not the session.
    public let sessionHeader: AssistantSessionHeader?
    /// A query the request needs, e.g. an Azure legacy `api-version`.
    public let queryItems: [URLQueryItem]
    /// The addresses this vendor also serves, the row's own first. Two entries
    /// make the page show a Plan pop-up.
    public let plans: [AssistantProviderPlan]
    /// The beginnings of the model ids this row cannot be used with, because
    /// the vendor serves them on a wire shape this build does not speak.
    public let excludedModelPrefixes: [String]
    /// Body members only a rewrite sends, so a long reasoning pass cannot slow
    /// a two-sentence rewrite down.
    public let rewriteBody: [String: JSONValue]
    /// The line under the key row, when the vendor's key has a condition worth
    /// stating.
    public let keyNote: String?

    public init(
        id: String,
        name: String,
        style: AssistantAPIStyle,
        defaultBaseURL: URL?,
        path: String,
        defaultModels: [String] = [],
        modelsURL: URL? = nil,
        requiresKey: Bool,
        authStyle: AuthStyle = .bearer,
        includeUsage: Bool = false,
        extraHeaders: [String: String] = [:],
        sessionHeader: AssistantSessionHeader? = nil,
        queryItems: [URLQueryItem] = [],
        plans: [AssistantProviderPlan] = [],
        excludedModelPrefixes: [String] = [],
        rewriteBody: [String: JSONValue] = [:],
        keyNote: String? = nil
    ) {
        self.id = id
        self.name = name
        self.style = style
        self.defaultBaseURL = defaultBaseURL
        self.path = path
        self.defaultModels = defaultModels
        self.modelsURL = modelsURL
        self.requiresKey = requiresKey
        self.authStyle = authStyle
        self.includeUsage = includeUsage
        self.extraHeaders = extraHeaders
        self.sessionHeader = sessionHeader
        self.queryItems = queryItems
        self.plans = plans
        self.excludedModelPrefixes = excludedModelPrefixes
        self.rewriteBody = rewriteBody
        self.keyNote = keyNote
    }

    /// The hosts this row may be asked to send a key to.
    ///
    /// A model list can name the address a model is served at, and a service
    /// that has been compromised — or a proxy that answers in its place — could
    /// name a stranger's host and be handed the person's key. Only the hosts
    /// the catalogue itself ships for the row are trusted: its default address,
    /// the address its list is read at, and the addresses of its plans.
    public var trustedRouteHosts: Set<String> {
        var hosts = Set<String>()
        for address in [defaultBaseURL, modelsURL] + plans.map(\.baseURL) {
            guard let host = address?.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !host.isEmpty
            else { continue }
            hosts.insert(host)
        }
        return hosts
    }

    /// The row under a different id, for an endpoint the catalogue does not
    /// know. The key stays the person's own item.
    func withID(_ newID: String) -> AssistantProviderRow {
        AssistantProviderRow(
            id: newID,
            name: name,
            style: style,
            defaultBaseURL: defaultBaseURL,
            path: path,
            defaultModels: defaultModels,
            modelsURL: modelsURL,
            requiresKey: requiresKey,
            authStyle: authStyle,
            includeUsage: includeUsage,
            extraHeaders: extraHeaders,
            sessionHeader: sessionHeader,
            queryItems: queryItems,
            plans: plans,
            excludedModelPrefixes: excludedModelPrefixes,
            rewriteBody: rewriteBody,
            keyNote: keyNote
        )
    }
}

/// The ids of rows the app names for something other than a pop-up.
///
/// A view may only show the name a row carries, so the id of a service the app
/// has to mention (a render's sample, a test's case) lives here with the data
/// rather than in a string in the UI.
public enum AssistantProviderID {
    /// The vendor that also sells speech-to-text, under one key.
    public static let xiaomi = "xiaomi"
    /// The subscription service whose catalogue is read from the endpoint.
    public static let openCodeGo = "opencode-go"
}

/// A header a vendor asks every request of one conversation to carry.
///
/// The value is not a credential and not a setting: the client mints one id per
/// conversation and sends that same id with every request of it, so the service
/// can route the conversation and reuse its cache. A row that names a header is
/// the only thing that makes a provider send one, so a service that never asked
/// for it — another vendor, or an endpoint the catalogue does not know — never
/// receives it.
public enum AssistantSessionHeader: String, Sendable, Equatable {
    /// OpenCode Go's documented header. Go answers an inference request that
    /// arrives without one with `400 MissingSessionID`, before it reads the key.
    case openCodeGo = "x-opencode-session"

    /// A session id in the shape the vendors write one: a `ses_` prefix and a
    /// lowercase UUID.
    ///
    /// The value is opaque to Dot and carries nothing about the person, the
    /// account or the key. It exists so the service can recognize the requests
    /// of one conversation, and it is minted from the system's random source
    /// rather than stored anywhere.
    static func makeIdentifier() -> String {
        "ses_" + UUID().uuidString.lowercased()
    }
}

/// The chat services Dot ships a row for.
///
/// This list is deliberately separate from ``ProviderPreset/declared`` and from
/// ``ProviderRegistry/builtInIDs``: those drive the speech selection, the
/// twenty-second speech probe and the launch fallback, and a chat id in either
/// of them would select a service that cannot transcribe.
public enum AssistantProviderCatalogue {
    /// The endpoint for anything the catalogue does not name.
    public static let customRow = AssistantProviderRow(
        id: "custom",
        name: "Custom endpoint",
        style: .openAICompatible,
        defaultBaseURL: nil,
        path: "chat/completions",
        requiresKey: false
    )

    /// The longest answer Anthropic is asked for, in its own token unit.
    public static let anthropicAnswerLimit = 1024

    /// The version a legacy Azure deployment URL is called with.
    ///
    /// Azure's v1 form takes no version at all, but a deployment URL
    /// (`.../openai/deployments/<name>/chat/completions`) is only served with
    /// `api-version`, so one is supplied when that shape is detected.
    public static let legacyAzureAPIVersion = "2024-06-01"

    /// Every row, in the order Settings shows them.
    public static let rows: [AssistantProviderRow] = [
        AssistantProviderRow(
            id: "openai",
            name: "OpenAI",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.openai.com/v1"),
            path: "chat/completions",
            requiresKey: true,
            includeUsage: true
        ),
        AssistantProviderRow(
            id: "groq",
            name: "Groq",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.groq.com/openai/v1"),
            path: "chat/completions",
            requiresKey: true
        ),
        AssistantProviderRow(
            id: "anthropic",
            name: "Anthropic",
            style: .anthropic,
            defaultBaseURL: URL(string: "https://api.anthropic.com"),
            path: "v1/messages",
            requiresKey: true
        ),
        AssistantProviderRow(
            id: "google",
            name: "Google",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai"),
            path: "chat/completions",
            requiresKey: true
        ),
        AssistantProviderRow(
            id: "openrouter",
            name: "OpenRouter",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://openrouter.ai/api/v1"),
            path: "chat/completions",
            requiresKey: true,
            extraHeaders: [
                "HTTP-Referer": "https://dot.mac",
                "X-OpenRouter-Title": "Dot",
            ]
        ),
        AssistantProviderRow(
            id: "xai",
            name: "xAI",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.x.ai/v1"),
            path: "chat/completions",
            requiresKey: true
        ),
        AssistantProviderRow(
            id: "deepseek",
            name: "DeepSeek",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.deepseek.com"),
            path: "chat/completions",
            requiresKey: true
        ),
        AssistantProviderRow(
            id: "mistral",
            name: "Mistral",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.mistral.ai/v1"),
            path: "chat/completions",
            requiresKey: true
        ),
        AssistantProviderRow(
            id: "ollama",
            name: "Ollama",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "http://localhost:11434/v1"),
            path: "chat/completions",
            requiresKey: false
        ),
        AssistantProviderRow(
            id: "lmstudio",
            name: "LM Studio",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "http://localhost:1234/v1"),
            path: "chat/completions",
            requiresKey: false
        ),
        AssistantProviderRow(
            id: "azure-openai",
            name: "Azure OpenAI",
            style: .openAICompatible,
            // The v1 form: no api-version, the standard OpenAI path. The
            // resource name is a placeholder the person replaces. A legacy
            // deployment URL typed as the base URL also works: appending
            // `chat/completions` to `/openai/deployments/<name>` is the legacy
            // path, and `legacyAzureQuery` adds the version it needs.
            defaultBaseURL: URL(string: "https://example.openai.azure.com/openai/v1"),
            path: "chat/completions",
            requiresKey: true,
            authStyle: .apiKey
        ),
        AssistantProviderRow(
            id: "opencode-go",
            name: "OpenCode Go",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://opencode.ai/inference/go/openai/v1"),
            path: "chat/completions",
            // Go serves inference under `/openai/v1` and `/anthropic/v1` and
            // lists what the subscription offers at the plan's own address, so
            // the list is read there rather than under the inference base.
            modelsURL: URL(string: "https://opencode.ai/inference/go/v1/models"),
            requiresKey: true,
            // Every Go inference request must name the conversation it belongs
            // to, stable for that conversation. The provider mints the id; the
            // row only says which header carries it.
            sessionHeader: .openCodeGo,
            // The same subscription serves a Responses-API-only catalogue that
            // this build cannot speak, so those ids are never offered.
            excludedModelPrefixes: ["grok-", "gpt-", "muse-spark-"]
        ),
        AssistantProviderRow(
            // The same vendor the speech page calls `xiaomi`, so one key serves
            // both capabilities.
            id: "xiaomi",
            name: "Xiaomi",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.xiaomimimo.com/v1"),
            path: "chat/completions",
            requiresKey: true,
            // A subscription answers on its own host and hands out keys that
            // say so; the page offers the choice, and a pasted subscription key
            // selects it on its own.
            plans: [
                AssistantProviderPlan(id: "pay-as-you-go", title: "Pay as you go", baseURL: nil),
                AssistantProviderPlan(
                    id: "token-plan",
                    title: "Token Plan",
                    baseURL: URL(string: "https://token-plan-cn.xiaomimimo.com/v1"),
                    keyPrefixes: ["tp-", "ttp-"]
                ),
            ],
            // A rewrite is two sentences and a reasoning pass can take a minute
            // over them. The vendor documents the switch on its OpenAI-shaped
            // API, and the assistant itself keeps the default.
            rewriteBody: ["thinking": .object(["type": .string("disabled")])]
        ),
        customRow,
    ]
}

extension AssistantProviderCatalogue {
    /// How the catalogue reads an id.
    ///
    /// - Parameter id: the id stored in the settings.
    /// - Returns: the row the catalogue ships, or a custom row under that id.
    ///   An id this build does not know is treated as a custom endpoint so a
    ///   configuration written by a newer build still opens; the person's key
    ///   item keeps its own name either way.
    public static func row(for id: String) -> AssistantProviderRow {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = rows.first(where: { $0.id == trimmed }) { return match }
        return customRow.withID(trimmed.isEmpty ? customRow.id : trimmed)
    }

    /// The row the catalogue ships under an id, when it names one.
    public static func shippedRow(for id: String) -> AssistantProviderRow? {
        rows.first { $0.id == id }
    }

    /// The address a request is posted to.
    ///
    /// A typed address replaces the row's and goes through ``EndpointPolicy``,
    /// so a proxy is held to the same rule as a speech endpoint: TLS unless it
    /// is this Mac.
    public static func resolvedBaseURL(
        settings: AssistantSettings,
        row: AssistantProviderRow
    ) throws -> URL? {
        let typed = settings.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let typed, !typed.isEmpty {
            return try EndpointPolicy.url(from: typed)
        }
        return row.defaultBaseURL
    }

    /// The model id a provider is asked for.
    public static func model(for settings: AssistantSettings) -> String {
        settings.resolvedModel(using: row(for: settings.resolvedProviderID).defaultModels)
    }

    /// The plan a record's address names.
    ///
    /// - Parameters:
    ///   - settings: the chat settings.
    ///   - row: the catalogue row.
    /// - Returns: the plan whose address the record carries, the row's own plan
    ///   when it carries none, and `nil` for a vendor that sells only one.
    public static func plan(
        for settings: AssistantSettings,
        row: AssistantProviderRow
    ) -> AssistantProviderPlan? {
        guard let first = row.plans.first else { return nil }
        let typed = settings.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !typed.isEmpty else { return first }
        return row.plans.first { $0.baseURL?.absoluteString == typed } ?? first
    }

    /// The plan a key belongs to, when the vendor hands its plans their own
    /// prefixes.
    ///
    /// - Parameters:
    ///   - key: what the person pasted.
    ///   - row: the catalogue row.
    /// - Returns: the plan that hands out that kind of key, if any.
    public static func plan(impliedByKey key: String, row: AssistantProviderRow) -> AssistantProviderPlan? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        return row.plans.first { plan in
            plan.keyPrefixes.contains { trimmed.hasPrefix($0) }
        }
    }

    /// The plan a stored key moves the record to, when it names another one.
    ///
    /// A key pasted while the other plan is selected moves the address, so the
    /// service is never asked at a host that will refuse the key. A key that
    /// names the plan already in use changes nothing.
    ///
    /// - Parameters:
    ///   - key: what the person stored.
    ///   - settings: the chat settings before the key.
    ///   - row: the catalogue row.
    /// - Returns: the plan the key belongs to, or `nil` when the address stays
    ///   as it is.
    public static func movedPlan(
        forStoredKey key: String,
        settings: AssistantSettings,
        row: AssistantProviderRow
    ) -> AssistantProviderPlan? {
        guard let implied = plan(impliedByKey: key, row: row) else { return nil }
        guard implied.id != plan(for: settings, row: row)?.id else { return nil }
        return implied
    }

    /// The query a legacy Azure deployment URL needs.
    ///
    /// - Parameters:
    ///   - row: the catalogue row.
    ///   - baseURL: the address the request is built from.
    /// - Returns: one `api-version` item for a deployment URL that does not
    ///   already carry one, otherwise nothing.
    public static func legacyAzureQuery(
        row: AssistantProviderRow,
        baseURL: URL
    ) -> [URLQueryItem] {
        guard row.id == "azure-openai",
              baseURL.absoluteString.contains("/deployments/"),
              !baseURL.absoluteString.lowercased().contains("api-version")
        else { return [] }
        return [URLQueryItem(name: "api-version", value: legacyAzureAPIVersion)]
    }

    /// The path a request is posted to, when a discovered model names another
    /// wire shape than the row does.
    ///
    /// OpenCode Go serves two shapes under one subscription: chat completions
    /// under its OpenAI address and messages under its Anthropic one. A model
    /// the service lists with a route is posted to that route's own path,
    /// because the row's path belongs to the row's shape.
    ///
    /// - Parameter style: the shape the route speaks.
    /// - Returns: the path relative to the route's base URL.
    public static func path(for style: AssistantAPIStyle) -> String {
        style == .anthropic ? "messages" : "chat/completions"
    }

    /// The route a discovered model names, when it may be used as it is.
    ///
    /// A discovered route is only honoured for a person who has not typed an
    /// address or a shape: a typed value is a decision of their own, and a
    /// model's metadata may not silently replace it. The model also has to be
    /// the one the record names, so a discovery that belongs to a model the
    /// person has since replaced cannot route the new one.
    ///
    /// A route is metadata from the service, and the request carries the key,
    /// so the address is held to the hosts the catalogue ships for the row. A
    /// service that names a stranger's host is answered on the row's own
    /// address instead of being handed the key.
    ///
    /// - Parameters:
    ///   - settings: the sanitized chat settings.
    ///   - discovered: the model the settings carry, when they carry one.
    /// - Returns: the route to post to, or `nil` for the row's own.
    static func discoveredRoute(
        settings: AssistantSettings,
        discovered: DiscoveredModel?
    ) -> ModelAPIRoute? {
        guard let discovered,
              discovered.id == settings.model,
              settings.baseURL == nil,
              settings.apiStyle == nil,
              let route = discovered.route,
              routeIsTrusted(route, row: row(for: settings.resolvedProviderID))
        else { return nil }
        return route
    }

    /// Whether a discovered route may carry a request that holds the key.
    ///
    /// - Parameters:
    ///   - route: the address and shape the service published.
    ///   - row: the catalogue row the request belongs to.
    /// - Returns: `true` only for an address on a host the row ships, with no
    ///   credentials in the URL and a scheme ``EndpointPolicy`` accepts.
    static func routeIsTrusted(_ route: ModelAPIRoute, row: AssistantProviderRow) -> Bool {
        guard let host = route.baseURL.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty,
              row.trustedRouteHosts.contains(host),
              route.baseURL.user == nil,
              route.baseURL.password == nil
        else { return false }
        return EndpointPolicy.validate(route.baseURL) == nil
    }

    /// The body members a reasoning choice adds to a request.
    ///
    /// The members come from what the service published about the model and
    /// from the one choice the person made in Settings. Nothing is invented: a
    /// model that publishes no efforts gets none, and a shape that has no way
    /// to express a choice is sent nothing rather than a guess.
    ///
    /// - Parameters:
    ///   - variant: the choice from the settings, `nil` for "the service's own".
    ///   - model: the discovered model, when one was discovered.
    ///   - row: the catalogue row.
    ///   - style: the shape the request is posted as.
    /// - Returns: the members to merge into the request body.
    static func reasoningBody(
        variant: String?,
        model: DiscoveredModel?,
        row: AssistantProviderRow,
        style: AssistantAPIStyle
    ) -> [String: JSONValue] {
        guard let variant = variant?.trimmingCharacters(in: .whitespacesAndNewlines),
              !variant.isEmpty
        else { return [:] }
        // A choice is only sent when the model published it. A hand-edited
        // file, or a discovery that arrived with a level this build does not
        // know, must not become an effort the service never documented.
        guard let reasoning = model?.reasoning, reasoning.supportsReasoning else { return [:] }
        let choice = variant.lowercased()
        switch choice {
        case "off", "on":
            guard reasoning.toggle else { return [:] }
        default:
            guard reasoning.efforts.contains(choice) else { return [:] }
        }
        switch style {
        case .openAICompatible:
            if choice == "off" {
                // Two ways to turn reasoning off are documented: a vendor's
                // `thinking` switch, and Xiaomi's rewrite switch, which this
                // build already sends for a rewrite.
                return ["thinking": .object(["type": .string("disabled")])]
            }
            if choice == "on" {
                return ["thinking": .object(["type": .string("enabled")])]
            }
            // OpenRouter takes an effort inside its own `reasoning` object;
            // every other compatible service documents `reasoning_effort`.
            if row.id == "openrouter" {
                return ["reasoning": .object(["effort": .string(choice)])]
            }
            return ["reasoning_effort": .string(choice)]
        case .anthropic:
            if choice == "off" {
                return ["thinking": .object(["type": .string("disabled")])]
            }
            if choice == "on" {
                // Anthropic's `enabled` thinking needs a token budget this
                // build's answer does not leave room for; only the adaptive
                // form can be asked for as it stands.
                guard reasoning.thinkingTypes.contains("adaptive") else { return [:] }
                return ["thinking": .object(["type": .string("adaptive")])]
            }
            var body: [String: JSONValue] = ["output_config": .object(["effort": .string(choice)])]
            if reasoning.thinkingTypes.contains("adaptive") {
                body["thinking"] = .object(["type": .string("adaptive")])
            }
            return body
        }
    }

    /// The reasoning choice a rewrite asks for, from what the model published.
    ///
    /// A rewrite is two sentences, and a reasoning pass over them is time the
    /// person spends waiting for words they did not ask to see. The choice is
    /// therefore the lightest level the model offers rather than the one made
    /// in Settings: a model that can be switched off is asked for `off`, and a
    /// model that only publishes efforts is asked for the lowest of them. A
    /// model that publishes no reasoning control is sent no member at all,
    /// because an effort it never documented would be refused at the service.
    ///
    /// - Parameter model: the discovered model, when one was discovered.
    /// - Returns: the variant to hand to ``reasoningBody(variant:model:row:style:)``,
    ///   or `nil` when the model publishes nothing to choose.
    static func rewriteReasoningVariant(for model: DiscoveredModel?) -> String? {
        guard let reasoning = model?.reasoning, reasoning.supportsReasoning else { return nil }
        if reasoning.toggle { return "off" }
        // The documented levels, lightest first. The order is what decides the
        // choice: a service that lists its efforts in any order is still asked
        // for the one that thinks least.
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        let published = Set(reasoning.efforts.map { $0.lowercased() })
        return order.first { published.contains($0) }
    }

    /// Builds the provider one turn sends with.
    ///
    /// - Parameters:
    ///   - settings: the assistant's record. It is sanitized here, so a
    ///     hand-edited step count cannot reach the turn loop.
    ///   - apiKey: the key, when the person has one.
    ///   - session: the session to send with, or `nil` for a fresh one. A
    ///     session is never retained past the provider.
    ///   - temperature: a sampling temperature that replaces the one stored in
    ///     the settings.
    ///   - forRewrite: whether the request is a rewrite rather than an answer.
    ///     A rewrite asks for the lightest reasoning the model publishes, from
    ///     ``rewriteReasoningVariant(for:)``, instead of the level stored in the
    ///     settings: a two sentence rewrite should not wait for a minute of
    ///     thinking. The row's own rewrite members are still sent, and a model
    ///     that publishes no reasoning control gets only those.
    /// - Returns: a provider for the row's wire shape.
    /// - Throws: ``ProviderError/missingCredential(_:)`` when the row needs a
    ///   key that is absent, ``ProviderError/unavailable(_:)`` when no address
    ///   is known, ``EndpointPolicy/Rejection`` when a typed address is refused.
    public static func makeProvider(
        settings: AssistantSettings,
        apiKey: String?,
        session: URLSession? = nil,
        temperature: Double? = nil,
        forRewrite: Bool = false
    ) throws -> any ChatProvider {
        let settings = settings.sanitized()
        let row = row(for: settings.resolvedProviderID)
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if row.requiresKey, key?.isEmpty != false {
            throw ProviderError.missingCredential("Add a key for \(row.name) to use AI rewrite.")
        }
        let discovered = settings.discoveredModel
        let route = discoveredRoute(settings: settings, discovered: discovered)
        let baseURL: URL
        if let route {
            // A route came from the service, but it is still posted to over the
            // same rule as a typed address: TLS unless it is this Mac.
            if let rejection = EndpointPolicy.validate(route.baseURL) { throw rejection }
            baseURL = route.baseURL
        } else {
            guard let resolved = try resolvedBaseURL(settings: settings, row: row) else {
                throw ProviderError.unavailable("Add the address of the \(row.name) endpoint.")
            }
            baseURL = resolved
        }
        let style = route?.style ?? settings.apiStyle ?? row.style
        let path = route == nil ? row.path : path(for: style)
        // A model that published "no temperature" rejects the member outright,
        // so it is left out rather than sent and refused.
        let sampling = discovered?.supportsTemperature == false ? nil : temperature ?? settings.temperature
        var extraBody: [String: JSONValue] = forRewrite ? row.rewriteBody : [:]
        // A rewrite asks the model for the lightest reasoning it publishes, so
        // the level chosen for the assistant never makes a two sentence rewrite
        // wait on a thinking pass. The answer keeps the stored choice.
        let variant = forRewrite
            ? rewriteReasoningVariant(for: discovered)
            : settings.reasoningVariant
        for (name, value) in reasoningBody(
            variant: variant,
            model: discovered,
            row: row,
            style: style
        ) {
            extraBody[name] = value
        }
        switch style {
        case .openAICompatible:
            return OpenAIChatProvider(
                baseURL: baseURL,
                path: path,
                queryItems: row.queryItems + legacyAzureQuery(row: row, baseURL: baseURL),
                apiKey: key,
                authStyle: row.authStyle,
                extraHeaders: row.extraHeaders,
                sessionHeader: row.sessionHeader,
                temperature: sampling,
                includeUsage: row.includeUsage,
                extraBody: extraBody,
                session: session ?? OpenAIChatProvider.makeSession()
            )
        case .anthropic:
            return AnthropicChatProvider(
                baseURL: baseURL,
                path: path,
                apiKey: key,
                extraHeaders: row.extraHeaders,
                sessionHeader: row.sessionHeader,
                maxTokens: anthropicAnswerLimit,
                temperature: sampling,
                extraBody: extraBody,
                session: session ?? AnthropicChatProvider.makeSession()
            )
        }
    }
}
