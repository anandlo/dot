import AppKit
@testable import Dot
import DotCore
import XCTest

/// The live partial of the recording card, without an engine or a microphone.
@MainActor
final class HUDLiveTests: XCTestCase {
    func testTheModelStartsWithoutLiveText() {
        let model = HUDModel()

        XCTAssertEqual(model.liveText, "")
        XCTAssertEqual(model.cardSize, HUDState.recordingCard.size)
    }

    func testLiveTextExpandsOnlyTheRecordingCard() {
        let model = HUDModel()
        model.mode = .recording(elapsed: "0:02")
        model.cardSize = HUDState.recordingCard.size

        model.showLiveText("A live partial sentence.")

        XCTAssertEqual(model.liveText, "A live partial sentence.")
        XCTAssertEqual(model.cardSize, HUDState.liveCard.size)
        XCTAssertEqual(model.cardSize, HUDCardSpec(width: 520, height: 84).size)

        model.showLiveText("   ")

        XCTAssertEqual(model.liveText, "")
        XCTAssertEqual(model.cardSize, HUDState.recordingCard.size)
    }

    func testALatePartialCannotEnterAnotherState() {
        let model = HUDModel()
        model.mode = .working
        model.cardSize = HUDState.recordingCard.size

        model.showLiveText("A partial that arrived after Stop.")

        XCTAssertEqual(model.liveText, "")
        XCTAssertEqual(model.cardSize, HUDState.recordingCard.size)
    }

    func testTheClockDoesNotEraseTheLiveText() {
        let model = HUDModel()
        model.mode = .recording(elapsed: "0:00")
        model.showLiveText("The words keep their place.")

        model.updateRecording(elapsed: "0:09")

        XCTAssertEqual(model.liveText, "The words keep their place.")
        XCTAssertEqual(model.mode, .recording(elapsed: "0:09"))
        XCTAssertEqual(model.cardSize, HUDState.liveCard.size)
    }

    func testClearingTheLiveTextLeavesTheStateToTheCaller() {
        let model = HUDModel()
        model.mode = .recording(elapsed: "0:04")
        model.showLiveText("A sentence that is about to end.")

        model.clearLiveText()

        XCTAssertEqual(model.liveText, "")
        XCTAssertEqual(model.mode, .recording(elapsed: "0:04"))
        XCTAssertEqual(model.cardSize, HUDState.liveCard.size)
    }

    func testTheLiveStateRendersAtItsCardSize() throws {
        let image = try HUDPreview.render(state: .live, showsShadow: false)
        let inset = Int(HUD.shadowPadding * 2)

        XCTAssertEqual(image.pixelsWide, Int(HUDState.liveWidth) * 2 + inset * 2)
        XCTAssertEqual(image.pixelsHigh, Int(HUDState.liveHeight) * 2 + inset * 2)

        for (x, y) in [
            (0, 0),
            (image.pixelsWide - 1, 0),
            (0, image.pixelsHigh - 1),
            (image.pixelsWide - 1, image.pixelsHigh - 1),
        ] {
            let color = try XCTUnwrap(image.colorAt(x: x, y: y))
            XCTAssertEqual(color.alphaComponent, 0, accuracy: 0.001, "corner (\(x), \(y)) is not transparent")
        }

        let middle = try XCTUnwrap(
            image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)
        )
        XCTAssertGreaterThan(middle.alphaComponent, 0.9)
    }

    func testTheLiveStateIsInTheRenderSet() {
        XCTAssertTrue(HUDPreview.State.allCases.contains(.live))
        XCTAssertEqual(HUDPreview.State.live.rawValue, "live")
        XCTAssertFalse(HUDPreview.livePartial.isEmpty)
    }
}
