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
        let liveDotLeaves = FrameLeafProbe.liveDotBodies
        if let reportPath = ProcessInfo.processInfo.environment["DOT_PACING_REPORT_DIR"], !reportPath.isEmpty {
            let directory = URL(fileURLWithPath: reportPath, isDirectory: true)
            let report: [String: Any] = [
                "ticks": 600,
                "object_will_change": invalidations,
                "body_evaluations": bodyEvaluations,
                "waveform_leaf_evaluations": waveformLeaves,
                "live_dot_leaf_evaluations": liveDotLeaves,
            ]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("stage2-acceptance.json"), options: .atomic)
        }
        BodyEvalProbe.captures = false
        FrameLeafProbe.captures = false
        withExtendedLifetime(observer) {}

        XCTAssertEqual(invalidations, 0, "the model was invalidated by frame updates")
        XCTAssertLessThanOrEqual(bodyEvaluations, 20, "the card body was rebuilt more than twice per 60 ticks")
        XCTAssertEqual(waveformLeaves, 600, "the waveform leaf was not evaluated exactly once per tick")
        XCTAssertEqual(liveDotLeaves, 0, "the live dot leaf evaluated in SwiftUI during steady ticks")
        XCTAssertGreaterThan(hud.debugFrameModel.history.count, 0)
    }

    func testEmergenceWritesToFrameModelWithoutInvalidatingHUDModel() {
        let hud = HUD(offscreen: true)
        hud.visualizer = .matrix
        hud.material = .black
        hud.debugSetReduceMotion(false)
        hud.showRecording(elapsed: "0:00")
        defer { hud.hide() }

        var invalidations = 0
        let observer = hud.debugModel.objectWillChange.sink { _ in invalidations += 1 }
        let start = 200.0
        for index in 1...15 {
            hud.debugTick(now: start + Double(index) / 60)
        }
        withExtendedLifetime(observer) {}

        XCTAssertEqual(invalidations, 0, "emergence frames invalidated HUDModel instead of HUDFrameModel")
        XCTAssertGreaterThan(hud.debugPresence, 0.1)
        XCTAssertGreaterThan(hud.debugContent, 0.1)
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

    func testPreviewVisualizerSeedsNonFlatHistory() {
        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.material = .black
        hud.debugSetReduceMotion(false)
        hud.previewVisualizer(.stretch)

        let start = CACurrentMediaTime()
        for index in 1...3 {
            hud.debugTick(now: start + Double(index) / 60.0)
        }

        let history = hud.debugFrameModel.history
        XCTAssertGreaterThan(history.max() ?? 0, 0.1, "preview visualizer history is flat")
        let distinctLevels = Set(history.map { Int(($0 * 1000).rounded()) })
        XCTAssertGreaterThan(distinctLevels.count, 5, "preview visualizer trace lacks dynamic range")

        let spectrumPeak = hud.debugFrameModel.spectrumHistory
            .map { max($0.bands.0, $0.bands.1, $0.bands.2, $0.bands.3, $0.bands.4) }
            .max() ?? 0
        XCTAssertGreaterThan(spectrumPeak, 0.05, "preview visualizer spectrum history is empty")

        hud.previewVisualizer(.matrix)
        for index in 1...3 {
            hud.debugTick(now: start + 1.0 + Double(index) / 60.0)
        }
        let secondHistory = hud.debugFrameModel.history
        XCTAssertGreaterThan(secondHistory.max() ?? 0, 0.1, "repeat preview visualizer history is flat")
        XCTAssertGreaterThan(
            Set(secondHistory.map { Int(($0 * 1000).rounded()) }).count,
            5,
            "repeat preview visualizer trace lacks dynamic range"
        )
        let secondSpectrumPeak = hud.debugFrameModel.spectrumHistory
            .map { max($0.bands.0, $0.bands.1, $0.bands.2, $0.bands.3, $0.bands.4) }
            .max() ?? 0
        XCTAssertGreaterThan(secondSpectrumPeak, 0.05, "repeat preview visualizer spectrum history is empty")
    }
}
