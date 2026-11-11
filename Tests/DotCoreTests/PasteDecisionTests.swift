import XCTest
@testable import DotCore

/// The guard that decides whether a transcript may be pasted.
///
/// A paste is a keystroke into whatever is frontmost, so a transcript that is
/// typed into the wrong application is at best noise in someone else's window
/// and at worst a sentence from a private note in a group chat. The decision is
/// pure, and every case below is one the person can actually produce.
final class PasteDecisionTests: XCTestCase {
    private let dotBundle = "com.anandlo.dot"
    private let mail = FrontmostApp(processIdentifier: 101, bundleIdentifier: "com.apple.mail")

    private func decide(
        atPress: FrontmostApp?,
        atDelivery: FrontmostApp?,
        accessibilityGranted: Bool = true,
        autoPasteEnabled: Bool = true
    ) -> PasteDecision {
        PasteDecision.decide(
            atPress: atPress,
            atDelivery: atDelivery,
            accessibilityGranted: accessibilityGranted,
            autoPasteEnabled: autoPasteEnabled,
            ownBundleIdentifier: dotBundle
        )
    }

    func testTheSameApplicationIsPasted() {
        XCTAssertEqual(decide(atPress: mail, atDelivery: mail), .paste)
    }

    func testASwitchedApplicationIsCopied() {
        let safari = FrontmostApp(processIdentifier: 202, bundleIdentifier: "com.apple.Safari")

        XCTAssertEqual(
            decide(atPress: mail, atDelivery: safari),
            .copy(.applicationChanged)
        )
    }

    func testAnApplicationThatQuitIsCopied() {
        XCTAssertEqual(
            decide(atPress: mail, atDelivery: nil),
            .copy(.applicationGone)
        )
    }

    func testDotItselfIsNeverPastedInto() {
        let dot = FrontmostApp(processIdentifier: 303, bundleIdentifier: dotBundle)

        XCTAssertEqual(decide(atPress: mail, atDelivery: dot), .copy(.dotIsFrontmost))
        XCTAssertEqual(decide(atPress: dot, atDelivery: dot), .copy(.dotIsFrontmost))
    }

    func testNoAccessibilityIsCopied() {
        XCTAssertEqual(
            decide(atPress: mail, atDelivery: mail, accessibilityGranted: false),
            .copy(.accessibilityMissing)
        )
    }

    func testAutoPasteOffIsCopied() {
        XCTAssertEqual(
            decide(atPress: mail, atDelivery: mail, autoPasteEnabled: false),
            .copy(.autoPasteOff)
        )
    }

    func testNoApplicationAtThePressIsCopied() {
        XCTAssertEqual(
            decide(atPress: nil, atDelivery: mail),
            .copy(.noApplicationAtPress)
        )
    }

    func testARelaunchOfTheSameApplicationIsCopied() {
        let relaunchedMail = FrontmostApp(
            processIdentifier: 104,
            bundleIdentifier: "com.apple.mail"
        )

        XCTAssertEqual(
            decide(atPress: mail, atDelivery: relaunchedMail),
            .copy(.applicationChanged)
        )
    }

    func testApplicationsWithoutABundleIdentifierAreComparedByProcess() {
        let first = FrontmostApp(processIdentifier: 404, bundleIdentifier: nil)
        let sameProcess = FrontmostApp(processIdentifier: 404, bundleIdentifier: nil)
        let otherProcess = FrontmostApp(processIdentifier: 405, bundleIdentifier: nil)

        XCTAssertEqual(decide(atPress: first, atDelivery: sameProcess), .paste)
        XCTAssertEqual(
            decide(atPress: first, atDelivery: otherProcess),
            .copy(.applicationChanged)
        )
    }

    func testApplicationsWithNoIdentityAtAllAreCopied() {
        XCTAssertEqual(
            decide(atPress: FrontmostApp(), atDelivery: FrontmostApp()),
            .copy(.applicationChanged)
        )
    }

    func testTheSettingIsCheckedBeforeTheApplication() {
        let safari = FrontmostApp(processIdentifier: 202, bundleIdentifier: "com.apple.Safari")

        XCTAssertEqual(
            decide(atPress: mail, atDelivery: safari, autoPasteEnabled: false),
            .copy(.autoPasteOff)
        )
        XCTAssertEqual(
            decide(atPress: mail, atDelivery: safari, accessibilityGranted: false),
            .copy(.accessibilityMissing)
        )
    }

    func testOnlyAMissingPermissionIsAWarning() {
        XCTAssertTrue(PasteDecision.CopyReason.accessibilityMissing.isWarning)
        for reason: PasteDecision.CopyReason in [
            .autoPasteOff, .noApplicationAtPress, .applicationGone,
            .dotIsFrontmost, .applicationChanged,
        ] {
            XCTAssertFalse(reason.isWarning, "\(reason) would be logged as a warning")
        }
    }

    func testEveryReasonLogsItsOwnLine() {
        let reasons: [PasteDecision.CopyReason] = [
            .autoPasteOff, .accessibilityMissing, .noApplicationAtPress,
            .applicationGone, .dotIsFrontmost, .applicationChanged,
        ]
        let events = reasons.map(\.logEvent)

        XCTAssertEqual(Set(events).count, reasons.count, "two reasons share a log line: \(events)")
        XCTAssertTrue(events.allSatisfy { $0.hasPrefix("autopaste.") }, "\(events)")
    }
}
