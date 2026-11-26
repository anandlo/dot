import AppKit
import Combine
import DotCore
import os
import QuartzCore
import SwiftUI
import XCTest

@testable import Dot

@MainActor
final class AnimationFluidityTests: XCTestCase {
    private final class VisibleOffscreenWindow: OffscreenWindow {
        override var occlusionState: NSWindow.OcclusionState { .visible }
    }

    private struct DrawSample: Sendable {
        let timestamp: CFTimeInterval
        let durationMS: Double
    }

    private final class DrawCollector: Sendable {
        private let samplesLock = OSAllocatedUnfairLock<[DrawSample]>(initialState: [])

        func record(now: CFTimeInterval, durationMS: Double) {
            samplesLock.withLock { $0.append(DrawSample(timestamp: now, durationMS: durationMS)) }
        }

        func snapshot() -> [DrawSample] {
            samplesLock.withLock { $0 }
        }

        func reset() {
            samplesLock.withLock { $0.removeAll(keepingCapacity: true) }
        }
    }

    override func setUp() {
        super.setUp()
        FontFixture.register()
        MainActor.assumeIsolated {
            DotScrollInteraction.debugReset()
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            DotScrollInteraction.debugReset()
        }
        super.tearDown()
    }

    private func pumpRunLoop(seconds: TimeInterval, slice: TimeInterval = 1.0 / 60.0) {
        let deadline = CFAbsoluteTimeGetCurrent() + seconds
        while CFAbsoluteTimeGetCurrent() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(slice))
            CATransaction.flush()
        }
    }

    private static func percentile95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded(.up)))
        return sorted[index]
    }

    func testHUDRecordingAndExpandedLiveFluidityAcrossAllFiveVisualizers() {
        BodyEvalProbe.captures = true
        FrameLeafProbe.captures = true
        defer {
            BodyEvalProbe.captures = false
            FrameLeafProbe.captures = false
        }

        for visualizer in HUDVisualizer.allCases {
            let hud = HUD(offscreen: true)
            defer { hud.hide() }

            hud.visualizer = visualizer
            hud.material = .black
            hud.debugSetReduceMotion(false)

            var speechPhase = 0.0
            hud.setLevelProvider {
                speechPhase += 0.09
                return 0.15 + 0.75 * (0.5 + 0.5 * sin(speechPhase))
            }
            hud.setSpectrumProvider {
                let wave = 0.5 + 0.5 * sin(speechPhase * 1.1)
                return AudioSpectrumFrame(bands: (
                    0.18 + 0.72 * wave,
                    0.16 + 0.65 * (0.5 + 0.5 * cos(speechPhase * 0.8)),
                    0.15 + 0.58 * wave,
                    0.14 + 0.62 * (0.5 + 0.5 * sin(speechPhase * 1.4)),
                    0.12 + 0.45 * wave
                ))
            }

            let stats = hud.debugFrameStatistics
            hud.showRecording(elapsed: "0:00")
            hud.debugFrameModel.visualizerSink.onLayerDraw = { [weak stats] now, durationMS in
                stats?.recordCanvasDraw(now: now, durationMS: durationMS)
            }

            pumpRunLoop(seconds: 0.25)

            var invalidations = 0
            let observer = hud.debugModel.objectWillChange.sink { _ in invalidations += 1 }
            BodyEvalProbe.reset()
            FrameLeafProbe.reset()

            let compactStartTime = hud.debugFrameModel.time
            pumpRunLoop(seconds: 0.40)
            let compactEndTime = hud.debugFrameModel.time

            let compactInvalidations = invalidations
            let compactBodyEvals = BodyEvalProbe.count
            let compactLiveDotLeaves = FrameLeafProbe.liveDotBodies

            XCTAssertEqual(compactInvalidations, 0, "\(visualizer.rawValue) steady compact recording invalidated HUDModel")
            XCTAssertEqual(compactBodyEvals, 0, "\(visualizer.rawValue) steady compact recording evaluated HUD body")
            XCTAssertEqual(compactLiveDotLeaves, 0, "\(visualizer.rawValue) steady compact recording evaluated LiveDot SwiftUI leaf")
            XCTAssertGreaterThan(compactEndTime, compactStartTime, "\(visualizer.rawValue) frame time stalled in compact mode")

            hud.showLiveText("Testing fluid live expansion across all five visualizers without frame drops.")
            XCTAssertEqual(hud.debugModel.cardSize, HUDState.liveCard.size)

            // Allow one RunLoop turn + flush for the mode/size transition before measuring steady expanded live ticks.
            pumpRunLoop(seconds: 0.08)

            invalidations = 0
            BodyEvalProbe.reset()
            FrameLeafProbe.reset()

            let liveStartTime = hud.debugFrameModel.time
            pumpRunLoop(seconds: 0.45)
            let liveEndTime = hud.debugFrameModel.time

            let liveInvalidations = invalidations
            let liveBodyEvals = BodyEvalProbe.count
            let liveDotLeaves = FrameLeafProbe.liveDotBodies
            withExtendedLifetime(observer) {}

            let summary = hud.debugFrameStatistics.current()
            let drawBudgetMS: Double = switch visualizer {
            case .stretch, .silk, .haloEdge: 7.0
            case .matrix: 10.0
            case .filament: 18.0
            }

            print(String(
                format: "FLUIDITY-HUD %@: frames=%d draws=%d interval_p50=%.3fms interval_p95=%.3fms tick_p95=%.3fms draw_p95=%.3fms over33=%d",
                visualizer.rawValue,
                summary.frames,
                summary.canvasDraws,
                summary.intervalP50,
                summary.intervalP95,
                summary.tickP95,
                summary.canvasDrawP95,
                summary.over33ms
            ))

            XCTAssertEqual(liveInvalidations, 0, "\(visualizer.rawValue) steady expanded live invalidated HUDModel")
            XCTAssertEqual(liveBodyEvals, 0, "\(visualizer.rawValue) steady expanded live evaluated HUD body")
            XCTAssertEqual(liveDotLeaves, 0, "\(visualizer.rawValue) steady expanded live evaluated LiveDot SwiftUI leaf")
            XCTAssertGreaterThanOrEqual(summary.frames, 25, "\(visualizer.rawValue) produced too few ticks: \(summary.frames)")
            XCTAssertGreaterThanOrEqual(summary.canvasDraws, 15, "\(visualizer.rawValue) produced too few layer draws: \(summary.canvasDraws)")
            XCTAssertLessThanOrEqual(summary.intervalP50, 20.0, "\(visualizer.rawValue) interval_p50 exceeded 20 ms: \(summary.intervalP50)")
            XCTAssertLessThanOrEqual(summary.intervalP95, 32.0, "\(visualizer.rawValue) interval_p95 exceeded 32 ms: \(summary.intervalP95)")
            XCTAssertLessThanOrEqual(summary.tickP95, 4.0, "\(visualizer.rawValue) tick_p95 exceeded 4 ms: \(summary.tickP95)")
            XCTAssertLessThanOrEqual(summary.over33ms, 2, "\(visualizer.rawValue) exceeded over33 budget: \(summary.over33ms)")
            XCTAssertLessThanOrEqual(summary.canvasDrawP95, drawBudgetMS, "\(visualizer.rawValue) draw_p95 exceeded \(drawBudgetMS) ms: \(summary.canvasDrawP95)")
            XCTAssertGreaterThan(liveEndTime, liveStartTime, "\(visualizer.rawValue) frame time stalled in expanded live mode")
            XCTAssertGreaterThan(hud.debugFrameModel.history.max() ?? 0, 0.2, "\(visualizer.rawValue) live history remained flat")

            hud.hide()
        }
    }

    func testHUDPreviewDemoFluidityAndImmediateDismissalStopsRenderLoop() {
        let hud = HUD(offscreen: true)
        defer { hud.hide() }

        for visualizer in [HUDVisualizer.stretch, .silk] {
            hud.previewVisualizer(visualizer)
            pumpRunLoop(seconds: 0.08)

            var invalidations = 0
            let observer = hud.debugModel.objectWillChange.sink { _ in invalidations += 1 }
            let startTicks = hud.debugTickCount
            pumpRunLoop(seconds: 0.25)
            withExtendedLifetime(observer) {}

            let deltaTicks = hud.debugTickCount - startTicks
            XCTAssertGreaterThanOrEqual(deltaTicks, 8, "\(visualizer.rawValue) preview advanced only \(deltaTicks) ticks")
            XCTAssertEqual(invalidations, 0, "\(visualizer.rawValue) steady preview invalidated HUDModel")

            let history = hud.debugFrameModel.history
            XCTAssertGreaterThan(history.max() ?? 0, 0.15, "\(visualizer.rawValue) preview history stayed flat")
            XCTAssertGreaterThan(Set(history.map { Int(($0 * 1000).rounded()) }).count, 5, "\(visualizer.rawValue) preview lacked dynamic variation")

            hud.dismissPreview()
            XCTAssertFalse(hud.isPreviewing)
            XCTAssertFalse(hud.isVisible)

            // Wait for the smooth 0.22 s exit fade / escape handler to complete cleanly.
            pumpRunLoop(seconds: 0.40)
            XCTAssertFalse(hud.debugRenderLoop.isRunning, "\(visualizer.rawValue) preview render loop stayed active after exit")
            XCTAssertFalse(hud.debugPanelVisible, "\(visualizer.rawValue) panel stayed visible after preview exit")

            let ticksAfterSettled = hud.debugTickCount
            pumpRunLoop(seconds: 0.25)
            XCTAssertEqual(hud.debugTickCount, ticksAfterSettled, "\(visualizer.rawValue) preview leaked ticks after exit settled")
        }

        hud.previewMaterial(.glass)
        let materialStartTicks = hud.debugTickCount
        pumpRunLoop(seconds: 0.25)
        XCTAssertGreaterThanOrEqual(hud.debugTickCount - materialStartTicks, 8)
        XCTAssertTrue(hud.isPreviewing)

        hud.dismissPreview()
        XCTAssertFalse(hud.isPreviewing)
        XCTAssertFalse(hud.isVisible)

        pumpRunLoop(seconds: 0.40)
        XCTAssertFalse(hud.debugRenderLoop.isRunning, "material preview render loop stayed active after exit")
        XCTAssertFalse(hud.debugPanelVisible, "material panel stayed visible after preview exit")

        let materialDismissTicks = hud.debugTickCount
        pumpRunLoop(seconds: 0.25)
        XCTAssertEqual(hud.debugTickCount, materialDismissTicks, "material preview leaked ticks after exit settled")
    }

    func testHUDActionFeedbackTransitionAndSettleWithoutRunawayTicks() {
        let hud = HUD(offscreen: true)
        defer { hud.hide() }

        hud.showTranscript(text: "Fluid feedback check.", delivery: .pasted, elapsed: "0:03")
        for _ in 0..<45 {
            hud.debugAdvanceAppearance(by: 1.0 / 60.0)
        }
        XCTAssertTrue(hud.debugAppearanceAtRest, "transcript appearance did not settle to rest")
        hud.debugStopRenderLoop()
        XCTAssertFalse(hud.debugRenderLoop.isRunning)
        let ticksBeforeFeedback = hud.debugTickCount

        hud.showActionFeedback(for: .copy, outcome: .copied)
        let firstID = hud.debugModel.actionFeedback?.id
        XCTAssertEqual(hud.debugModel.actionFeedback?.action, .copy)
        XCTAssertEqual(hud.debugModel.actionFeedback?.outcome, .copied)

        hud.showActionFeedback(for: .copy, outcome: .copied)
        let secondID = hud.debugModel.actionFeedback?.id
        XCTAssertNotNil(firstID)
        XCTAssertNotNil(secondID)
        XCTAssertNotEqual(firstID, secondID)

        hud.showActionFeedback(for: .paste, outcome: .pasted)
        XCTAssertEqual(hud.debugModel.actionFeedback?.action, .paste)
        XCTAssertEqual(hud.debugModel.actionFeedback?.outcome, .pasted)

        hud.showActionFeedback(for: .paste, outcome: .fallbackCopied)
        XCTAssertEqual(hud.debugModel.actionFeedback?.action, .paste)
        XCTAssertEqual(hud.debugModel.actionFeedback?.outcome, .fallbackCopied)

        pumpRunLoop(seconds: 0.15)
        XCTAssertFalse(hud.debugRenderLoop.isRunning, "action feedback unexpectedly woke HUD render loop")
        XCTAssertEqual(hud.debugTickCount, ticksBeforeFeedback, "action feedback triggered unexpected HUD ticks")

        hud.showActionFeedback(for: .history, outcome: .triggered)
        XCTAssertEqual(hud.debugModel.actionFeedback?.outcome, .triggered)
        let deadline = CFAbsoluteTimeGetCurrent() + 0.80
        while hud.debugModel.actionFeedback != nil && CFAbsoluteTimeGetCurrent() < deadline {
            pumpRunLoop(seconds: 0.05)
        }
        XCTAssertNil(hud.debugModel.actionFeedback, "short .triggered feedback did not auto-clear")

        hud.showActionFeedback(for: .copy, outcome: .copied)
        XCTAssertNotNil(hud.debugModel.actionFeedback)
        hud.hide()
        XCTAssertNil(hud.debugModel.actionFeedback)
    }

    func testSettingsAppearanceSwatchAnimationFluidityAcrossAllVisualizers() {
        let driver = VisualizerSwatchDriver()
        let window = VisibleOffscreenWindow(size: CGSize(width: 120, height: 60), styleMask: [.borderless])
        let swatchView = LiveVisualizerNSView(frame: NSRect(x: 0, y: 0, width: 64, height: 22))
        window.contentView = swatchView
        window.orderFrontRegardless()

        let collector = DrawCollector()
        driver.frameSink.onLayerDraw = { now, durationMS in
            collector.record(now: now, durationMS: durationMS)
        }

        var driverClosed = false
        defer {
            driver.stop()
            if !driverClosed {
                window.close()
            }
        }

        for visualizer in HUDVisualizer.allCases {
            collector.reset()
            var invalidations = 0
            let observer = driver.objectWillChange.sink { _ in invalidations += 1 }

            driver.configure(activeVisualizer: visualizer, isRunning: true, headless: false)
            driver.attach(hostView: swatchView)
            swatchView.bind(sink: driver.frameSink) {
                driver.currentFrame(visualizer: visualizer, material: .black)
            }
            let startTime = driver.time

            pumpRunLoop(seconds: 0.35)
            withExtendedLifetime(observer) {}

            let samples = collector.snapshot()
            var intervalsMS: [Double] = []
            if samples.count > 1 {
                intervalsMS.reserveCapacity(samples.count - 1)
                for idx in 1..<samples.count {
                    intervalsMS.append((samples[idx].timestamp - samples[idx - 1].timestamp) * 1000)
                }
            }
            let drawDurations = samples.map(\.durationMS)
            let intervalP95 = Self.percentile95(intervalsMS)
            let drawP95 = Self.percentile95(drawDurations)
            let over33 = intervalsMS.filter { $0 > 33.0 }.count

            print(String(
                format: "FLUIDITY-SWATCH %@: draws=%d interval_p95=%.3fms draw_p95=%.3fms over33=%d",
                visualizer.rawValue,
                samples.count,
                intervalP95,
                drawP95,
                over33
            ))

            XCTAssertEqual(invalidations, 0, "\(visualizer.rawValue) swatch driver emitted ObservableObject invalidations")
            XCTAssertGreaterThan(driver.time, startTime, "\(visualizer.rawValue) swatch time did not advance")
            XCTAssertGreaterThanOrEqual(samples.count, 12, "\(visualizer.rawValue) swatch produced only \(samples.count) draws")
            XCTAssertLessThanOrEqual(drawP95, 8.0, "\(visualizer.rawValue) swatch draw_p95 exceeded 8 ms: \(drawP95)")
            XCTAssertLessThanOrEqual(intervalP95, 30.0, "\(visualizer.rawValue) swatch interval_p95 exceeded 30 ms: \(intervalP95)")
            XCTAssertLessThanOrEqual(over33, 2, "\(visualizer.rawValue) swatch over33 count exceeded 2: \(over33)")
        }

        window.close()
        driverClosed = true
        pumpRunLoop(seconds: 0.05)
        collector.reset()
        pumpRunLoop(seconds: 0.20)

        XCTAssertEqual(driver.debugActiveClockCount, 0, "swatch clock remained active after window closed")
        XCTAssertEqual(collector.snapshot().count, 0, "swatch layer continued drawing after window closed")
    }

    func testSettingsPageSwitchingFluidityAndTabContainerReuse() {
        var config = DotConfig()
        config.assistant.rewrite.enabled = true
        let store = ConfigStore(config: config)
        let providers = MenuBuilder.providerRows(config: config) { _ in false }

        func makeView(tab: Int) -> AnyView {
            AnyView(
                SettingsView(
                    store: store,
                    providers: providers,
                    tab: tab,
                    onChange: {},
                    onSetAPIKey: { _, _ in nil },
                    onChangeShortcut: {}
                )
                .environment(\.settingsHeadless, true)
                .environment(\.assistantKeyedProviders, [])
            )
        }

        let size = CGSize(width: 820, height: 640)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        let host = NSHostingView(rootView: makeView(tab: 0))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }

        func collectCachedContainers(in root: NSView, result: inout [NSView]) {
            let typeName = String(reflecting: type(of: root))
            if typeName.contains("SettingsCachedTab") && typeName.hasSuffix(".ContainerView") {
                result.append(root)
            }
            for subview in root.subviews {
                collectCachedContainers(in: subview, result: &result)
            }
        }

        func switchTo(tab: Int) -> Double {
            let started = CACurrentMediaTime()
            host.rootView = makeView(tab: tab)
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            return (CACurrentMediaTime() - started) * 1000
        }

        // Warm all 6 sidebar pages once before measuring warm switching fluidity.
        for tab in [0, 1, 2, 3, 5, 4] {
            _ = switchTo(tab: tab)
        }

        for tab in [0, 1, 2, 3, 5, 4, 3, 0] {
            let switchMS = switchTo(tab: tab)
            print(String(format: "FLUIDITY-SETTINGS-SWITCH tab=%d: %.3fms", tab, switchMS))
            XCTAssertLessThan(switchMS, 150.0, "warm switch to tab \(tab) took \(switchMS) ms")

            var containers: [NSView] = []
            collectCachedContainers(in: host, result: &containers)
            XCTAssertLessThanOrEqual(containers.count, 5, "tab \(tab) leaked duplicate cached containers: \(containers.count)")
            let visibleCount = containers.filter { !$0.isHidden }.count
            XCTAssertLessThanOrEqual(visibleCount, 1, "tab \(tab) left \(visibleCount) cached containers visible simultaneously")
        }
    }

    func testStretchAndSilkMotionContinuityAndMonotonicResponse() {
        var previousStretch = -1.0
        var previousSilkThickness = -1.0
        var previousSilkCentre = -1.0

        for step in 0...50 {
            let level = Double(step) / 50.0
            let stretchValue = HUDWaveform.Stretch.responseCurve(level)
            let thicknessValue = HUDWaveform.Silk.thicknessEnergy(level)
            let centreValue = HUDWaveform.Silk.centreEnergy(level)

            XCTAssertTrue(stretchValue.isFinite)
            XCTAssertGreaterThanOrEqual(stretchValue, 0)
            XCTAssertLessThanOrEqual(stretchValue, 1)
            XCTAssertGreaterThanOrEqual(stretchValue, previousStretch)

            XCTAssertTrue(thicknessValue.isFinite)
            XCTAssertGreaterThanOrEqual(thicknessValue, HUDWaveform.Silk.silentFloor)
            XCTAssertLessThanOrEqual(thicknessValue, 1)
            XCTAssertGreaterThanOrEqual(thicknessValue, previousSilkThickness)

            XCTAssertTrue(centreValue.isFinite)
            XCTAssertGreaterThanOrEqual(centreValue, HUDWaveform.Silk.silentFloor)
            XCTAssertLessThanOrEqual(centreValue, 1)
            XCTAssertGreaterThanOrEqual(centreValue, previousSilkCentre)

            previousStretch = stretchValue
            previousSilkThickness = thicknessValue
            previousSilkCentre = centreValue
        }

        XCTAssertEqual(HUDWaveform.Stretch.responseCurve(0), 0, accuracy: 1e-12)
        XCTAssertEqual(HUDWaveform.Stretch.responseCurve(1), 1, accuracy: 1e-12)
        XCTAssertEqual(HUDWaveform.Silk.thicknessEnergy(1), 1, accuracy: 1e-12)
        XCTAssertEqual(HUDWaveform.Silk.centreEnergy(1), 1, accuracy: 1e-12)

        let canvasSize = CGSize(width: 520, height: 44)
        let silkReach = HUDWaveform.Silk.reach(forHeight: canvasSize.height)
        var history = [Double](repeating: 0, count: Waveform.historyLength)
        var previousBarHeights: [Int: CGFloat] = [:]
        var previousSilkExcursion: CGFloat?
        var maxBarJump: CGFloat = 0
        var maxSilkJump: CGFloat = 0

        for tick in 0..<60 {
            let phase = Double(tick) / 59.0
            let speechLevel = 0.90 * sin(phase * .pi)
            history.removeFirst()
            history.append(speechLevel)

            let time = 3.0 + Double(tick) / Waveform.sampleRate
            let bars = HUDWaveform.Stretch.bars(
                history: history,
                phase: 0,
                time: time,
                reveal: 1,
                canvas: canvasSize.width,
                reduceMotion: false
            )
            XCTAssertFalse(bars.isEmpty)

            var currentHeights: [Int: CGFloat] = [:]
            for bar in bars {
                XCTAssertTrue(bar.centre.isFinite)
                XCTAssertTrue(bar.width.isFinite)
                XCTAssertTrue(bar.height.isFinite)
                currentHeights[bar.window] = bar.height
                if let prior = previousBarHeights[bar.window], !bar.isLive {
                    maxBarJump = max(maxBarJump, abs(bar.height - prior))
                }
            }
            previousBarHeights = currentHeights

            let taper = HUDWaveform.Silk.edge(0.5)
            let centre = HUDWaveform.Silk.centreOffset(
                ribbon: 0,
                u: 0.5,
                energy: speechLevel,
                reach: silkReach,
                time: time,
                taper: taper
            )
            let half = HUDWaveform.Silk.halfThickness(
                ribbon: 0,
                u: 0.5,
                energy: speechLevel,
                reach: silkReach,
                time: time,
                taper: taper
            )
            XCTAssertTrue(centre.isFinite)
            XCTAssertTrue(half.isFinite)
            let excursion = abs(centre) + half
            XCTAssertLessThanOrEqual(excursion, silkReach + 0.01)
            if let prior = previousSilkExcursion {
                maxSilkJump = max(maxSilkJump, abs(excursion - prior))
            }
            previousSilkExcursion = excursion
        }

        XCTAssertLessThan(maxBarJump, 8.0, "Stretch bar height jumped sharply across closed windows: \(maxBarJump)")
        XCTAssertLessThan(maxSilkJump, 4.0, "Silk excursion jumped sharply between consecutive frames: \(maxSilkJump)")
    }

    private func findViews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var result: [T] = []
        if let typed = root as? T {
            result.append(typed)
        }
        for subview in root.subviews {
            result.append(contentsOf: findViews(of: type, in: subview))
        }
        return result
    }

    private func firstVisiblePageScrollView(in root: NSView) -> DotPageScrollView? {
        for view in findViews(of: DotPageScrollView.self, in: root) {
            var cursor: NSView? = view
            var visible = true
            while let current = cursor {
                if current.isHidden {
                    visible = false
                    break
                }
                cursor = current.superview
            }
            if visible {
                return view
            }
        }
        return nil
    }

    func testSettingsScrollFramePacingZeroBodyChurnAndCleanLiveScroll() {
        var config = DotConfig()
        config.assistant.rewrite.enabled = true
        let store = ConfigStore(config: config)
        let providers = MenuBuilder.providerRows(config: config) { _ in false }

        func makeView(tab: Int) -> AnyView {
            AnyView(
                SettingsView(
                    store: store,
                    providers: providers,
                    tab: tab,
                    onChange: {},
                    onSetAPIKey: { _, _ in nil },
                    onChangeShortcut: {}
                )
                .environment(\.settingsHeadless, true)
                .environment(\.assistantKeyedProviders, [])
            )
        }

        let size = CGSize(width: 820, height: 600)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        let host = NSHostingView(rootView: makeView(tab: 0))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }

        for tab in [0, 1, 2, 3, 5, 4] {
            host.rootView = makeView(tab: tab)
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()

            guard let scrollView = firstVisiblePageScrollView(in: host) else {
                XCTFail("tab \(tab) did not expose a visible DotPageScrollView")
                return
            }
            XCTAssertFalse(scrollView.mouseDownCanMoveWindow, "tab \(tab) scroll view allows window background drag")
            XCTAssertEqual(scrollView.horizontalScrollElasticity, .none, "tab \(tab) allows horizontal bounce")

            let pocketViews = findViews(of: NSView.self, in: scrollView).filter {
                String(reflecting: type(of: $0)).contains("ScrollPocket")
            }
            XCTAssertTrue(pocketViews.isEmpty, "tab \(tab) unexpectedly created NSScrollPocket")

            let documentFrameChanges = OSAllocatedUnfairLock<Int>(initialState: 0)
            let token: NSObjectProtocol? = scrollView.documentView.map { doc in
                doc.postsFrameChangedNotifications = true
                return NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: doc,
                    queue: .main
                ) { _ in
                    documentFrameChanges.withLock { $0 += 1 }
                }
            }
            defer {
                if let token { NotificationCenter.default.removeObserver(token) }
            }

            let docH = scrollView.documentView?.frame.height ?? 0
            let clipH = scrollView.contentView.bounds.height
            let maxY = max(0, docH - clipH)
            var stepTimesMS: [Double] = []
            stepTimesMS.reserveCapacity(60)

            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            XCTAssertTrue(DotScrollInteraction.isScrolling, "tab \(tab) live scroll did not engage scroll interaction gate")

            for step in 0..<60 {
                let progress = step < 30 ? Double(step) / 29.0 : Double(59 - step) / 29.0
                let targetY = maxY * progress
                let started = CACurrentMediaTime()
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                host.layoutSubtreeIfNeeded()
                CATransaction.flush()
                stepTimesMS.append((CACurrentMediaTime() - started) * 1000)
            }

            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            XCTAssertFalse(DotScrollInteraction.isLiveScrolling, "tab \(tab) live scroll remained stuck active")

            let p95 = Self.percentile95(stepTimesMS)
            let over33 = stepTimesMS.filter { $0 > 33.0 }.count
            print(String(format: "FLUIDITY-SCROLL tab=%d: maxY=%.1f step_p95=%.3fms over33=%d", tab, maxY, p95, over33))
            XCTAssertLessThan(p95, 8.0, "tab \(tab) scroll step p95 exceeded 8 ms: \(p95)")
            XCTAssertEqual(over33, 0, "tab \(tab) had \(over33) scroll steps over 33 ms")
            XCTAssertEqual(documentFrameChanges.withLock { $0 }, 0, "tab \(tab) churned document frame during scroll")
        }

        // The Appearance swatch keeps animating through a live scroll (owner, 2026-11-25:
        // a demo that freezes while the page scrolls and resumes on release is a defect).
        let driver = VisualizerSwatchDriver()
        let swatchWindow = VisibleOffscreenWindow(size: CGSize(width: 120, height: 60), styleMask: [.borderless])
        let swatchView = LiveVisualizerNSView(frame: NSRect(x: 0, y: 0, width: 64, height: 22))
        swatchWindow.contentView = swatchView
        swatchWindow.orderFrontRegardless()
        let collector = DrawCollector()
        driver.frameSink.onLayerDraw = { now, durationMS in
            collector.record(now: now, durationMS: durationMS)
        }
        driver.configure(activeVisualizer: .filament, isRunning: true, headless: false)
        driver.attach(hostView: swatchView)
        swatchView.bind(sink: driver.frameSink) {
            driver.currentFrame(visualizer: .filament, material: .black)
        }
        defer {
            driver.stop()
            swatchWindow.close()
        }

        pumpRunLoop(seconds: 0.12)
        DotScrollInteraction.beginLiveScroll()
        collector.reset()
        pumpRunLoop(seconds: 0.3)
        XCTAssertGreaterThan(collector.snapshot().count, 6, "swatch froze during an active scroll")

        DotScrollInteraction.endLiveScroll()
        collector.reset()
        pumpRunLoop(seconds: 0.18)
        XCTAssertGreaterThan(collector.snapshot().count, 3, "swatch stopped after the scroll ended")
    }

    func testScrollElasticityMatchesOverflowAndDynamicHeightChanges() throws {
        let hostHeight: CGFloat = 500
        var currentHeight: CGFloat = 1400

        struct DynamicTestView: View {
            let height: CGFloat
            var body: some View {
                Color.clear.frame(height: height)
            }
        }

        let scrollHost = DotPageScrollHostView(rootView: AnyView(DynamicTestView(height: currentHeight)))
        let window = OffscreenWindow(size: CGSize(width: 820, height: hostHeight), styleMask: [.borderless])
        scrollHost.frame = NSRect(origin: .zero, size: CGSize(width: 820, height: hostHeight))
        window.contentView = scrollHost
        window.orderFrontRegardless()
        scrollHost.layoutSubtreeIfNeeded()
        defer { window.close() }

        let pageScroll = scrollHost.scrollView
        XCTAssertEqual(pageScroll.verticalScrollElasticity, .allowed, "tall overflowing page must allow vertical bounce")
        XCTAssertEqual(pageScroll.horizontalScrollElasticity, .none)
        XCTAssertFalse(pageScroll.mouseDownCanMoveWindow)
        XCTAssertGreaterThan(scrollHost.bottomFadeView.debugOpacity, 0.9)

        let maxY = (pageScroll.documentView?.frame.height ?? 0) - pageScroll.contentView.bounds.height
        pageScroll.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        pageScroll.reflectScrolledClipView(pageScroll.contentView)
        scrollHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrollHost.bottomFadeView.debugOpacity, 0, accuracy: 0.01, "bottom fade remained sticky at bottom limit")

        pageScroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        pageScroll.reflectScrolledClipView(pageScroll.contentView)

        // Grow content taller: preserve current scroll origin and elasticity.
        currentHeight = 1700
        scrollHost.hostingView.rootView = AnyView(DynamicTestView(height: currentHeight))
        scrollHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(pageScroll.contentView.bounds.origin.y, 200, accuracy: 0.5)
        XCTAssertEqual(pageScroll.verticalScrollElasticity, .allowed)

        // Shrink content below viewport: clamp origin back to 0 and disable elasticity.
        currentHeight = 180
        scrollHost.hostingView.rootView = AnyView(DynamicTestView(height: currentHeight))
        scrollHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(pageScroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
        XCTAssertEqual(pageScroll.verticalScrollElasticity, .none, "short page must disable vertical bounce")
        XCTAssertEqual(scrollHost.bottomFadeView.debugOpacity, 0, accuracy: 0.01)

        // Verify short non-overflowing HistoryView disables vertical bounce too.
        let historyWindow = OffscreenWindow(size: CGSize(width: 620, height: 560), styleMask: [.borderless])
        let historyHost = NSHostingView(
            rootView: HistoryView(
                history: ["Short first entry", "Short second entry"],
                onCopy: { _ in },
                onClear: {},
                onClose: {}
            )
            .environment(\.historyHeadless, true)
        )
        historyHost.frame = NSRect(origin: .zero, size: CGSize(width: 620, height: 560))
        historyWindow.contentView = historyHost
        historyWindow.orderFrontRegardless()
        historyHost.layoutSubtreeIfNeeded()
        pumpRunLoop(seconds: 0.05)
        defer { historyWindow.close() }

        let historyScroll = try XCTUnwrap(findViews(of: NSScrollView.self, in: historyHost).first)
        XCTAssertEqual(historyScroll.verticalScrollElasticity, NSScrollView.Elasticity.none)
    }

    func testBottomFadeUsesPaperColorForEachColorScheme() throws {
        func luminance(_ color: CGColor?) throws -> CGFloat {
            let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let converted = try XCTUnwrap(color?.converted(to: srgb, intent: .defaultIntent, options: nil))
            let c = try XCTUnwrap(converted.components)
            XCTAssertGreaterThanOrEqual(c.count, 3)
            return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        }

        let fade = DotBottomFadeOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: DotBottomFadeOverlayView.fadeHeight))
        fade.setColorScheme(.light)
        let light = try luminance(fade.debugOpaqueColor)
        fade.setColorScheme(.dark)
        let dark = try luminance(fade.debugOpaqueColor)
        XCTAssertGreaterThan(light, 0.8, "light fade is not light paper: \(light)")
        XCTAssertLessThan(dark, 0.25, "dark fade is not dark paper: \(dark)")

        fade.setRemaining(11)
        XCTAssertEqual(fade.debugOpacity, 0.5, accuracy: 0.001)
        fade.setRemaining(0.5)
        XCTAssertEqual(fade.debugOpacity, 0)
        fade.setRemaining(0.6)
        XCTAssertGreaterThan(fade.debugOpacity, 0, "fade did not reappear after reaching zero")
        fade.setRemaining(0.02)
        XCTAssertEqual(fade.debugOpacity, 0, "fade kept a residue at the bottom limit")
        fade.setRemaining(0.4)
        XCTAssertEqual(fade.debugOpacity, 0, "sub-threshold overflow showed a fade")
    }

    func testReleasingPageScrollViewMidScrollBalancesScrollInteraction() {
        weak var released: DotPageScrollView?
        autoreleasepool {
            let scroll = DotPageScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            released = scroll
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            XCTAssertTrue(DotScrollInteraction.isLiveScrolling, "live scroll did not engage")
        }
        XCTAssertNil(released, "scroll view leaked")
        pumpRunLoop(seconds: 0.2)
        XCTAssertFalse(DotScrollInteraction.isLiveScrolling, "released scroll view left a live scroll open")
        XCTAssertFalse(DotScrollInteraction.isScrolling, "scroll gate did not settle after release")
    }

    func testHistoryViewLargeListScrollFluidityAndIsolatedHover() throws {
        let entries = (0..<250).map { "Transcript line \($0): Testing smooth scrolling performance without frame drops." }
        let size = CGSize(width: 620, height: 560)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        let host = NSHostingView(
            rootView: HistoryView(
                history: entries,
                onCopy: { _ in },
                onClear: {},
                onClose: {}
            )
            .environment(\.historyHeadless, true)
        )
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        pumpRunLoop(seconds: 0.05)
        defer { window.close() }

        let table = try XCTUnwrap(findViews(of: HistoryTranscriptTableView.self, in: host).first)
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertEqual(scrollView.verticalScrollElasticity, .allowed)
        XCTAssertEqual(scrollView.horizontalScrollElasticity, .none)

        let docH = scrollView.documentView?.frame.height ?? 0
        let clipH = scrollView.contentView.bounds.height
        let maxY = max(0, docH - clipH)
        var stepTimesMS: [Double] = []
        var wallTimesMS: [Double] = []
        stepTimesMS.reserveCapacity(60)
        wallTimesMS.reserveCapacity(60)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        XCTAssertTrue(DotScrollInteraction.isScrolling)

        XCTAssertGreaterThan(maxY, 1000, "the History list must overflow to be a scroll benchmark")
        var maxTravel: CGFloat = 0
        for step in 0..<60 {
            let progress = step < 30 ? Double(step) / 29.0 : Double(59 - step) / 29.0
            let targetY = maxY * progress
            let started = CACurrentMediaTime()
            let startedCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            // Thread CPU time, so preemption by other processes on a loaded
            // machine does not count as work done by the scroll step.
            stepTimesMS.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - startedCPU) / 1_000_000)
            wallTimesMS.append((CACurrentMediaTime() - started) * 1000)
            let origin = scrollView.contentView.bounds.origin.y
            XCTAssertEqual(origin, targetY, accuracy: 1, "step \(step) did not scroll")
            maxTravel = max(maxTravel, origin)
        }

        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        XCTAssertFalse(DotScrollInteraction.isLiveScrolling)
        XCTAssertEqual(maxTravel, maxY, accuracy: 1)

        let p95 = Self.percentile95(stepTimesMS)
        let over33 = stepTimesMS.filter { $0 > 33.0 }.count
        print(String(format: "FLUIDITY-HISTORY-SCROLL: docH=%.1f step_cpu_p95=%.3fms over33=%d wall_p95=%.3fms",
                     docH, p95, over33, Self.percentile95(wallTimesMS)))
        XCTAssertLessThan(p95, 15.0, "History scroll p95 exceeded 15 ms: \(p95)")
        XCTAssertEqual(over33, 0, "History scroll had \(over33) steps over 33 ms")
    }

    func testDotPaperCachesRasterLayerAcrossScrollFrames() {
        DotPaperNSView.debugResetRenderCount()

        struct PaperTestView: View {
            let scheme: ColorScheme
            var body: some View {
                DotPaper().environment(\.colorScheme, scheme)
            }
        }

        let size = CGSize(width: 820, height: 600)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        let host = NSHostingView(rootView: PaperTestView(scheme: .light))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.close() }

        XCTAssertEqual(DotPaperNSView.debugRenderCount, 1, "DotPaper should render once for initial layout")

        let hit = window.contentView?.hitTest(NSPoint(x: 410, y: 560))
        XCTAssertFalse(hit is DotPaperNSView, "paper backing must not swallow clicks")
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit?.mouseDownCanMoveWindow ?? false, "a click on bare paper must still drag the window")

        for _ in 0..<60 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        XCTAssertEqual(DotPaperNSView.debugRenderCount, 1, "DotPaper re-rendered unexpectedly across idle/scroll cycles")

        host.rootView = PaperTestView(scheme: .dark)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertEqual(DotPaperNSView.debugRenderCount, 2, "DotPaper did not re-render on appearance change")

        let resized = CGSize(width: 820, height: 640)
        host.frame = NSRect(origin: .zero, size: resized)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertEqual(DotPaperNSView.debugRenderCount, 3, "DotPaper did not re-render on size change")
    }

    func testAllFiveVisualizersBroadDynamicRangeAndFilamentThermalPhysics() throws {
        var stretchHeights: [CGFloat] = []
        var filamentHeats: [Double] = []
        var silkThicknesses: [Double] = []
        var matrixDisplays: [Double] = []
        var haloRadii: [CGFloat] = []
        var haloKicks: [Double] = []

        for decibels in [-40.0, -30.0, -20.0, -10.0, 0.0] {
            let meter = VoiceMeter()
            meter.setCalibration(nil)
            var history: [Double] = []
            var spectrum: [AudioSpectrumFrame] = []
            for step in 0...Int(3.5 * Waveform.sampleRate) {
                meter.push(decibels: decibels, now: Double(step) / Waveform.sampleRate)
                meter.copyOrderedHistory(into: &history)
                let shape = meter.shape
                spectrum.append(AudioSpectrumFrame(bands: (shape, shape, shape, shape, shape)))
            }
            let level = try XCTUnwrap(history.last)
            let stretch = HUDWaveform.Stretch.height(HUDWaveform.Stretch.bars(
                history: history,
                phase: 0,
                time: 4.0,
                reveal: 1,
                canvas: 520,
                reduceMotion: true
            ).first?.value ?? level)
            stretchHeights.append(stretch)

            let heat = HUDWaveform.Filament.heatProfile(
                history: history,
                spectrum: spectrum,
                reveal: 1,
                reduceMotion: false
            ).max() ?? 0
            filamentHeats.append(heat)

            silkThicknesses.append(HUDWaveform.Silk.thicknessEnergy(level))
            matrixDisplays.append(pow(level, HUDWaveform.MatrixLattice.displayExponent))
            haloRadii.append(HUDWaveform.Halo.radius(ring: 0, width: 102, energy: level))
            haloKicks.append(HUDWaveform.Halo.kickEnergy(ring: 0, offset: 0, history: history))
        }

        for idx in 1..<5 {
            XCTAssertGreaterThan(stretchHeights[idx], stretchHeights[idx - 1])
            XCTAssertGreaterThan(filamentHeats[idx], filamentHeats[idx - 1])
            XCTAssertGreaterThan(silkThicknesses[idx], silkThicknesses[idx - 1])
            XCTAssertGreaterThan(matrixDisplays[idx], matrixDisplays[idx - 1])
            XCTAssertGreaterThan(haloRadii[idx], haloRadii[idx - 1])
            XCTAssertGreaterThan(haloKicks[idx], haloKicks[idx - 1])
        }

        // Broad dynamic range: medium voice (-30 / -20 dBFS) stays clearly below saturation.
        XCTAssertLessThan(stretchHeights[1], 10.0)
        XCTAssertGreaterThan(stretchHeights[4], 20.0)
        XCTAssertLessThan(filamentHeats[1], 0.52)
        XCTAssertLessThanOrEqual(filamentHeats[2], 0.75)
        XCTAssertGreaterThanOrEqual(filamentHeats[4], 0.97)
        XCTAssertLessThan(silkThicknesses[2], 0.55)
        XCTAssertGreaterThan(silkThicknesses[4], 0.85)
        XCTAssertLessThan(matrixDisplays[1], 0.35)
        XCTAssertLessThanOrEqual(matrixDisplays[2], 0.55)
        XCTAssertGreaterThan(matrixDisplays[4], 0.85)
        XCTAssertLessThan(haloKicks[2], 0.80)
        XCTAssertGreaterThanOrEqual(haloKicks[4], 0.97)

        // Filament blackbody low/mid red-hot glow and core gating at -20 vs 0 dBFS.
        let redGlow = HUDWaveform.Filament.components(heat: filamentHeats[1], material: .black)
        XCTAssertGreaterThan(redGlow.red, 0.70, "cherry red-hot stop lacked red luminance: \(redGlow)")
        XCTAssertGreaterThan(redGlow.red, redGlow.green * 2.0, "cherry red-hot stop turned orange/yellow too early: \(redGlow)")

        let midProfile = [Double](repeating: filamentHeats[2], count: HUDWaveform.Filament.heatSamples)
        let peakProfile = [Double](repeating: filamentHeats[4], count: HUDWaveform.Filament.heatSamples)
        let shape = HUDWaveform.Filament.geometry(for: CGSize(width: 102, height: 26))
        XCTAssertTrue(HUDWaveform.Filament.corePieces(HUDWaveform.Filament.coil(
            in: shape, heat: midProfile, time: 1.0, reduceMotion: true
        )).isEmpty, "white-hot core ignited prematurely at -20 dBFS")
        XCTAssertFalse(HUDWaveform.Filament.corePieces(HUDWaveform.Filament.coil(
            in: shape, heat: peakProfile, time: 1.0, reduceMotion: true
        )).isEmpty, "white-hot core missing at 0 dBFS peak")
    }
}
