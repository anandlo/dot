import Foundation

/// Builds the voice provider a setting names.
///
/// The factory is the one place that turns an id into a type, so the registry
/// that will own assistant configuration has one call to make and one switch to
/// read. It reuses the vendor ids the speech providers already use, which is what
/// makes one Keychain item serve both directions: an OpenAI, ElevenLabs, Azure or
/// Deepgram key typed for dictation is already the key for speech.
public enum VoiceProviderFactory {
    /// Whether a provider can be used without reading its key.
    ///
    /// The question is answered from the Keychain item's attributes, never its
    /// data, so a Settings row can show "configured" without a decrypt and
    /// without a system prompt.
    ///
    /// - Parameter providerID: the vendor id.
    /// - Returns: `true` for the on-device provider and for a vendor whose key
    ///   exists.
    public static func hasKey(providerID: String) -> Bool {
        let id = normalized(providerID)
        if id == VoiceProviderID.apple { return true }
        return CredentialStore.hasKey(for: id)
    }

    /// Builds a provider with a key that has already been resolved.
    ///
    /// - Parameters:
    ///   - providerID: the vendor id, e.g. `cartesia`.
    ///   - apiKey: the key, or `nil` when the person has not stored one.
    ///   - baseURL: an endpoint override, normally the stored provider base URL.
    ///   - region: the Azure region; ignored by the other vendors.
    ///   - language: the language an on-device or Cartesia voice speaks.
    ///   - session: the session to send requests with.
    /// - Returns: the provider, or `nil` when Dot does not know the id.
    public static func make(
        providerID: String,
        apiKey: String?,
        baseURL: URL? = nil,
        region: String = AzureVoiceProvider.defaultRegion,
        language: String? = nil,
        session: URLSession = OpenAICompatibleProvider.makeSession()
    ) -> (any VoiceProvider)? {
        let id = normalized(providerID)
        switch id {
        case VoiceProviderID.apple:
            return AppleVoiceProvider(language: language)
        case VoiceProviderID.cartesia:
            return CartesiaVoiceProvider(
                baseURL: baseURL ?? CartesiaVoiceProvider.defaultBaseURL,
                apiKey: apiKey,
                language: language ?? "en",
                session: session
            )
        case VoiceProviderID.elevenLabs:
            return ElevenLabsVoiceProvider(
                baseURL: baseURL ?? ElevenLabsVoiceProvider.defaultBaseURL,
                apiKey: apiKey,
                session: session
            )
        case VoiceProviderID.azure:
            return AzureVoiceProvider(
                region: region,
                baseURL: baseURL,
                apiKey: apiKey,
                session: session
            )
        case VoiceProviderID.deepgram:
            return DeepgramVoiceProvider(
                baseURL: baseURL ?? DeepgramVoiceProvider.defaultBaseURL,
                apiKey: apiKey,
                session: session
            )
        case VoiceProviderID.openAI:
            return OpenAIVoiceProvider(
                baseURL: baseURL ?? OpenAIVoiceProvider.defaultBaseURL,
                apiKey: apiKey,
                session: session
            )
        default:
            return nil
        }
    }

    /// Builds a provider, resolving its key from the session cache.
    ///
    /// The read happens inside ``CredentialCache``, which decrypts at most once
    /// per provider per session and registers the key with the logger. A caller
    /// on the main actor should warm the cache off the main actor first, which
    /// is what `AppDelegate.warmCredentials()` already does for speech.
    ///
    /// - Parameters:
    ///   - providerID: the vendor id.
    ///   - credentials: the cache the app uses.
    ///   - baseURL: an endpoint override.
    ///   - region: the Azure region.
    ///   - language: the language a voice speaks.
    ///   - session: the session to send requests with.
    /// - Returns: the provider, or `nil` when Dot does not know the id.
    public static func make(
        providerID: String,
        credentials: CredentialCache,
        baseURL: URL? = nil,
        region: String = AzureVoiceProvider.defaultRegion,
        language: String? = nil,
        session: URLSession = OpenAICompatibleProvider.makeSession()
    ) -> (any VoiceProvider)? {
        let id = normalized(providerID)
        let key = id == VoiceProviderID.apple ? nil : credentials.key(for: id)
        return make(
            providerID: id,
            apiKey: key,
            baseURL: baseURL,
            region: region,
            language: language,
            session: session
        )
    }

    /// The id in the form the Keychain and the presets use.
    ///
    /// - Parameter providerID: the id as it was stored or typed.
    /// - Returns: the id, lowercased and trimmed.
    public static func normalized(_ providerID: String) -> String {
        providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The preset of one id.
    ///
    /// - Parameter providerID: the vendor id.
    /// - Returns: the row, or `nil` when Dot does not know the id.
    public static func preset(providerID: String) -> VoiceProviderPreset? {
        VoicePresets.preset(id: normalized(providerID))
    }
}

// MARK: - Keys that can block

extension VoiceProviderFactory {
    /// The longest a caller waits for the Keychain before giving up.
    ///
    /// A decrypting read can sit behind a system prompt for as long as the
    /// person takes. Five seconds is longer than a healthy read and short enough
    /// that a card does not look stuck; when it passes, the provider is built
    /// without a key, which it reports as "not configured" rather than as a
    /// failure.
    public static let credentialTimeout: Duration = .seconds(5)

    /// Builds a provider without blocking the caller on the Keychain.
    ///
    /// The read runs off the caller's actor under ``BoundedWork`` and the answer
    /// is put in ``CredentialCache`` by the cache itself, so a second call in the
    /// same session costs nothing. This is the overload a screen should use: the
    /// synchronous one is for code that already runs on a background queue.
    ///
    /// - Parameters:
    ///   - providerID: the vendor id.
    ///   - credentials: the cache the app uses.
    ///   - baseURL: an endpoint override.
    ///   - region: the Azure region.
    ///   - language: the language a voice speaks.
    ///   - timeout: how long to wait for the Keychain.
    ///   - session: the session to send requests with.
    /// - Returns: the provider, or `nil` when Dot does not know the id.
    public static func make(
        providerID: String,
        credentials: CredentialCache,
        baseURL: URL? = nil,
        region: String = AzureVoiceProvider.defaultRegion,
        language: String? = nil,
        timeout: Duration = credentialTimeout,
        session: URLSession = OpenAICompatibleProvider.makeSession()
    ) async -> (any VoiceProvider)? {
        let id = normalized(providerID)
        var key: String?
        if id != VoiceProviderID.apple {
            let outcome = await BoundedWork.run(within: timeout) { () -> String? in
                credentials.key(for: id)
            }
            key = outcome.value ?? nil
        }
        return make(
            providerID: id,
            apiKey: key,
            baseURL: baseURL,
            region: region,
            language: language,
            session: session
        )
    }
}
