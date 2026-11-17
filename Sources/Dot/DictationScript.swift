import DotCore
import Foundation

/// A dictation, written the way a person says it.
///
/// The visualiser previews used to draw nine syllables of 180 to 210
/// milliseconds each, with 100 to 120 milliseconds between them and a band
/// modulation of `voice * (0.45 + 0.55 * abs(sin(now * 9.3)))` on top. That is a
/// metronome with a tremolo, and it is why the island's demonstration read as an
/// animation rather than as a recording: nothing in it was slower than anything
/// else, so the eye had no phrase to follow.
///
/// Speech is not like that, in four ways this script is written from. A stressed
/// syllable is two to three times the length of the function word beside it. The
/// loudness falls from the first stressed syllable of a phrase to its last, by
/// about a fifth. An unstressed syllable leans on the stressed one until the two
/// are one sound, so the level never returns to nothing inside a word. And a
/// breath after a clause is several times the breath between two words, and a
/// sentence's is longer again, which is what gives a sentence its shape at a
/// glance.
///
/// So this is a script rather than a tempo: thirty three syllables over twenty
/// six words in five phrases, every length, gap, pause and peak drawn once from
/// ``SpeechShape``'s field, which is a hash and not a generator with state. The
/// same numbers come out on every run, on every machine, which is what lets the
/// preview, the Settings tiles and the renders be one demonstration. It runs at
/// a little under a hundred and forty words a minute over thirteen and a half
/// seconds: a second of room, eleven seconds of speech and a second and a half of
/// room after it.
///
/// Everything that shows a simulated voice draws it from here. The Welcome tour
/// keeps its own schedule (``SpeechSchedule``), because it types its sentence a
/// word at a time and reads the syllable list to do it.
enum DictationScript {
    // MARK: - The script

    /// The sentence, as it reads in the script.
    static let text = """
    Hey Sam, quick update on the launch. The new build is ready, and I'll send it over this \
    afternoon. Let me know if anything looks off.
    """

    /// How a syllable carries its stress.
    enum Stress: Equatable {
        /// The stressed syllable of a content word: the long, loud one.
        case stressed
        /// A content word's other syllable. Shorter, quieter, and it leans on
        /// the stressed syllable beside it until the two overlap.
        case weak
        /// A function word: a stop or a schwa, the shortest thing in the line,
        /// and the place a reader's eye skips.
        case function

        /// The range the syllable's peak is drawn from, before the declination.
        var peakRange: ClosedRange<Double> {
            switch self {
            case .stressed: DictationScript.stressedPeak
            case .weak: DictationScript.weakPeak
            case .function: DictationScript.functionPeak
            }
        }

        /// The range the syllable's body is drawn from, in seconds.
        var durationRange: ClosedRange<Double> {
            switch self {
            case .stressed: DictationScript.stressedDuration
            case .weak: DictationScript.weakDuration
            case .function: DictationScript.functionDuration
            }
        }

        /// The weights this kind of syllable puts across the five bands.
        var bands: (Double, Double, Double, Double, Double) {
            switch self {
            case .stressed, .weak: DictationScript.vowelBands
            case .function: DictationScript.stopBands
            }
        }
    }

    /// One syllable of the script, placed in time.
    struct Syllable: Equatable {
        /// The word the syllable belongs to, as it is written.
        let word: String
        /// Which word of the script it belongs to, counting from `0`.
        let wordIndex: Int
        /// The syllable itself: `af`, `ter`, `noon`.
        let text: String
        /// How it carries its stress.
        let stress: Stress
        /// Whether the syllable is noise rather than voice. A fricative is
        /// quieter than a vowel of the same stress and its energy sits at the
        /// top of the spectrum, which is what makes a spectrum that moves with
        /// the words instead of with the envelope.
        let fricative: Bool
        /// When the syllable opens, in seconds from the start of the script.
        let start: Double
        /// How long the attack and the sustaining vowel last, in seconds. The
        /// release is added after this, so a syllable's sound outlives its body.
        let duration: Double
        /// The peak the stress band drew, before the declination, the noise of a
        /// fricative and the script's own peak are applied. It is kept so the
        /// shaping of a peak is a value a reader can check rather than a curve to
        /// fit.
        let drawnPeak: Double
        /// The level at the crest of the attack, from `0` to `1`.
        let peak: Double
        /// Where it sits in its phrase, from `0` at the first syllable to `1` at
        /// the last. The declination is written against this.
        let position: Double
        /// Which phrase of the script it belongs to, counting from `0`.
        let phrase: Int

        /// When the attack reaches its peak, in seconds.
        var crest: Double { start + DictationScript.attack }

        /// When the release has died away, in seconds.
        var end: Double { start + duration + DictationScript.release }
    }

    /// A breath between two phrases.
    struct Pause: Equatable {
        /// Which kind of breath it is.
        let kind: Kind
        /// When it starts, in seconds.
        let start: Double
        /// How long it lasts, in seconds.
        let duration: Double

        /// The two pauses a spoken sentence has.
        enum Kind: Equatable {
            /// Between two clauses: a breath long enough to hear, short of a stop.
            case clause
            /// Between two sentences: the longest silence in the script.
            case sentence
        }
    }

    // MARK: - Timing

    /// How long the room is heard before the first syllable, in seconds.
    ///
    /// A preview that begins on the first syllable reads as a sound effect; a
    /// breath before it reads as someone about to speak.
    static let leadIn: Double = 1.0

    /// How long the room is heard after the last syllable, in seconds.
    static let trailing: Double = 1.4

    /// How long the card rests after the script, in seconds.
    ///
    /// A loop that ends on the last syllable and starts again at once reads as a
    /// stuck recording. The rest is the room between two takes.
    static let resting: Double = 0.6

    /// How long the attack of a syllable takes to reach its peak, in seconds.
    static let attack: Double = 0.045

    /// How long the release of a syllable takes to die away after its body, in
    /// seconds.
    ///
    /// A hundred and ten milliseconds is longer than the gaps between most words,
    /// so a release crosses the breath after its own word: that is the overlap
    /// the ear hears as one sound running into the next, and it is why the level
    /// between two words dips rather than stopping.
    static let release: Double = 0.110

    /// The share of a syllable's amplitude the sustaining vowel loses before the
    /// release, from `0` to `1`.
    static let sustainDecay: Double = 0.12

    /// How fast the vowel beats while it sustains, in hertz.
    static let wobbleRate: Double = 5.0

    /// How far the vowel beats, as a share of its amplitude.
    static let wobbleDepth: Double = 0.06

    /// How much of the shorter syllable the next syllable of the same word
    /// covers, from `0` to `1`.
    ///
    /// Two syllables of one word are one gesture: the vowel is still sounding
    /// when the next consonant starts, and an envelope that returns to zero
    /// between them draws beads on a wire instead of a word.
    static let coarticulation: Double = 0.25

    /// How far the loudness falls from the first syllable of a phrase to its
    /// last, from `0` to `1`.
    static let declination: Double = 0.18

    /// How much quieter a fricative is than a vowel of the same stress.
    static let fricativeScale: Double = 0.55

    /// How far the grain moves a fricative, as a share of its amplitude.
    ///
    /// Noise is ragged in a way a vowel is not, which is the one part of a
    /// sibilant a level trace can show.
    static let fricativeGrain: Double = 0.25

    /// How far the grain moves a syllable that is not a fricative.
    static let grainDepth: Double = 0.12

    /// The level of the room the recording is made in, before its slow field.
    static let roomFloor: Double = 0.04

    /// How far the room's own level moves, in either direction.
    static let roomSwing: Double = 0.02

    /// How far a band's share of the level moves, in either direction.
    ///
    /// Without it the five bands are the same shape at five heights and read as
    /// one number drawn five times.
    static let bandSwing: Double = 0.15

    /// The syllable lengths a stressed syllable is drawn from, in seconds.
    static let stressedDuration: ClosedRange<Double> = 0.22...0.32
    /// The syllable lengths a weak syllable is drawn from, in seconds.
    static let weakDuration: ClosedRange<Double> = 0.13...0.19
    /// The syllable lengths a function word is drawn from, in seconds.
    static let functionDuration: ClosedRange<Double> = 0.09...0.14
    /// The breath between two syllables of one word, before the overlap.
    static let intraWordGap: ClosedRange<Double> = 0.00...0.02
    /// The breath between two words of one phrase, in seconds.
    static let wordGap: ClosedRange<Double> = 0.05...0.11
    /// The breath after a clause, in seconds.
    static let clausePause: ClosedRange<Double> = 0.35...0.50
    /// The breath after a sentence, in seconds.
    static let sentencePause: ClosedRange<Double> = 0.80...1.10

    /// The peaks a stressed syllable is drawn from.
    static let stressedPeak: ClosedRange<Double> = 0.70...0.95
    /// The peaks a weak syllable is drawn from.
    static let weakPeak: ClosedRange<Double> = 0.40...0.55
    /// The peaks a function word is drawn from.
    static let functionPeak: ClosedRange<Double> = 0.28...0.40

    /// The level of the loudest syllable of the script.
    static let loudest: Double = 0.95

    /// The weights a vowel puts across the five bands.
    ///
    /// Row `0` is the top of the grid and the top of the spectrum: a vowel has
    /// most of its energy at the bottom, in the fundamental and the chest.
    static let vowelBands: (Double, Double, Double, Double, Double) = (0.90, 0.85, 0.60, 0.30, 0.12)

    /// The weights a fricative puts across the five bands: the mirror of a vowel.
    static let fricativeBands: (Double, Double, Double, Double, Double) = (0.12, 0.20, 0.40, 0.85, 1.00)

    /// The weights a stop or a function word puts across the five bands: flat,
    /// because a stop is a click and a click has no pitch.
    static let stopBands: (Double, Double, Double, Double, Double) = (0.50, 0.55, 0.50, 0.45, 0.30)

    // MARK: - The script in time

    /// Every syllable of the script, in the order it is said.
    static let syllables: [Syllable] = build().syllables

    /// Every breath between two phrases, in the order it is taken.
    static let pauses: [Pause] = build().pauses

    /// When the first syllable opens, in seconds.
    static let speechStart: Double = syllables.first?.start ?? leadIn

    /// When the last syllable has died away, in seconds.
    static let speechEnd: Double = syllables.last?.end ?? leadIn

    /// How long the speech itself lasts, from the first attack to the last
    /// release, in seconds.
    ///
    /// This is what the pace is measured over: the room before and after it is
    /// not speaking time.
    static let speech: Double = speechEnd - speechStart

    /// The number of words in the script.
    static let wordCount: Int = Set(syllables.map(\.wordIndex)).count

    /// How long one pass of the demonstration lasts, in seconds.
    ///
    /// The room before the voice, the voice, and the room after it. The loop the
    /// preview draws is this plus ``resting``.
    static let duration: Double = leadIn + speech + trailing

    /// The whole loop of the demonstration: the script and the rest after it.
    static let loop: Double = duration + resting

    /// Where the still tiles are frozen, in seconds.
    ///
    /// A hundred and fifty milliseconds after the crest of `send`, the loudest
    /// syllable of the script, which is inside the fourth phrase and past its
    /// opening words: every visualiser has something to draw there, where a tile
    /// frozen in the breath before the first syllable would be a picture of
    /// silence next to the selected one.
    static let stillTime: Double = (syllables.first { $0.text == "send" }?.crest ?? 2.4) + 0.15

    // MARK: - The voice

    /// The level of the voice at a moment, from `0` to `1`.
    ///
    /// - Parameter time: seconds from the start of the script. Before the script
    ///   and after its loop is silence, because that is what a microphone hears
    ///   before it is armed; the room itself is heard throughout the loop.
    /// - Returns: the level, which never returns to nothing while a syllable or
    ///   its release is sounding.
    static func level(at time: Double) -> Double {
        guard time >= 0, time <= loop else { return 0 }
        let room = roomLevel(at: time)
        return room + sounding(at: time).voice * (1 - room)
    }

    /// The five bands of the voice at a moment.
    ///
    /// Each band is its share of the level, where the shares are the weights of
    /// whichever syllables are sounding, blended by their own envelopes: a word
    /// with an `s` in it lifts the top row as it passes and drops it again, which
    /// is the movement a grid of five rows has instead of a level trace. Each
    /// band then takes its own slow field, because five rows locked to one
    /// envelope are one row drawn five times.
    ///
    /// - Parameter time: seconds from the start of the script.
    /// - Returns: the five bands as shares of the level, from `0` to `1`, in the
    ///   same domain the recorder reports its bands in, or
    ///   ``AudioSpectrumFrame/zero`` when nothing is sounding. The card maps them
    ///   onto the take's own window before it draws them, exactly as it maps a
    ///   recorded frame.
    static func bands(at time: Double) -> AudioSpectrumFrame {
        guard time >= 0, time <= loop else { return .zero }
        let sound = sounding(at: time)
        guard sound.total > 0.0001 else { return .zero }
        let room = roomLevel(at: time)
        let voice = room + sound.voice * (1 - room)
        func band(_ index: Int, _ weight: Double) -> Double {
            let swing = 1 + bandSwing * (2 * SpeechShape.field(time * 0.7, 70 + Double(index)) - 1)
            return min(1, max(0, voice * (weight / sound.total) * swing))
        }
        return AudioSpectrumFrame(bands: (
            band(0, sound.band0),
            band(1, sound.band1),
            band(2, sound.band2),
            band(3, sound.band3),
            band(4, sound.band4)
        ))
    }

    /// The level history the island's waveform is drawn from, oldest first.
    ///
    /// The same shape and the same rate the live card keeps: three seconds at
    /// sixty samples a second, so the preview and a recording are drawn by the
    /// same code with the same kind of data.
    ///
    /// - Parameter time: where the newest sample sits, in seconds.
    static func history(endingAt time: Double) -> [Double] {
        let count = Waveform.historyLength
        let rate = Waveform.sampleRate
        return (0..<count).map { index in
            level(at: time - Double(count - 1 - index) / rate)
        }
    }

    /// The five bands the grid and the scrolling meter draw, oldest first.
    ///
    /// The card maps a recorded frame onto the take's own window before it draws
    /// it, band by band, so that the quietest and the loudest moment of a voice
    /// fill the grid. This does the same to the script, over the whole history at
    /// once, which is what a tile needs: a spectrum history already on the scale
    /// the drawing reads.
    ///
    /// - Parameter time: where the newest sample sits, in seconds.
    /// - Returns: one frame per sample of ``history(endingAt:)``, oldest first.
    static func spectrumHistory(endingAt time: Double) -> [AudioSpectrumFrame] {
        let count = Waveform.historyLength
        let rate = Waveform.sampleRate
        let dt = 1 / rate
        var scale = SpectrumScale()
        return (0..<count).map { index in
            let moment = time - Double(count - 1 - index) / rate
            return scale.normalise(bands(at: moment), dt: dt)
        }
    }

    /// Where inside the current sample the display sits, from `0` to `1`.
    static func phase(at time: Double) -> Double {
        let ticks = time * Waveform.sampleRate
        return ticks - ticks.rounded(.down)
    }

    // MARK: - Sounding a moment

    /// What is sounding at one moment.
    private struct Sound {
        /// The soft sum of the envelopes, from `0` to `1`.
        var voice: Double = 0
        /// The envelope-weighted sum of each band's share, before the division.
        var band0: Double = 0
        var band1: Double = 0
        var band2: Double = 0
        var band3: Double = 0
        var band4: Double = 0
        /// The sum of the envelopes, which is what the band sums are divided by.
        var total: Double = 0
    }

    /// Every syllable sounding at a moment, summed into one level.
    ///
    /// Two sounds at once are heard as one level, and the sum of two amplitudes
    /// is not that level: a vowel and the release of the syllable before it are
    /// together louder than either and never twice as loud. The soft sum
    /// `1 - (1 - a)(1 - b)` is the standard answer to that, and it is also what
    /// keeps the script's peak at the value its stress wrote, because it can
    /// never exceed the loudest of its terms.
    private static func sounding(at time: Double) -> Sound {
        var sound = Sound()
        var remaining = 1.0
        for syllable in syllables {
            guard time >= syllable.start, time <= syllable.end else { continue }
            let amplitude = amplitude(of: syllable, at: time)
            guard amplitude > 0 else { continue }
            remaining *= 1 - amplitude
            let bands = syllable.fricative ? fricativeBands : syllable.stress.bands
            sound.band0 += amplitude * bands.0
            sound.band1 += amplitude * bands.1
            sound.band2 += amplitude * bands.2
            sound.band3 += amplitude * bands.3
            sound.band4 += amplitude * bands.4
            sound.total += amplitude
        }
        sound.voice = min(1, 1 - remaining)
        return sound
    }

    /// The envelope of one syllable at a moment, from `0` to its peak.
    ///
    /// Three phases: a forty five millisecond attack that opens fast and settles
    /// onto the peak, a body that loses an eighth of its height while the vowel
    /// beats at five hertz, and a hundred and ten millisecond release that starts
    /// where the body left off and dies away.
    private static func amplitude(of syllable: Syllable, at time: Double) -> Double {
        let local = time - syllable.start
        guard local >= 0, local <= syllable.duration + release else { return 0 }
        if local < attack {
            // Ease-out: a syllable opens in a burst and then finds its level, and
            // at the end of the attack it is exactly the peak its stress wrote,
            // which is what makes a peak a stated value.
            let opened = local / attack
            return syllable.peak * (1 - (1 - opened) * (1 - opened))
        }
        if local <= syllable.duration {
            return syllable.peak * body(of: syllable, at: local) * grain(of: syllable, at: local)
        }
        let leaving = syllable.peak * body(of: syllable, at: syllable.duration)
            * grain(of: syllable, at: syllable.duration)
        let released = (local - syllable.duration) / release
        return leaving * (1 - released) * (1 - released)
    }

    /// The sustaining vowel: the height it has lost and the beat across it.
    private static func body(of syllable: Syllable, at local: Double) -> Double {
        let progress = (local - attack) / max(0.001, syllable.duration - attack)
        let decay = 1 - sustainDecay * progress
        // The beat is locked to the syllable's own start, so the script is the
        // same on every run and two syllables never beat in step.
        let beat = 1 + wobbleDepth * sin(2 * .pi * wobbleRate * local + 6.3 * syllable.start)
        return min(1, decay * beat)
    }

    /// The fast field that makes a level look measured rather than drawn.
    ///
    /// It rides on the body and not on the crest: the ripple grows in over the
    /// sixty milliseconds after the attack, so a syllable's peak is the value its
    /// stress wrote and not wherever a noise field happened to be.
    private static func grain(of syllable: Syllable, at local: Double) -> Double {
        let depth = syllable.fricative ? fricativeGrain : grainDepth
        let settled = min(1, max(0, (local - attack) / 0.06))
        let field = SpeechShape.field(local * 17, 3.3 + syllable.start * 5)
        return 1 - depth * settled * field
    }

    /// The room the recording is made in, from `0` to `1`.
    ///
    /// A microphone never hears nothing while it is armed: there is breath and
    /// room, and without it the pauses are perfectly flat, which no recording has
    /// ever been. It is slow as well as quiet, so it is a floor under the voice
    /// rather than a flicker in it.
    private static func roomLevel(at time: Double) -> Double {
        roomFloor + roomSwing * SpeechShape.field(time * 0.9, 61)
    }

    // MARK: - Building the script

    /// One syllable of the written script, before it is placed in time.
    private struct Part {
        let text: String
        let stress: Stress
        let fricative: Bool

        init(_ text: String, _ stress: Stress, fricative: Bool = false) {
            self.text = text
            self.stress = stress
            self.fricative = fricative
        }
    }

    /// One word of the written script.
    private struct Line {
        let word: String
        let parts: [Part]
    }

    /// One phrase of the written script and the breath after it.
    private struct LineGroup {
        let words: [Line]
        let pause: Pause.Kind?
    }

    /// The script as it is written: five phrases, twenty six words, thirty three
    /// syllables.
    ///
    /// The stress is the reading a person would give the line, not a pattern:
    /// `Hey` and `Sam` are both called, `update` is said on its first syllable,
    /// `the` and `on` are said at all only because English needs them, and
    /// `afternoon` carries two stresses with a weak syllable between them. The
    /// fricative marks are the words with an `s`, a `sh` or an `f` in them, which
    /// is where the grid's top row lives.
    private static let written: [LineGroup] = [
        LineGroup(words: [
            Line(word: "Hey", parts: [Part("Hey", .stressed)]),
            Line(word: "Sam", parts: [Part("Sam", .stressed)]),
        ], pause: .clause),
        LineGroup(words: [
            Line(word: "quick", parts: [Part("quick", .stressed)]),
            Line(word: "update", parts: [Part("up", .stressed), Part("date", .weak)]),
            Line(word: "on", parts: [Part("on", .function)]),
            Line(word: "the", parts: [Part("the", .function)]),
            Line(word: "launch", parts: [Part("launch", .stressed, fricative: true)]),
        ], pause: .sentence),
        LineGroup(words: [
            Line(word: "The", parts: [Part("The", .function)]),
            Line(word: "new", parts: [Part("new", .stressed)]),
            Line(word: "build", parts: [Part("build", .stressed)]),
            Line(word: "is", parts: [Part("is", .function)]),
            Line(word: "ready", parts: [Part("read", .stressed), Part("y", .weak)]),
        ], pause: .clause),
        LineGroup(words: [
            Line(word: "and", parts: [Part("and", .function)]),
            Line(word: "I'll", parts: [Part("I'll", .function)]),
            Line(word: "send", parts: [Part("send", .stressed, fricative: true)]),
            Line(word: "it", parts: [Part("it", .function)]),
            Line(word: "over", parts: [Part("o", .stressed), Part("ver", .weak)]),
            Line(word: "this", parts: [Part("this", .function, fricative: true)]),
            Line(word: "afternoon", parts: [
                Part("af", .stressed),
                Part("ter", .weak),
                Part("noon", .stressed),
            ]),
        ], pause: .sentence),
        LineGroup(words: [
            Line(word: "Let", parts: [Part("Let", .stressed)]),
            Line(word: "me", parts: [Part("me", .function)]),
            Line(word: "know", parts: [Part("know", .stressed)]),
            Line(word: "if", parts: [Part("if", .function)]),
            Line(word: "anything", parts: [
                Part("an", .stressed),
                Part("y", .weak),
                Part("thing", .weak),
            ]),
            Line(word: "looks", parts: [Part("looks", .stressed, fricative: true)]),
            Line(word: "off", parts: [Part("off", .stressed, fricative: true)]),
        ], pause: nil),
    ]

    /// Places the written script in time, drawing every length and peak once.
    private static func build() -> (syllables: [Syllable], pauses: [Pause]) {
        var syllables: [Syllable] = []
        var pauses: [Pause] = []
        var time = leadIn
        var seed = 0.0
        var wordIndex = 0
        for (phraseIndex, group) in written.enumerated() {
            let count = group.words.reduce(0) { $0 + $1.parts.count }
            var ordinal = 0
            for (lineIndex, line) in group.words.enumerated() {
                // The lengths are drawn before anything is placed, because the
                // overlap of two syllables of a word is a share of the shorter one
                // and the shorter one is the syllable after it as often as not.
                var lengths: [Double] = []
                for part in line.parts {
                    lengths.append(draw(part.stress.durationRange, seed: seed, salt: 14))
                    seed += 1
                }
                for (partIndex, part) in line.parts.enumerated() {
                    let position = count > 1 ? Double(ordinal) / Double(count - 1) : 0
                    let drawn = draw(part.stress.peakRange, seed: seed, salt: 21)
                    seed += 1
                    syllables.append(Syllable(
                        word: line.word,
                        wordIndex: wordIndex,
                        text: part.text,
                        stress: part.stress,
                        fricative: part.fricative,
                        start: time,
                        duration: lengths[partIndex],
                        drawnPeak: drawn,
                        peak: peak(drawn, of: part, position: position),
                        position: position,
                        phrase: phraseIndex
                    ))
                    time += lengths[partIndex]
                    ordinal += 1
                    guard partIndex < line.parts.count - 1 else { continue }
                    // The two syllables of a word overlap: the breath between them
                    // is laid down first and then taken back by the coarticulation,
                    // which is how a word of two syllables comes out as one gesture
                    // rather than as two beats.
                    let shorter = min(lengths[partIndex], lengths[partIndex + 1])
                    time += draw(intraWordGap, seed: seed, salt: 31) - coarticulation * shorter
                    seed += 1
                }
                wordIndex += 1
                guard lineIndex < group.words.count - 1 else { continue }
                time += draw(wordGap, seed: seed, salt: 44)
                seed += 1
            }
            guard let pause = group.pause else { continue }
            let length = draw(pause == .clause ? clausePause : sentencePause, seed: seed, salt: 57)
            seed += 1
            pauses.append(Pause(kind: pause, start: time, duration: length))
            time += length
        }
        return (syllables, pauses)
    }

    /// The peak a syllable ends up with, after its stress, its phrase and its
    /// noise have had their say.
    ///
    /// - Parameters:
    ///   - drawn: the peak the stress band drew.
    ///   - part: the syllable being placed.
    ///   - position: where it sits in its phrase, from `0` to `1`.
    /// - Returns: the level at the crest of its attack.
    private static func peak(_ drawn: Double, of part: Part, position: Double) -> Double {
        var value = drawn * (1 - declination * position)
        if part.fricative {
            // A fricative is noise pushed through a narrow gap, not a vowel
            // across an open throat, and it measures about half the level of the
            // vowel beside it at the same effort.
            value *= fricativeScale
        }
        // The script needs one peak to draw: `send` is it, and every other
        // syllable is held under it, so the loudest moment of the demonstration is
        // a design value and not the luck of a draw.
        guard part.text == "send" else { return min(value, loudest - 0.01) }
        return loudest
    }

    /// A value inside a range, drawn from the script's field.
    ///
    /// The draws sit around the middle of each range and never at its edges. The
    /// ranges are the outside of the habit and not its average: a script that
    /// walked the extremes of every band would spend most of its length on a
    /// syllable nobody says that length, and the demonstration would read as a
    /// list of oddities rather than as a sentence.
    ///
    /// - Parameters:
    ///   - range: the band the value may fall in.
    ///   - seed: a counter that keeps every draw in the script independent.
    ///   - salt: which field the draw comes from, so two lengths drawn one after
    ///     the other are not the same number.
    private static func draw(_ range: ClosedRange<Double>, seed: Double, salt: Double) -> Double {
        let field = SpeechShape.field(seed * 1.618_033_988_75 + 3.1, salt)
        let position = min(max(0.5 + (field - 0.5) * 0.70, 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * position
    }
}
