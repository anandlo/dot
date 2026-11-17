import Foundation

/// The wire shape a chat endpoint speaks.
///
/// Most services speak the OpenAI Chat Completions shape, including the local
/// ones. Anthropic's Messages shape is served by Anthropic, by LM Studio and by
/// translators, so it is a setting rather than a property of an address.
///
/// The raw values are stable: they are written into the configuration file.
public enum AssistantAPIStyle: String, Codable, Sendable, CaseIterable {
    /// `POST {base}/chat/completions`, `data: [DONE]`, positional tool calls.
    case openAICompatible = "openai"
    /// `POST {base}/v1/messages`, named stream events, `tool_use` blocks.
    case anthropic
}

/// How the assistant talks to its language model.
///
/// The fields are the five a person can change plus the shape override a custom
/// endpoint may need. Everything else about a vendor lives in the catalogue, so
/// this record cannot disagree with the endpoint it ships.
///
/// Every key decodes tolerantly, and every enum-valued key decodes through
/// `try?`: a hand-edited spelling must not reset the rest of the file, which is
/// the rule the rest of Dot's configuration follows.
public struct AssistantSettings: Codable, Sendable, Equatable {
    /// The catalogue id of the chat service, which is also the Keychain id.
    public var providerID: String
    /// The model id. Empty means "the catalogue's first suggestion".
    public var model: String
    /// An address that replaces the catalogue's default, for a proxy or a
    /// server on this Mac.
    public var baseURL: String?
    /// Sampling temperature, when the person set one.
    public var temperature: Double?
    /// How many model turns one request may take before the answer is cut off.
    public var maxSteps: Int
    /// A shape override for an endpoint that does not match its catalogue row.
    public var apiStyle: AssistantAPIStyle?
    /// The reasoning variant the person chose for the selected model.
    ///
    /// The values are the service's own: `"off"`, `"on"`, or one of the effort
    /// levels the model published. `nil` means the service's default, which is
    /// what a fresh install and every model without a choice keep.
    public var reasoningVariant: String?
    /// What the service published about the selected model.
    ///
    /// It is stored beside the model because the request needs it without a
    /// network call: whether the model accepts a temperature, which shape and
    /// address serve it, and which reasoning levels it publishes. It describes
    /// one model at one service, so it is cleared when the model or the service
    /// changes.
    public var discoveredModel: DiscoveredModel?

    /// The largest number of steps a turn may take.
    public static let maximumSteps = 8
    /// The smallest number of steps that still allows one tool round.
    public static let minimumSteps = 1
    /// The provider a fresh configuration points at.
    public static let defaultProviderID = "openai"
    /// The number of model turns a fresh configuration allows.
    public static let defaultMaxSteps = 6

    public init(
        providerID: String = AssistantSettings.defaultProviderID,
        model: String = "",
        baseURL: String? = nil,
        temperature: Double? = nil,
        maxSteps: Int = AssistantSettings.defaultMaxSteps,
        apiStyle: AssistantAPIStyle? = nil,
        reasoningVariant: String? = nil,
        discoveredModel: DiscoveredModel? = nil
    ) {
        self.providerID = providerID
        self.model = model
        self.baseURL = baseURL
        self.temperature = temperature
        self.maxSteps = maxSteps
        self.apiStyle = apiStyle
        self.reasoningVariant = reasoningVariant
        self.discoveredModel = discoveredModel
    }

    /// The settings a fresh install starts with.
    public static let `default` = AssistantSettings()

    /// The provider id every reader should use: trimmed, with the build's
    /// default when the stored value is blank.
    ///
    /// It is one function because three places ask two questions of the same
    /// id — which catalogue row, and which Keychain item. A hand-edited file
    /// with a space around its id must not answer them differently, so the
    /// request builder, the menu and the settings page all read this.
    public var resolvedProviderID: String {
        let trimmed = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultProviderID : trimmed
    }

    /// The model to ask for, given the catalogue's suggestions.
    ///
    /// - Parameter suggestions: the models the catalogue offers for the row.
    /// - Returns: the configured model, or the first suggestion, or an empty
    ///   string when there is nothing to choose.
    public func resolvedModel(using suggestions: [String]) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return suggestions.first ?? ""
    }

    /// The record with every value inside its allowed range.
    ///
    /// Applied on read and on save: a hand-edited step count cannot make a turn
    /// run forever, and a temperature outside the range a service accepts is
    /// clamped instead of being refused.
    public func sanitized() -> AssistantSettings {
        var copy = self
        copy.providerID = resolvedProviderID
        copy.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let address = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), address.isEmpty {
            copy.baseURL = nil
        } else {
            copy.baseURL = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        copy.temperature = temperature.map { min(max($0, 0), 2) }
        copy.maxSteps = min(max(maxSteps, Self.minimumSteps), Self.maximumSteps)
        if let variant = reasoningVariant?.trimmingCharacters(in: .whitespacesAndNewlines),
           variant.isEmpty {
            copy.reasoningVariant = nil
        } else {
            copy.reasoningVariant = reasoningVariant?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A discovery belongs to the model it describes. A record that names
        // another model cannot route a request through it, so it is dropped
        // rather than left to disagree with the settings the picker shows.
        if let discoveredModel, discoveredModel.id != copy.model {
            copy.discoveredModel = nil
        }
        return copy
    }

    /// The record after the person picks a service.
    ///
    /// Everything a service publishes about a model is that service's, so a
    /// discovery and its reasoning choice do not survive the move: a level one
    /// vendor documents can mean nothing to another, and a route names an
    /// address the new service does not serve. The model id is the page's to
    /// clear, because it also decides whether a typed address is kept.
    ///
    /// - Parameter id: the catalogue id the person chose.
    public mutating func selectProvider(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != resolvedProviderID else { return }
        providerID = trimmed
        reasoningVariant = nil
        discoveredModel = nil
    }

    private enum CodingKeys: String, CodingKey {
        case providerID = "provider"
        case model
        case baseURL
        case temperature
        case maxSteps
        case apiStyle
        case reasoningVariant
        case discoveredModel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AssistantSettings.default
        providerID = (try? container.decodeIfPresent(String.self, forKey: .providerID))
            ?? fallback.providerID
        model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? fallback.model
        baseURL = (try? container.decodeIfPresent(String.self, forKey: .baseURL)) ?? nil
        temperature = (try? container.decodeIfPresent(Double.self, forKey: .temperature)) ?? nil
        maxSteps = (try? container.decodeIfPresent(Int.self, forKey: .maxSteps)) ?? fallback.maxSteps
        // The enum is read the tolerant way for the same reason every other
        // enum in the configuration is: a spelling this build does not know
        // must not throw the rest of the record away.
        apiStyle = (try? container.decodeIfPresent(AssistantAPIStyle.self, forKey: .apiStyle)) ?? nil
        // A discovery describes one model at one service. A value this build
        // cannot read says nothing, and the model is still asked for by id.
        reasoningVariant = (try? container.decodeIfPresent(String.self, forKey: .reasoningVariant)) ?? nil
        discoveredModel = (try? container.decodeIfPresent(DiscoveredModel.self, forKey: .discoveredModel)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerID, forKey: .providerID)
        if !model.isEmpty {
            try container.encode(model, forKey: .model)
        }
        try container.encodeIfPresent(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encode(maxSteps, forKey: .maxSteps)
        try container.encodeIfPresent(apiStyle, forKey: .apiStyle)
        try container.encodeIfPresent(reasoningVariant, forKey: .reasoningVariant)
        try container.encodeIfPresent(discoveredModel, forKey: .discoveredModel)
    }
}
