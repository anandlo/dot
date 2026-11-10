import CoreGraphics
import Foundation

/// The scrolling waveform of the HUD.
///
/// The waveform is the hero of the recording card. It is drawn as a symmetric
/// filled shape around the card's centre line, so every piece of this file
/// exists to make one promise: **the shape is smooth and symmetric**. No
/// spikes, no diamonds, no seams.
///
/// The model is deliberately simple. The meter keeps three seconds of the
/// envelope in a ring buffer, written at a fixed rate; the phase says where
/// inside the current sample the display is; and a column of the shape is
/// the linear interpolation of the buffer at the position that column shows.
public enum Waveform {
    /// How many samples of history the waveform keeps.
    public static let historyLength = 180
    /// How many samples a second the history is written at.
    ///
    /// 180 samples at 60 Hz is three seconds of audio.
    public static let sampleRate: Double = 60.0
    /// How many columns the shape is drawn with.
    public static let columnCount = 96
    /// The smallest half height a column may have, in points.
    ///
    /// A flat line is silence; the card shows it as a hairline that still
    /// breathes, never as nothing at all.
    public static let minimumHalfHeight: CGFloat = 1.5
    /// How much the shape breathes at silence, in points.
    public static let breathAmplitude: CGFloat = 1.6
    /// How much the breath moves from one column to the next, in radians.
    ///
    /// The breath travels along the shape instead of pumping it as one.
    public static let breathPhaseStep: Double = 0.16

    /// The amplitude of a sample.
    ///
    /// The envelope is already the honest, perceptually scaled level of the
    /// voice (``LevelScale`` maps dBFS onto it), so the shape draws it as it
    /// is: a sample of `1` is a full column, and a sample of `0.5` is half a
    /// column. There is deliberately no exaggeration here. A curve that
    /// multiplied the level by 1.6 and clamped it turned every level above
    /// `0.62` into a full column, which is what made normal speech look stuck
    /// at the top of the card.
    ///
    /// - Parameter sample: the envelope value, from `0` to `1`.
    /// - Returns: the amplitude of the column, from `0` to `1`.
    public static func amplitude(for sample: Double) -> Double {
        min(max(sample, 0), 1)
    }

    /// The columns of the waveform, from the left of the shape to the right.
    ///
    /// - Parameters:
    ///   - history: the envelope history, oldest first.
    ///   - phase: where inside the current sample the display is, from `0` to
    ///     `1`.
    ///   - count: how many columns the shape has.
    /// - Returns: the shaped amplitude of every column, from `0` to `1`.
    public static func columns(history: [Double], phase: Double, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard !history.isEmpty else { return Array(repeating: 0, count: count) }
        let last = history.count - 1
        let wrap = phase - phase.rounded(.down)
        var columns: [Double] = []
        columns.reserveCapacity(count)
        for index in 0..<count {
            let position = Double(index) / Double(max(count - 1, 1))
            // The newest sample sits at the right edge; the history moves to
            // the left at a constant rate, one sample per sample period.
            let read = position * Double(last) + wrap - 1
            columns.append(amplitude(for: sample(in: history, at: read)))
        }
        return columns
    }

    /// The half height of every column of the shape, in points.
    ///
    /// The shape breathes: even in silence the columns move, so the card
    /// never shows a dead straight line.
    ///
    /// - Parameters:
    ///   - history: the envelope history, oldest first.
    ///   - phase: where inside the current sample the display is.
    ///   - count: how many columns the shape has.
    ///   - maximum: the half height of the tallest column, in points.
    ///   - breath: the phase of the breath, in turns.
    /// - Returns: the half height of every column, in points.
    public static func halfHeights(
        history: [Double],
        phase: Double,
        count: Int,
        maximum: CGFloat,
        breath: Double
    ) -> [CGFloat] {
        let columns = columns(history: history, phase: phase, count: count)
        return columns.enumerated().map { index, value in
            let height = CGFloat(value) * maximum
            let wave = CGFloat(sin(breath * 2 * .pi + Double(index) * breathPhaseStep))
            return max(minimumHalfHeight, height + wave * breathAmplitude)
        }
    }

    /// The value of the history at a fractional position, interpolated.
    ///
    /// - Parameters:
    ///   - history: the envelope history, oldest first.
    ///   - position: the position to read, in samples.
    /// - Returns: the interpolated value.
    public static func sample(in history: [Double], at position: Double) -> Double {
        guard let first = history.first else { return 0 }
        guard history.count > 1 else { return first }
        let lower = Int(position.rounded(.down))
        let fraction = position - Double(lower)
        let a = history[min(max(lower, 0), history.count - 1)]
        let b = history[min(max(lower + 1, 0), history.count - 1)]
        return a + (b - a) * fraction
    }

    /// The half height of a column, in points.
    ///
    /// - Parameters:
    ///   - column: the shaped amplitude of the column, from `0` to `1`.
    ///   - maximum: the half height of the tallest column, in points.
    /// - Returns: the half height of the column, in points.
    public static func halfHeight(column: Double, maximum: CGFloat) -> CGFloat {
        max(minimumHalfHeight, CGFloat(column) * maximum)
    }

    /// Smooths a series of values with a Catmull-Rom spline.
    ///
    /// The waveform is drawn from these points, so the shape has no corners:
    /// it is one smooth curve from the left edge to the right edge.
    ///
    /// - Parameters:
    ///   - values: the values to smooth.
    ///   - samples: how many points the curve has.
    /// - Returns: the smoothed values.
    public static func smoothed(_ values: [CGFloat], samples: Int) -> [CGFloat] {
        guard values.count > 1, samples > 0 else { return values }
        if values.count == 2 {
            return (0..<samples).map { index in
                let t = CGFloat(index) / CGFloat(max(samples - 1, 1))
                return values[0] + (values[1] - values[0]) * t
            }
        }
        var result: [CGFloat] = []
        result.reserveCapacity(samples)
        let segments = values.count - 1
        for index in 0..<samples {
            let position = Double(index) / Double(max(samples - 1, 1)) * Double(segments)
            let segment = min(Int(position), segments - 1)
            let t = CGFloat(position - Double(segment))
            let p0 = values[max(segment - 1, 0)]
            let p1 = values[segment]
            let p2 = values[min(segment + 1, values.count - 1)]
            let p3 = values[min(segment + 2, values.count - 1)]
            let t2 = t * t
            let t3 = t2 * t
            result.append(0.5 * (
                (2 * p1)
                    + (-p0 + p2) * t
                    + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                    + (-p0 + 3 * p1 - 3 * p2 + p3) * t3
            ))
        }
        return result
    }
}
