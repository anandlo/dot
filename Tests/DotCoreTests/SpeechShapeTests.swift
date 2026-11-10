import XCTest

@testable import DotCore

/// The shape a voice draws.
///
/// The welcome's waveform used to be a sine, and a sine is the one shape speech
/// never makes: every crest identical, the same pattern on a period. These tests
/// pin the three properties that separate the two, so the field cannot quietly
/// turn back into a wave.
final class SpeechShapeTests: XCTestCase {
    func testEveryValueIsAnAmplitude() {
        for step in 0...200 {
            for tick in 0...40 {
                let value = SpeechShape.value(
                    at: Double(step) / 200,
                    time: Double(tick) / 4
                )
                XCTAssertTrue((0...1).contains(value), "\(value) is not an amplitude")
            }
        }
    }

    func testTheSameMomentDrawsTheSameShape() {
        // A render is a photograph of the field, so it has to be reproducible.
        XCTAssertEqual(
            SpeechShape.value(at: 0.42, time: 3.7),
            SpeechShape.value(at: 0.42, time: 3.7)
        )
        XCTAssertEqual(
            SpeechShape.loudness(at: 5.25),
            SpeechShape.loudness(at: 5.25)
        )
    }

    func testNeighbouringBarsDiffer() {
        // A sine's neighbours move in step and the row reads as a pattern. A
        // voice's neighbours disagree, which is the ragged edge that makes a
        // waveform look drawn rather than generated. Measured as the middle of
        // the differences, so a run of two tall bars in a row is not a failure.
        var steps: [Double] = []
        for tick in stride(from: 0.0, to: 6.0, by: 0.5) {
            for index in 0..<21 {
                let here = SpeechShape.value(at: Double(index) / 22, time: tick)
                let next = SpeechShape.value(at: Double(index + 1) / 22, time: tick)
                steps.append(abs(here - next))
            }
        }
        steps.sort()
        let median = steps[steps.count / 2]
        XCTAssertGreaterThan(median, 0.04, "the bars move together like a sine")
    }

    func testTheShapeHasNoPeriod() {
        // The same window of time, one second apart, must not be the same shape:
        // a periodic wave would repeat exactly.
        let first = (0..<24).map { SpeechShape.value(at: Double($0) / 24, time: 1.0) }
        let second = (0..<24).map { SpeechShape.value(at: Double($0) / 24, time: 2.0) }
        XCTAssertNotEqual(first, second)

        // And the loudness must not come back on a beat either: nearly every
        // tenth of a second is its own level.
        let loudness = (0..<60).map { SpeechShape.loudness(at: Double($0) / 10) }
        let levels = Set(loudness.map { ($0 * 1000).rounded() })
        XCTAssertGreaterThanOrEqual(levels.count, 50, "the loudness repeats on a beat")
    }
}
