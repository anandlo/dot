import DotCore
import Foundation

/// The analysis and WAV preparation of one live-transcription attempt.
///
/// Everything it reads is a value or a locked store, so the same work can run
/// away from the main actor without changing what is sent to the provider.
struct LiveTranscriptionWork: Sendable {
    /// The audio and the commit decision of one attempt.
    struct Request: Sendable {
        let range: Range<Int>
        let isCommit: Bool
        let commitUpTo: Int
        let wav: Data
    }

    /// The segmenter's decision, before a WAV was made.
    let plan: TranscriptLedger.VADPlan?
    /// The request to send, when there was audio to encode.
    let request: Request?

    /// Copies the open audio, asks the ledger what to send and encodes it.
    ///
    /// - Parameters:
    ///   - ledger: the ledger state at the start of the attempt.
    ///   - sampleCount: how many samples the take held at that moment.
    ///   - store: the take's sample store.
    ///   - noiseFloorDBFS: the measured room floor, when one is known.
    /// - Returns: the decision and, when audio was available, the WAV.
    static func prepare(
        ledger: TranscriptLedger,
        sampleCount: Int,
        store: AudioSampleStore?,
        noiseFloorDBFS: Double?
    ) -> LiveTranscriptionWork {
        let committed = ledger.committedSamples
        let openSamples = sampleCount > committed
            ? store?.samples(in: committed..<sampleCount) ?? []
            : []
        let plan = ledger.evaluateVAD(in: openSamples)
        guard let plan else {
            return LiveTranscriptionWork(plan: nil, request: nil)
        }

        let reqRange: Range<Int>
        let isCommit: Bool
        let commitUpTo: Int
        switch plan {
        case .sendSegment(let segRange, let upTo):
            reqRange = segRange
            isCommit = true
            commitUpTo = upTo
        case .sendProvisional(let provRange):
            reqRange = provRange
            isCommit = false
            commitUpTo = provRange.upperBound
        }

        guard let wav = encodedWAV(range: reqRange, store: store, floor: noiseFloorDBFS) else {
            return LiveTranscriptionWork(plan: plan, request: nil)
        }
        return LiveTranscriptionWork(
            plan: plan,
            request: Request(range: reqRange, isCommit: isCommit, commitUpTo: commitUpTo, wav: wav)
        )
    }

    /// A WAV of one range of the take, with the room tone at its edges cut.
    private static func encodedWAV(
        range: Range<Int>,
        store: AudioSampleStore?,
        floor: Double?
    ) -> Data? {
        let samples = store?.samples(in: range) ?? []
        guard !samples.isEmpty else { return nil }
        guard let floor else { return WAVWriter.encode(samples: samples) }
        let trim = SilenceTrim.trim(samples, noiseFloorDBFS: floor)
        guard trim.range != 0..<samples.count else { return WAVWriter.encode(samples: samples) }
        return WAVWriter.encode(samples: Array(samples[trim.range]))
    }
}

/// The executor that does one live attempt's CPU work.
///
/// One actor serialises the attempts, so a slow analysis cannot overlap another
/// one, and none of the copying, VAD or WAV encoding occupies the main actor.
actor LiveTranscriptionAnalyzer {
    static let shared = LiveTranscriptionAnalyzer()

    /// Copies the open audio, decides what to send and encodes it.
    func prepare(
        ledger: TranscriptLedger,
        sampleCount: Int,
        store: AudioSampleStore?,
        noiseFloorDBFS: Double?
    ) -> LiveTranscriptionWork {
        LiveTranscriptionWork.prepare(
            ledger: ledger,
            sampleCount: sampleCount,
            store: store,
            noiseFloorDBFS: noiseFloorDBFS
        )
    }
}
