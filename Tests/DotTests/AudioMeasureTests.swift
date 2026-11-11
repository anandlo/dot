import XCTest

@testable import Dot
import DotCore

/// The measurement the audio tap takes from every buffer.
///
/// The level and the five bands come out of one walk over the samples. The
/// meter that reads them must show exactly what the two-walk version showed,
/// otherwise the optimisation changed the picture on the card.
final class AudioMeasureTests: XCTestCase {
    private func sine(frames: Int, sampleRate: Double, frequency: Double = 440, amplitude: Float = 0.4) -> [Float] {
        (0..<frames).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    func testTheLevelIsTheRMSOfTheBuffer() {
        let mono = sine(frames: 1_024, sampleRate: 48_000)
        var total = 0.0
        for value in mono {
            total += Double(value) * Double(value)
        }
        let expected = (total / Double(mono.count)).squareRoot()

        let measure = AudioSpectrumFrame.measure(mono: mono, sampleRate: 48_000)
        XCTAssertEqual(measure.level, expected, accuracy: 1e-12)
        XCTAssertGreaterThan(measure.level, 0)
    }

    func testTheBandsAreTheOnesTheTwoWalkVersionProduced() {
        let mono = sine(frames: 1_024, sampleRate: 48_000)
        let single = AudioSpectrumFrame.measure(mono: mono, sampleRate: 48_000)
        let twoWalk = AudioSpectrumFrame.analyze(mono: mono, sampleRate: 48_000)

        XCTAssertEqual(single.frame, twoWalk)
        for row in 0..<5 {
            XCTAssertEqual(single.frame[row], twoWalk[row], accuracy: 1e-12)
        }
    }

    func testSilenceReadsAsZeroLevelAndNoBands() {
        let silence = [Float](repeating: 0, count: 1_024)
        let measure = AudioSpectrumFrame.measure(mono: silence, sampleRate: 48_000)
        XCTAssertEqual(measure.level, 0)
        XCTAssertEqual(measure.frame, .zero)
    }

    func testAShortBufferIsNotMeasured() {
        // A buffer shorter than the filter's window has no level and no bands:
        // the tap may see one at the very start of a recording.
        let short = [Float](repeating: 0.5, count: 8)
        let measure = AudioSpectrumFrame.measure(mono: short, sampleRate: 48_000)
        XCTAssertEqual(measure.level, 0)
        XCTAssertEqual(measure.frame, .zero)
    }

    func testTheLevelIsIndependentOfTheRate() {
        // The same samples at two rates have the same RMS: the level is the
        // buffer's, not the clock's.
        let mono = sine(frames: 1_024, sampleRate: 44_100)
        let atFortyFour = AudioSpectrumFrame.measure(mono: mono, sampleRate: 44_100)
        let atFortyEight = AudioSpectrumFrame.measure(mono: mono, sampleRate: 48_000)
        XCTAssertEqual(atFortyFour.level, atFortyEight.level, accuracy: 1e-12)
    }
}
