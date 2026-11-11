import Foundation
import XCTest

@testable import Dot
@testable import DotCore

/// The version line the About window prints and the copy button hands over.
///
/// A bug report gets its build from that line, so its format is checked here
/// rather than left to the eye: a line that names the version but not the build
/// sends whoever reads the report to the wrong binary. The sample numbers are
/// deliberately not this product's: the version is written down once, in
/// `VERSION`, and a test that repeated it would be a second copy to keep.
@MainActor
final class AboutTests: XCTestCase {
    func testTheCopyLineCarriesTheVersionTheBuildAndTheSystem() {
        let line = AboutInfo.copyLine(version: "9.8.7-beta", build: "7", macOS: "14.5")
        XCTAssertEqual(line, "Dot 9.8.7-beta (7), macOS 14.5")
    }

    func testTheSystemVersionDropsAPatchOfZero() {
        XCTAssertEqual(
            AboutInfo.operatingSystem(
                OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
            ),
            "14.5"
        )
        XCTAssertEqual(
            AboutInfo.operatingSystem(
                OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 3)
            ),
            "14.5.3"
        )
    }

    /// The update row compares the newest tag with the running build, and a
    /// prerelease suffix must not change the numbers in front of it.
    func testANewerReleaseIsRecognisedAcrossAPrereleaseSuffix() {
        XCTAssertTrue(UpdateController.isVersion("9.8.8", newerThan: "9.8.7-beta"))
        XCTAssertTrue(UpdateController.isVersion("9.8.8", newerThan: "9.8"))
        // The final release of a beta is the newer build, not the same one.
        XCTAssertTrue(UpdateController.isVersion("9.8.7", newerThan: "9.8.7-beta"))
        XCTAssertFalse(UpdateController.isVersion("9.8.7-beta", newerThan: "9.8.7-beta"))
        XCTAssertFalse(UpdateController.isVersion("1.9.9", newerThan: "2.0.0"))
    }
}
