import DotCore
import Foundation

/// A recording of the Welcome tour's sentence, syllable by syllable.
///
/// This is the difference between a wave that looks like a voice and a wave that
/// looks like decoration. Speech is not a wandering line: it is bursts. A
/// syllable opens in about fifteen milliseconds, holds, and closes over a
/// hundred; words are one or two of those with a breath between them; a phrase
/// is several words with a longer breath after it. Drawn at the speed a card
/// draws it, that structure is instantly recognisable, and a noise field never
/// is, however carefully it is shaped.
///
/// This schedule drives the Welcome tour and nothing else. The tour types its
/// sentence a word at a time, so it needs the syllable list as well as the
/// level: a word appears on the card when its last syllable has been said. The
/// visualizer previews used to draw from it as well, which is why it is written
/// at a pace that suits a seven word line rather than a dictation; they now draw
/// ``DictationScript``, which is a longer sentence at the pace a person dictates
/// at.
enum SpeechSchedule {
    /// One syllable of the demonstration.
    struct Syllable: Equatable {
        /// When it starts, in seconds.
        let start: Double
        /// How long it lasts, in seconds.
        let duration: Double
        /// How loud it is, from `0` to `1`.
        let peak: Double
        /// Where it sits: the word it belongs to, and which syllable of it.
        let word: Int
        let index: Int
    }

    /// The silence between the two phrases, in seconds.
    static let phrasePause: Double = 0.32

    /// The silence before the first syllable, in seconds.
    ///
    /// A preview that begins on the first syllable reads as a sound effect; a
    /// breath before it reads as someone about to speak.
    static let leadIn: Double = 0.50

    /// The tail of a syllable: the vowel still sounding after its nominal end.
    static let tail: Double = 0.040

    /// The whole utterance, in seconds, before any trailing silence.
    static let spoken: Double = syllables.last.map { $0.start + $0.duration } ?? 0

    /// Every syllable of the sentence, in order.
    static let syllables: [Syllable] = build()

    /// The level of the voice at a moment, from `0` to `1`.
    ///
    /// - Parameter time: seconds from the start of the utterance. Negative or
    ///   past the end is silence, because that is what a microphone hears.
    static func level(at time: Double) -> Double {
        guard time >= 0, time <= spoken else { return 0 }
        var total = 0.0
        for syllable in syllables {
            // The tail outlives the syllable's nominal length. Speech does not
            // return to zero between the syllables of a word - the vowel is still
            // sounding when the next consonant starts - and a shape that does
            // come to zero draws beads on a wire instead of a voice.
            let span = syllable.duration + tail
            let end = syllable.start + span
            guard time >= syllable.start, time <= end else { continue }
            let position = (time - syllable.start) / span
            let body = syllable.duration / span
            // A syllable drawn at this zoom is four to seven columns wide, so its
            // fifteen-millisecond attack cannot be resolved: drawn literally it
            // comes out as a thorn. The shape is a burst - opening quickly,
            // closing slower - that fits in the columns there are.
            let shape: Double
            if position < 0.22 {
                shape = pow(position / 0.22, 0.6)
            } else if position < body {
                shape = 1 - 0.5 * (position - 0.22) / max(0.001, body - 0.22)
            } else {
                shape = 0.5 * pow(1 - (position - body) / max(0.001, 1 - body), 1.2)
            }
            total += syllable.peak * shape
        }
        // The grain of the signal: a voice measured sixty times a second is not
        // a smooth envelope, and a smooth one reads as a drawing. It moves at
        // about two and a half cycles a second, which is inside the band the
        // meter's own 75 ms release passes: a faster field is drawn as a
        // shimmer on the level rather than as the voice, and it made the
        // demonstration modulate at nearly twice the pace of a real take.
        let grain = 0.88 + 0.12 * SpeechShape.field(time * 17, 3.3)
        // A microphone never hears nothing while someone is speaking: there is
        // breath and room, and without it the gaps between words are perfectly
        // flat, which no recording has ever been. It is slow as well as quiet,
        // so the gaps are a floor to the shape rather than a flicker in it.
        let room = 0.045 + 0.025 * SpeechShape.field(time * 9, 44.0)
        return min(1, total * grain + room)
    }

    /// When a word is finished being said.
    static func finished(_ word: Int) -> Double {
        syllables
            .filter { $0.word == word }
            .map { $0.start + $0.duration }
            .max() ?? 0
    }

    // MARK: - Building the utterance

    /// The loudness of each syllable, before its jitter.
    ///
    /// The pattern is the sentence's stress: one loud first word, a quiet
    /// middle, a second rise on `send`, and a second phrase that answers it.
    /// A phrase of evenly loud syllables reads as a machine whatever its
    /// timing, because a person puts one stress in every word and one stronger
    /// stress in every phrase.
    private static let stress: [Double] = [0.95, 0.30, 0.78, 0.26, 0.70, 0.28, 0.80, 0.24, 0.60]

    /// The shortest and longest syllable, in seconds.
    private static let syllableRange: ClosedRange<Double> = 0.180...0.210
    /// The shortest and longest breath inside a word, in seconds.
    private static let intraWordRange: ClosedRange<Double> = 0.030...0.045
    /// The shortest and longest breath between two words, in seconds.
    private static let wordRange: ClosedRange<Double> = 0.100...0.120
    /// How far a peak may be jittered, as a share of its own value.
    private static let jitter: Double = 0.12

    /// The syllables, in the order they are said.
    ///
    /// The sentence is the tour's, and the tour types a word when the word is
    /// finished, so every word has at least one syllable and the syllables are
    /// grouped by the word they belong to. The first five words carry one
    /// syllable each; the second phrase's middle word carries two, which is the
    /// only word in the sentence that is said in two parts.
    private static func build() -> [Syllable] {
        let words = TourFrame.words
        guard !words.isEmpty else { return [] }
        var counts = [Int](repeating: 1, count: words.count)
        // The word before the last: `before`, the one two-syllable word.
        let split = max(0, words.count - 3)
        if words.count >= 3 {
            counts[split] = 2
        }

        // The pause falls after the first phrase's last word: five syllables,
        // then the break, then the second phrase's four.
        let phraseBreak = min(words.count - 1, 4)

        var syllables: [Syllable] = []
        var time = leadIn
        for (word, count) in counts.enumerated() {
            for index in 0..<count {
                let seed = Double(syllables.count)
                let duration = interpolate(
                    syllableRange,
                    SpeechShape.field(seed * 2.3 + 1.7, 14.0)
                )
                // Every peak but the loudest is jittered, so the pattern is the
                // sentence's and the detail is the take's. One syllable sits at
                // the top of the range: a demonstration in which nothing is the
                // loudest thing has no peak to draw.
                let base = seed < Double(stress.count) ? stress[Int(seed)] : 0.4
                let wobble = 1 + jitter * (2 * SpeechShape.field(seed * 5.1 + 2.9, 21.0) - 1)
                let peak = base >= 0.95 ? 0.95 : min(0.95, max(0.18, base * wobble))
                syllables.append(Syllable(
                    start: time,
                    duration: duration,
                    peak: peak,
                    word: word,
                    index: index
                ))
                time += duration
                if index < count - 1 {
                    time += interpolate(intraWordRange, SpeechShape.field(seed * 3.7, 31.0))
                }
            }
            // Between two words there is a breath, and between the two phrases
            // a longer one.
            time += word == phraseBreak ? phrasePause : interpolate(wordRange, SpeechShape.field(Double(word) * 2.9, 44.0))
        }
        return syllables
    }

    /// A value inside a range, from a field value in `0...1`.
    private static func interpolate(_ range: ClosedRange<Double>, _ field: Double) -> Double {
        let position = min(max(field, 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * position
    }
}
