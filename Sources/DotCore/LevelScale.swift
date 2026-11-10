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

    /// The level, from `0` to `1`, of a microphone level in dBFS.
    ///
    /// - Parameters:
    ///   - decibels: the RMS of the last block of audio, in dBFS. Silence and
    ///     a missing buffer are `-.infinity`.
    ///   - floor: the tracked room floor, in dBFS; `silenceDBFS` before one has
    ///     been measured. It lifts the bottom of the scale so a noisy room is
    ///     not drawn as continuous speech.
    /// - Returns: the level, from `0` to `1`.
    public static func level(decibels: Double, floor: Double = silenceDBFS) -> Double {
        guard decibels.isFinite else { return 0 }
        let bottom = gate(floor: floor)
        let span = ceilingDBFS - bottom
        guard span > 0 else { return 0 }
        return min(max((decibels - bottom) / span, 0), 1)
    }

    /// The bottom of the scale for a tracked room floor.
    ///
    /// - Parameter floor: the tracked room floor, in dBFS.
    /// - Returns: the level that reads as zero, in dBFS.
    public static func gate(floor: Double) -> Double {
        guard floor.isFinite else { return floorDBFS }
        return min(max(floor + gateOffsetDB, floorDBFS), gateCeilingDBFS)
    }
}

/// The attack and release of the envelope.
///
/// A fast attack matters more than anything else here: a syllable that arrives
/// and is drawn late reads as "not hearing me". The release is deliberately
/// long enough to see: a voice that stops leaves a shape that falls over about
/// a third of a second instead of a flicker.
public enum EnvelopeShape {
    /// How fast the envelope follows a rise, in seconds.
    public static let attackTau: TimeInterval = 0.012
    /// How fast the envelope falls, in seconds.
    public static let releaseTau: TimeInterval = 0.14

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
}
