import XCTest

import DotCore
@testable import Dot

/// What a failed take still owes after its microphone went away.
///
/// A failure has no key release to explain trailing silence, so the recovery
/// may only leave a quarter of a second to an existing partial. A partial that
/// stopped while the person was speaking is not the final text.
final class FailedTakeRecoveryTests: XCTestCase {
    private let rate = WAVSpec.sampleRate

    private func seconds(_ value: Double) -> Int { Int(value * Double(rate)) }

    func testAPartialOneAndAHalfSecondsBehindStillLeavesASpokenTail() {
        var ledger = TranscriptLedger(commitSeconds: 12)
        ledger.commit(range: 0..<seconds(10), text: "one two")
        ledger.recordProvisional(range: seconds(10)..<seconds(10.5), text: "three")

        // With the release-silence tolerance of the normal stop (2 s) this
        // partial would be reused and 1.5 s of audio would never be sent.
        XCTAssertEqual(
            ledger.stopPlan(sampleCount: seconds(12), trailingTolerance: WAVSpec.sampleRate * 2),
            .alreadyFinal(text: "one two three"),
            "the release-silence tolerance should show why recovery cannot use it"
        )
        XCTAssertEqual(
            FailedTakeRecovery.plan(ledger: ledger, sampleCount: seconds(12)),
            .send(range: seconds(10)..<seconds(12), prefix: "one two")
        )
    }

    func testAPartialInsideTheStrictToleranceIsReused() {
        var ledger = TranscriptLedger(commitSeconds: 12)
        ledger.commit(range: 0..<seconds(10), text: "one two")
        ledger.recordProvisional(range: seconds(10)..<seconds(11.9), text: "three")

        XCTAssertEqual(
            FailedTakeRecovery.plan(ledger: ledger, sampleCount: seconds(12)),
            .alreadyFinal(text: "one two three")
        )
    }

    func testATakeWithNothingCommittedSendsTheWholeTail() {
        let ledger = TranscriptLedger(commitSeconds: 12)

        XCTAssertEqual(
            FailedTakeRecovery.plan(ledger: ledger, sampleCount: seconds(3)),
            .send(range: 0..<seconds(3), prefix: "")
        )
    }

    func testTheToleranceIsAQuarterOfASecond() {
        XCTAssertEqual(FailedTakeRecovery.trailingTolerance, rate / 4)
    }
}
