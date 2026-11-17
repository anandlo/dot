import Foundation
import XCTest

@testable import Dot
@testable import DotCore

/// The one number of the history every style shares.
///
/// A style reads its own moments of the envelope rather than a buffer of heights
/// computed for it, so what is left here is the reading itself: a sample of the
/// history at an offset from the newest, and the answer it gives when the offset
/// is off the ring.
final class VisualizerBarsTests: XCTestCase {
    func testAnOffsetPastTheHistoryReadsZero() {
        XCTAssertEqual(VisualizerBars.sample(history: [0.5], offsetFromNewest: 3), 0)
        XCTAssertEqual(VisualizerBars.sample(history: [], offsetFromNewest: 0), 0)
        XCTAssertEqual(VisualizerBars.sample(history: [0.2, 0.9], offsetFromNewest: 0), 0.9)
        XCTAssertEqual(VisualizerBars.sample(history: [0.2, 0.9], offsetFromNewest: 1), 0.2)
    }

    func testASampleIsHeldInsideTheUnitRange() {
        XCTAssertEqual(VisualizerBars.sample(history: [1.7, -0.4], offsetFromNewest: 1), 1)
        XCTAssertEqual(VisualizerBars.sample(history: [1.7, -0.4], offsetFromNewest: 0), 0)
    }
}
