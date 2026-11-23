import Combine
import CoreGraphics
@testable import Dot
import XCTest

/// The frame clock must not invalidate the card's model or rebuild its body.
@MainActor
final class HUDFramePacingAcceptanceTests: XCTestCase {
    func testSteadyRecordingDoesNotInvalidateTheModelOrRebuildTheCard() {
        let hud = HUD(offscreen: true)
        hud.visualizer = .matrix
        hud.material = .black
        hud.debugSetReduceMotion(false)
        hud.showRecording(elapsed: "0:00")

        let start = 100.0
        for index in 0..<180 {
            hud.debugTick(now: start + Double(index) / 60)
            hud.debugRootView.layoutSubtreeIfNeeded()
        }

        HUDTickProbe.reset()
        BodyEvalProbe.reset()
        FrameLeafProbe.reset()
        var invalidations = 0
        let observer = hud.debugModel.objectWillChange.sink { _ in invalidations += 1 }
        BodyEvalProbe.captures = true
        FrameLeafProbe.captures = true

        for index in 0..<600 {
            hud.debugTick(now: start + 3 + Double(index) / 60)
            hud.debugRootView.layoutSubtreeIfNeeded()
        }

        let bodyEvaluations = BodyEvalProbe.count
        let waveformLeaves = FrameLeafProbe.waveformBodies
        let directory = URL(
            fileURLWithPath: "/Users/anandlo/Developer/dot-r17/evidence/matrix-frame-pacing/fix",
            isDirectory: true
        )
        let report: [String: Any] = [
            "ticks": 600,
            "object_will_change": invalidations,
            "body_evaluations": bodyEvaluations,
            "waveform_leaf_evaluations": waveformLeaves,
        ]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("stage2-acceptance.json"), options: .atomic)
        BodyEvalProbe.captures = false
        FrameLeafProbe.captures = false
        withExtendedLifetime(observer) {}

        XCTAssertEqual(invalidations, 0, "the model was invalidated by frame updates")
        XCTAssertLessThanOrEqual(bodyEvaluations, 20, "the card body was rebuilt more than twice per 60 ticks")
        XCTAssertEqual(waveformLeaves, 600, "the waveform leaf was not evaluated exactly once per tick")
        XCTAssertGreaterThan(hud.debugFrameModel.history.count, 0)
    }

    func testUpdatingTheClockOnlyWritesANewElapsedString() {
        let model = HUDModel()
        model.mode = .recording(elapsed: "0:01")
        var writes = 0
        let observer = model.objectWillChange.sink { _ in writes += 1 }

        model.updateRecording(elapsed: "0:01")
        XCTAssertEqual(writes, 0)
        model.updateRecording(elapsed: "0:02")
        XCTAssertEqual(writes, 1)
        withExtendedLifetime(observer) {}
    }
}
