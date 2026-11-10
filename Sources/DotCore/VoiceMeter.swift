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
    /// seconds instead of being drawn as speech.
    public static let floorRiseRate: Double = 1.5
    /// The loudest the tracked floor may be, in dBFS.
    ///
    /// It is the point where ``LevelScale`` stops lifting the bottom of the
    /// scale: past it the scale would be a few decibels wide and every level
    /// would read the same.
    public static let floorCeilingDBFS: Double = LevelScale.gateCeilingDBFS - LevelScale.gateOffsetDB

    /// The level of the voice, from `0` to `1`.
    public private(set) var level: Double = 0
    /// The envelope of the voice, from `0` to `1`.
    public private(set) var envelope: Double = 0
    /// The highest level that was reached, from `0` to `1`.
    public private(set) var peak: Double = 0
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
        level = LevelScale.level(decibels: decibels, floor: floorDBFS ?? LevelScale.silenceDBFS)
        envelope = EnvelopeShape.step(envelope: envelope, level: level, dt: dt)

        if envelope >= peak {
            peak = envelope
            peakHoldUntil = now + Self.peakHoldSeconds
        } else if now > peakHoldUntil {
            let decay = 1 - exp(-dt / Self.peakDecayTau)
            peak += (envelope - peak) * decay
        }

        advanceHistory(by: dt)
    }

    /// Tracks the room floor.
    ///
    /// Only a frame that carries audio may seed or move the floor. The first
    /// frames of a recording arrive before `AVAudioEngine` has produced a
    /// buffer, so they read as digital silence; seeding the floor from one of
    /// them put the bottom of the scale 70 dB below the room and pinned the
    /// whole recording at full scale.
    private func trackFloor(decibels: Double, dt: Double) {
        guard decibels.isFinite, decibels > LevelScale.silenceDBFS else { return }
        guard let current = floorDBFS else {
            floorDBFS = min(max(decibels, LevelScale.silenceDBFS), Self.floorCeilingDBFS)
            return
        }
        // A room that gets quieter is followed at once; a room that gets
        // louder is followed at `floorRiseRate`, so a chair creak or a cough
        // does not raise the bottom of the scale for the rest of the take.
        let next = decibels < current
            ? decibels
            : min(decibels, current + Self.floorRiseRate * dt)
        floorDBFS = min(max(next, LevelScale.silenceDBFS), Self.floorCeilingDBFS)
    }

    /// Writes the history at a fixed rate, whatever the display does.
    private func advanceHistory(by dt: Double) {
        clock += dt * Self.sampleRate
        while clock >= 1 {
            clock -= 1
            history[historyIndex] = envelope
            historyIndex = (historyIndex + 1) % Self.historyLength
        }
        scrollPhase = clock
        phase = min(max(clock - clock.rounded(.down), 0), 1)
    }

    /// The history, oldest first.
    public var orderedHistory: [Double] {
        guard historyIndex != 0 else { return history }
        return Array(history[historyIndex...]) + Array(history[..<historyIndex])
    }

    /// Puts the meter back to zero.
    public func reset() {
        level = 0
        envelope = 0
        peak = 0
        phase = 0
        scrollPhase = 0
        clock = 0
        floorDBFS = nil
        lastUpdate = nil
        peakHoldUntil = 0
        history = Array(repeating: 0, count: Self.historyLength)
        historyIndex = 0
    }
}
