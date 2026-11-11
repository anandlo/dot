import Foundation

/// How a provider lets a request keep the audio and the transcript out of
/// server-side retention.
///
/// Dot only offers the zero-retention setting where the request itself carries
/// it. A service whose retention is decided in its own console, or whose host
/// the app cannot speak for, gets no toggle: a switch that changes nothing in
/// the request is a promise the app cannot keep, and the person reading the
/// settings has no way to tell the difference.
public enum RetentionControl: Equatable, Sendable {
    /// A parameter on the request Dot sends, which opts this one request out.
    case perRequest(parameter: String)
    /// A setting in the provider's console or organisation that a request
    /// cannot change.
    case providerSetting
    /// The audio never leaves the Mac.
    case onDevice
    /// The host of a stored endpoint decides, and the request cannot say
    /// anything about it. This is the answer for every endpoint Dot does not
    /// own.
    case endpointPolicy

    /// The control for a provider id.
    ///
    /// The three per-request parameters are the ones the vendors document on the
    /// endpoint Dot calls: Deepgram's `mip_opt_out`, ElevenLabs'
    /// `enable_logging` and Azure's `storeAudio`. OpenAI and Groq both decide
    /// retention at the account or project level, and neither transcription
    /// endpoint accepts a parameter that changes it.
    ///
    /// - Parameter providerID: the id the configuration selects.
    public static func control(for providerID: String) -> RetentionControl {
        switch providerID {
        case ProviderIdentifier.deepgram:
            .perRequest(parameter: "mip_opt_out")
        case ProviderIdentifier.elevenLabs:
            .perRequest(parameter: "enable_logging")
        case ProviderIdentifier.azure:
            .perRequest(parameter: "storeAudio")
        case ProviderIdentifier.openAI, ProviderIdentifier.groq:
            .providerSetting
        case ProviderIdentifier.apple:
            .onDevice
        default:
            .endpointPolicy
        }
    }

    /// Whether the zero-retention setting reaches the request for this provider.
    ///
    /// - Parameter providerID: the id the configuration selects.
    public static func supportsPerRequestControl(_ providerID: String) -> Bool {
        if case .perRequest = control(for: providerID) { return true }
        return false
    }

    /// The request parameter that carries the setting, when there is one.
    ///
    /// - Parameter providerID: the id the configuration selects.
    public static func parameter(for providerID: String) -> String? {
        if case .perRequest(let parameter) = control(for: providerID) { return parameter }
        return nil
    }

    /// One line about who decides retention, for the settings and the docs.
    public var detail: String {
        switch self {
        case .perRequest(let parameter):
            "Dot sends `\(parameter)` with every request."
        case .providerSetting:
            "Retention is set on the provider's own account, not per request, so Dot offers no switch for it."
        case .onDevice:
            "The audio never leaves this Mac."
        case .endpointPolicy:
            "The host of this endpoint decides its retention policy."
        }
    }
}
