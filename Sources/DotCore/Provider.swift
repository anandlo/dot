import Foundation

/// A speech-to-text backend.
///
/// Dot does not know or care which model is behind a provider: a provider is
/// a *capability*, and the model is a configuration value. Everything the HUD
/// shows about a provider comes from ``displayName`` and never from a model
/// brand.
public protocol Provider: Sendable {
    /// Stable id used in the configuration file, e.g. `openai`, `xiaomi`.
    var id: String { get }
    /// The implementation's own name, e.g. "OpenAI-compatible". Never a model
    /// brand.
    ///
    /// A surface that has a configuration names the service from its row, which
    /// is the only thing that can say where the speech is actually going.
    var displayName: String { get }
    /// Whether the provider can use an API key.
    ///
    /// The Settings menu offers to store one for the providers that can.
    var requiresCredential: Bool { get }
    /// The longest recording the provider wants in one request, in seconds.
    ///
    /// This is a *capability* of the provider, not a limit Dot imposes: a
    /// longer recording is split into segments of this size and sent one after
    /// the other.
    var maxSegmentSeconds: Int { get }
    /// Can it transcribe right now (key present, service up, ...)?
    func isAvailable() async -> Bool
    /// Transcribe a 16 kHz mono PCM16 WAV. Throws a typed error for the HUD to
    /// show.
    func transcribe(wav: Data, model: String?, language: String?) async throws -> String
}

extension Provider {
    /// A provider uses no API key unless it says otherwise.
    public var requiresCredential: Bool { false }

    /// A provider takes thirty seconds of audio per request unless it says
    /// otherwise.
    public var maxSegmentSeconds: Int { 30 }
}

/// Something went wrong while talking to a provider.
///
/// Every case carries the message the user sees; the HUD shows it verbatim.
public enum ProviderError: Error, Equatable, LocalizedError, Sendable {
    /// The provider cannot be used right now.
    case unavailable(String)
    /// The provider needs a credential that is not in the Keychain.
    case missingCredential(String)
    /// The service answered with something other than a success.
    case rejected(status: Int, message: String?)
    /// The answer was not the shape the provider promised.
    case invalidResponse(String)
    /// The request never made it to the service.
    case transport(String)
    /// The service heard nothing in the recording.
    case noSpeech
    /// The provider cannot run on this machine.
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            detail
        case .missingCredential(let detail):
            detail
        case .rejected(let status, let message):
            // A service, or a proxy in front of one, can answer with a page of
            // markup. What the card shows and the log keeps is the head of it.
            if let message = ProviderErrorText.sanitized(message) {
                "The service answered HTTP \(status): \(message)"
            } else {
                "The service answered HTTP \(status)."
            }
        case .invalidResponse(let detail):
            "The service sent an unexpected answer: "
                + (ProviderErrorText.sanitized(detail) ?? "no detail")
        case .transport(let detail):
            "The service could not be reached: " + (ProviderErrorText.sanitized(detail) ?? "no detail")
        case .noSpeech:
            "No speech was recognised in the recording."
        case .unsupported(let detail):
            detail
        }
    }
}
