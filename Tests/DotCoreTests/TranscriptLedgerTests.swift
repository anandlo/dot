import XCTest

@testable import DotCore

/// The commit arithmetic of a live recording.
///
/// Nothing here touches audio: the ledger works in sample offsets, which is
/// what makes "the stop sends only the tail" a fact a test can check.
final class TranscriptLedgerTests: XCTestCase {
    private let rate = WAVSpec.sampleRate

    private func seconds(_ value: Double) -> Int {
        Int(value * Double(rate))
    }

    func testTheDisplayShowsTheFinalTextAndThePartial() {
        var ledger = TranscriptLedger(commitSeconds: 12)
        ledger.commit(range: 0..<seconds(12), text: "  the meeting is at four  ")
        ledger.recordProvisional(range: seconds(12)..<seconds(14), text: "and the")
        XCTAssertEqual(ledger.displayText, "the meeting is at four and the")
    }

    func testTheStopSendsTheTailThatIsStillOpen() {
        let ledger = TranscriptLedger(commitSeconds: 12)
        XCTAssertEqual(
            ledger.stopPlan(sampleCount: seconds(8)),
            .send(range: 0..<seconds(8), prefix: "")
        )
    }

    func testTheStopSendsNothingWhenTheLastPartialCoveredTheTail() {
        var ledger = TranscriptLedger(commitSeconds: 12)
        ledger.commit(range: 0..<seconds(12), text: "one")
        ledger.recordProvisional(range: seconds(12)..<seconds(15), text: "two")

        // The recording ended on the sample the partial already saw.
        XCTAssertEqual(ledger.stopPlan(sampleCount: seconds(15)), .alreadyFinal(text: "one two"))
    }

    func testTheStopSendsNothingWhenTheRecordingEndsOnAChunk() {
        var ledger = TranscriptLedger(commitSeconds: 12)
        ledger.commit(range: 0..<seconds(12), text: "one")
        XCTAssertEqual(ledger.stopPlan(sampleCount: seconds(12)), .alreadyFinal(text: "one"))
    }

    func testAPartialThatMissedAudioIsNotUsedAsTheFinalText() {
        var ledger = TranscriptLedger(commitSeconds: 12)
        ledger.commit(range: 0..<seconds(12), text: "one")
        // The partial only saw the newest second of a three second tail: the
        // stop has to send the whole tail, or two seconds would be lost.
        ledger.recordProvisional(range: seconds(14)..<seconds(15), text: "three")

        XCTAssertEqual(
            ledger.stopPlan(sampleCount: seconds(15)),
            .send(range: seconds(12)..<seconds(15), prefix: "one")
        )
    }

    func testACommitForgetsThePartialItSwallowed() {
        var ledger = TranscriptLedger(commitSeconds: 12)
        ledger.recordProvisional(range: 0..<seconds(2), text: "partial")
        ledger.commit(range: 0..<seconds(12), text: "final")

        XCTAssertNil(ledger.provisional)
        XCTAssertEqual(ledger.stopPlan(sampleCount: seconds(12)), .alreadyFinal(text: "final"))
    }

    func testAnEmptyTranscriptNeverLeavesDoubleSpaces() {
        var ledger = TranscriptLedger(commitSeconds: 12)
        ledger.commit(range: 0..<seconds(12), text: "  ")
        ledger.commit(range: seconds(12)..<seconds(24), text: "hello  ")
        ledger.commit(range: seconds(24)..<seconds(36), text: "   world ")

        XCTAssertEqual(ledger.displayText, "hello world")
    }
}
