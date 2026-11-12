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
    /// Suggested models, best first. The first one is the default.
    public let defaultModels: [String]
    /// Whether the service cannot be used without a key.
    public let requiresKey: Bool
    /// The header the key travels in.
    public let authStyle: AuthStyle
    /// Whether the vendor documents a usage chunk on a streamed answer.
    public let includeUsage: Bool
    /// Headers the vendor's documentation asks for that are not the key.
    public let extraHeaders: [String: String]
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
        requiresKey: Bool,
        authStyle: AuthStyle = .bearer,
        includeUsage: Bool = false,
        extraHeaders: [String: String] = [:],
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
        self.requiresKey = requiresKey
        self.authStyle = authStyle
        self.includeUsage = includeUsage
        self.extraHeaders = extraHeaders
        self.queryItems = queryItems
        self.plans = plans
        self.excludedModelPrefixes = excludedModelPrefixes
        self.rewriteBody = rewriteBody
        self.keyNote = keyNote
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
            requiresKey: requiresKey,
            authStyle: authStyle,
            includeUsage: includeUsage,
            extraHeaders: extraHeaders,
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
            defaultModels: ["gpt-4o-mini", "gpt-4o"],
            requiresKey: true,
            includeUsage: true
        ),
        AssistantProviderRow(
            id: "groq",
            name: "Groq",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.groq.com/openai/v1"),
            path: "chat/completions",
            defaultModels: ["llama-3.3-70b-versatile", "llama-3.1-8b-instant"],
            requiresKey: true
        ),
        AssistantProviderRow(
            id: "anthropic",
            name: "Anthropic",
            style: .anthropic,
            defaultBaseURL: URL(string: "https://api.anthropic.com"),
            path: "v1/messages",
            defaultModels: ["claude-sonnet-4-20250514", "claude-3-5-haiku-20241022"],
            requiresKey: true
        ),
        AssistantProviderRow(
            id: "google",
            name: "Google",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai"),
            path: "chat/completions",
            defaultModels: ["gemini-2.0-flash", "gemini-2.5-pro"],
            requiresKey: true
        ),
        AssistantProviderRow(
            id: "openrouter",
            name: "OpenRouter",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://openrouter.ai/api/v1"),
            path: "chat/completions",
            defaultModels: ["openai/gpt-4o-mini", "anthropic/claude-sonnet-4"],
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
            defaultModels: ["grok-3-mini", "grok-3"],
            requiresKey: true
        ),
        AssistantProviderRow(
            id: "deepseek",
            name: "DeepSeek",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.deepseek.com"),
            path: "chat/completions",
            defaultModels: ["deepseek-chat", "deepseek-reasoner"],
            requiresKey: true
        ),
        AssistantProviderRow(
            id: "mistral",
            name: "Mistral",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.mistral.ai/v1"),
            path: "chat/completions",
            defaultModels: ["mistral-large-latest", "mistral-small-latest"],
            requiresKey: true
        ),
        AssistantProviderRow(
            id: "ollama",
            name: "Ollama",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "http://localhost:11434/v1"),
            path: "chat/completions",
            defaultModels: ["llama3.2", "qwen2.5"],
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
            defaultModels: ["deepseek-v4.1-flash", "glm-5.3", "kimi-k3", "mimo-v2.6-flash", "qwen3.8-flash"],
            requiresKey: true,
            // The same subscription serves a Responses-API-only catalogue that
            // this build cannot speak, so those ids are never offered.
            excludedModelPrefixes: ["grok-", "gpt-", "muse-spark-"],
            keyNote: "Uses your OpenCode Go subscription key."
        ),
        AssistantProviderRow(
            // The same vendor the speech page calls `xiaomi`, so one key serves
            // both capabilities.
            id: "xiaomi",
            name: "Xiaomi",
            style: .openAICompatible,
            defaultBaseURL: URL(string: "https://api.xiaomimimo.com/v1"),
            path: "chat/completions",
            defaultModels: ["mimo-v2.6-flash", "mimo-v2.6-pro"],
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
        settings.resolvedModel(using: row(for: settings.providerID).defaultModels)
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
    ///     A row may turn a vendor's reasoning off for one: a two sentence
    ///     rewrite should not wait for a minute of thinking.
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
        let row = row(for: settings.providerID)
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if row.requiresKey, key?.isEmpty != false {
            throw ProviderError.missingCredential("Add a key for \(row.name) to use the assistant.")
        }
        guard let baseURL = try resolvedBaseURL(settings: settings, row: row) else {
            throw ProviderError.unavailable("Add the address of the \(row.name) endpoint.")
        }
        switch settings.apiStyle ?? row.style {
        case .openAICompatible:
            return OpenAIChatProvider(
                baseURL: baseURL,
                path: row.path,
                queryItems: row.queryItems + legacyAzureQuery(row: row, baseURL: baseURL),
                apiKey: key,
                authStyle: row.authStyle,
                extraHeaders: row.extraHeaders,
                temperature: temperature ?? settings.temperature,
                includeUsage: row.includeUsage,
                extraBody: forRewrite ? row.rewriteBody : [:],
                session: session ?? OpenAIChatProvider.makeSession()
            )
        case .anthropic:
            return AnthropicChatProvider(
                baseURL: baseURL,
                path: row.path,
                apiKey: key,
                extraHeaders: row.extraHeaders,
                maxTokens: anthropicAnswerLimit,
                temperature: temperature ?? settings.temperature,
                session: session ?? AnthropicChatProvider.makeSession()
            )
        }
    }
}
