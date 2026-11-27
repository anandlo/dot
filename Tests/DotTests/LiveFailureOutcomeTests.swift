import DotCore
import XCTest

@testable import Dot

/// An empty answer leaves the range open for the stop; only real failures
/// count against the provider.
final class LiveFailureOutcomeTests: XCTestCase {
    func testNoSpeechIsNotCountedAsAFailure() {
        XCTAssertEqual(LiveFailureOutcome(error: ProviderError.noSpeech), .noText)
    }

    func testARejectedRequestCountsAsAFailure() {
        let rejected = ProviderError.rejected(status: 400, message: "Param Incorrect")
        XCTAssertEqual(LiveFailureOutcome(error: rejected), .count)
        XCTAssertEqual(LiveFailureOutcome(error: URLError(.timedOut)), .count)
    }
}
