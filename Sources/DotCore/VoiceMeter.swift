import Foundation

/// The live signal of the microphone.
///
/// The meter is not an animation: it is the real level of the microphone, put
/// on the fixed dBFS scale of ``LevelScale`` and through a fast-attack /
/// slow-release envelope so the movement is calm but never late. The tracked
/// room floor only decides where the bottom of the scale sits; it never
/// normalises the shape against the loudest moment of the recording.
///
/// The history is written at a fixed rate of 60 samples a second, no matter
/// how fast the display refreshes. That is what makes the scrolling
/// waveform move at a constant speed: on a 120 Hz display the history still
/// advances at 60 samples a second, so the waveform scrolls at the same rate
/// everywhere.
@MainActor
public final class VoiceMeter {
    /// How many samples of history the waveform keeps, at the sample rate.
    ///
    /// 180 samples at 60 Hz is three seconds of audio.
    public static let historyLength = Waveform.historyLength
    /// How many samples a second the history is written at.
    public static let sampleRate = Waveform.sampleRate

    /// How long the peak is held before it starts to fall, in seconds.
    public static let peakHoldSeconds: TimeInterval = 0.8
    /// How fast the peak falls once it is released, in seconds.
    public static let peakDecayTau: TimeInterval = 0.9
    /// How fast the room floor rises, in decibels per second.
    ///
    /// The floor follows a quieter room at once and a louder one this fast, so
    /// a fan that starts halfway through a recording is absorbed in a few
    /// seconds instead of being drawn as speech. It is slow enough that a vowel
    /// held for a second cannot carry the bottom of the scale with it, and the
    /// next gap between words puts the floor back where the room is.
    public static let floorRiseRate: Double = 3
    /// How steady a frame has to be to move the floor, in decibels.
    ///
    /// Speech is not steady: a syllable opens thirty milliseconds after the one
    /// before it closed, so consecutive blocks of a voice differ by several
    /// decibels. A fan, a fridge or an air conditioner differ by a fraction of
    /// one. A floor that rises only on a steady frame therefore rises in a noisy
    /// room and stays where it is in a person's mouth.
    public static let floorSteadinessDB: Double = 1.5
    /// How long a level has to hold still before it is treated as the room.
    ///
    /// The recorder hands the card the same block six times in a row at 60 Hz,
    /// so a voice repeats itself for a block at a time and a single steady
    /// frame says nothing. A room holds still for this long; a syllable does
    /// not, and neither does a sentence.
    public static let floorSettledSeconds: TimeInterval = 0.6
    /// The longest a frame may be from being the floor, in dBFS.
    ///
    /// The ceiling is where ``LevelScale`` stops lifting the bottom of the
    /// scale. Above it the scale would be so narrow that every level would read
    /// the same, so a very noisy room is drawn as a quiet room with a voice in
    /// it rather than as a room with no room in it.
    public static let floorCeilingDBFS: Double = LevelScale.gateCeilingDBFS - LevelScale.gateOffsetDB - 10

    /// The level of the voice, from `0` to `1`.
    public private(set) var level: Double = 0
    /// The envelope of the voice, from `0` to `1`.
    public private(set) var envelope: Double = 0
    /// The envelope the shape is drawn from, from `0` to `1`.
    ///
    /// It follows the voice faster than ``envelope`` does, so the syllables of a
    /// word survive being drawn as a recording of the last half second. See
    /// ``EnvelopeShape/shapeReleaseTau`` for why there are two.
    public private(set) var shape: Double = 0
    /// The highest level that was reached, from `0` to `1`.
    ///
    /// It is held for ``peakHoldSeconds`` and then released at
    /// ``peakDecayTau``, so a shape that is loud for a word leaves a ceiling
    /// that falls on its own instead of a ceiling that stays where the loudest
    /// syllable of the take put it. The visualiser uses it to decide when a bar
    /// is a peak of *this* voice rather than a peak of any voice, which is the
    /// difference between a bright amber tip on the loudest syllable and a shape
    /// that is bright all the time.
    public private(set) var peak: Double = 0
    /// The peak the visualiser draws against, from `0` to `1`.
    ///
    /// A ceiling that fell to zero would make every bar a peak, so it never
    /// drops below ``minimumCeiling``. It follows the voice rather than
    /// normalising it: heights stay absolute, and only the colour knows what
    /// the loudest moment of this take was.
    public var ceiling: Double { max(peak, Self.minimumCeiling) }

    /// The lowest the adaptive ceiling may fall, from `0` to `1`.
    public static let minimumCeiling: Double = 0.45
    /// Where inside the current sample the history is, from `0` to `1`.
    ///
    /// The waveform reads the history at this phase, so it moves smoothly
    /// instead of one sample at a time.
    public private(set) var phase: Double = 0
    /// How many sample periods have passed since the meter started.
    ///
    /// The phase of the breath of the waveform: it never stops, so the shape
    /// is alive even in silence.
    public private(set) var scrollPhase: Double = 0
    /// What Dot learned about the microphone that is recording.
    ///
    /// It moves the bottom of the scale to the room the device sits in, so a
    /// quiet headset's room reads as a floor instead of as continuous speech. It
    /// never moves the top: heights have to mean the same thing on every device,
    /// or a take recorded on a headset is drawn taller than the same words
    /// recorded on a USB microphone. A device with no history keeps the fixed
    /// scale, lifted by the room the meter tracks.
    public private(set) var calibration: MicrophoneCalibration?

    /// The room floor the meter has tracked, in dBFS.
    ///
    /// `nil` until a frame that carries audio has been seen; the meter never
    /// seeds it from the silence that arrives before the first buffer.
    public private(set) var floorDBFS: Double?

    /// The history of the envelope, oldest first.
    private var history: [Double]
    /// Where the next sample goes in the history.
    private var historyIndex = 0
    /// The time since the last sample of the history, in sample periods.
    private var clock: Double = 0
    /// When the peak stops being held.
    private var peakHoldUntil: TimeInterval = 0
    /// The decibels of the frame before this one, so the floor can tell a room
    /// from a voice by how steady it is.
    private var previousDBFS: Double?
    /// How long the level has held still, in seconds.
    private var steadySeconds: TimeInterval = 0
    /// The moment the last update happened.
    private var lastUpdate: TimeInterval?

    /// Creates a meter.
    public init() {
        history = Array(repeating: 0, count: Self.historyLength)
    }

    /// The level of the voice, from `0` to `1`.
    public var currentLevel: Double { level }

    /// Puts a new microphone level into the meter.
    ///
    /// - Parameters:
    ///   - decibels: the RMS of the last block of audio, in dBFS. A missing
    ///     buffer or digital silence is `-.infinity`.
    ///   - now: the current time, in seconds.
    public func push(decibels: Double, now: TimeInterval) {
        let dt: Double
        if let lastUpdate {
            dt = max(0, min(now - lastUpdate, 0.25))
        } else {
            dt = 1.0 / Self.sampleRate
        }
        lastUpdate = now

        trackFloor(decibels: decibels, dt: dt)
        // One window, one place. The bottom is the higher of the room the meter
        // has tracked and the room Dot learned about this device, so a learned
        // floor from a quiet morning cannot be blown by a noisy afternoon, and
        // the top is always the physical ceiling. The old path drew a second,
        // unsmoothed level from the calibration window and took the larger of
        // the two, which is how a single loud frame reached the shape before the
        // attack had moved at all.
        level = LevelScale.level(decibels: decibels, window: window)
        envelope = EnvelopeShape.step(envelope: envelope, level: level, dt: dt)
        shape = EnvelopeShape.shapeStep(envelope: shape, level: level, dt: dt)

        if shape >= peak {
            peak = shape
            peakHoldUntil = now + Self.peakHoldSeconds
        } else if now > peakHoldUntil {
            let decay = 1 - exp(-dt / Self.peakDecayTau)
            peak += (shape - peak) * decay
        }

        advanceHistory(by: dt)
    }

    /// The window the meter draws on for the device that is recording.
    ///
    /// The bottom is the higher of the two room estimates the meter has: the one
    /// it tracked from this take and the one Dot learned from every earlier take
    /// on the device. The top is the physical ceiling. When nothing has been
    /// heard yet the shipped window is used, so the first syllable of the first
    /// take is drawn exactly as the first syllable of every later take is.
    private var window: LevelWindow {
        let learned = LevelScale.window(for: calibration).bottomDBFS
        let tracked = LevelScale.gate(floor: floorDBFS ?? LevelScale.floorDBFS)
        return LevelWindow(
            bottomDBFS: max(learned, tracked),
            topDBFS: LevelScale.ceilingDBFS
        )
    }

    /// Tracks the room floor.
    ///
    /// The floor starts at the shipped one rather than at the first frame that
    /// carries audio, and it only rises on a frame that is steady. That is what
    /// makes the two failure modes of an adaptive floor impossible:
    ///
    /// - A take that begins with the first word used to seed the floor at the
    ///   level of that word, which collapsed the scale to a few decibels and
    ///   drew the rest of the take as a hairline. A voice is never steady, so it
    ///   never seeds the floor and the take is drawn on the scale it deserves.
    /// - A take that is loud for a long time used to drag the floor up with it.
    ///   A voice is not steady between frames either, so a sentence cannot move
    ///   the floor that a fan can.
    ///
    /// Only a frame that carries audio may move the floor at all, which is the
    /// invariant the first version of this meter broke: the frames that arrive
    /// before `AVAudioEngine` has produced a buffer read as digital silence, and
    /// seeding the floor from one of them put the bottom of the scale 70 dB
    /// below the room and pinned the whole recording at full height.
    private func trackFloor(decibels: Double, dt: Double) {
        guard decibels.isFinite, decibels > LevelScale.silenceDBFS else { return }
        // The floor starts at the shipped one, which is a bound rather than a
        // guess: it can only rise from here.
        if floorDBFS == nil { floorDBFS = LevelScale.floorDBFS }
        guard let current = floorDBFS else { return }
        guard let previous = previousDBFS else {
            previousDBFS = decibels
            return
        }
        previousDBFS = decibels

        // A frame that differs from the one before it is a voice, a door or a
        // keystroke, and none of those are the room. The recorder hands the
        // card the same block six times in a row at 60 Hz, so a voice also
        // repeats itself for a block at a time; the room has to hold still for
        // `floorSettledSeconds` before it is believed.
        if abs(decibels - previous) > Self.floorSteadinessDB {
            steadySeconds = 0
        } else {
            steadySeconds += dt
        }

        let next: Double
        if decibels < current {
            // A room that gets quieter is followed at once.
            next = decibels
            steadySeconds = max(steadySeconds, Self.floorSettledSeconds)
        } else if steadySeconds >= Self.floorSettledSeconds {
            next = min(decibels, current + Self.floorRiseRate * dt)
        } else {
            next = current
        }
        floorDBFS = min(max(next, LevelScale.silenceDBFS), Self.floorCeilingDBFS)
    }

    /// Writes the history at a fixed rate, whatever the display does.
    private func advanceHistory(by dt: Double) {
        clock += dt * Self.sampleRate
        while clock >= 1 {
            clock -= 1
            history[historyIndex] = shape
            historyIndex = (historyIndex + 1) % Self.historyLength
        }
        scrollPhase = clock
        phase = min(max(clock - clock.rounded(.down), 0), 1)
    }

    /// The history, oldest first.
    public var orderedHistory: [Double] {
        var copy: [Double] = []
        copyOrderedHistory(into: &copy)
        return copy
    }

    /// Copies the history, oldest first, into a buffer the caller owns.
    ///
    /// The card reads the history sixty times a second, and reading it through
    /// ``orderedHistory`` allocated two arrays and a concatenation on every one
    /// of those frames. This writes into a buffer that is kept between frames
    /// instead, so a tick costs a copy and nothing else.
    ///
    /// - Parameter buffer: the buffer to fill. It is resized to
    ///   ``historyLength`` and left in the caller's hands.
    public func copyOrderedHistory(into buffer: inout [Double]) {
        if buffer.count != Self.historyLength {
            buffer = [Double](repeating: 0, count: Self.historyLength)
        }
        guard historyIndex != 0 else {
            buffer = history
            return
        }
        let tail = Self.historyLength - historyIndex
        for index in 0..<tail {
            buffer[index] = history[historyIndex + index]
        }
        for index in 0..<historyIndex {
            buffer[tail + index] = history[index]
        }
    }

    /// Tells the meter which device is recording.
    ///
    /// - Parameter calibration: what Dot learned about the device, or `nil`
    ///   for a device with no history. A missing entry keeps the fixed scale,
    ///   which is what shipped.
    public func setCalibration(_ calibration: MicrophoneCalibration?) {
        self.calibration = calibration?.clamped
    }

    /// Seeds the room floor from what Dot learned about this microphone.
    ///
    /// The meter otherwise starts blind and uses the first frame that carries
    /// audio as its floor. That first frame is a guess made from a fraction of
    /// a second; a calibration is the answer from every previous take, so a
    /// quiet headset reads at its real level from the first syllable instead of
    /// settling over the first sentence.
    ///
    /// - Parameter floor: the learned room floor, in dBFS. A missing or
    ///   non-finite value leaves the meter as it was.
    public func seed(floor: Double?) {
        guard let floor, floor.isFinite else { return }
        floorDBFS = min(max(floor, LevelScale.silenceDBFS), Self.floorCeilingDBFS)
        steadySeconds = 0
        previousDBFS = nil
    }

    /// Puts the meter back to zero.
    public func reset() {
        level = 0
        envelope = 0
        shape = 0
        peak = 0
        phase = 0
        scrollPhase = 0
        clock = 0
        floorDBFS = nil
        calibration = nil
        lastUpdate = nil
        peakHoldUntil = 0
        previousDBFS = nil
        steadySeconds = 0
        history = Array(repeating: 0, count: Self.historyLength)
        historyIndex = 0
    }
}
