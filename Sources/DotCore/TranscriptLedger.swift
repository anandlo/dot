import Foundation

/// What has already been transcribed for a recording, and what is still open.
///
/// A recording is transcribed in committed chunks while the microphone runs. A
/// committed chunk is final: its samples are never sent again. What remains is
/// the *open* audio after the last commit, which is what a live preview shows and
/// what the stop sends.
///
/// Two invariants hold at every point:
///
/// - `committedSamples` is the number of samples the committed text accounts
///   for, and it only ever increases.
/// - The open audio is exactly `committedSamples..<sampleCount`, so a stop sends
///   at most one chunk however long the recording was.
///
/// The type is pure: it holds sample offsets and text and touches no audio, no
/// network and no provider, which is what makes the commit arithmetic testable
/// without a microphone.
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

    /// The text to show while recording: what is final plus the current partial.
    public var displayText: String {
        TranscriptLedger.join(committedText + [provisional?.text ?? ""])
    }

    /// What the streaming VAD pause segmenter decided to do next.
    public enum VADPlan: Equatable, Sendable {
        /// A segment to commit: the audio ends at a natural pause when one
        /// arrives, and at the quietest short window near ``commitSamples``
        /// when speech does not stop.
        ///
        /// The range always starts at ``committedSamples``, so every recorded
        /// sample is covered by exactly one committed range and none is skipped.
        /// The *boundary* is placed by silence, which means a segment can end in
        /// the middle of a pause and carry that pause's tail with it.
        case sendSegment(range: Range<Int>, commitUpTo: Int)
        /// A live partial covering `committedSamples..<range.upperBound`: the
        /// open audio up to the quietest recent dip. Nothing is committed, so
        /// the same samples are sent again with the next preview.
        case sendProvisional(range: Range<Int>)
    }

    // MARK: - Tuning

    /// The length of one analysis frame, in samples: 16 ms at 16 kHz.
    static let hopSize = 256
    /// The pause, in seconds, that ends a committed segment once the speaker
    /// has already said enough to commit. A paragraph break, not a breath.
    static let commitSilenceSeconds: Double = 1.80
    /// The speech, in seconds, a segment must contain before a pause may commit
    /// it. Below this a pause is a breath and the segment stays open.
    static let minimumSpeechBeforeCommitSeconds: Double = 10.0
    /// The shortest committed segment, in seconds. A pause that arrives sooner
    /// is not worth a request of its own.
    static let minimumSegmentSeconds: Double = 4.0
    /// The length of a breath, in seconds.
    ///
    /// Two uses, one meaning: the width of the window the dip search averages
    /// over, and the shortest trailing pause that ends an open preview.
    static let breathSeconds: Double = 0.32
    /// The speech, in seconds, a preview needs before it is worth sending at all.
    static let minimumPreviewSpeechSeconds: Double = 0.35
    /// The newest audio, in seconds, a preview needs before a pause may send it.
    static let previewGrowthSeconds: Double = 1.1
    /// The newest audio, in seconds, after which a preview is sent even though
    /// the speaker has not paused.
    static let previewIntervalSeconds: Double = 2.2
    /// The speech, in seconds, to skip before searching for the quietest frame.
    /// A cut placed on the first syllable of a sentence is worse than a late one.
    static let dipSearchLeadSeconds: Double = 4.0
    /// How far before the size limit, in seconds, the quietest frame is searched
    /// for. Wider than the search window of a preview because a commit is final.
    static let commitDipSearchWindowSeconds: Double = 5.0
    /// The peak frame level, as a linear value, below which the open buffer is
    /// treated as silence rather than as speech worth sending.
    static let minimumPeakLevel: Double = 0.005

    /// Evaluates the open audio buffer (`committedSamples..<sampleCount`) and
    /// decides whether to commit a finished segment or preview what is open.
    ///
    /// - A commit needs either a paragraph pause (``commitSilenceSeconds``)
    ///   after ``minimumSpeechBeforeCommitSeconds`` of speech, or
    ///   ``commitSamples`` of open audio.
    /// - A preview is sent on a breath pause (``breathSeconds``) once
    ///   ``previewGrowthSeconds`` is new, or after ``previewIntervalSeconds`` of
    ///   new speech, cut at the quietest recent dip.
    ///
    /// - Parameter openSamples: the audio after the last commit, in 16 kHz mono
    ///   samples.
    /// - Returns: the next step, or `nil` when the open audio decides nothing
    ///   yet.
    public func evaluateVAD(in openSamples: [Int16]) -> VADPlan? {
        let hopSize = Self.hopSize
        let rate = Double(WAVSpec.sampleRate)
        let hopSeconds = Double(hopSize) / rate
        let commitSilenceSeconds = Self.commitSilenceSeconds
        let minSpeechBeforeCommitSeconds = Self.minimumSpeechBeforeCommitSeconds

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
                        if segEnd - segStart > Int(rate * Self.minimumSegmentSeconds) {
                            return .sendSegment(range: segStart..<segEnd, commitUpTo: segEnd)
                        }
                    }
                }
            }
        }

        // Speech that never pauses is committed at the quietest breath near the
        // size limit: a boundary placed on a breath is inaudible, one placed on a
        // syllable is a cut in the middle of a word.
        if active && openSamples.count >= commitSamples {
            let windowFrames = max(1, Int(Self.breathSeconds / hopSeconds))
            let searchEndFrame = min(totalFrames - windowFrames, commitSamples / hopSize)
            let searchStartFrame = max(
                activeStartFrame + Int(Self.dipSearchLeadSeconds / hopSeconds),
                searchEndFrame - Int(Self.commitDipSearchWindowSeconds / hopSeconds)
            )
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

        // Otherwise emit a cumulative preview from `committedSamples` to the cut,
        // so the model sees the whole open utterance with its context instead of
        // the tail of it.
        guard active,
              sumPositiveSeconds >= Self.minimumPreviewSpeechSeconds,
              peakRMS >= Self.minimumPeakLevel
        else { return nil }
        let currentSampleCount = committedSamples + openSamples.count
        let lastProvisionalEnd = provisional?.endSample ?? committedSamples
        let newSamplesSinceProvisional = currentSampleCount - lastProvisionalEnd

        // A preview is worth sending on a breath pause once enough is new, or
        // after a fixed stretch of speech; both cuts land on the quietest dip.
        let trailingSilenceFrames = silenceStartFrame.map { totalFrames - $0 } ?? 0
        let trailingSilenceSeconds = Double(trailingSilenceFrames) * hopSeconds

        if trailingSilenceSeconds >= Self.breathSeconds,
           newSamplesSinceProvisional >= Int(rate * Self.previewGrowthSeconds) {
            return .sendProvisional(range: committedSamples..<currentSampleCount)
        }

        if newSamplesSinceProvisional >= Int(rate * Self.previewIntervalSeconds) {
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

    /// Records a chunk as final.
    ///
    /// - Parameters:
    ///   - range: the audio the provider transcribed.
    ///   - text: what it said.
    public mutating func commit(range: Range<Int>, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { committedText.append(trimmed) }
        committedSamples = max(committedSamples, range.upperBound)
        // A partial that starts inside the committed range is superseded: its
        // audio is now final, so it can be neither shown nor reused.
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

    /// What the stop has to send.
    ///
    /// The last partial becomes the final text when it already covered the audio
    /// that is still open, within `trailingTolerance` samples. The tolerance
    /// exists for the key-release delay at the end of a push-to-talk recording:
    /// a few thousand samples of room tone are not worth a second request.
    ///
    /// - Parameters:
    ///   - sampleCount: how many samples the recording holds.
    ///   - trailingTolerance: the untranscribed trailing samples that may be left
    ///     to a reused partial rather than sent.
    /// - Returns: the work the stop still has, if any.
    public func stopPlan(sampleCount: Int, trailingTolerance: Int = 0) -> StopPlan {
        guard sampleCount > committedSamples else {
            return .alreadyFinal(text: TranscriptLedger.join(committedText))
        }
        if let provisional,
           provisional.startSample <= committedSamples,
           !provisional.text.isEmpty {
            let uncovered = sampleCount - provisional.endSample
            if uncovered <= max(0, trailingTolerance) {
                return .alreadyFinal(text: TranscriptLedger.join(committedText + [provisional.text]))
            }
        }
        return .send(
            range: committedSamples..<sampleCount,
            prefix: TranscriptLedger.join(committedText)
        )
    }

    /// Joins the pieces of a transcript with single spaces.
    public static func join(_ pieces: [String]) -> String {
        pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
