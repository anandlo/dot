import Foundation

/// The shape of a voice, for anything that draws one.
///
/// A sine draws a wave, not a voice. Every crest is the same crest, the pattern
/// comes back on a period, and the eye reads that as a machine, which is what
/// made the welcome's waveform look cheap. Speech is irregular in two
/// directions at once: neighbouring moments differ, and the shape across the
/// bars differs too.
///
/// This is value noise in both, which is deterministic, cheap, has no period,
/// and needs no table: two octaves of it give the ragged edge of a waveform,
/// and a slower third band gives the swell of a sentence.
public enum SpeechShape {
    /// The amplitude of a voice, from `0` to `1`.
    ///
    /// - Parameters:
    ///   - position: where on the waveform, from `0` to `1` across its width.
    ///   - time: the moment, in seconds.
    /// - Returns: the height of that point at that moment.
    public static func value(at position: Double, time: Double) -> Double {
        let fine = noise(position * 20, time * 2.7)
        let coarse = noise(position * 2.1, time * 0.9)
        // The loudness of the sentence itself: a syllable is a swell, not a
        // beat, so this one moves on its own much slower clock.
        let swell = 0.20 + 0.80 * noise(time * 0.37, 8.3)
        // Both factors are already inside 0...1. The curve lifts the middle of
        // the range, because two noises multiplied together spend most of their
        // time low and the waveform would read as a thin line; the last clip is
        // rare enough not to flatten neighbours into a plateau.
        let shaped = (0.20 + 0.80 * swell) * (0.75 * fine + 0.25 * coarse)
        return min(pow(max(shaped, 0), 0.65) * 1.12, 1)
    }

    /// The loudness of the voice at a moment, from `0` to `1`.
    ///
    /// - Parameter time: the moment, in seconds.
    /// - Returns: how loud the voice is, independent of where the bars are.
    public static func loudness(at time: Double) -> Double {
        let swell = noise(time * 0.37, 8.3)
        let breath = noise(time * 1.9, 3.1)
        return min(max(0.22 + 0.78 * swell * (0.55 + 0.45 * breath), 0), 1)
    }

    // MARK: - Value noise

    /// The same smooth random field the waveforms are built from.
    ///
    /// Exposed so a drawing can compose its own speech from the one noise
    /// implementation: two of them would drift, and a waveform that does not
    /// match the others in the app is a mistake nobody would think to look for.
    public static func field(_ x: Double, _ y: Double) -> Double {
        noise(x, y)
    }

    /// A smooth random field, in two dimensions.
    ///
    /// The lattice values come from a hash, so the field is the same on every
    /// run and needs no storage. Smoothstep between the corners keeps it free of
    /// the straight edges a plain random pick would show.
    private static func noise(_ x: Double, _ y: Double) -> Double {
        let x0 = x.rounded(.down)
        let y0 = y.rounded(.down)
        let fx = x - x0
        let fy = y - y0
        let u = fx * fx * (3 - 2 * fx)
        let v = fy * fy * (3 - 2 * fy)
        let a = hash(Int(x0), Int(y0))
        let b = hash(Int(x0) + 1, Int(y0))
        let c = hash(Int(x0), Int(y0) + 1)
        let d = hash(Int(x0) + 1, Int(y0) + 1)
        let top = a + (b - a) * u
        let bottom = c + (d - c) * u
        return top + (bottom - top) * v
    }

    /// A lattice value, from a hash of the two coordinates.
    ///
    /// The value is taken from the **high** bits. An earlier version divided the
    /// low bits by 100 000, and the low bits of a linear congruential generator
    /// are correlated: neighbouring cells came out in a smooth ramp, so the
    /// waveform drew as a dome with a comb's worth of variation and looked
    /// generated all over again.
    private static func hash(_ x: Int, _ y: Int) -> Double {
        var value = UInt64(bitPattern: Int64(x &* 73_856_093 ^ y &* 19_349_663))
        value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        value ^= value >> 33
        value = value &* 0xff51_afd7_ed55_8ccd
        value ^= value >> 33
        return Double(value >> 11) / Double(UInt64(1) << 53)
    }
}
