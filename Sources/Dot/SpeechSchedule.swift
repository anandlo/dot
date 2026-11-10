import DotCore
import Foundation

/// A recording of the demonstration sentence, syllable by syllable.
///
/// This is the difference between a wave that looks like a voice and a wave that
/// looks like decoration. Speech is not a wandering line: it is bursts. A
/// syllable opens in about fifteen milliseconds, holds, and closes over a
/// hundred; words are two or three of those with a breath between them; a phrase
/// is several words with a longer breath after it. Drawn at the speed a call
/// draws it, that structure is instantly recognisable, and a noise field never
/// is, however carefully it is shaped.
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
            let tail = 0.055
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
        // a smooth envelope, and a smooth one reads as a drawing.
        let grain = 0.84 + 0.16 * SpeechShape.field(time * 41, 3.3)
        // A microphone never hears nothing while someone is speaking: there is
        // breath and room, and without it the gaps between words are perfectly
        // flat, which no recording has ever been.
        let room = 0.05 + 0.05 * SpeechShape.field(time * 17, 44.0)
        return min(1, total * grain + room)
    }

    /// The level history the island's waveform is drawn from, oldest first.
    ///
    /// The same shape and the same rate the live card keeps: three seconds at
    /// sixty samples a second, so the welcome page and the island are drawn by
    /// the same code with the same kind of data.
    static func history(endingAt time: Double) -> [Double] {
        let count = Waveform.historyLength
        let rate = Waveform.sampleRate
        return (0..<count).map { index in
            level(at: time - Double(count - 1 - index) / rate)
        }
    }

    /// Where inside the current sample the display sits, from `0` to `1`.
    static func phase(at time: Double) -> Double {
        let ticks = time * Waveform.sampleRate
        return ticks - ticks.rounded(.down)
    }

    /// When a word is finished being said.
    static func finished(_ word: Int) -> Double {
        syllables
            .filter { $0.word == word }
            .map { $0.start + $0.duration }
            .max() ?? 0
    }

    // MARK: - Building the utterance

    private static func build() -> [Syllable] {
        var syllables: [Syllable] = []
        var time = 0.0
        for (word, piece) in TourFrame.words.enumerated() {
            // One to three syllables, decided by the word itself so the schedule
            // is the same on every run.
            let seed = SpeechShape.field(Double(word) * 3.7, 9.0)
            let count = piece.text.count <= 2 ? 1 : (seed < 0.55 ? 2 : 3)
            for index in 0..<count {
                let jitter = SpeechShape.field(Double(word) * 5.1 + Double(index) * 2.3, 14.0)
                let duration = 0.085 + 0.105 * jitter
                // The first syllable of a word carries the stress.
                let peak = 0.34 + 0.62 * SpeechShape.field(Double(word) * 1.9 + Double(index) * 4.1, 21.0)
                let stressed = index == 0 ? 1.0 : 0.82
                syllables.append(Syllable(
                    start: time,
                    duration: duration,
                    peak: min(1, peak * stressed),
                    word: word,
                    index: index
                ))
                time += duration
                // Inside a word the syllables run together; between words there
                // is a breath, and after a phrase a longer one.
                if index < count - 1 {
                    time += 0.012 + 0.02 * jitter
                }
            }
            time += word == 3 ? 0.22 : 0.045 + 0.05 * SpeechShape.field(Double(word) * 2.9, 31.0)
        }
        return syllables
    }
}
