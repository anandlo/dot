import DotCore
import Foundation

/// The chat service a rewrite is asked of.
///
/// It is a protocol so a test can stream a rewrite from a fake: the runner's
/// job is the state machine around the stream, and the real factory is only the
/// settings-to-provider step the assistant already performs.
@MainActor
protocol RewriteProviderFactory {
    /// The assistant's catalogue id.
    var providerID: String { get }
    /// Whether a key is stored, answered without decrypting it.
    func hasKey() -> Bool
    /// The model a rewrite is asked for.
    func model() -> String
    /// Builds a provider with the rewrite's own sampling temperature.
    func makeProvider(temperature: Double) async throws -> any ChatProvider
}

/// The live factory: the assistant's configuration, its key and its model.
struct AssistantRewriteProviderFactory: RewriteProviderFactory {
    /// The session cache every key read goes through.
    let credentials: CredentialCache
    /// The assistant's block of the configuration.
    let configuration: () -> AssistantConfiguration

    var providerID: String { configuration().chat.providerID }

    func hasKey() -> Bool {
        AssistantCredentials.hasKey(for: providerID)
    }

    func model() -> String {
        AssistantProviderCatalogue.model(for: configuration().chat)
    }

    func makeProvider(temperature: Double) async throws -> any ChatProvider {
        let chat = configuration().chat
        let row = AssistantProviderCatalogue.row(for: chat.providerID)
        // A service on this Mac has no key, and reading one would ask the
        // person for a Keychain item they never made.
        let key = row.requiresKey
            ? await AssistantCredentials.resolvedKey(for: chat.providerID, cache: credentials)
            : nil
        return try AssistantProviderCatalogue.makeProvider(
            settings: chat,
            apiKey: key,
            temperature: temperature
        )
    }
}
