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

    func testAChunkIsDueOnlyWhenTheWholeChunkHasArrived() {
        var ledger = TranscriptLedger(commitSeconds: 12)

        XCTAssertNil(ledger.dueChunk(sampleCount: 0))
        XCTAssertNil(ledger.dueChunk(sampleCount: seconds(11.9)))
        XCTAssertEqual(ledger.dueChunk(sampleCount: seconds(12)), 0..<seconds(12))
        XCTAssertEqual(ledger.dueChunk(sampleCount: seconds(30)), 0..<seconds(12))

        ledger.commit(range: 0..<seconds(12), text: "first")

        // The next chunk starts where the last one ended, and never overlaps it.
        XCTAssertNil(ledger.dueChunk(sampleCount: seconds(23.9)))
        XCTAssertEqual(ledger.dueChunk(sampleCount: seconds(24)), seconds(12)..<seconds(24))
        XCTAssertEqual(ledger.committedSamples, seconds(12))
    }

    func testAProvisionalNeverReachesBackIntoCommittedAudio() {
        var ledger = TranscriptLedger(commitSeconds: 12)
        ledger.commit(range: 0..<seconds(12), text: "first")

        let range = ledger.provisionalRange(sampleCount: seconds(15))

        XCTAssertEqual(range, seconds(12)..<seconds(15))
    }

    func testAProvisionalStartsAtTheCommitBoundaryAndOnlyGrows() {
        let ledger = TranscriptLedger(commitSeconds: 12)

        // Each partial covers the whole open tail. A window that slid forward
        // would make the card's first words disappear while the user was still
        // speaking, and come back re-transcribed when the chunk was committed.
        XCTAssertEqual(ledger.provisionalRange(sampleCount: seconds(2)), 0..<seconds(2))
        XCTAssertEqual(ledger.provisionalRange(sampleCount: seconds(9)), 0..<seconds(9))
        XCTAssertEqual(ledger.provisionalRange(sampleCount: seconds(11.5)), 0..<seconds(11.5))
        XCTAssertNil(ledger.provisionalRange(sampleCount: 0))
    }

    func testAProvisionalIsNotSentTwiceForTheSameAudio() {
        var ledger = TranscriptLedger(commitSeconds: 12)
        let growth = seconds(0.4)

        // Nothing new has arrived, so nothing is sent.
        XCTAssertFalse(ledger.shouldSendProvisional(sampleCount: 0, minimumGrowth: growth))

        ledger.recordProvisional(range: 0..<seconds(1), text: "hello")
        XCTAssertFalse(ledger.shouldSendProvisional(sampleCount: seconds(1.2), minimumGrowth: growth))
        XCTAssertTrue(ledger.shouldSendProvisional(sampleCount: seconds(1.5), minimumGrowth: growth))
    }

    func testTheFirstPartialAlsoWaitsForEnoughAudio() {
        let ledger = TranscriptLedger(commitSeconds: 12)
        let growth = seconds(2)

        // A request for a sliver of audio is what makes a provider guess at the
        // language, so the first partial obeys the same rule as the rest.
        XCTAssertFalse(ledger.shouldSendProvisional(sampleCount: seconds(1.9), minimumGrowth: growth))
        XCTAssertTrue(ledger.shouldSendProvisional(sampleCount: seconds(2), minimumGrowth: growth))
    }

    func testTheDisplayShowsTheFinalTextAndThePartial() {
        var ledger = TranscriptLedger(commitSeconds: 12)
        ledger.commit(range: 0..<seconds(12), text: "  the meeting is at four  ")
        ledger.recordProvisional(range: seconds(12)..<seconds(14), text: "and the")
        XCTAssertEqual(ledger.displayText, "the meeting is at four and the")
        XCTAssertEqual(ledger.finalText, "the meeting is at four")
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

        XCTAssertEqual(ledger.finalText, "hello world")
    }
}
