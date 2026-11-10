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

    /// Creates the provider.
    public init(localeIdentifier: String = "en_US") {
        self.localeIdentifier = localeIdentifier
    }

    /// Whether the on-device transcriber can run right now.
    public func isAvailable() async -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        guard SpeechTranscriber.isAvailable else { return false }
        guard let locale = await Self.resolvedLocale(identifier: localeIdentifier) else { return false }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [transcriber])
        return status == .installed || status == .supported
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
private actor TranscriptCollector {
    private var buffer = ""
    private var error: Error?

    func add(_ text: String) {
        buffer = text
    }

    func fail(_ error: Error) {
        self.error = error
    }

    var text: String { buffer }
    var failure: Error? { error }
}
