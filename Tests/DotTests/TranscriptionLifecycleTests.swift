import XCTest

@testable import Dot

/// Whether a finished transcription may be delivered.
///
/// The two terminal cases are a quitting app and a cancelled task. Neither may
/// paste, and neither may leave the transcribing card behind.
final class TranscriptionLifecycleTests: XCTestCase {
    func testAFinishedTaskOnARunningAppIsDelivered() {
        XCTAssertEqual(
            TranscriptionLifecycle.end(isTerminating: false, isCancelled: false),
            .deliver
        )
    }

    func testACancelledTaskIsAbandoned() {
        XCTAssertEqual(
            TranscriptionLifecycle.end(isTerminating: false, isCancelled: true),
            .abandon
        )
    }

    func testATranscriptThatFinishesDuringTerminationIsAbandoned() {
        XCTAssertEqual(
            TranscriptionLifecycle.end(isTerminating: true, isCancelled: false),
            .abandon
        )
    }

    func testATerminatingCancelledTaskIsAbandoned() {
        XCTAssertEqual(
            TranscriptionLifecycle.end(isTerminating: true, isCancelled: true),
            .abandon
        )
    }
}
