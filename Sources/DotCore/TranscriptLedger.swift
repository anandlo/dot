import Foundation

/// What has already been transcribed for a recording, and what is still open.
///
/// A recording is not one transcript. While the microphone runs, Dot commits
/// the audio in chunks: a chunk that has been transcribed is *final*, and the
/// same samples are never sent again. What is left is the tail — the audio
/// after the last commit — which is what a live partial shows and what the
/// stop sends.
///
/// This is the difference between a stop that waits for the whole recording and
/// a stop that waits for at most one chunk:
///
/// | recording | before: requests after stop | after: requests after stop |
/// | --------- | --------------------------- | -------------------------- |
/// | 8 s       | 1 (8 s)                     | 1 (8 s)                    |
/// | 32 s      | 2 (30 s + 2 s)              | 1 (8 s)                    |
/// | 164 s     | 6 (5 × 30 s + 14 s)         | 1 (8 s)                    |
///
/// The ledger is pure: it holds the sample offsets and the text, and it never
/// touches audio, the network or a provider. That is what makes the commit
/// arithmetic testable without a microphone.
public struct TranscriptLedger: Equatable, Sendable {
    /// A live partial: the audio it covered and what the provider said.
    public struct Provisional: Equatable, Sendable {
        /// The first sample the partial covered.
        public let startSample: Int
        /// The sample after the last one the partial covered.
        public let endSample: Int
        /// The text the provider returned.
        public let text: String

        /// Creates a partial.
        public init(startSample: Int, endSample: Int, text: String) {
            self.startSample = startSample
            self.endSample = endSample
            self.text = text
        }
    }

    /// What the stop still has to do.
    public enum StopPlan: Equatable, Sendable {
        /// Every sample is transcribed: the stop sends nothing.
        case alreadyFinal(text: String)
        /// The audio from `range` is not transcribed yet.
        ///
        /// `prefix` is the text of the chunks that are already final; the text
        /// of this range is appended to it.
        case send(range: Range<Int>, prefix: String)
    }

    /// How many samples one committed chunk holds.
    public let commitSamples: Int
    /// How many samples of the recording are final.
    public private(set) var committedSamples = 0
    /// The text of every committed chunk, in order.
    public private(set) var committedText: [String] = []
    /// The last partial, if the provider answered one.
    public private(set) var provisional: Provisional?

    /// Creates a ledger.
    ///
    /// - Parameter commitSeconds: how long one committed chunk is, in seconds.
    public init(commitSeconds: Int) {
        commitSamples = max(1, commitSeconds) * WAVSpec.sampleRate
    }

    /// The text that is final so far.
    public var finalText: String {
        TranscriptLedger.join(committedText)
    }

    /// The text to show while recording: what is final plus the current partial.
    public var displayText: String {
        TranscriptLedger.join(committedText + [provisional?.text ?? ""])
    }

    /// Whether every sample of a recording of `sampleCount` is final.
    public func isComplete(sampleCount: Int) -> Bool {
        committedSamples >= sampleCount
    }

    /// The next chunk that can be committed, when a whole one is available.
    ///
    /// - Parameter sampleCount: how many samples the recording holds.
    /// - Returns: the range to send, or `nil` when less than one chunk is open.
    public func dueChunk(sampleCount: Int) -> Range<Int>? {
        guard sampleCount - committedSamples >= commitSamples else { return nil }
        return committedSamples..<(committedSamples + commitSamples)
    }

    /// Action returned by the streaming VAD pause segmenter.
    public enum VADPlan: Equatable, Sendable {
        /// A complete speech segment bounded by a natural pause (`minSilenceS = 1.6s`)
        /// or a long continuous chunk (`commitSamples`), starting at `committedSamples`
        /// so zero recorded samples are ever dropped or skipped.
        case sendSegment(range: Range<Int>, commitUpTo: Int)
        /// A cumulative live partial covering `committedSamples..<upToSample` up to a quiet
        /// breath dip, so the HUD updates live without splitting or committing mid-sentence.
        case sendProvisional(range: Range<Int>)
    }

    /// Evaluates the open audio buffer (`committedSamples..<sampleCount`) to decide whether
    /// to commit a completed long segment or preview the cumulative open audio:
    /// - Never drops or skips any recorded audio samples (no silence trimming).
    /// - Only commits a segment when there has been substantial speech (`>= 10s`) followed by a
    ///   long paragraph pause (`>= 1.8s`), or when open audio reaches `commitSamples` (`60s`),
    ///   so `mimo-v2.5-asr` receives full continuous utterances instead of mid-sentence fragments.
    /// - Emits `.sendProvisional` on natural short breath pauses (`>= 0.35s`) or every ~2.2s of new
    ///   speech at the quietest local frame so the user sees smooth live transcription.
    public func evaluateVAD(in openSamples: [Int16]) -> VADPlan? {
        let hopSize = 256 // 16 ms at 16 kHz
        let rate = Double(WAVSpec.sampleRate)
        let hopSeconds = Double(hopSize) / rate
        let commitSilenceSeconds = 1.80 // 1.8s full paragraph pause after >=10s speech before committing
        let minSpeechBeforeCommitSeconds = 10.0

        let totalFrames = openSamples.count / hopSize
        guard totalFrames >= 20 else { return nil }

        var frameRMS = [Double](repeating: 0, count: totalFrames)
        var sortedRMS = [Double]()
        sortedRMS.reserveCapacity(totalFrames)
        var peakRMS = 0.0
        for f in 0..<totalFrames {
            let start = f * hopSize
            var sumSq: Double = 0
            for i in start..<(start + hopSize) {
                let norm = Double(openSamples[i]) / 32768.0
                sumSq += norm * norm
            }
            let rms = sqrt(sumSq / Double(hopSize))
            frameRMS[f] = rms
            if rms > peakRMS { peakRMS = rms }
            if rms > 0.00005 {
                sortedRMS.append(rms)
            }
        }
        sortedRMS.sort()
        let p20 = sortedRMS.isEmpty ? 0.0015 : sortedRMS[max(0, min(sortedRMS.count - 1, sortedRMS.count / 5))]
        let noiseFloor = min(0.006, max(0.0012, p20))
        // Sensitive threshold so quiet conversational speech (-45 dBFS) is always recognized
        let startThreshold = max(0.0045, noiseFloor * 2.0)
        let endThreshold = max(0.0035, noiseFloor * 1.5)

        var active = false
        var activeStartFrame = 0
        var sumPositiveSeconds: Double = 0
        var silenceStartFrame: Int? = nil

        for f in 0..<totalFrames {
            let rms = frameRMS[f]
            if !active {
                if rms >= startThreshold {
                    active = true
                    activeStartFrame = f
                    sumPositiveSeconds = hopSeconds
                    silenceStartFrame = nil
                }
            } else {
                if rms >= endThreshold {
                    silenceStartFrame = nil
                    sumPositiveSeconds += hopSeconds
                } else if silenceStartFrame == nil {
                    silenceStartFrame = f
                }

                if let silStart = silenceStartFrame,
                   sumPositiveSeconds >= minSpeechBeforeCommitSeconds,
                   openSamples.count >= Int(rate * 15.0) {
                    let silenceDuration = Double(f - silStart + 1) * hopSeconds
                    if silenceDuration >= commitSilenceSeconds {
                        let endFrame = f + 1
                        let segStart = committedSamples
                        let segEnd = committedSamples + min(openSamples.count, endFrame * hopSize)
                        if segEnd - segStart > Int(rate * 4.0) {
                            return .sendSegment(range: segStart..<segEnd, commitUpTo: segEnd)
                        }
                    }
                }
            }
        }

        // If the user speaks continuously up to commitSamples (e.g. 60s), commit at the deepest 320ms breath dip.
        if active && openSamples.count >= commitSamples {
            let windowFrames = max(1, Int(0.32 / hopSeconds))
            let searchEndFrame = min(totalFrames - windowFrames, commitSamples / hopSize)
            let searchStartFrame = max(activeStartFrame + Int(4.0 / hopSeconds), searchEndFrame - Int(5.0 / hopSeconds))
            var cutFrame = searchEndFrame
            if searchStartFrame < searchEndFrame {
                var lowestEnergy = Double.greatestFiniteMagnitude
                for f in searchStartFrame...searchEndFrame {
                    var energy = 0.0
                    for w in 0..<windowFrames {
                        energy += frameRMS[f + w]
                    }
                    if energy < lowestEnergy {
                        lowestEnergy = energy
                        cutFrame = f + windowFrames / 2
                    }
                }
            }
            let segStart = committedSamples
            let segEnd = committedSamples + min(openSamples.count, max(hopSize, cutFrame * hopSize))
            return .sendSegment(range: segStart..<segEnd, commitUpTo: segEnd)
        }

        // Otherwise, emit a cumulative live provisional request covering `committedSamples..<cutSample`
        // so the model always sees the full continuous audio from `committedSamples` with complete context!
        guard active, sumPositiveSeconds >= 0.35, peakRMS >= 0.005 else { return nil }
        let currentSampleCount = committedSamples + openSamples.count
        let lastProvisionalEnd = provisional?.endSample ?? committedSamples
        let newSamplesSinceProvisional = currentSampleCount - lastProvisionalEnd

        // Trigger a live update either when the user pauses briefly (>= 0.32s after >= 1.1s of new audio)
        // OR after >= 2.2s of new speech, cutting at the quietest recent 160ms syllable dip.
        let trailingSilenceFrames = silenceStartFrame.map { totalFrames - $0 } ?? 0
        let trailingSilenceSeconds = Double(trailingSilenceFrames) * hopSeconds

        if trailingSilenceSeconds >= 0.32 && newSamplesSinceProvisional >= Int(rate * 1.1) {
            return .sendProvisional(range: committedSamples..<currentSampleCount)
        }

        if newSamplesSinceProvisional >= Int(rate * 2.2) {
            let windowFrames = max(1, Int(0.16 / hopSeconds))
            let searchEnd = max(windowFrames, totalFrames - windowFrames)
            let searchStart = max(0, searchEnd - Int(0.80 / hopSeconds))
            var bestFrame = totalFrames
            if searchStart < searchEnd {
                var lowest = Double.greatestFiniteMagnitude
                for f in searchStart...searchEnd {
                    var energy = 0.0
                    for w in 0..<windowFrames where (f + w) < totalFrames {
                        energy += frameRMS[f + w]
                    }
                    if energy < lowest {
                        lowest = energy
                        bestFrame = f + windowFrames / 2
                    }
                }
            }
            let cutSample = committedSamples + min(openSamples.count, max(hopSize, bestFrame * hopSize))
            if cutSample - lastProvisionalEnd >= Int(rate * 1.2) {
                return .sendProvisional(range: committedSamples..<cutSample)
            }
        }

        return nil
    }

    /// The audio a live partial should cover.
    ///
    /// The partial is the **whole open tail**: the audio after the last commit.
    /// It never reaches back into audio that is already final, and it never
    /// starts later than the commit boundary. A window that slid forward would
    /// make the first words of the card vanish while the user was still
    /// speaking, and they would come back re-transcribed once the chunk was
    /// committed.
    ///
    /// The tail is bounded by ``commitSamples``: a whole chunk is committed as
    /// soon as one is available, so the tail is shorter than one chunk.
    ///
    /// - Parameter sampleCount: how many samples the recording holds.
    /// - Returns: the range to send, or `nil` when there is nothing new.
    public func provisionalRange(sampleCount: Int) -> Range<Int>? {
        guard sampleCount > committedSamples else { return nil }
        return committedSamples..<sampleCount
    }

    /// Whether a live partial is worth sending.
    ///
    /// A loop that ticks faster than audio arrives would otherwise send the
    /// same samples again and again, and a request for a sliver of audio is
    /// what makes a provider guess at the language: the first partial used to
    /// go out after about one second of speech.
    ///
    /// - Parameters:
    ///   - sampleCount: how many samples the recording holds.
    ///   - minimumGrowth: the least new audio, in samples, that justifies a
    ///     request. The first partial needs it too.
    public func shouldSendProvisional(sampleCount: Int, minimumGrowth: Int) -> Bool {
        let transcribed = provisional?.endSample ?? committedSamples
        return sampleCount - transcribed >= max(1, minimumGrowth)
    }

    /// Records a chunk as final.
    ///
    /// - Parameters:
    ///   - range: the audio the provider transcribed.
    ///   - text: what it said.
    public mutating func commit(range: Range<Int>, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { committedText.append(trimmed) }
        committedSamples = max(committedSamples, range.upperBound)
        // A partial that covered audio inside this chunk is no longer news.
        if let provisional, provisional.startSample < committedSamples {
            self.provisional = nil
        }
    }

    /// Records the last live partial.
    ///
    /// - Parameters:
    ///   - range: the audio the partial covered.
    ///   - text: what the provider said.
    public mutating func recordProvisional(range: Range<Int>, text: String) {
        provisional = Provisional(
            startSample: range.lowerBound,
            endSample: range.upperBound,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Forgets the last partial.
    public mutating func clearProvisional() {
        provisional = nil
    }

    /// What the stop has to send.
    ///
    /// The tail is reused as the final text when the last partial covered
    /// the audio that is still open (within `trailingTolerance` samples, e.g.
    /// trailing key-release silence): transcribing it a second time
    /// would be work the app has already done.
    ///
    /// - Parameters:
    ///   - sampleCount: how many samples the recording holds.
    ///   - trailingTolerance: max un-transcribed trailing samples (silence/key-up delay) allowed to reuse provisional text.
    public func stopPlan(sampleCount: Int, trailingTolerance: Int = 0) -> StopPlan {
        guard sampleCount > committedSamples else {
            return .alreadyFinal(text: finalText)
        }
        if let provisional,
           provisional.startSample <= committedSamples,
           !provisional.text.isEmpty {
            let uncovered = sampleCount - provisional.endSample
            if uncovered <= max(0, trailingTolerance) {
                return .alreadyFinal(text: TranscriptLedger.join(committedText + [provisional.text]))
            }
        }
        return .send(range: committedSamples..<sampleCount, prefix: finalText)
    }

    /// Joins the pieces of a transcript with single spaces.
    public static func join(_ pieces: [String]) -> String {
        pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
