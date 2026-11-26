import AppKit
import DotCore
import QuartzCore
import SwiftUI

/// Drives the animated visualizer swatch in Settings using a monotonic
/// `CADisplayLink` (`HUDRenderLoop`) instead of wall-clock `TimelineView`.
///
/// Pushes frames directly into `frameSink` for the synchronous `CALayer` without
/// invalidating any SwiftUI views on `SettingsView` or the Appearance page.
@MainActor
final class VisualizerSwatchDriver: ObservableObject {
    /// Where inside the dictation script the swatch demonstration opens.
    static let startOffset: Double = VisualizerTile.stillTime
    /// Maximum frame delta applied per tick so wakeups or window moves never
    /// cause the feed to jump ahead and trigger a reset.
    static let maxFrameDelta: Double = 1.0 / 15.0
    /// Extra history seeded ahead of the opening frame so wide tiles open full.
    private static let seedLeadSeconds: Double = 3.0

    private(set) var history: [Double] = []
    private(set) var spectrumHistory: [AudioSpectrumFrame] = []
    private(set) var phase: Double = 0
    private(set) var time: Double = VisualizerSwatchDriver.startOffset

    let frameSink = VisualizerFrameSink()
    private let renderLoop = HUDRenderLoop()
    private var feed: VisualizerFeed?
    private var lastWrittenSamples = -1
    private var lastTick: CFTimeInterval?
    private var elapsed: Double = 0
    private weak var hostView: NSView?
    private weak var observedWindow: NSWindow?
    private var activeVisualizer: HUDVisualizer?
    private var shouldRun = false
    private var isHeadless = false
    private var isWindowVisible = true
    private var isAppHidden = false
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var appObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var latencyActivity: NSObjectProtocol?

    var debugActiveClockCount: Int {
        renderLoop.activeClockCount
    }

    var debugActiveBackend: HUDRenderLoop.Backend {
        renderLoop.activeBackend
    }

    private var isCountedAsFrameSource = false

    init() {
        renderLoop.wakeProvider = { [weak self] in
            guard let self, let view = self.hostView, let window = view.window else { return nil }
            return (view, Self.screenID(of: window.screen))
        }
        seedInitialState()
    }

    deinit {
        if let latencyActivity {
            ProcessInfo.processInfo.endActivity(latencyActivity)
        }
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func currentFrame(visualizer: HUDVisualizer, material: HUDMaterial) -> VisualizerFrame {
        VisualizerFrame(
            visualizer: visualizer,
            material: material,
            history: history,
            spectrumHistory: spectrumHistory,
            time: time,
            level: 0.68,
            phase: phase,
            pulse: 0.25,
            ceiling: 1,
            reveal: 1,
            reduceMotion: false,
            highlight: true
        )
    }

    func configure(activeVisualizer: HUDVisualizer?, isRunning: Bool, headless: Bool) {
        let visualizerChanged = self.activeVisualizer != activeVisualizer
        self.activeVisualizer = activeVisualizer
        self.shouldRun = isRunning && activeVisualizer != nil
        self.isHeadless = headless

        if headless {
            stopLoop()
            if visualizerChanged {
                seedInitialState()
            }
            return
        }

        installAppObserversIfNeeded()

        if visualizerChanged || feed == nil {
            seedInitialState()
        }

        updateLoopState()
    }

    func attach(hostView: NSView?) {
        self.hostView = hostView
        if observedWindow !== hostView?.window {
            installWindowObservers(for: hostView?.window)
        }
        refreshWindowState()
        updateLoopState()
    }

    func stop() {
        shouldRun = false
        stopLoop()
        removeWindowObservers()
        removeAppObservers()
        hostView = nil
    }

    func debugTick(at now: CFTimeInterval) {
        tick(now: now)
    }

    private func seedInitialState() {
        let seeded = VisualizerFeed.seeded(at: Self.startOffset, leadSeconds: Self.seedLeadSeconds)
        feed = seeded
        elapsed = 0
        lastTick = nil
        lastWrittenSamples = -1
        publish(from: seeded)
    }

    private func tick(now: CFTimeInterval) {
        guard shouldRun, !isHeadless else { return }
        if feed == nil {
            seedInitialState()
        }
        guard let feed else { return }
        let dt = lastTick.map { min(max(now - $0, 0), Self.maxFrameDelta) } ?? 0
        lastTick = now
        elapsed += dt
        feed.advance(to: Self.startOffset + elapsed)
        publish(from: feed)
    }

    private func publish(from feed: VisualizerFeed) {
        let written = feed.meter.writtenSamples
        if written != lastWrittenSamples || history.isEmpty || spectrumHistory.isEmpty {
            lastWrittenSamples = written
            feed.meter.copyOrderedHistory(into: &history)
            feed.spectrum.copyOrderedRing(into: &spectrumHistory)
        }
        let nextPhase = feed.phase
        if phase != nextPhase {
            phase = nextPhase
        }
        let nextTime = feed.time
        if time != nextTime {
            time = nextTime
        }
        if let visualizer = activeVisualizer {
            frameSink.push(currentFrame(visualizer: visualizer, material: .black))
        }
    }

    private func updateLoopState() {
        let canAnimate = shouldRun && !isHeadless && isWindowVisible && !isAppHidden
        guard canAnimate else {
            stopLoop()
            return
        }
        guard !renderLoop.isRunning else { return }
        lastTick = nil
        if !isCountedAsFrameSource {
            isCountedAsFrameSource = true
            FrameDropMonitor.shared.begin("swatch")
        }
        if latencyActivity == nil {
            latencyActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Animate the visualizer swatch"
            )
        }
        let screenID = Self.screenID(of: hostView?.window?.screen)
        renderLoop.start(
            on: hostView,
            screenID: screenID,
            offscreen: false
        ) { [weak self] timestamp in
            self?.tick(now: timestamp)
        }
    }

    private func stopLoop() {
        renderLoop.stop()
        lastTick = nil
        if isCountedAsFrameSource {
            isCountedAsFrameSource = false
            FrameDropMonitor.shared.end("swatch")
        }
        if let latencyActivity {
            ProcessInfo.processInfo.endActivity(latencyActivity)
            self.latencyActivity = nil
        }
    }

    private func refreshWindowState() {
        guard let window = hostView?.window else {
            isWindowVisible = false
            return
        }
        isWindowVisible = window.occlusionState.contains(.visible)
        if renderLoop.isRunning {
            let screenID = Self.screenID(of: window.screen)
            if renderLoop.activeBackend == .displayLink {
                renderLoop.refresh(on: hostView, screenID: screenID)
            } else if screenID != nil {
                stopLoop()
            }
        }
    }

    private func installWindowObservers(for window: NSWindow?) {
        removeWindowObservers()
        observedWindow = window
        guard let window else { return }
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshWindowState()
                    self?.updateLoopState()
                }
            },
            center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshWindowState()
                    self?.updateLoopState()
                }
            },
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isWindowVisible = false
                    self?.stopLoop()
                }
            },
        ]
    }

    private func installAppObserversIfNeeded() {
        guard appObservers.isEmpty else { return }
        isAppHidden = NSApp?.isHidden ?? false
        let center = NotificationCenter.default
        appObservers = [
            center.addObserver(
                forName: NSApplication.didHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isAppHidden = true
                    self?.updateLoopState()
                }
            },
            center.addObserver(
                forName: NSApplication.didUnhideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isAppHidden = false
                    self?.refreshWindowState()
                    self?.updateLoopState()
                }
            },
        ]
    }

    private func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
        observedWindow = nil
    }

    private func removeAppObservers() {
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        appObservers.removeAll()
    }

    private static func screenID(of screen: NSScreen?) -> Int? {
        guard let screen else { return nil }
        return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .intValue
    }
}

/// Zero-size `NSView` anchor providing a window-backed `CADisplayLink` target for
/// `VisualizerSwatchDriver` without invalidating SwiftUI layout.
struct VisualizerDisplayLinkAnchor: NSViewRepresentable {
    let driver: VisualizerSwatchDriver

    final class AnchorView: NSView {
        var onWindowChange: ((NSView?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window == nil ? nil : self)
        }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView(frame: .zero)
        view.onWindowChange = { [weak driver] attachedView in
            driver?.attach(hostView: attachedView)
        }
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.onWindowChange = { [weak driver] attachedView in
            driver?.attach(hostView: attachedView)
        }
        if nsView.window != nil {
            driver.attach(hostView: nsView)
        }
    }
}
