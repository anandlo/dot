import CoreGraphics
import DotCore
import XCTest

/// The progress the transcribing card shows.
///
/// A spinner cannot tell "almost done" from "stuck", so the card counts the
/// requests it is waiting for.
final class HUDProgressTests: XCTestCase {
    func testASingleRequestIsNotCounted() {
        XCTAssertEqual(HUDProgress.detail(done: 0, total: 0), "")
        XCTAssertEqual(HUDProgress.detail(done: 1, total: 1), "")
        XCTAssertEqual(HUDProgress.detail(done: 0, total: 1), "")
    }

    func testTheCountIsTheRequestThatIsInFlight() {
        XCTAssertEqual(HUDProgress.detail(done: 0, total: 3), "0 of 3")
        XCTAssertEqual(HUDProgress.detail(done: 1, total: 3), "1 of 3")
        XCTAssertEqual(HUDProgress.detail(done: 3, total: 3), "3 of 3")
    }

    func testTheCountCannotRunPastTheTotal() {
        XCTAssertEqual(HUDProgress.detail(done: 9, total: 3), "3 of 3")
        XCTAssertEqual(HUDProgress.detail(done: -2, total: 3), "0 of 3")
    }
}
