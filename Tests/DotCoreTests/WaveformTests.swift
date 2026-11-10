import CoreGraphics
import XCTest

@testable import DotCore

/// The island's waveform travels as a recording does.
///
/// This was measured the wrong way round once, and the mistake was invisible: a
/// shape drawn from position alone and a shape drawn from a history both look
/// like a waveform in a still, and only the direction of travel tells them
/// apart. So the direction is pinned here, on a history whose shape is known
/// exactly, rather than inferred from comparing two noisy frames.
final class WaveformTests: XCTestCase {
    /// A history with one column of sound in it, and silence everywhere else.
    private func spike(at index: Int) -> [Double] {
        var history = [Double](repeating: 0, count: Waveform.historyLength)
        history[index] = 1
        return history
    }

    /// Where the loudest column sits.
    private func peak(_ columns: [Double]) -> Int {
        columns.enumerated().max { $0.element < $1.element }?.offset ?? -1
    }

    func testTheShapeTravelsFromRightToLeft() {
        // One column per sample, so a spike sits in exactly one column and its
        // movement is exact. The card itself draws fewer columns than it keeps
        // samples; the direction is the same either way and this way is
        // countable.
        let history = spike(at: 100)
        let count = Waveform.historyLength
        let early = Waveform.columns(history: history, phase: 0.25, count: count)
        let late = Waveform.columns(history: history, phase: 0.75, count: count)

        XCTAssertEqual(peak(early), 101)
        XCTAssertEqual(peak(late), 100, "the shape moved right as time passed")
    }

    func testTheNewestSampleIsReadAtTheRightEdge() {
        // A history is read oldest at the left and newest at the right; if that
        // is inverted the card shows a recording playing backwards.
        let newest = Waveform.columns(history: spike(at: 179), phase: 0.99, count: 180)
        let oldest = Waveform.columns(history: spike(at: 0), phase: 0.99, count: 180)

        XCTAssertGreaterThan(newest.suffix(20).reduce(0, +), 0.5, "the newest sample is not at the right edge")
        XCTAssertEqual(oldest.suffix(20).reduce(0, +), 0, accuracy: 1e-9, "the oldest sample reached the right edge")
        XCTAssertGreaterThan(oldest.prefix(20).reduce(0, +), 0.5, "the oldest sample is not at the left edge")
    }

    /// Silence is a hairline that still moves, never nothing at all.
    func testSilenceBreathesRatherThanVanishing() {
        let flat = [Double](repeating: 0, count: Waveform.historyLength)
        let first = Waveform.halfHeights(
            history: flat,
            phase: 0,
            count: Waveform.columnCount,
            maximum: 11,
            breath: 0
        )
        let later = Waveform.halfHeights(
            history: flat,
            phase: 0,
            count: Waveform.columnCount,
            maximum: 11,
            breath: 0.25
        )
        XCTAssertTrue(first.allSatisfy { $0 >= Waveform.minimumHalfHeight })
        XCTAssertNotEqual(first, later, "silence is a still picture")
    }
}
