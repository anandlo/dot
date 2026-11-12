import Foundation

/// The window one voice's spectrum is drawn on, per band.
///
/// The recorder maps each band's RMS to `0...1` on a fixed scale, one unit per
/// sixty decibels, with a floor at `-60 dBFS`. That scale is a measurement, and
/// it is the same measurement for every speaker: ordinary speech puts a band
/// around `0.33` and a raised voice around `0.55`, so a fixed scale spends the
/// top half of every dot's range on a loudness the speaker never reaches. The
/// grid then has no level to show above a threshold and reads as dots switching
/// on rather than as a voice.
///
/// This type tracks what the speaker's own bands actually do and maps them onto
/// the whole `0...1` range, per band, per take. ``floors`` follows the quietest
/// moment of each band and ``peaks`` the loudest, and the frame is written
/// between the two. The tracked window is guarded, rises and falls slowly, and
/// is fed through the same perceptual curve as the level meter, so a quiet voice
/// and a loud one both sweep the range a person can see.
///
/// The type is a value with ten stored doubles: taking a step allocates
/// nothing, which is what lets the card call it sixty times a second.
public struct SpectrumScale: Sendable {
    /// The bottom of each band's window before the take has said anything, in
    /// the recorder's band domain. `0.25` is `-45 dBFS`: under conversational
    /// speech at a desk and over the room tone of a quiet room.
    public static let floorSeeds: (Double, Double, Double, Double, Double) =
        (0.25, 0.25, 0.25, 0.25, 0.25)

    /// The top of each band's window before the take has said anything. `0.55`
    /// is `-27 dBFS`: above ordinary speech, so a band that opens a take loudly
    /// is not drawn at the top before it has been heard, and near enough to it
    /// that the window finds the voice within a word rather than within a take.
    public static let peakSeeds: (Double, Double, Double, Double, Double) =
        (0.55, 0.55, 0.55, 0.55, 0.55)

    /// The window a band is drawn on, in the recorder's band domain.
    ///
    /// `0.18` is ten point eight decibels, which is the spread ordinary speech
    /// covers in one band, so the quietest and the loudest moment of a voice fill
    /// the grid instead of the lower half of it. It is both bounds of the window:
    /// the guard raises the top when it would be narrower, and the floor is held
    /// no more than this under the top (`normalised`), which is what stops a
    /// syllable's tail — a frame that clears the recorder's gate but carries
    /// almost no band energy — from dragging the bottom of the window down and
    /// spreading a real voice over two thirds of the grid. A real microphone
    /// produces those frames on every syllable, so the window measured a
    /// twenty-nine decibel span on real speech while the voice itself covered
    /// eight; the dots then all sat in the same high slice of the ramp and read
    /// as one dull tone.
    public static let minimumSpan: Double = 0.18

    /// How fast the bottom of a window climbs while the band stays above it,
    /// in band units per second. `0.08` is four point eight decibels per
    /// second: fast enough to reach the bottom of a voice that starts speaking
    /// loudly within a few seconds, slow enough that the gaps inside a word do
    /// not lift the floor above the word.
    public static let floorRise: Double = 0.08

    /// How fast the top of a window falls, in band units per second. `0.15` is
    /// nine decibels per second: a syllable that is louder than the voice so far
    /// raises the top of the window at once, and the top comes down again fast
    /// enough that a loud word lets go of the take in a fraction of a second
    /// instead of pinning it for four. Three decibels a second held the window
    /// open above the next, quieter syllables for seconds, which flattened them.
    public static let peakFall: Double = 0.15

    /// The bottom of each band's window, in the recorder's `0...1` band domain.
    public private(set) var floors: (Double, Double, Double, Double, Double) = SpectrumScale.floorSeeds

    /// The top of each band's window, in the recorder's `0...1` band domain.
    public private(set) var peaks: (Double, Double, Double, Double, Double) = SpectrumScale.peakSeeds

    /// A scale at its seeds, as a take starts.
    public init() {}

    /// Puts every band back to its seeds.
    ///
    /// The card calls this when a recording starts, next to the reset of the
    /// spectrum history: a window that carried over from the last take would
    /// draw the first syllable of this one on the last voice's range.
    public mutating func reset() {
        floors = Self.floorSeeds
        peaks = Self.peakSeeds
    }

    /// Writes one measured frame onto this voice's range.
    ///
    /// - Parameters:
    ///   - frame: the five bands of the last block of audio, in the recorder's
    ///     `0...1` band domain.
    ///   - dt: the time since the last frame, in seconds. The caller passes the
    ///     time that really elapsed, so the rise and the fall are the same on a
    ///     machine that drops frames.
    /// - Returns: the five bands mapped onto `0...1`, through the meter's own
    ///   perceptual curve. A frame the recorder gated as silence returns
    ///   ``AudioSpectrumFrame/zero`` and leaves the window where it was.
    public mutating func normalise(_ frame: AudioSpectrumFrame, dt: Double) -> AudioSpectrumFrame {
        let bands = frame.bands
        guard bands.0 != 0 || bands.1 != 0 || bands.2 != 0 || bands.3 != 0 || bands.4 != 0 else {
            return .zero
        }
        let rise = Self.floorRise * dt
        let fall = Self.peakFall * dt
        let out0 = Self.normalised(bands.0, floors: &floors.0, peaks: &peaks.0, rise: rise, fall: fall)
        let out1 = Self.normalised(bands.1, floors: &floors.1, peaks: &peaks.1, rise: rise, fall: fall)
        let out2 = Self.normalised(bands.2, floors: &floors.2, peaks: &peaks.2, rise: rise, fall: fall)
        let out3 = Self.normalised(bands.3, floors: &floors.3, peaks: &peaks.3, rise: rise, fall: fall)
        let out4 = Self.normalised(bands.4, floors: &floors.4, peaks: &peaks.4, rise: rise, fall: fall)
        return AudioSpectrumFrame(bands: (out0, out1, out2, out3, out4))
    }

    /// One band of one frame: the window step, then the position inside it.
    ///
    /// - Parameters:
    ///   - level: this band of this frame, in the recorder's band domain.
    ///   - floor: the bottom of this band's window, updated in place.
    ///   - peak: the top of this band's window, updated in place.
    ///   - rise: how far the floor may climb this frame, in band units.
    ///   - fall: how far the peak may drop this frame, in band units.
    /// - Returns: this band on `0...1`, through ``LevelScale/perceptual(_:)``.
    private static func normalised(
        _ level: Double,
        floors floor: inout Double,
        peaks peak: inout Double,
        rise: Double,
        fall: Double
    ) -> Double {
        if level < floor {
            floor = level
        } else {
            floor += rise
        }
        if level > peak {
            peak = level
        } else {
            peak -= fall
        }
        // The bottom never sits further under the top than the window is wide.
        // A frame that clears the recorder's gate can still carry only the tail
        // of a syllable, and letting that tail set the floor stretched the
        // window to three times the span a voice covers, which drew every dot
        // in the same high slice of the ramp.
        if floor < peak - minimumSpan {
            floor = peak - minimumSpan
        }
        if peak < floor + minimumSpan {
            peak = floor + minimumSpan
        }
        let span = peak - floor
        let position = span > 0 ? min(max((level - floor) / span, 0), 1) : 0
        return LevelScale.perceptual(position)
    }
}
