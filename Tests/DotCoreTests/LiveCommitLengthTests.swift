import XCTest

@testable import DotCore

/// A live commit is one provider request, so it can never carry more audio
/// than the ledger's commit length: the provider rejects a longer clip, and
/// the stop path cuts its own segments at the same length.
final class LiveCommitLengthTests: XCTestCase {
    private let rate = WAVSpec.sampleRate

    private func tone(seconds: Double) -> [Int16] {
        let count = Int(seconds * Double(rate))
        return (0..<count).map { i in
            Int16(3000 * sin(2 * Double.pi * 220 * Double(i) / Double(rate)))
        }
    }

    private func silence(seconds: Double) -> [Int16] {
        [Int16](repeating: 0, count: Int(seconds * Double(rate)))
    }

    private func committedRange(_ plan: TranscriptLedger.VADPlan?) -> Range<Int>? {
        guard case .sendSegment(let range, let upTo)? = plan else { return nil }
        XCTAssertEqual(range.upperBound, upTo)
        return range
    }

    /// Speech that ran past the limit before its first long pause is cut near
    /// the limit, not at the pause.
    func testAPauseAfterTheLimitDoesNotStretchTheCommit() throws {
        let ledger = TranscriptLedger(commitSeconds: 30)
        let open = tone(seconds: 70) + silence(seconds: 2)

        let range = try XCTUnwrap(committedRange(ledger.evaluateVAD(in: open)))

        XCTAssertLessThanOrEqual(range.count, ledger.commitSamples)
        XCTAssertGreaterThan(range.count, 0)
    }

    /// The quietest breath near the limit can begin exactly at it; the cut in
    /// the middle of that breath must still stay inside the limit.
    func testABreathAtTheLimitDoesNotPushTheCutPastIt() throws {
        let ledger = TranscriptLedger(commitSeconds: 60)
        let open = tone(seconds: 60) + silence(seconds: 0.32) + tone(seconds: 2)

        let range = try XCTUnwrap(committedRange(ledger.evaluateVAD(in: open)))

        XCTAssertLessThanOrEqual(range.count, ledger.commitSamples)
    }

    /// A pause inside the limit still ends the segment there.
    func testAPauseInsideTheLimitStillCommitsAtThePause() throws {
        let ledger = TranscriptLedger(commitSeconds: 30)
        let open = tone(seconds: 20) + silence(seconds: 2) + tone(seconds: 3)

        let range = try XCTUnwrap(committedRange(ledger.evaluateVAD(in: open)))

        XCTAssertGreaterThan(range.count, Int(20 * Double(rate)))
        XCTAssertLessThan(range.count, Int(22 * Double(rate)))
    }
}
