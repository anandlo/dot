import XCTest
@testable import Dot
@testable import DotCore

/// The ready card has to answer "what is my speech going to", so a configured
/// endpoint is named by its host rather than by the generic row it sits under.
final class ActiveServiceLabelTests: XCTestCase {
    func testAHostIsTakenWithoutSchemeOrPath() {
        XCTAssertEqual(
            AppDelegate.host(of: "https://api.example.com/v1"),
            "api.example.com"
        )
        XCTAssertEqual(
            AppDelegate.host(of: "http://127.0.0.1:8080/v1/"),
            "127.0.0.1"
        )
    }

    func testAMissingOrInvalidEndpointHasNoHost() {
        XCTAssertNil(AppDelegate.host(of: nil))
        XCTAssertNil(AppDelegate.host(of: ""))
        XCTAssertNil(AppDelegate.host(of: "not a url"))
    }

    func testALoopbackServerIsNamedByItsHost() {
        // A local model server is the case where "Custom endpoint" says the
        // least and the host says the most.
        XCTAssertEqual(AppDelegate.host(of: "http://localhost:11434/v1"), "localhost")
    }
}
