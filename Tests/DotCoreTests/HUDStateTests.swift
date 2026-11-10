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

/// The state machine knows the launch card and its shape.
final class HUDStateTests: XCTestCase {
    func testTheLaunchCardIsCompact() {
        var machine = HUDStateMachine()
        machine.showReady(shortcut: "⌥⌘D")

        XCTAssertEqual(machine.mode, .ready(shortcut: "⌥⌘D"))
        XCTAssertEqual(machine.card, HUDCardSpec(width: 300, height: 54))
        XCTAssertEqual(machine.card, HUDState.readyCard)
        XCTAssertTrue(machine.isReady)
        XCTAssertFalse(machine.isRecording)
        XCTAssertFalse(machine.isWorking)
        XCTAssertFalse(machine.showsTranscript)
    }

    func testTheLaunchStateIsAValue() {
        var machine = HUDStateMachine()
        machine.showReady(shortcut: "⌥⌘D")
        let copy = machine

        machine.showRecording(elapsed: "0:03")

        XCTAssertEqual(copy.mode, .ready(shortcut: "⌥⌘D"))
        XCTAssertEqual(copy.card, HUDState.readyCard)
        XCTAssertTrue(copy.isReady)
        XCTAssertFalse(machine.isReady)
        XCTAssertEqual(machine.card, HUDState.recordingCard)
    }

    func testEveryStateLeavesTheLaunchState() {
        var machine = HUDStateMachine()
        machine.showReady(shortcut: "⌥⌘D")

        machine.showRecording(elapsed: "0:00")
        XCTAssertFalse(machine.isReady)

        machine.showReady(shortcut: "⌥⌘D")
        machine.showTranscribing()
        XCTAssertFalse(machine.isReady)

        machine.showReady(shortcut: "⌥⌘D")
        machine.showTranscript(text: "A transcript.", delivery: .copied, elapsed: "0:04", bodyHeight: 66)
        XCTAssertFalse(machine.isReady)

        machine.showReady(shortcut: "⌥⌘D")
        machine.showMessage(text: "Something happened.", symbol: "info.circle", width: 280)
        XCTAssertFalse(machine.isReady)
    }

    func testTheLiveCardIsAnExpandedRecordingPill() {
        XCTAssertEqual(HUDState.liveWidth, 520)
        XCTAssertEqual(HUDState.liveHeight, 84)
        XCTAssertEqual(HUDState.liveTextMaxLines, 2)
        XCTAssertEqual(HUDState.liveCard, HUDCardSpec(width: 520, height: 84))
        XCTAssertNotEqual(HUDState.liveCard, HUDState.recordingCard)
        XCTAssertEqual(HUDState.recordingCard, HUDCardSpec(width: 316, height: 54))
    }

    func testTheLaunchShortcutIsPartOfTheState() {
        var first = HUDStateMachine()
        first.showReady(shortcut: "⌥⌘D")
        var second = HUDStateMachine()
        second.showReady(shortcut: "⌃⌥Space")

        XCTAssertNotEqual(first.mode, second.mode)
        if case .ready(let shortcut) = second.mode {
            XCTAssertEqual(shortcut, "⌃⌥Space")
        } else {
            XCTFail("the launch state is missing")
        }
    }
}
