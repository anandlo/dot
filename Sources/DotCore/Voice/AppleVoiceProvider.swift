import AVFoundation
import Foundation

/// The voice that lives on this Mac.
///
/// This is the row that makes Dot's assistant work with no account, no key and
/// no network. It is not free speed: on one Mac the first utterance of a process
/// took about 2.1 s to its first buffer and later utterances about 0.6 s, because
/// the system speech service has to be woken and the voice loaded. A cloud vendor
/// with a 100 ms model can beat that over a fast link, which is why the on-device
/// row is the offline and no-key default rather than a speculative first word.
/// The buffers come from ``AVSpeechSynthesizer/write(_:toBufferCallback:)``
/// rather than the speaker, so the app keeps one audio path for every provider.
///
/// Two platform details shape the catalogue. Premium voices (macOS 13 and later)
/// and enhanced voices are downloaded by the person, so they are listed first and
/// the picker says which tier a voice is. The user's own Personal Voice is
/// listed too, but only when the app has been authorised for it, which is why
/// ``requestPersonalVoiceAuthorization()`` exists: the system prompt must be
/// raised from a place where asking makes sense, never from a speech call.
public struct AppleVoiceProvider: VoiceProvider {
    public let id: String = VoiceProviderID.apple
    public let displayName: String = "Apple Voices"
    public let requiresCredential: Bool = false
    public let audioFormat: VoiceAudioFormat = .pcm22k

    /// The preferred language, e.g. `en-US`; `nil` uses the system's first
    /// preferred language.
    public let language: String?

    /// Creates the on-device provider.
    public init(language: String? = nil) {
        self.language = language
    }

    /// Whether the machine has any voice installed.
    public func isAvailable() async -> Bool {
        !AVSpeechSynthesisVoice.speechVoices().isEmpty
    }

    /// The installed voices, best first.
    public func voices(language: String?) async throws -> [VoiceDescriptor] {
        VoiceCatalogue.select(
            Self.installedVoices(),
            language: language ?? self.language,
            locale: Locale.current.identifier
        )
    }
}

// MARK: - The catalogue

extension AppleVoiceProvider {
    /// How the system's quality value maps onto Dot's tiers.
    ///
    /// - Parameter quality: the platform's quality.
    /// - Returns: the tier the picker shows.
    public static func tier(for quality: AVSpeechSynthesisVoiceQuality) -> VoiceDescriptor.QualityTier {
        switch quality {
        case .premium: .premium
        case .enhanced: .enhanced
        case .default: .standard
        @unknown default: .unknown
        }
    }

    /// Every installed voice, including Personal Voice when it is authorised.
    public static func installedVoices() -> [VoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().compactMap { voice in
            if #available(macOS 14.0, *), voice.voiceTraits.contains(.isPersonalVoice) {
                guard personalVoiceAuthorizationStatus == .authorized else { return nil }
            }
            return VoiceDescriptor(
                providerID: VoiceProviderID.apple,
                id: voice.identifier,
                name: voice.name,
                language: voice.language,
                quality: tier(for: voice.quality),
                detail: detail(for: voice)
            )
        }
    }

    /// A one-line description of a voice.
    static func detail(for voice: AVSpeechSynthesisVoice) -> String {
        var parts: [String] = []
        if #available(macOS 14.0, *), voice.voiceTraits.contains(.isPersonalVoice) {
            parts.append("Personal Voice")
        }
        switch voice.gender {
        case .male: parts.append("Male")
        case .female: parts.append("Female")
        default: break
        }
        switch voice.quality {
        case .premium: parts.append("Premium")
        case .enhanced: parts.append("Enhanced")
        default: break
        }
        return parts.joined(separator: ", ")
    }

    /// The voice a setting asks for, or the best installed one.
    ///
    /// - Parameter settings: the chosen voice and quality floor.
    /// - Returns: the voice to speak with, or `nil` when the Mac has none.
    public static func voice(for settings: VoiceSettings) -> AVSpeechSynthesisVoice? {
        if let identifier = settings.voiceID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identifier.isEmpty,
           let chosen = AVSpeechSynthesisVoice(identifier: identifier) {
            return chosen
        }
        let floor = settings.qualityFloor
        let candidates = VoiceCatalogue.select(
            installedVoices(),
            floor: floor,
            locale: Locale.current.identifier
        )
        for candidate in candidates {
            if let voice = AVSpeechSynthesisVoice(identifier: candidate.id) { return voice }
        }
        return VoiceCatalogue.select(installedVoices(), locale: Locale.current.identifier)
            .first
            .flatMap { AVSpeechSynthesisVoice(identifier: $0.id) }
    }

    /// The utterance rate for a speed multiplier.
    ///
    /// The platform's rate is not words per minute; it is a linear scale whose
    /// middle is ``AVSpeechUtteranceDefaultSpeechRate``. A multiplier is applied
    /// to that middle and clamped to the platform's own bounds, so `1` is the
    /// voice's normal pace rather than its fastest.
    ///
    /// - Parameter speed: the multiplier from the setting.
    /// - Returns: the rate to enqueue.
    public static func rate(for speed: Double) -> Float {
        let scaled = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
        return min(
            max(scaled, AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
    }
}

// MARK: - Personal Voice

extension AppleVoiceProvider {
    /// The system's answer about the user's Personal Voice.
    public static var personalVoiceAuthorizationStatus: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus? {
        guard #available(macOS 14.0, *) else { return nil }
        return AVSpeechSynthesizer.personalVoiceAuthorizationStatus
    }

    /// Asks for permission to use the user's Personal Voice.
    ///
    /// Call this from Settings, next to the voice list, so the system prompt
    /// arrives where the person is already thinking about voices. The answer is
    /// remembered by the system; calling again does not prompt again.
    ///
    /// - Returns: the status after the prompt, or `nil` on a system that has no
    ///   Personal Voice.
    public static func requestPersonalVoiceAuthorization() async -> AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus? {
        guard #available(macOS 14.0, *) else { return nil }
        return await withCheckedContinuation { continuation in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

// MARK: - Synthesis

extension AppleVoiceProvider {
    /// Speaks one sentence with the system synthesizer.
    ///
    /// The audio is captured with the buffer callback, not played by the
    /// synthesizer: the player owns the output device, which is what keeps
    /// volume, ducking and teardown in one place.
    ///
    /// - Parameters:
    ///   - text: the sentence to speak.
    ///   - settings: the chosen voice and rate.
    /// - Returns: the audio as the synthesizer produces it.
    /// - Throws: ``ProviderError`` when the Mac has no voice or the chosen voice
    ///   is a Personal Voice Dot is not allowed to use.
    public func speech(
        text: String,
        settings: VoiceSettings
    ) async throws -> AsyncThrowingStream<VoiceChunk, Error> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderError.unavailable("There is nothing to speak.") }
        guard let voice = Self.voice(for: settings) else {
            throw ProviderError.unsupported("This Mac has no voices installed.")
        }
        if #available(macOS 14.0, *), voice.voiceTraits.contains(.isPersonalVoice),
           AVSpeechSynthesizer.personalVoiceAuthorizationStatus != .authorized {
            throw ProviderError.unsupported(
                "Dot is not allowed to use your Personal Voice. Allow it in Settings."
            )
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        utterance.rate = Self.rate(for: settings.effectiveSpeed)
        utterance.pitchMultiplier = 1
        utterance.volume = 1

        let handle = AppleSpeechHandle()
        let declaredFormat = audioFormat
        return AsyncThrowingStream { continuation in
            let synthesizer = AVSpeechSynthesizer()
            handle.attach(synthesizer)
            // The synthesizer hands back one buffer per few milliseconds. Yielding
            // each of them would schedule the player node hundreds of times a
            // second and convert every 256-frame piece on its own, so they are
            // gathered into chunks the same size the network path uses.
            var pending = Data()
            var format = declaredFormat
            func flushPending() {
                guard !pending.isEmpty else { return }
                continuation.yield(VoiceChunk(data: pending, format: format))
                pending = Data()
            }
            synthesizer.write(utterance) { buffer in
                guard !handle.isCancelled else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    // The callback reports the end of the utterance with no
                    // buffer; that is the only completion signal there is.
                    flushPending()
                    continuation.finish()
                    return
                }
                guard pcm.frameLength > 0 else {
                    flushPending()
                    continuation.finish()
                    return
                }
                guard let chunk = Self.chunk(from: pcm) else { return }
                format = chunk.format
                pending.append(chunk.data)
                if pending.count >= AppleVoiceProvider.minimumChunkBytes {
                    flushPending()
                }
            }
            continuation.onTermination = { _ in
                handle.cancel()
            }
        }
    }

    /// The smallest piece of on-device audio handed to the player.
    ///
    /// 2 KB is about 46 ms at 22.05 kHz: long enough that the player is not
    /// woken for every synthesizer buffer, short enough that it costs no audible
    /// delay before the first sample is scheduled.
    public static let minimumChunkBytes = 2048

    /// Converts one synthesizer buffer into the PCM the player schedules.
    ///
    /// - Parameter buffer: a buffer from the synthesizer's callback.
    /// - Returns: the chunk, or `nil` when the buffer's layout is not one Dot
    ///   can convert.
    static func chunk(from buffer: AVAudioPCMBuffer) -> VoiceChunk? {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        let format = VoiceAudioFormat(
            sampleRate: buffer.format.sampleRate,
            channelCount: 1
        )
        var data = Data(count: frames * 2)
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { return nil }
            let samples = channels[0]
            data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                let out = base.assumingMemoryBound(to: Int16.self)
                for frame in 0..<frames {
                    let sample = max(-1, min(1, samples[frame]))
                    out[frame] = Int16((sample * 32_767).rounded())
                }
            }
        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else { return nil }
            data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                base.copyMemory(from: channels[0], byteCount: frames * 2)
            }
        default:
            return nil
        }
        return VoiceChunk(data: data, format: format)
    }
}

/// Keeps a synthesizer alive for the length of one stream and can stop it.
///
/// `AVSpeechSynthesizer` is not `Sendable`, and the stream's termination handler
/// may run on any thread. The handle owns the only strong reference to it and
/// answers "cancelled" under a lock, so the audio callback and the stop cannot
/// disagree about whether the utterance is still wanted.
final class AppleSpeechHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var synthesizer: AVSpeechSynthesizer?
    private var cancelled = false

    init() {}

    /// Whether the stream has already been stopped.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Takes ownership of the synthesizer that is writing.
    ///
    /// - Parameter synthesizer: the synthesizer for this utterance.
    func attach(_ synthesizer: AVSpeechSynthesizer) {
        lock.lock()
        self.synthesizer = synthesizer
        lock.unlock()
    }

    /// Stops the utterance and releases the synthesizer.
    func cancel() {
        lock.lock()
        cancelled = true
        let synthesizer = self.synthesizer
        self.synthesizer = nil
        lock.unlock()
        synthesizer?.stopSpeaking(at: .immediate)
    }
}
