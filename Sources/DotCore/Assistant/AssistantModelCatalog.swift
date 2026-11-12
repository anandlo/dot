import Foundation

/// The model list a chat service publishes about itself.
///
/// The catalogue ships a few suggestions so the picker is never empty, but a
/// service adds and retires models faster than Dot ships a build. `GET
/// <base>/models` is the request that answers both questions a person asks of a
/// service: whether it works, and what it offers. The status row sends it to
/// check the address and the key, and the model picker sends the same one to
/// fill its list.
public enum AssistantModelCatalog {
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
    /// - Parameters:
    ///   - settings: the chat settings, which name the service and any typed
    ///     address.
    ///   - row: the catalogue row.
    /// - Returns: the address, or `nil` when the row has none and the person
    ///   typed none.
    /// - Throws: ``EndpointPolicy/Rejection`` when a typed address is refused.
    public static func url(settings: AssistantSettings, row: AssistantProviderRow) throws -> URL? {
        guard let base = try AssistantProviderCatalogue.resolvedBaseURL(settings: settings, row: row)
        else { return nil }
        return base.appendingPathComponent(path(for: settings.apiStyle ?? row.style))
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
        let row = AssistantProviderCatalogue.row(for: settings.providerID)
        guard let url = try url(settings: settings, row: row) else {
            throw ProviderError.unavailable("Add the address of the \(row.name) endpoint.")
        }
        if let rejection = EndpointPolicy.validate(url) { throw rejection }
        var request = URLRequest(url: url)
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
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        var seen = Set<String>()
        return payload.data
            .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { id in
                guard !id.isEmpty else { return false }
                guard !prefixes.contains(where: { id.hasPrefix($0) }) else { return false }
                return seen.insert(id).inserted
            }
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
        let request: URLRequest
        do {
            request = try makeRequest(settings: settings, apiKey: apiKey)
        } catch {
            return []
        }
        guard let answer = try? await HTTPTransport.send(request, session: session),
              let response = answer.response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode)
        else { return [] }
        let row = AssistantProviderCatalogue.row(for: settings.sanitized().providerID)
        return models(in: answer.data, excluding: row.excludedModelPrefixes)
    }

    /// The shape both vendors' lists arrive in.
    private struct Payload: Decodable {
        struct Model: Decodable {
            var id: String
        }

        var data: [Model]
    }
}
