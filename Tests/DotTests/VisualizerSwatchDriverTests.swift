import DotCore
import QuartzCore
import XCTest
@testable import Dot

@MainActor
final class VisualizerSwatchDriverTests: XCTestCase {
    func testMonotonicTicksAdvanceSmoothlyWithoutResetAcrossPauseAndResume() {
        let driver = VisualizerSwatchDriver()
        defer { driver.stop() }

        for visualizer in [HUDVisualizer.stretch, .matrix] {
            driver.configure(activeVisualizer: visualizer, isRunning: true, headless: false)
            var now: CFTimeInterval = 100.0
            var previousTime = driver.time
            var previousSample = driver.spectrumHistory.last?.sample ?? 0

            for _ in 0..<120 {
                now += 1.0 / 120.0
                driver.debugTick(at: now)
                XCTAssertGreaterThanOrEqual(driver.time, previousTime)
                XCTAssertGreaterThanOrEqual(driver.phase, 0)
                XCTAssertLessThan(driver.phase, 1)
                XCTAssertEqual(driver.history.count, Waveform.historyLength)
                let sample = driver.spectrumHistory.last?.sample ?? -1
                XCTAssertGreaterThanOrEqual(sample, previousSample)
                previousTime = driver.time
                previousSample = sample
            }

            // Simulate a 5-second pause / tab switch / window wakeup: elapsed delta
            // is clamped so the feed never sees a >1 s jump and never resets.
            now += 5.0
            driver.debugTick(at: now)
            let sampleAfterPause = driver.spectrumHistory.last?.sample ?? -1
            XCTAssertGreaterThan(driver.time, previousTime)
            XCTAssertLessThanOrEqual(driver.time - previousTime, VisualizerSwatchDriver.maxFrameDelta + 1e-6)
            XCTAssertGreaterThanOrEqual(sampleAfterPause, previousSample)
            XCTAssertLessThanOrEqual(sampleAfterPause - previousSample, 5)
        }
    }

    func testDeactivatingTabOrHeadlessStopsRenderLoop() {
        let driver = VisualizerSwatchDriver()
        defer { driver.stop() }

        driver.configure(activeVisualizer: .filament, isRunning: true, headless: true)
        XCTAssertEqual(driver.debugActiveClockCount, 0)

        driver.configure(activeVisualizer: .filament, isRunning: true, headless: false)
        XCTAssertEqual(driver.debugActiveClockCount, 1)

        driver.configure(activeVisualizer: .filament, isRunning: false, headless: false)
        XCTAssertEqual(driver.debugActiveClockCount, 0)

        driver.configure(activeVisualizer: .silk, isRunning: true, headless: false)
        XCTAssertEqual(driver.debugActiveClockCount, 1)

        driver.attach(hostView: nil)
        XCTAssertEqual(driver.debugActiveClockCount, 0)

        driver.stop()
        XCTAssertEqual(driver.debugActiveClockCount, 0)
    }

    func testSwitchingVisualizerSeedsSynchronouslyWithoutStaleFrame() {
        let driver = VisualizerSwatchDriver()
        defer { driver.stop() }

        XCTAssertFalse(driver.history.isEmpty)
        XCTAssertFalse(driver.spectrumHistory.isEmpty)
        XCTAssertEqual(driver.history.count, Waveform.historyLength)
        XCTAssertEqual(driver.time, VisualizerSwatchDriver.startOffset, accuracy: 1e-9)
        XCTAssertGreaterThan(driver.history.max() ?? 0, 0.3)

        driver.configure(activeVisualizer: .stretch, isRunning: true, headless: false)
        driver.debugTick(at: 10.0)
        driver.debugTick(at: 10.5)
        XCTAssertGreaterThan(driver.time, VisualizerSwatchDriver.startOffset)

        driver.configure(activeVisualizer: .haloEdge, isRunning: true, headless: false)
        XCTAssertFalse(driver.history.isEmpty)
        XCTAssertFalse(driver.spectrumHistory.isEmpty)
        XCTAssertEqual(driver.time, VisualizerSwatchDriver.startOffset, accuracy: 1e-9)
        XCTAssertGreaterThan(driver.history.max() ?? 0, 0.3)
    }

    func testVisualizerFeedSeededHonorsCustomLeadSeconds() {
        let seededTwo = VisualizerFeed.seeded(at: VisualizerTile.stillTime, leadSeconds: 2.0)
        XCTAssertEqual(seededTwo.meter.writtenSamples, 120)

        let seededThree = VisualizerFeed.seeded(at: VisualizerTile.stillTime, leadSeconds: 3.0)
        XCTAssertEqual(seededThree.meter.writtenSamples, 180)
    }

    func testSixtyHzTicksNeverStallOrDoubleJumpSampleCounter() {
        let feed = VisualizerFeed.seeded(at: VisualizerTile.stillTime, leadSeconds: 3.0)
        var previousWritten = feed.meter.writtenSamples
        var time = VisualizerTile.stillTime
        let step = 1.0 / VisualizerMath.sampleRate

        for tickIndex in 1...600 {
            time += step
            feed.advance(to: time)
            let written = feed.meter.writtenSamples
            XCTAssertEqual(
                written - previousWritten,
                1,
                "tick \(tickIndex) wrote \(written - previousWritten) samples instead of 1"
            )
            previousWritten = written
            XCTAssertLessThan(feed.phase, 0.05)
        }
    }
}
