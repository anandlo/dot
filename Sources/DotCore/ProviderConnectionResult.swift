import Foundation

/// What happened when Dot turned a chosen service into a provider.
///
/// The Keychain write and the configuration change happen in the app; this
/// value only carries the result to the view. It never holds the key itself.
public struct ProviderConnectionResult: Equatable, Sendable {
    /// How far the setup got.
    public enum Status: Equatable, Sendable {
        /// The service is selected and ready to transcribe.
        case connected
        /// The choice was saved, but the service still needs an endpoint.
        case stored
        /// Nothing could be stored or the provider could not be built.
        case failed
    }

    /// The state the view shows.
    public let status: Status
    /// A sentence for the user. It never contains the key.
    public let message: String
    /// The row the user chose, e.g. "OpenAI".
    public let providerName: String

    /// Creates a result.
    public init(status: Status, message: String, providerName: String) {
        self.status = status
        self.message = message
        self.providerName = providerName
    }

    /// Whether the provider can transcribe now.
    public var isConnected: Bool {
        status == .connected
    }

    /// The short label for a status row.
    ///
    /// It states the state and nothing else. The row above the label already
    /// names the service, and ``message`` already says what happened, so a
    /// label carrying the name as well made one card say the same thing twice.
    public var statusLabel: String {
        switch status {
        case .connected:
            return "Connected"
        case .stored:
            return "Not ready"
        case .failed:
            return "Not connected"
        }
    }

    /// A failed connection that never touched the Keychain.
    public static func failure(
        _ message: String,
        providerName: String
    ) -> ProviderConnectionResult {
        ProviderConnectionResult(status: .failed, message: message, providerName: providerName)
    }

    /// Describes the change a chosen row and its key produced.
    ///
    /// The view never decides this: it hands over the row the user picked and
    /// the key, and this factory reads the configuration back to say whether a
    /// provider can be built from it.
    ///
    /// - Parameters:
    ///   - preset: the row the user picked.
    ///   - keyStored: whether a key was written for it.
    ///   - config: the configuration after the choice was applied.
    /// - Returns: the result the view draws.
    public static func make(
        _ preset: ProviderPreset,
        keyStored: Bool,
        config: DotConfig
    ) -> ProviderConnectionResult {
        if (try? ProviderRegistry.selectedProvider(config: config, credentials: .empty)) != nil {
            let message = keyStored
                ? "Key saved. Using \(preset.name)."
                : "Using \(preset.name). No key needed."
            return ProviderConnectionResult(
                status: .connected,
                message: message,
                providerName: preset.name
            )
        }
        let message = keyStored
            ? "Key saved. Set the base URL for \(preset.name) in Settings."
            : "Set the base URL for \(preset.name) in Settings."
        return ProviderConnectionResult(status: .stored, message: message, providerName: preset.name)
    }
}
