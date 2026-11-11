import DotCore
import Foundation

/// The heights one frame of the visualiser draws, as numbers.
///
/// The visualiser used to be drawn from a single number: the level of the voice
/// at that instant. Every bar of the stretch shape was that one number times a
/// fixed bell, plus three more terms that were also that same number, so the
/// shape was one flat envelope that grew and shrank and never had two bars with
/// different heights. That is what "it just hits the threshold" looks like in
/// code: a shape with one value in it.
///
/// This type is the fix, and it is a value rather than a drawing so it can be
/// tested: every bar is a different measurement of the recent past, read from
/// the envelope history and the five bands the audio tap already produces, and
/// then shaped by a static taper. The taper is the only thing about the shape
/// that is not data, and it is never applied as a floor.
enum VisualizerBars {
    /// How many bars the stretch visualiser draws.
    static let stretchCount = 15
    /// How many envelope ticks one bar of the stretch shape covers.
    ///
    /// Two ticks is 33 milliseconds at the 60 Hz the history is written at, so
    /// fifteen bars cover half a second of speech: two to four syllables, which
    /// is enough for the shape to have a body, a shoulder and an edge.
    static let stretchTickStep = 2

    /// Fills the bars of the stretch visualiser, oldest at the left.
    ///
    /// - Parameters:
    ///   - bars: the buffer to fill, resized to ``stretchCount``.
    ///   - history: the envelope history, oldest first, each in `0...1`.
    ///   - spectrum: the 5-band history, oldest first. Empty when the tap has
    ///     not produced one.
    ///   - reveal: how much of the shape has arrived, from `0` to `1`.
    static func stretch(
        into bars: inout [Double],
        history: [Double],
        spectrum: [AudioSpectrumFrame],
        reveal: Double
    ) {
        let count = stretchCount
        if bars.count != count {
            bars = [Double](repeating: 0, count: count)
        }
        guard !history.isEmpty else {
            for index in 0..<count { bars[index] = 0 }
            return
        }
        let centre = Double(count - 1) / 2
        let newest = history.count - 1
        let shown = min(max(reveal, 0), 1)
        for index in 0..<count {
            // Every bar is its own moment of the voice, oldest at the left.
            let offset = (count - 1 - index) * stretchTickStep
            let value = sample(history: history, offsetFromNewest: offset)
            let dist = centre > 0 ? abs(Double(index) - centre) / centre : 0
            let bell = exp(-dist * dist * 1.25)
            // The taper is the island's silhouette and nothing more. It is
            // gentle on purpose: a strong bell makes every frame the same
            // arch, which is a drawing of a voice rather than a meter of one.
            let taper = 0.74 + 0.26 * bell
            let tilt = bandTilt(spectrum: spectrum, newest: newest, offset: offset, dist: dist)
            bars[index] = min(1, max(0, value * taper * tilt * shown))
        }
    }

    /// Fills a scrolling bar meter, newest at the right.
    ///
    /// - Parameters:
    ///   - bars: the buffer to fill, resized to `count`.
    ///   - count: how many bars fit across the card.
    ///   - history: the envelope history, oldest first.
    ///   - spectrum: the 5-band history, oldest first.
    ///   - reveal: how much of the meter has arrived, from `0` to `1`.
    static func scrolling(
        into bars: inout [Double],
        count: Int,
        history: [Double],
        spectrum: [AudioSpectrumFrame],
        reveal: Double
    ) {
        let barCount = max(1, count)
        if bars.count != barCount {
            bars = [Double](repeating: 0, count: barCount)
        }
        let shown = min(max(reveal, 0), 1)
        let newest = history.count - 1
        for index in 0..<barCount {
            guard !history.isEmpty else {
                bars[index] = 0
                continue
            }
            let offset = index * 2
            let value = sample(history: history, offsetFromNewest: offset)
            let peak = bandPeak(spectrum: spectrum, newest: newest, offset: offset)
            bars[index] = min(1, max(0, max(value, peak) * shown))
        }
    }

    /// The envelope sample `offset` ticks ago, `0` being the newest.
    ///
    /// - Parameters:
    ///   - history: the envelope history, oldest first.
    ///   - offset: how many ticks back to read.
    /// - Returns: the sample, from `0` to `1`; `0` when it is off the history.
    static func sample(history: [Double], offsetFromNewest offset: Int) -> Double {
        let index = history.count - 1 - offset
        guard index >= 0, index < history.count else { return 0 }
        return min(1, max(0, history[index]))
    }

    /// How much the band that belongs at a bar's distance lifts it.
    ///
    /// The chest and fundamental sit at the centre of the shape and the
    /// sibilants at its edges, so a word with a hard `s` in it draws a wider
    /// shape than a vowel of the same loudness. When the tap has produced no
    /// spectrum the tilt is one, and the shape is the envelope alone.
    private static func bandTilt(
        spectrum: [AudioSpectrumFrame],
        newest: Int,
        offset: Int,
        dist: Double
    ) -> Double {
        guard newest >= 0, !spectrum.isEmpty else { return 1 }
        let index = max(0, newest - offset)
        guard index < spectrum.count else { return 1 }
        let row = min(4, max(0, Int((dist * 5).rounded(.down))))
        return 0.80 + 0.20 * min(1, max(0, spectrum[index][row]))
    }

    /// The loudest band at a moment, used by the scrolling meters.
    private static func bandPeak(spectrum: [AudioSpectrumFrame], newest: Int, offset: Int) -> Double {
        guard newest >= 0, !spectrum.isEmpty else { return 0 }
        let index = max(0, newest - offset)
        guard index < spectrum.count else { return 0 }
        let frame = spectrum[index]
        return min(
            1,
            max(frame.bands.0, max(frame.bands.1, max(frame.bands.2, max(frame.bands.3, frame.bands.4))))
        )
    }
}
