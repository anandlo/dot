import Foundation

/// The audio a voice provider hands back.
///
/// Every provider Dot speaks through is normalised to one shape: signed 16-bit
/// little-endian PCM, mono. That is the only format every vendor in the matrix
/// can return, and it is the format a byte stream can be cut at any point
/// without a decoder and without buffering a whole file. A vendor that answers
/// in WAV asks for `linear16` instead, so the header never reaches the player.
public struct VoiceAudioFormat: Sendable, Equatable, Codable {
    /// How the samples are laid out.
    public enum Encoding: String, Sendable, Codable {
        /// Signed 16-bit little-endian samples.
        case pcm16LittleEndian = "pcm_s16le"
    }

    /// The sample layout.
    public let encoding: Encoding
    /// Frames per second, e.g. `24000`.
    public let sampleRate: Double
    /// Interleaved channels. Dot asks every vendor for mono.
    public let channelCount: Int

    /// Creates a format.
    public init(
        encoding: Encoding = .pcm16LittleEndian,
        sampleRate: Double,
        channelCount: Int = 1
    ) {
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// The format the cloud providers are asked for.
    public static let pcm24k = VoiceAudioFormat(sampleRate: 24_000)
    /// The format the on-device synthesizer produces.
    public static let pcm22k = VoiceAudioFormat(sampleRate: 22_050)

    /// Bytes in one frame across every channel.
    public var bytesPerFrame: Int { 2 * channelCount }

    /// Bytes one second of audio occupies.
    public var bytesPerSecond: Double { sampleRate * Double(bytesPerFrame) }

    /// How long `byteCount` bytes of this format last.
    ///
    /// - Parameter byteCount: the size of one chunk or of a whole answer.
    public func duration(ofByteCount byteCount: Int) -> Double {
        guard bytesPerSecond > 0 else { return 0 }
        return Double(byteCount) / bytesPerSecond
    }

    /// Whether two formats describe the same audio.
    ///
    /// - Parameter other: the format to compare with.
    public func matches(_ other: VoiceAudioFormat) -> Bool {
        encoding == other.encoding
            && channelCount == other.channelCount
            && abs(sampleRate - other.sampleRate) < 0.5
    }
}

/// One piece of an answer's audio, as it arrives.
///
/// The format is carried on the chunk rather than assumed from the provider:
/// the on-device synthesizer picks its rate from the voice, and a player that
/// reconfigures itself from the chunk cannot be wrong about it.
public struct VoiceChunk: Sendable, Equatable {
    /// The PCM bytes. A chunk boundary can fall anywhere, including inside one
    /// sample's two bytes only if the vendor misbehaves; the player keeps a
    /// trailing odd byte for the next chunk.
    public let data: Data
    /// The layout of `data`.
    public let format: VoiceAudioFormat

    /// Creates a chunk.
    public init(data: Data, format: VoiceAudioFormat) {
        self.data = data
        self.format = format
    }
}

/// How well the wiring of a provider has been checked against a real service.
///
/// The distinction is shown in Settings, so a person is never told that a
/// vendor is ready when only its request shape has been read from a document.
public enum VoiceVerification: Sendable, Equatable {
    /// The endpoint, the fields and the auth style were read from the vendor's
    /// own reference.
    case verified
    /// At least one part of the wiring is not confirmed; the note says which.
    case unverified(String)

    /// Whether everything about this provider is confirmed.
    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    /// The sentence shown next to the provider's name.
    public var note: String? {
        switch self {
        case .verified:
            nil
        case .unverified(let detail):
            detail
        }
    }
}

/// A backend that turns text into speech.
///
/// A provider is a capability, not a model: the model and the voice are part of
/// ``VoiceSettings``, so one provider row can serve many voices. The protocol
/// is deliberately small. Everything past it, sentence chunking, playback,
/// format conversion and ducking, belongs to the player, which is why adding a
/// vendor does not touch playback.
public protocol VoiceProvider: Sendable {
    /// Stable vendor id, e.g. `openai`, `elevenlabs`, `cartesia`. It is the same
    /// string the speech provider uses, so one Keychain item serves both
    /// directions for a vendor that does both.
    var id: String { get }
    /// The implementation's own name. Never a model brand.
    var displayName: String { get }
    /// Whether the provider cannot be used without a key.
    var requiresCredential: Bool { get }
    /// The format ``speech(text:settings:)`` usually yields.
    ///
    /// It is what the player prepares its converter with. A chunk may still
    /// declare another rate, and the player follows the chunk.
    var audioFormat: VoiceAudioFormat { get }

    /// Whether the provider can speak right now: a key is present, the voice is
    /// selected, the synthesizer exists.
    func isAvailable() async -> Bool

    /// The voices the provider offers, best first.
    ///
    /// - Parameter language: a BCP-47 prefix to filter by, e.g. `en`; `nil`
    ///   lists everything.
    /// - Returns: the catalogue, sorted by quality and then by name.
    func voices(language: String?) async throws -> [VoiceDescriptor]

    /// Speaks one piece of text.
    ///
    /// The text is a sentence, not an answer: the player segments the stream
    /// and calls this per sentence so the first sentence can be heard while the
    /// model is still writing the second.
    ///
    /// - Parameters:
    ///   - text: the sentence to speak.
    ///   - settings: the chosen voice, model, speed and style.
    /// - Returns: the audio as it arrives. Cancelling the consuming task stops
    ///   the request.
    /// - Throws: ``ProviderError`` when the request cannot be made or refused.
    func speech(text: String, settings: VoiceSettings) async throws -> AsyncThrowingStream<VoiceChunk, Error>
}

extension VoiceProvider {
    /// A provider needs a key unless it says otherwise.
    public var requiresCredential: Bool { true }
}

/// The vendor ids voice providers use.
///
/// The speech ids are reused verbatim so that `DOT_API_KEY_<ID>` is one item per
/// vendor: an OpenAI, ElevenLabs, Azure or Deepgram key typed for dictation is
/// already the key for speech. Cartesia has no speech product in Dot, so its id
/// is new.
public enum VoiceProviderID {
    /// Apple's on-device synthesizer. No key.
    public static let apple = ProviderIdentifier.apple
    /// OpenAI `/v1/audio/speech`. Deprecated by the vendor; see ``VoicePresets``.
    public static let openAI = ProviderIdentifier.openAI
    /// ElevenLabs `/v1/text-to-speech/{voice_id}/stream`.
    public static let elevenLabs = ProviderIdentifier.elevenLabs
    /// Azure Speech neural TTS on the region endpoint.
    public static let azure = ProviderIdentifier.azure
    /// Deepgram Aura-2 `/v1/speak`.
    public static let deepgram = ProviderIdentifier.deepgram
    /// Cartesia Sonic `/tts/bytes`.
    public static let cartesia = "cartesia"

    /// Every id a voice provider can have.
    public static let all = [apple, cartesia, elevenLabs, azure, deepgram, openAI]
}
