import Foundation

/// Cuts the room tone from the edges of a take before it is sent.
///
/// Dot records from the key press, so every take opens with the tone of the
/// room it was recorded in and the first word arrives a fraction of a second
/// later. A chat-style speech model answers that quiet lead-in with the
/// furniture of a chat answer - a list number, a timestamp - and the transcript
/// then begins with a number nobody said. The audio is not the problem: the
/// silence in front of it is.
///
/// The trimmer is deliberately timid, because it holds the one job that can
/// lose words. It measures 10 ms frames, which cannot hold a whole word: a
/// syllable lasts a tenth of a second or more, so speech lifts several frames in
/// a row above the threshold and a single quiet frame inside a word is never
/// mistaken for the edge of it. Even when a head is found, the cut stops 150 ms
/// short of the first frame of speech, so the breath in front of a word stays
/// with the word. Everything else is a refusal: a clip too short to be worth
/// trimming, a clip already beginning on speech, an opening that never rises
/// above the threshold, a head that would lose less than a tenth of a second,
/// or a measurement that is not a number. A wrong trim that eats the first word
/// costs more than every stray number it could prevent.
///
/// Nothing is reordered, resampled or scaled. The result is a range of the
/// samples that were handed in, and the caller encodes exactly that range.
public enum SilenceTrim {
    /// What one trim decided.
    public struct Result: Equatable {
        /// The samples to send, as offsets into the clip that was trimmed.
        public let range: Range<Int>
        /// How many samples were cut from the head.
        public let removedLeadingSamples: Int
        /// How many samples were cut from the end.
        public let removedTrailingSamples: Int

        /// Creates a result.
        ///
        /// - Parameters:
        ///   - range: the samples to send.
        ///   - removedLeadingSamples: how many samples were cut from the head.
        ///   - removedTrailingSamples: how many samples were cut from the end.
        public init(range: Range<Int>, removedLeadingSamples: Int, removedTrailingSamples: Int) {
            self.range = range
            self.removedLeadingSamples = removedLeadingSamples
            self.removedTrailingSamples = removedTrailingSamples
        }
    }

    /// The length of one analysis frame, in samples.
    ///
    /// Ten milliseconds at the 16 kHz Dot records at. Short enough that a frame
    /// cannot hold a syllable, long enough that its RMS is a measurement rather
    /// than a sample.
    public static let frameSamples = WAVSpec.sampleRate / 100

    /// How far above the room floor a frame has to sit to count as sound, in
    /// decibels.
    ///
    /// Twelve decibels is the margin between the loudest a quiet room gets and
    /// the quietest a voice gets, which is why a floor that says the tone is
    /// loud leaves the clip alone instead of cutting into it.
    public static let thresholdAboveFloorDB: Double = 12

    /// The audio kept in front of the first frame of speech, in samples.
    ///
    /// A hundred and fifty milliseconds: a breath, a lip smack, the room tone
    /// the first consonant was spoken over. Words start before their first
    /// loud frame, and this is what stops the cut from landing on one.
    public static let preRollSamples = WAVSpec.sampleRate * 150 / 1000

    /// The audio kept after the last frame of speech, in samples.
    ///
    /// A quarter of a second, for the same reason at the other edge: the tail
    /// of a final consonant is quieter than its vowel.
    public static let tailSamples = WAVSpec.sampleRate * 250 / 1000

    /// The shortest clip that is measured, in samples.
    ///
    /// Three hundred milliseconds: below that there is not enough of the
    /// opening to tell tone from the start of a word.
    public static let minimumClipSamples = WAVSpec.sampleRate * 300 / 1000

    /// The shortest head worth cutting, in samples.
    ///
    /// A hundred milliseconds. A shorter cut saves a request nothing and moves
    /// the boundary a listener cannot hear.
    public static let minimumHeadTrimSamples = WAVSpec.sampleRate * 100 / 1000

    /// How much of the opening is measured when no floor is supplied, in
    /// samples.
    ///
    /// Three hundred milliseconds, the stretch a take opens on before the
    /// person starts speaking.
    static let openingSamples = WAVSpec.sampleRate * 300 / 1000

    /// The samples to send, with the room tone at the edges cut.
    ///
    /// - Parameters:
    ///   - samples: 16 kHz mono PCM16 samples, as the recorder produced them.
    ///   - noiseFloorDBFS: the room floor measured on the device that recorded
    ///     the clip, or `nil` when nothing has measured it. A `nil` floor is
    ///     not a reason to skip the trim; see ``thresholdDBFS(_:noiseFloorDBFS:)``.
    /// - Returns: the range to encode, and how much was cut from each edge.
    public static func trim(_ samples: [Int16], noiseFloorDBFS: Double?) -> Result {
        let whole = Result(
            range: 0..<samples.count,
            removedLeadingSamples: 0,
            removedTrailingSamples: 0
        )
        guard samples.count >= minimumClipSamples else { return whole }

        let threshold = thresholdDBFS(samples, noiseFloorDBFS: noiseFloorDBFS)
        // A threshold that is not a number describes no room, so it decides
        // nothing.
        guard threshold.isFinite else { return whole }

        let levels = frameLevels(samples)
        // The whole clip is searched, not an opening window: a person who
        // presses the key and then thinks for two seconds leaves two seconds of
        // room tone, which is the case the model numbers most readily. A clip
        // that opens on a word finds its onset in the first frame, and the
        // minimum-head guard sends it unchanged.
        guard let onset = levels.firstIndex(where: { $0 >= threshold }) else {
            return whole
        }

        // The first frame of speech can begin anywhere inside itself, so the
        // cut lands before the frame, minus the pre-roll.
        let head = max(0, onset * frameSamples - preRollSamples)
        guard head >= minimumHeadTrimSamples else { return whole }

        guard let last = levels.lastIndex(where: { $0 >= threshold }) else { return whole }
        let tail = min(samples.count, (last + 1) * frameSamples + tailSamples)
        // Nothing is cut if the two edges would meet: a clip that is speech
        // throughout is a clip with no edges to cut.
        guard head < tail else { return whole }

        return Result(
            range: head..<tail,
            removedLeadingSamples: head,
            removedTrailingSamples: samples.count - tail
        )
    }

    /// The level a frame has to reach to count as sound, in dBFS.
    ///
    /// A supplied floor is what Dot measured of the room on this device, so the
    /// bar sits a fixed step above it. Without one the clip is its own
    /// reference: the median level of its first 300 ms is the tone the take
    /// opened on, and the same step above it is the bar. The median and not the
    /// mean, because one keyboard click in the opening would drag a mean up and
    /// hide the first word behind it.
    ///
    /// - Parameters:
    ///   - samples: 16 kHz mono PCM16 samples.
    ///   - noiseFloorDBFS: the measured room floor, or `nil`.
    /// - Returns: the threshold, or a non-finite number when the opening
    ///   carries nothing to measure.
    static func thresholdDBFS(_ samples: [Int16], noiseFloorDBFS: Double?) -> Double {
        if let noiseFloorDBFS { return noiseFloorDBFS + thresholdAboveFloorDB }
        let opening = frameLevels(Array(samples.prefix(openingSamples)))
        guard !opening.isEmpty else { return .nan }
        return opening.sorted()[opening.count / 2] + thresholdAboveFloorDB
    }

    /// The level of every whole frame of a clip, in dBFS.
    ///
    /// A frame's level is its RMS, the same measurement ``AudioLevel`` makes of
    /// a whole recording. Digital silence has no level in decibels at all, so
    /// it is reported at ``LevelScale/silenceDBFS``: a floor rather than a
    /// number that would sit below every threshold and be read as a boundary of
    /// its own.
    private static func frameLevels(_ samples: [Int16]) -> [Double] {
        let count = samples.count / frameSamples
        var levels: [Double] = []
        levels.reserveCapacity(count)
        for frame in 0..<count {
            let start = frame * frameSamples
            var total = 0.0
            for index in start..<(start + frameSamples) {
                let value = Double(samples[index]) / 32_768.0
                total += value * value
            }
            let decibels = AudioLevel.decibels((total / Double(frameSamples)).squareRoot())
            levels.append(decibels.isFinite ? decibels : LevelScale.silenceDBFS)
        }
        return levels
    }
}
