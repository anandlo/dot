import Foundation

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
        queryItems: [URLQueryItem] = []
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
            queryItems: queryItems
        )
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
    /// - Returns: a provider for the row's wire shape.
    /// - Throws: ``ProviderError/missingCredential(_:)`` when the row needs a
    ///   key that is absent, ``ProviderError/unavailable(_:)`` when no address
    ///   is known, ``EndpointPolicy/Rejection`` when a typed address is refused.
    public static func makeProvider(
        settings: AssistantSettings,
        apiKey: String?,
        session: URLSession? = nil
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
                temperature: settings.temperature,
                includeUsage: row.includeUsage,
                session: session ?? OpenAIChatProvider.makeSession()
            )
        case .anthropic:
            return AnthropicChatProvider(
                baseURL: baseURL,
                path: row.path,
                apiKey: key,
                extraHeaders: row.extraHeaders,
                maxTokens: anthropicAnswerLimit,
                temperature: settings.temperature,
                session: session ?? AnthropicChatProvider.makeSession()
            )
        }
    }
}
