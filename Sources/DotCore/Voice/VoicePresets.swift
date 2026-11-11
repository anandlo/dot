import Foundation

/// The voice providers Dot knows, in the order the audio path should try them.
///
/// The order is the research's ladder, not the alphabet: the on-device voice
/// first because it is the only one that answers in no time and costs nothing,
/// then the cloud rows by measured or published time to first byte, and OpenAI
/// last because its endpoint has a shutdown date.
public enum VoicePresets {
    /// Apple's on-device synthesizer.
    public static let apple = VoiceProviderPreset(
        id: VoiceProviderID.apple,
        displayName: "Apple Voices",
        detail: "Speaks on this Mac. No key, no network, no cost, and nothing leaves the machine.",
        requiresCredential: false,
        audioFormat: .pcm22k,
        // Every fact about the API comes from the AVFAudio SDK header, which is
        // the primary source for availability and for the buffer callback.
        verification: .verified,
        rank: 1
    )

    /// Cartesia Sonic.
    public static let cartesia = VoiceProviderPreset(
        id: VoiceProviderID.cartesia,
        displayName: "Cartesia",
        detail: "Sonic. Raw PCM out of `/tts/bytes`, with the lowest published model latency of the cloud rows.",
        requiresCredential: true,
        models: [
            VoiceModelOption(id: "sonic-3.6", name: "Sonic 3.6", detail: "Current default. 90 ms model latency"),
            VoiceModelOption(id: "sonic-3.5", name: "Sonic 3.5", detail: "Previous generation"),
            VoiceModelOption(id: "sonic-3", name: "Sonic 3", detail: "First generation with emotion control"),
            VoiceModelOption(id: "sonic-latest", name: "Sonic Latest", detail: "Follows Cartesia's default"),
        ],
        defaultModel: "sonic-3.6",
        verification: .unverified(
            "The endpoint, the Cartesia-Version header and the body fields come from Cartesia's "
                + "reference. The API-key header name and output_format's encoding and sample_rate "
                + "fields are not in the verified set."
        ),
        rank: 2
    )

    /// ElevenLabs Flash v2.5 over HTTP streaming.
    public static let elevenLabs = VoiceProviderPreset(
        id: VoiceProviderID.elevenLabs,
        displayName: "ElevenLabs",
        detail: "Flash v2.5 over the HTTP stream endpoint. The best cloned voices; v3 and v4 are not on the websocket.",
        requiresCredential: true,
        models: [
            VoiceModelOption(
                id: "eleven_flash_v2_5",
                name: "Flash v2.5",
                detail: "About 100 ms median model latency, 32 languages"
            ),
            VoiceModelOption(
                id: "eleven_turbo_v2_5",
                name: "Turbo v2.5",
                detail: "Same latency target, more languages"
            ),
            VoiceModelOption(
                id: "eleven_multilingual_v2",
                name: "Multilingual v2",
                detail: "Highest quality, slowest"
            ),
            VoiceModelOption(
                id: "eleven_v3",
                name: "v3",
                detail: "Most expressive; only works on the dialogue websocket"
            ),
        ],
        defaultModel: "eleven_flash_v2_5",
        // The voice id used throughout ElevenLabs' own streaming examples.
        defaultVoiceID: "JBFqnCBsd6RMkjVDRZzb",
        verification: .unverified(
            "The endpoint, the xi-api-key header, the body fields and pcm_24000 come from ElevenLabs' "
                + "reference. voice_settings.speed is not in the verified set."
        ),
        rank: 3
    )

    /// Azure Speech neural TTS.
    public static let azure = VoiceProviderPreset(
        id: VoiceProviderID.azure,
        displayName: "Azure Speech",
        detail: "Neural voices and SSML prosody on the regional endpoint. Raw 24 kHz PCM out.",
        requiresCredential: true,
        defaultVoiceID: "en-US-JennyNeural",
        verification: .unverified(
            "The endpoint, the three headers, SSML and raw-24khz-16bit-mono-pcm come from Azure's "
                + "REST reference. The regional /cognitiveservices/voices/list path is not in it."
        ),
        rank: 4
    )

    /// Deepgram Aura-2.
    public static let deepgram = VoiceProviderPreset(
        id: VoiceProviderID.deepgram,
        displayName: "Deepgram",
        detail: "Aura-2. The widest roster of named voices, on the same key as Deepgram dictation.",
        requiresCredential: true,
        models: [
            VoiceModelOption(id: "aura-2-thalia-en", name: "Thalia", detail: "Clear, confident, energetic"),
            VoiceModelOption(id: "aura-2-arcas-en", name: "Arcas", detail: "Natural, smooth, clear"),
            VoiceModelOption(id: "aura-2-zeus-en", name: "Zeus", detail: "Deep, trustworthy, smooth"),
            VoiceModelOption(id: "aura-2-draco-en", name: "Draco", detail: "Warm, approachable, British"),
            VoiceModelOption(id: "aura-2-pandora-en", name: "Pandora", detail: "Smooth, calm, melodic, British"),
        ],
        defaultModel: "aura-2-thalia-en",
        verification: .unverified(
            "The endpoint, the Token auth scheme and the JSON body come from Deepgram's TTS reference. "
                + "The linear16 and sample_rate query parameters are not in it, and the five voices "
                + "listed are the ones quoted from the vendor's table."
        ),
        rank: 5
    )

    /// OpenAI's `/v1/audio/speech`, which is scheduled to shut down.
    public static let openAI = VoiceProviderPreset(
        id: VoiceProviderID.openAI,
        displayName: "OpenAI",
        detail: "Legacy /v1/audio/speech. Works until 6 January 2027, then the models stop answering.",
        requiresCredential: true,
        models: [
            VoiceModelOption(
                id: "gpt-4o-mini-tts",
                name: "gpt-4o-mini-tts",
                detail: "Style instructions, 13 voices",
                isDeprecated: true
            ),
            VoiceModelOption(
                id: "tts-1",
                name: "tts-1",
                detail: "Fastest legacy model, lower fidelity",
                isDeprecated: true
            ),
            VoiceModelOption(
                id: "tts-1-hd",
                name: "tts-1-hd",
                detail: "Higher fidelity legacy model",
                isDeprecated: true
            ),
        ],
        defaultModel: "gpt-4o-mini-tts",
        defaultVoiceID: "marin",
        verification: .unverified(
            "The endpoint, the fields, the formats and the shutdown date come from OpenAI's TTS "
                + "guide. The sample rate of response_format pcm is not in the verified set."
        ),
        deprecation: VoiceDeprecation(
            year: 2027,
            month: 1,
            day: 6,
            message: "OpenAI shuts these models down on 6 January 2027 and moves text to speech to "
                + "the Realtime API. Choose another voice provider before then."
        ),
        rank: 6
    )

    /// Every row, in the recommended order.
    public static let all: [VoiceProviderPreset] = [apple, cartesia, elevenLabs, azure, deepgram, openAI]

    /// The row of one provider.
    ///
    /// - Parameter id: the vendor id, e.g. `azure`.
    /// - Returns: the row, or `nil` when Dot does not know the id.
    public static func preset(id: String) -> VoiceProviderPreset? {
        all.first { $0.id == id }
    }

    /// The rows that need a key, in the recommended order.
    public static let keyed: [VoiceProviderPreset] = all.filter(\.requiresCredential)

    /// The rows that are already shut down at a moment.
    ///
    /// - Parameter date: the moment to ask about, normally now.
    /// - Returns: the rows whose vendor has switched its models off.
    public static func shutDown(asOf date: Date) -> [VoiceProviderPreset] {
        all.filter { $0.deprecation?.isShutDown(asOf: date) == true }
    }
}
