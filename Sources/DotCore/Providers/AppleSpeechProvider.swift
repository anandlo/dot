import AVFoundation
import Foundation
import Speech

/// Apple's on-device transcriber.
///
/// It runs inside the machine: nothing is sent anywhere, no account is
/// needed and no speech-recognition permission is asked for. It is the
/// provider that proves Dot works with no provider at all.
public struct AppleSpeechProvider: Provider {
    public let id: String = ProviderIdentifier.apple
    public let displayName: String = "Apple Speech"

    /// The locale the transcriber listens for.
    public let localeIdentifier: String

    /// Where readiness reads the machine's state.
    private let readiness: AppleSpeechReadinessEnvironment

    /// Creates the provider.
    public init(localeIdentifier: String = "en_US") {
        self.localeIdentifier = localeIdentifier
        self.readiness = .live
    }

    init(localeIdentifier: String, readiness: AppleSpeechReadinessEnvironment) {
        self.localeIdentifier = localeIdentifier
        self.readiness = readiness
    }

    /// Whether the on-device transcriber can run right now.
    public func isAvailable() async -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        if case .installed = await assetReadiness() { return true }
        return false
    }

    public func transcribe(wav: Data, model: String?, language: String?) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw ProviderError.unsupported("On-device transcription needs macOS 26 or newer.")
        }
        let samples = try WAVWriter.samples(in: wav)
        guard !samples.isEmpty else {
            throw ProviderError.noSpeech
        }
        guard let locale = await Self.resolvedLocale(identifier: localeIdentifier) else {
            throw ProviderError.unsupported("The on-device transcriber does not speak \(localeIdentifier).")
        }
        let text = try await Self.transcribe(samples: samples, locale: locale)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderError.noSpeech
        }
        return trimmed
    }

    // MARK: - Internals

    /// The machine state that decides readiness.
    ///
    /// Apple's locale equivalence decides which Speech locale a stored language
    /// id means. Readiness uses that locale alone and never the same-language
    /// fallback that lets transcription still make a request.
    private func assetReadiness() async -> AssetReadiness {
        guard readiness.transcriberIsAvailable() else { return .transcriber }
        guard let supported = await readiness.supportedLocale(localeIdentifier) else {
            return .unresolvedLocale
        }
        // Both sides are compared as maximal language ids, so a script the one
        // list spells out and the other implies (zh-CN, zh-Hans-CN) and any
        // Unicode extension do not make an installed model look missing.
        let supportedID = Self.modelIdentifier(supported.identifier(.bcp47))
        let installed = await readiness.installedLocaleIdentifiers()
        guard installed.contains(where: { Self.modelIdentifier($0) == supportedID }) else {
            return .missing(supported)
        }
        return .installed
    }

    static func modelIdentifier(_ bcp47: String) -> String {
        Locale.Language(identifier: bcp47).maximalIdentifier.lowercased()
    }

    /// The locale the transcriber should use.
    @available(macOS 26.0, *)
    static func resolvedLocale(identifier: String) async -> Locale? {
        let wanted = Locale(identifier: identifier)
        if let matched = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            return matched
        }
        let installed = await SpeechTranscriber.installedLocales
        return installed.first { $0.language.languageCode == wanted.language.languageCode }
    }

    /// The transcription itself.
    @available(macOS 26.0, *)
    static func transcribe(samples: [Int16], locale: Locale) async throws -> String {
        let reserved = try await AssetInventory.reserve(locale: locale)
        defer {
            Task { await AssetInventory.release(reservedLocale: locale) }
        }
        _ = reserved

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(WAVSpec.sampleRate),
            channels: AVAudioChannelCount(WAVSpec.channels),
            interleaved: false
        ) else {
            throw ProviderError.unsupported("The audio format could not be created.")
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.int16ChannelData?[0] else {
            throw ProviderError.invalidResponse("the audio buffer could not be created")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)

        let input = AnalyzerInput(buffer: buffer)
        let stream = AsyncStream<AnalyzerInput> { continuation in
            continuation.yield(input)
            continuation.finish()
        }

        let collector = TranscriptCollector()
        let collecting = Task {
            do {
                for try await result in transcriber.results {
                    await collector.add(String(result.text.characters))
                }
            } catch {
                await collector.fail(error)
            }
        }

        do {
            try await analyzer.start(inputSequence: stream)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collecting.cancel()
            throw ProviderError.transport(error.localizedDescription)
        }
        _ = await collecting.value

        if let failure = await collector.failure {
            throw ProviderError.transport(failure.localizedDescription)
        }
        return await collector.text
    }
}

/// Collects the transcript while the analysis runs.
///
/// `SpeechTranscriber.results` yields one result per finished segment, not one
/// for the whole recording, so every result has to be appended and not
/// overwritten. The fragments are joined with a single space, and empty ones
/// are dropped, so a long dictation reads as one sentence instead of running
/// its words together or leaving a double space where a silent segment sat.
actor TranscriptCollector {
    private var fragments: [String] = []
    private var error: Error?

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        fragments.append(trimmed)
    }

    func fail(_ error: Error) {
        self.error = error
    }

    var text: String { TranscriptLedger.join(fragments) }
    var failure: Error? { error }
}

extension AppleSpeechProvider: CredentialVerifying {
    /// Whether the on-device transcriber can run with the stored language.
    ///
    /// There is nothing to send anywhere, so the answer is the state of this
    /// Mac: the system, the transcriber and the installed language assets. A
    /// locale the system supports but has not installed is a setup step, not a
    /// provider fault.
    public func verifyCredentials() async -> CredentialCheck {
        guard #available(macOS 26.0, *) else {
            return .unavailable("Needs macOS 26 or newer.")
        }
        switch await assetReadiness() {
        case .installed:
            return .verified
        case .transcriber:
            return .unavailable("The on-device transcriber is not available on this Mac.")
        case .unresolvedLocale:
            return .unavailable("The on-device transcriber does not speak \(localeIdentifier).")
        case .missing(let locale):
            let name = Locale(identifier: "en_US").localizedString(forIdentifier: locale.identifier)
                ?? locale.identifier
            return .needsSetup("The on-device speech model for \(name) is not installed on this Mac.")
        }
    }
}

extension AppleSpeechProvider {
    /// The state of this Mac's on-device model, as a short string a cache name
    /// can carry.
    ///
    /// The locale and the asset are the two things that decide whether the
    /// on-device provider can run, and both can change while the app is running
    /// (a model finishes downloading, a language is chosen). A check that was
    /// cached before either changed is a different question, so the answer is
    /// part of the name it is cached under.
    ///
    /// - Returns: `macos`, `transcriber`, `locale:<id>`, `asset:installed` or
    ///   `asset:missing`.
    public func assetFingerprint() async -> String {
        guard #available(macOS 26.0, *) else { return "macos" }
        switch await assetReadiness() {
        case .installed: return "asset:installed"
        case .transcriber: return "transcriber"
        case .unresolvedLocale: return "locale:\(localeIdentifier)"
        case .missing: return "asset:missing"
        }
    }
}

/// What readiness found on this Mac.
private enum AssetReadiness {
    case installed
    case transcriber
    case unresolvedLocale
    case missing(Locale)
}

/// The reads readiness makes, kept behind one seam so tests never call Speech.
struct AppleSpeechReadinessEnvironment: Sendable {
    let transcriberIsAvailable: @Sendable () -> Bool
    let supportedLocale: @Sendable (String) async -> Locale?
    let installedLocaleIdentifiers: @Sendable () async -> [String]

    static let live = AppleSpeechReadinessEnvironment(
        transcriberIsAvailable: {
            guard #available(macOS 26.0, *) else { return false }
            return SpeechTranscriber.isAvailable
        },
        supportedLocale: { identifier in
            guard #available(macOS 26.0, *) else { return nil }
            return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
        },
        installedLocaleIdentifiers: {
            guard #available(macOS 26.0, *) else { return [] }
            return await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        }
    )
}
