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

/// Sends a recording to a provider, one segment at a time.
///
/// A segment that fails does not throw the recording away: the remaining
/// segments are still sent and the report says how many worked.
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
    /// - Throws: ``ProviderError`` when *every* segment failed.
    public static func transcribe(
        wav: Data,
        provider: any Provider,
        model: String? = nil,
        language: String? = nil,
        maxSegmentSeconds: Int = Segmenter.defaultSegmentSeconds,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> TranscriptReport {
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
    ///   - maxSegmentSeconds: how long one segment is.
    ///   - progress: called with `(done, total)` before every segment.
    /// - Throws: ``ProviderError`` when *every* segment failed.
    public static func transcribe(
        samples: [Int16],
        provider: any Provider,
        model: String? = nil,
        language: String? = nil,
        maxSegmentSeconds: Int = Segmenter.defaultSegmentSeconds,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> TranscriptReport {
        // The only thing that sends nothing at all: not a single sample.
        guard !samples.isEmpty else {
            return TranscriptReport(text: "", succeeded: 0, failed: 0, total: 0)
        }

        let pieces = Segmenter.segments(samples: samples, seconds: maxSegmentSeconds)
        var texts: [String] = []
        var failures: [Error] = []
        var succeeded = 0

        for (index, piece) in pieces.enumerated() {
            progress?(index + 1, pieces.count)
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
                failures.append(error)
                Log.shared.warn("transcription.segment.failed", [
                    "segment": .int(index + 1),
                    "segments": .int(pieces.count),
                    "error": .string(error.localizedDescription),
                ])
            }
        }

        guard !failures.isEmpty else {
            return TranscriptReport(
                text: texts.joined(separator: " "),
                succeeded: succeeded,
                failed: 0,
                total: pieces.count
            )
        }
        // Every segment failed: the caller has to know why.
        if texts.isEmpty, let first = failures.first {
            throw first
        }
        return TranscriptReport(
            text: texts.joined(separator: " "),
            succeeded: succeeded,
            failed: failures.count,
            total: pieces.count
        )
    }
}
