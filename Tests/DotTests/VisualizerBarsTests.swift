import Foundation
import XCTest

@testable import Dot
@testable import DotCore

/// The numbers behind one frame of the visualiser.
///
/// The shape used to be one level repeated across the card: every bar was the
/// same number times a fixed bell, so two bars of the same frame never disagreed
/// and the shape had one height in it. These tests are the proof that a frame
/// now carries as many different heights as the voice had moments.
final class VisualizerBarsTests: XCTestCase {
    /// A syllable-shaped history: five syllables of a phrase, sounding until the
    /// newest sample so the bars have something to read.
    private func speechHistory() -> [Double] {
        let count = Waveform.historyLength
        let spoken = Double(count) / Waveform.sampleRate
        return (0..<count).map { index in
            let time = Double(index) / Waveform.sampleRate
            // The phrase fills the newest two thirds of the history.
            guard time > spoken / 3, time <= spoken else { return 0 }
            let syllable = sin((time - spoken / 3) / 0.18 * .pi)
            return max(0, syllable) * (0.55 + 0.35 * sin(time * 3.1))
        }
    }

    func testEveryBarIsItsOwnMeasurement() {
        var bars: [Double] = []
        VisualizerBars.stretch(
            into: &bars,
            history: speechHistory(),
            spectrum: [],
            reveal: 1
        )
        XCTAssertEqual(bars.count, VisualizerBars.stretchCount)

        // The frame has a range in it: the tallest bar and the shortest differ
        // by a visible amount, which is what a single shared level cannot do.
        let tallest = bars.max() ?? 0
        let shortest = bars.min() ?? 0
        XCTAssertGreaterThan(tallest, 0.1)
        XCTAssertGreaterThan(tallest - shortest, 0.12)

        // And the neighbours differ too: a shape built from one number repeated
        // has identical neighbours.
        let neighbours = zip(bars, bars.dropFirst()).map { abs($0 - $1) }
        XCTAssertGreaterThan(neighbours.max() ?? 0, 0.04)
    }

    func testBarsNeverLeaveTheUnitRange() {
        for reveal in [-1.0, 0, 0.3, 1, 4] {
            var bars: [Double] = []
            VisualizerBars.stretch(
                into: &bars,
                history: speechHistory(),
                spectrum: [],
                reveal: reveal
            )
            for bar in bars {
                XCTAssertGreaterThanOrEqual(bar, 0)
                XCTAssertLessThanOrEqual(bar, 1)
            }
        }
    }

    func testSilenceIsARowOfRestingDots() {
        var bars: [Double] = []
        VisualizerBars.stretch(
            into: &bars,
            history: Array(repeating: 0, count: Waveform.historyLength),
            spectrum: [],
            reveal: 1
        )
        XCTAssertEqual(bars.max() ?? 1, 0, accuracy: 0.0001)
    }

    func testTheRevealGrowsTheShapeFromNothing() {
        let history = speechHistory()
        var none: [Double] = []
        var half: [Double] = []
        var full: [Double] = []
        VisualizerBars.stretch(into: &none, history: history, spectrum: [], reveal: 0)
        VisualizerBars.stretch(into: &half, history: history, spectrum: [], reveal: 0.5)
        VisualizerBars.stretch(into: &full, history: history, spectrum: [], reveal: 1)
        XCTAssertEqual(none.max() ?? 1, 0, accuracy: 0.0001)
        for index in 0..<full.count {
            XCTAssertEqual(half[index], full[index] * 0.5, accuracy: 0.0001)
        }
    }

    func testALouderHalfSecondDrawsTallerBars() {
        let quiet = speechHistory().map { $0 * 0.35 }
        let loud = speechHistory().map { min(1, $0 * 0.95) }
        var quietBars: [Double] = []
        var loudBars: [Double] = []
        VisualizerBars.stretch(into: &quietBars, history: quiet, spectrum: [], reveal: 1)
        VisualizerBars.stretch(into: &loudBars, history: loud, spectrum: [], reveal: 1)
        XCTAssertGreaterThan(loudBars.max() ?? 0, (quietBars.max() ?? 0) + 0.2)
    }

    func testTheScrollingMeterReadsTheSpectrumToo() {
        let history = Array(repeating: 0.0, count: Waveform.historyLength)
        let spectrum = Array(
            repeating: AudioSpectrumFrame(bands: (0.8, 0.8, 0.8, 0.8, 0.8)),
            count: Waveform.historyLength
        )
        var silent: [Double] = []
        var lit: [Double] = []
        VisualizerBars.scrolling(into: &silent, count: 40, history: history, spectrum: [], reveal: 1)
        VisualizerBars.scrolling(into: &lit, count: 40, history: history, spectrum: spectrum, reveal: 1)
        XCTAssertEqual(silent.max() ?? 1, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(lit.max() ?? 0, 0.7, "a band with energy lights the meter")
    }

    func testAnOffsetPastTheHistoryReadsZero() {
        XCTAssertEqual(VisualizerBars.sample(history: [0.5], offsetFromNewest: 3), 0)
        XCTAssertEqual(VisualizerBars.sample(history: [], offsetFromNewest: 0), 0)
        XCTAssertEqual(VisualizerBars.sample(history: [0.2, 0.9], offsetFromNewest: 0), 0.9)
        XCTAssertEqual(VisualizerBars.sample(history: [0.2, 0.9], offsetFromNewest: 1), 0.2)
    }
}
