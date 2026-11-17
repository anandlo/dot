import Foundation

/// Splits a recording into the segments that are sent one after the other.
///
/// The size of a segment is a *capability of the provider*, not a limit Dot
/// imposes: a recording that is longer than one segment is split and every
/// segment is sent on its own. No recording is ever rejected for being too
/// long.
public enum Segmenter {
    /// The segment size every provider starts with, in seconds.
    public static let defaultSegmentSeconds = 30

    /// The number of samples one segment holds.
    public static func sampleCount(seconds: Int) -> Int {
        max(1, seconds) * WAVSpec.sampleRate
    }

    /// Splits samples into segments.
    ///
    /// - Parameters:
    ///   - samples: the whole recording.
    ///   - seconds: the length of one segment.
    public static func segments(samples: [Int16], seconds: Int) -> [[Int16]] {
        let size = sampleCount(seconds: seconds)
        guard !samples.isEmpty else { return [] }
        var result: [[Int16]] = []
        var index = 0
        while index < samples.count {
            let end = min(index + size, samples.count)
            result.append(Array(samples[index..<end]))
            index = end
        }
        return result
    }

    /// How many segments a recording of `samples` samples becomes.
    ///
    /// The card says "1 of 3" before the first request, and counting is not
    /// worth copying the audio for.
    ///
    /// - Parameters:
    ///   - samples: how many 16 kHz samples the recording holds.
    ///   - seconds: the length of one segment.
    public static func segmentCount(samples: Int, seconds: Int) -> Int {
        guard samples > 0 else { return 0 }
        let size = sampleCount(seconds: seconds)
        return (samples + size - 1) / size
    }
}

/// What came back from a recording.
public struct TranscriptReport: Sendable, Equatable {
    /// The transcript of every segment that worked, joined with single spaces.
    public let text: String
    /// How many segments were transcribed.
    public let succeeded: Int
    /// How many segments failed.
    public let failed: Int
    /// How many segments there were in total.
    public let total: Int

    /// Creates a report.
    public init(text: String, succeeded: Int, failed: Int, total: Int) {
        self.text = text
        self.succeeded = succeeded
        self.failed = failed
        self.total = total
    }

    /// Whether every segment worked.
    public var isComplete: Bool { failed == 0 }

    /// Whether nothing at all was recorded.
    public var isEmpty: Bool { total == 0 }
}

/// A take whose first failed segment was a cancellation the provider reported.
///
/// A provider can fail a request with ``CancellationError`` while the caller's
/// task is still running — Foundation's structured concurrency raises it for a
/// cancelled provider-internal task, for instance. That is an ordinary segment
/// failure, but a bare ``CancellationError`` would read as the caller's
/// cancellation to anything that checks for one. This type keeps the two apart.
///
/// Only the first failure decides this type: later segments may have failed for
/// other reasons. ``HTTPTransport`` reports a request the session cancelled as
/// a provider transport failure, so a `URLSessionTask` cancelled inside a
/// provider does not reach this type; a provider that throws
/// ``CancellationError`` itself does.
///
/// ``CancellationError`` carries no message of its own, so the context here is
/// the provider's name and how many segments were attempted, not the original
/// error's text.
public struct ProviderCancellationFailure: Error, Equatable, Sendable, LocalizedError {
    /// The name of the provider that reported the cancellation, as the surfaces
    /// show it.
    public let provider: String
    /// How many segments were attempted in the take.
    public let segments: Int

    /// Creates the failure.
    ///
    /// - Parameters:
    ///   - provider: the provider's display name.
    ///   - segments: how many segments were attempted.
    public init(provider: String, segments: Int) {
        self.provider = provider
        self.segments = segments
    }

    public var errorDescription: String? {
        let attempted = segments == 1
            ? "1 segment was attempted"
            : "\(segments) segments were attempted"
        return "\(provider) reported a cancellation as the first failure; \(attempted)."
    }
}

/// Sends a recording to a provider, one segment at a time.
///
/// A segment that fails does not throw the recording away: the remaining
/// segments are still sent and the report says how many worked.
///
/// Cancellation is the *caller's* decision, and it is the only cancellation
/// this type acts on. While the task is not cancelled, a provider that fails a
/// segment with cancellation is a failed segment like any other, and the rest
/// of the recording is still sent: a provider's own ``CancellationError``
/// arrives here as that error, and a request the session cancelled arrives as
/// the ``ProviderError/transport(_:)`` ``HTTPTransport`` reports for it. When
/// the caller's task is cancelled, no further request is sent and
/// ``CancellationError`` is thrown even when earlier segments succeeded, so the
/// caller can tell a cancelled take from a partial one. When nothing was
/// transcribed and the first failure was the provider's own
/// ``CancellationError``, ``ProviderCancellationFailure`` is thrown instead,
/// because the caller did not cancel anything.
public enum Transcriber {
    /// Transcribes a whole recording.
    ///
    /// - Parameters:
    ///   - wav: the canonical 16 kHz mono PCM16 WAV.
    ///   - provider: the provider that does the work.
    ///   - model: the model to ask for; `nil` lets the provider decide.
    ///   - language: the language hint; `nil` lets the provider decide.
    ///   - maxSegmentSeconds: how long one segment is.
    ///   - progress: called with `(done, total)` before every segment, so the
    ///     card can say "2 of 3" instead of spinning.
    /// - Throws: ``ProviderError`` when *every* segment failed, and
    ///   ``CancellationError`` when the caller's task was cancelled.
    ///   ``ProviderCancellationFailure`` when nothing was transcribed and the
    ///   first failure was the provider's own cancellation.
    public static func transcribe(
        wav: Data,
        provider: any Provider,
        model: String? = nil,
        language: String? = nil,
        maxSegmentSeconds: Int = Segmenter.defaultSegmentSeconds,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> TranscriptReport {
        try Task.checkCancellation()
        let samples = try WAVWriter.samples(in: wav)
        return try await transcribe(
            samples: samples,
            provider: provider,
            model: model,
            language: language,
            maxSegmentSeconds: maxSegmentSeconds,
            progress: progress
        )
    }

    /// Transcribes samples, one segment at a time.
    ///
    /// This is the form both paths use: the stop sends the tail of a recording
    /// that the live loop has not committed yet, and it is samples, not a WAV,
    /// that the recorder hands over.
    ///
    /// - Parameters:
    ///   - samples: 16 kHz mono PCM16 samples.
    ///   - provider: the provider that does the work.
    ///   - model: the model to ask for; `nil` lets the provider decide.
    ///   - language: the language hint; `nil` lets the provider decide.
    ///   - noiseFloorDBFS: the room floor measured on the device that recorded
    ///     the samples, or `nil`. With a floor, the room tone at the edges of
    ///     the clip is cut before it is sent, because a chat-style model answers
    ///     a quiet lead-in with a list number or a timestamp that reads as the
    ///     start of the transcript. Without one nothing is cut: an untrimmed
    ///     clip is what every caller got before this existed, and a guess at
    ///     what is silence is the one way to lose a first word.
    ///   - maxSegmentSeconds: how long one segment is.
    ///   - progress: called with `(done, total)` before every segment.
    /// - Throws: ``ProviderError`` when *every* segment failed, and
    ///   ``CancellationError`` when the caller's task was cancelled.
    ///   ``ProviderCancellationFailure`` when nothing was transcribed and the
    ///   first failure was the provider's own cancellation.
    public static func transcribe(
        samples: [Int16],
        provider: any Provider,
        model: String? = nil,
        language: String? = nil,
        noiseFloorDBFS: Double? = nil,
        maxSegmentSeconds: Int = Segmenter.defaultSegmentSeconds,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> TranscriptReport {
        try Task.checkCancellation()

        // The only thing that sends nothing at all: not a single sample.
        guard !samples.isEmpty else {
            return TranscriptReport(text: "", succeeded: 0, failed: 0, total: 0)
        }

        // The segments and the count of them are taken from the audio that is
        // sent, not from what the recorder handed over: "2 of 3" has to name
        // the requests the provider will actually receive.
        let audio = trimmed(samples, noiseFloorDBFS: noiseFloorDBFS)
        let pieces = Segmenter.segments(samples: audio, seconds: maxSegmentSeconds)
        var texts: [String] = []
        var failures: [Error] = []
        var succeeded = 0

        for (index, piece) in pieces.enumerated() {
            // A cancelled take stops here: the next request is one the caller
            // has already said it no longer wants to pay for.
            try Task.checkCancellation()
            progress?(index + 1, pieces.count)
            // The callback runs caller code: it may have cancelled the take,
            // and no request should be sent on behalf of a task that stopped.
            try Task.checkCancellation()
            do {
                let transcript = try await provider.transcribe(
                    wav: WAVWriter.encode(samples: piece),
                    model: model,
                    language: language
                )
                succeeded += 1
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    texts.append(trimmed)
                }
            } catch {
                // Only the caller's cancellation stops the take. A provider
                // that calls its own cancellation an error is a failed
                // segment: the rest of the recording is still owed. That is a
                // provider's own CancellationError, or the transport failure
                // HTTPTransport reports for a request the session cancelled.
                if Task.isCancelled {
                    throw CancellationError()
                }
                failures.append(error)
                Log.shared.warn("transcription.segment.failed", [
                    "segment": .int(index + 1),
                    "segments": .int(pieces.count),
                    "error": .string(error.localizedDescription),
                ])
            }
        }

        // A cancellation that arrives with the last answer still wins: a caller
        // that cancelled must not be told the take succeeded.
        try Task.checkCancellation()

        guard !failures.isEmpty else {
            return TranscriptReport(
                text: texts.joined(separator: " "),
                succeeded: succeeded,
                failed: 0,
                total: pieces.count
            )
        }
        // Nothing was transcribed: the caller has to know why. A provider's own
        // cancellation is a failed segment, but it must not reach the caller as
        // a CancellationError: the caller's task was never cancelled, and any
        // code that checks for one would misread the take. Only the first
        // failure decides the wrapper; the failures behind it may be different,
        // and every other first failure is thrown exactly as it came.
        if texts.isEmpty, let first = failures.first {
            // A cancellation that raced with the last failure belongs to the
            // caller and must not be reported as the provider's.
            try Task.checkCancellation()
            if first is CancellationError {
                throw ProviderCancellationFailure(
                    provider: provider.displayName,
                    segments: pieces.count
                )
            }
            throw first
        }
        return TranscriptReport(
            text: texts.joined(separator: " "),
            succeeded: succeeded,
            failed: failures.count,
            total: pieces.count
        )
    }

    /// The samples to send, with the room tone at the edges cut when a floor is
    /// known.
    ///
    /// The cut is a measurement, so it is logged once, before the first
    /// request: the numbers say how much was taken off each edge and what
    /// decided it. The audio itself never reaches the log.
    ///
    /// - Parameters:
    ///   - samples: the clip as the recorder produced it.
    ///   - noiseFloorDBFS: the room floor of the device, or `nil`.
    /// - Returns: the same samples when there is nothing to cut, or a copy of
    ///   the range the trimmer kept.
    private static func trimmed(_ samples: [Int16], noiseFloorDBFS: Double?) -> [Int16] {
        guard let noiseFloorDBFS else { return samples }
        let trim = SilenceTrim.trim(samples, noiseFloorDBFS: noiseFloorDBFS)
        guard trim.range != 0..<samples.count else { return samples }
        Log.shared.info("transcription.silence.trimmed", [
            "leading_ms": .int(trim.removedLeadingSamples * 1000 / WAVSpec.sampleRate),
            "trailing_ms": .int(trim.removedTrailingSamples * 1000 / WAVSpec.sampleRate),
            "floor_dbfs": .double(noiseFloorDBFS),
            "threshold_dbfs": .double(SilenceTrim.thresholdDBFS(samples, noiseFloorDBFS: noiseFloorDBFS)),
            "samples": .int(trim.range.count),
        ])
        return Array(samples[trim.range])
    }
}
