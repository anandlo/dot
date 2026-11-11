import Foundation

/// The scale that turns the microphone's level into the height of the waveform.
///
/// The scale is fixed and expressed in dBFS, not in linear RMS and not relative
/// to the loudest moment of the recording. That is the whole point: a fixed
/// window means the shape answers "how loud is the voice right now", which is
/// what the card is for. A normalised scale answers "how loud is this compared
/// with the rest of the recording", which pins every recording at full height
/// after a single loud word.
///
/// The window is `-56 dBFS … +6 dBFS`:
///
/// - A quiet room (`-50 dBFS` and below) sits at the floor and reads as a
///   hairline, so "it can hear me" and "it cannot" look different.
/// - Normal conversational speech at a desk (`-30 … -15 dBFS`) reads `0.42 …
///   0.66`: clearly moving, never at the top.
/// - Loud speech (`-10 dBFS`) reads `0.74`.
/// - Digital full scale (`0 dBFS`, the loudest sample a PCM file can hold)
///   reads `0.90`, so a hot microphone cannot glue the shape to the edge of the
///   card: the top tenth is headroom the microphone cannot reach.
///
/// The reference points are the ones the audio world uses for speech: room tone
/// around `-50 … -40 dBFS`, normal speech `-30 … -15 dBFS`, loud speech
/// `-10 … -20 dBFS` with a crest factor of 12–20 dB above those RMS values.
public enum LevelScale {
    /// The level that reads as zero, in dBFS.
    public static let floorDBFS: Double = -56
    /// The level that reads as one, in dBFS.
    ///
    /// It is above digital full scale on purpose: the loudest representable
    /// input reads `0.90`, and the shape keeps its top for a signal that
    /// cannot exist in a PCM file.
    public static let ceilingDBFS: Double = 6
    /// Anything at or below this carries no audio at all.
    public static let silenceDBFS: Double = -90
    /// How far above the tracked room floor a level has to be to be heard.
    public static let gateOffsetDB: Double = 4
    /// The highest the gate may climb, in dBFS.
    ///
    /// A very noisy room lifts the bottom of the scale, but never so far that
    /// ordinary speech stops moving: above this the scale would be a few
    /// decibels wide and everything would read the same.
    public static let gateCeilingDBFS: Double = -26
    /// The narrowest a window can become, in decibels.
    ///
    /// The bottom is capped at ``gateCeilingDBFS`` and the top is always
    /// ``ceilingDBFS``, so this is the span of the narrowest window a
    /// calibration can ask for. It is stated here so a caller can rely on it.
    public static var minimumSpanDB: Double { ceilingDBFS - gateCeilingDBFS }

    /// The window one microphone is drawn on.
    ///
    /// A calibration moves the **bottom** of the scale and only the bottom. The
    /// top is always ``ceilingDBFS``, the same top every device is drawn
    /// against, because a top that followed the loudest moment Dot had heard on
    /// a device made the window a different height on every machine: a headset
    /// whose loudest word was `-30 dBFS` produced a window 24 decibels tall, so
    /// ordinary speech at `-25 dBFS` was drawn at full height from the first
    /// syllable and stayed there. That is the saturation this fixes. The room a
    /// device sits in is what differs between microphones; how far a voice
    /// carries above that room is the same performance everywhere, and it is
    /// drawn on the same scale everywhere.
    ///
    /// - Parameter calibration: what Dot learned about the device, or `nil`.
    /// - Returns: the fixed window when there is no history, so a device Dot
    ///   has never heard is drawn exactly as it shipped.
    public static func window(for calibration: MicrophoneCalibration?) -> LevelWindow {
        guard let calibration = calibration?.clamped, calibration.isUsable else {
            return fixedWindow
        }
        let bottom = gate(floor: calibration.noiseFloorDBFS)
        guard bottom > fixedWindow.bottomDBFS else { return fixedWindow }
        // The scale is never allowed to narrow to the point where every level
        // would read the same. The bottom is capped and the top is fixed, so
        // this holds by construction; it is checked because the two bounds are
        // constants a later change could move apart.
        guard ceilingDBFS - bottom >= minimumSpanDB else { return fixedWindow }
        return LevelWindow(bottomDBFS: bottom, topDBFS: ceilingDBFS)
    }

    /// The window a device with no history is drawn on.
    ///
    /// It is the window the card shipped with before any calibration existed:
    /// the shipped meter lifts the bottom to where the fixed floor's gate sits.
    /// Keeping it here as a value is what lets a call site swap windows without
    /// changing what a device Dot has never heard looks like.
    public static var fixedWindow: LevelWindow {
        LevelWindow(bottomDBFS: gate(floor: floorDBFS), topDBFS: ceilingDBFS)
    }

    /// The level, from `0` to `1`, of a microphone level on a window.
    ///
    /// - Parameters:
    ///   - decibels: the RMS of the last block of audio, in dBFS. Silence and
    ///     a missing buffer are `-.infinity`.
    ///   - window: the window the device is drawn on.
    /// - Returns: the level, from `0` to `1`.
    public static func level(decibels: Double, window: LevelWindow) -> Double {
        guard decibels.isFinite else { return 0 }
        let span = window.topDBFS - window.bottomDBFS
        guard span > 0 else { return 0 }
        return perceptual(min(max((decibels - window.bottomDBFS) / span, 0), 1))
    }

    /// The level, from `0` to `1`, of a microphone level in dBFS.
    ///
    /// - Parameters:
    ///   - decibels: the RMS of the last block of audio, in dBFS. Silence and
    ///     a missing buffer are `-.infinity`.
    ///   - floor: the tracked room floor, in dBFS; ``floorDBFS`` before one has
    ///     been measured, so a meter with no history draws on exactly the window
    ///     ``fixedWindow`` describes. It lifts the bottom of the scale so a noisy
    ///     room is not drawn as continuous speech.
    /// - Returns: the level, from `0` to `1`.
    public static func level(decibels: Double, floor: Double = floorDBFS) -> Double {
        guard decibels.isFinite else { return 0 }
        let bottom = gate(floor: floor)
        let span = ceilingDBFS - bottom
        guard span > 0 else { return 0 }
        return perceptual(min(max((decibels - bottom) / span, 0), 1))
    }

    /// The bottom of the scale for a tracked room floor.
    ///
    /// - Parameter floor: the tracked room floor, in dBFS.
    /// - Returns: the level that reads as zero, in dBFS.
    public static func gate(floor: Double) -> Double {
        guard floor.isFinite else { return floorDBFS }
        return min(max(floor + gateOffsetDB, floorDBFS), gateCeilingDBFS)
    }

    /// The bend of the perceptual curve.
    ///
    /// A position inside a window is a linear count of decibels, and a linear
    /// count spends three quarters of the shape's height on the last thirty
    /// decibels: a whisper four decibels above the room becomes one column
    /// above a hairline while a shout is a hand's width higher. The knee lifts
    /// the quiet and middle of the range without touching either end:
    ///
    ///     drawn = position + knee · position · (1 − position)
    ///
    /// The correction is zero at a position of `0`, so silence is still exactly
    /// the floor, and zero at `1`, so the loudest signal a window can carry is
    /// still exactly one. Its slope is `1 + knee · (1 − 2 · position)`, positive
    /// for every knee under one, so a louder sound is never drawn shorter: the
    /// curve is strictly monotonic.
    ///
    /// With the shipped window (`-52 … +6 dBFS`, 58 decibels) the curve reads:
    ///
    /// | RMS | Position | Drawn |
    /// | --- | --- | --- |
    /// | `-50 dBFS` | 0.03 | 0.05 |
    /// | `-45 dBFS` (a whisper) | 0.12 | 0.18 |
    /// | `-40 dBFS` | 0.21 | 0.30 |
    /// | `-30 dBFS` (quiet speech) | 0.38 | 0.51 |
    /// | `-25 dBFS` (normal speech) | 0.47 | 0.60 |
    /// | `-15 dBFS` (raised voice) | 0.64 | 0.77 |
    /// | `-8 dBFS` (loud speech) | 0.76 | 0.86 |
    /// | `0 dBFS` (full scale) | 0.90 | 0.95 |
    ///
    /// Every one of those is a different height on the card, which is what "it
    /// reflects the range of my voice" means in numbers.
    public static let knee: Double = 0.55

    /// The perceptual position of a position inside a window.
    ///
    /// - Parameter position: a linear position inside a window, from `0` to
    ///   `1`; values outside are held at the ends.
    /// - Returns: the position the shape is drawn at, from `0` to `1`.
    public static func perceptual(_ position: Double) -> Double {
        let x = min(max(position, 0), 1)
        return x + knee * x * (1 - x)
    }
}

/// The two decibel bounds a microphone's level is drawn between.
///
/// A window is a value rather than a pair of arguments so the fixed window and
/// a calibrated one cannot be mixed up at a call site: a device with no history
/// is drawn on ``LevelScale/fixedWindow``, and a calibrated device on the window
/// its own takes produced.
public struct LevelWindow: Equatable, Sendable {
    /// The level that reads as zero, in dBFS.
    public let bottomDBFS: Double
    /// The level that reads as one, in dBFS.
    public let topDBFS: Double

    /// Creates a window.
    public init(bottomDBFS: Double, topDBFS: Double) {
        self.bottomDBFS = bottomDBFS
        self.topDBFS = topDBFS
    }
}

/// The attack and release of the envelope.
///
/// A fast attack matters more than anything else here: a syllable that arrives
/// and is drawn late reads as "not hearing me". The attack is thirty
/// milliseconds, which is one frame of a 30 Hz meter and under two frames of
/// the 60 Hz clock the card is written at, so a word is at its height on the
/// frame it starts. The release is deliberately longer, two hundred
/// milliseconds, so a voice that stops leaves a shape that falls over about a
/// third of a second instead of a flicker, and so the gap between two syllables
/// of one word is drawn as a dip rather than as silence.
public enum EnvelopeShape {
    /// How fast the envelope follows a rise, in seconds.
    public static let attackTau: TimeInterval = 0.030
    /// How fast the envelope falls, in seconds.
    public static let releaseTau: TimeInterval = 0.200

    /// One step of the envelope.
    ///
    /// - Parameters:
    ///   - envelope: the current envelope, from `0` to `1`.
    ///   - level: the new level, from `0` to `1`.
    ///   - dt: the time since the last step, in seconds.
    /// - Returns: the new envelope, from `0` to `1`.
    public static func step(envelope: Double, level: Double, dt: Double) -> Double {
        guard dt > 0 else { return envelope }
        let tau = level > envelope ? attackTau : releaseTau
        let coefficient = 1 - exp(-dt / tau)
        return envelope + (level - envelope) * coefficient
    }

    /// How long a full-scale envelope takes to fall under `threshold`.
    ///
    /// - Parameter threshold: the level the fall is measured to.
    /// - Returns: the time, in seconds.
    public static func releaseTime(to threshold: Double) -> TimeInterval {
        guard threshold > 0, threshold < 1 else { return 0 }
        return -releaseTau * log(threshold)
    }

    /// How fast the drawn shape follows a rise, in seconds.
    ///
    /// There are two envelopes because the card draws two different things with
    /// them. The dot and the glow answer the question "is it hearing me" and
    /// settle over a fifth of a second, which is calm enough to read. The shape
    /// is a recording of the last half second, and a fifth of a second of
    /// release smears four syllables of a word into one plateau: at 60 Hz the
    /// envelope only falls eight percent between two syllables, so a sentence
    /// draws as a ruler. Seventy-five milliseconds is long enough to keep the
    /// shape smooth and short enough that every syllable survives it.
    public static let shapeAttackTau: TimeInterval = 0.020
    /// How fast the drawn shape falls, in seconds. See ``shapeAttackTau``.
    public static let shapeReleaseTau: TimeInterval = 0.075

    /// One step of the drawn shape's envelope.
    ///
    /// - Parameters:
    ///   - envelope: the current shape, from `0` to `1`.
    ///   - level: the new level, from `0` to `1`.
    ///   - dt: the time since the last step, in seconds.
    /// - Returns: the new shape, from `0` to `1`.
    public static func shapeStep(envelope: Double, level: Double, dt: Double) -> Double {
        guard dt > 0 else { return envelope }
        let tau = level > envelope ? shapeAttackTau : shapeReleaseTau
        let coefficient = 1 - exp(-dt / tau)
        return envelope + (level - envelope) * coefficient
    }
}
