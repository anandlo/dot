import AppKit
import Foundation

/// The display link an NSView hands out, as seen by the render loop.
///
/// The view's real link conforms. Tests hand in a small recorder so backend
/// choice and screen changes can be proved without putting a window on screen.
protocol HUDRenderLinking: AnyObject {
    var targetTimestamp: CFTimeInterval { get }
    var preferredFrameRateRange: CAFrameRateRange { get set }
    func add(to runLoop: RunLoop, forMode: RunLoop.Mode)
    func invalidate()
}

extension CADisplayLink: HUDRenderLinking {}

/// The target of the render loop's timer.
///
/// The timer retains its target, not the loop, so a loop can go away without
/// leaving a timer that keeps a dead object alive. The next fire of a timer
/// whose loop is gone invalidates itself.
@MainActor
private final class HUDRenderLoopTarget: NSObject {
    weak var loop: HUDRenderLoop?

    @objc func fire(_ timer: Timer) {
        guard let loop else {
            timer.invalidate()
            return
        }
        loop.fire(at: CACurrentMediaTime())
    }

    @objc func linkFired(_ link: CADisplayLink) {
        guard let loop else {
            link.invalidate()
            return
        }
        loop.fire(at: link.targetTimestamp)
    }
}

/// The frame clock of the HUD.
///
/// An on-screen card is driven by the view's display link, so its frames land
/// with the display instead of on a timer that drifts against it. A card with
/// no screen, the offscreen test HUD and a presentation whose link never
/// rendered use the timer in the common modes: the card cannot depend on a
/// display to become visible.
@MainActor
final class HUDRenderLoop {
    /// Which clock is driving the card.
    enum Backend: String, Equatable {
        case timer
        case displayLink
    }

    /// The interval of the timer backend.
    static let interval: TimeInterval = 1.0 / 60.0

    private let target = HUDRenderLoopTarget()
    private var timer: Timer?
    private var link: HUDRenderLinking?
    private weak var linkView: NSView?
    private var linkScreenID: Int?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var resumesOnWake = false
    private var interval = HUDRenderLoop.interval
    private var handler: (() -> Void)?
    private var timedHandler: ((CFTimeInterval) -> Void)?

    /// Test seam for the view's link. The app uses the real AppKit factory.
    var linkFactory: ((NSView, AnyObject, Selector) -> HUDRenderLinking?)? = {
        view, target, selector in
        view.displayLink(target: target, selector: selector)
    }

    /// The center that reports display sleep and wake. AppKit posts both only on
    /// the workspace center. Tests use their own.
    var notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    /// The view and screen to resume on after a wake.
    var wakeProvider: (() -> (NSView, Int?)?)?

    private(set) var activeBackend: Backend = .timer

    /// How many clocks are installed. A presentation must have exactly one.
    var activeClockCount: Int {
        (timer?.isValid == true ? 1 : 0) + (link != nil ? 1 : 0)
    }

    init() {
        target.loop = self
    }

    /// Whether the loop is installed on a run loop.
    var isRunning: Bool { timer?.isValid == true || link != nil }

    /// Which backend a card with this visibility would use.
    static func chooseBackend(offscreen: Bool, hasScreen: Bool) -> Backend {
        offscreen || !hasScreen ? .timer : .displayLink
    }

    /// Starts the timer backend, or does nothing when it already runs.
    ///
    /// - Parameters:
    ///   - interval: the interval between frames, in seconds.
    ///   - handler: the frame callback, on the main thread.
    func start(interval: TimeInterval = HUDRenderLoop.interval, handler: @escaping () -> Void) {
        guard !isRunning else { return }
        self.handler = handler
        self.timedHandler = nil
        self.interval = interval
        installTimer()
    }

    /// Starts the backend chosen for this presentation.
    ///
    /// - Parameters:
    ///   - view: the view whose display link drives an on-screen card.
    ///   - screenID: the identity of the screen the panel is on, when known.
    ///   - offscreen: whether the HUD is kept off every display.
    ///   - interval: the timer fallback's interval.
    ///   - handler: the frame callback, handed the timestamp of the frame.
    func start(
        on view: NSView?,
        screenID: Int?,
        offscreen: Bool,
        interval: TimeInterval = HUDRenderLoop.interval,
        handler: @escaping (CFTimeInterval) -> Void
    ) {
        guard !isRunning else { return }
        self.interval = interval
        self.handler = nil
        self.timedHandler = handler
        installSleepWakeObservers()
        let backend = Self.chooseBackend(offscreen: offscreen, hasScreen: view != nil && screenID != nil)
        if backend == .displayLink, let view, installLink(on: view, screenID: screenID) {
            return
        }
        activeBackend = .timer
        installTimer()
    }

    /// Reattaches a running link when the panel moves to another screen.
    func refresh(on view: NSView?, screenID: Int?) {
        guard activeBackend == .displayLink else { return }
        guard let view, let screenID else {
            fallbackToTimer()
            return
        }
        if linkView === view, linkScreenID == screenID { return }
        if !installLink(on: view, screenID: screenID) { fallbackToTimer() }
    }

    /// Switches this presentation to the timer after a link that never drew.
    func fallbackToTimer() {
        guard activeBackend == .displayLink else { return }
        link?.invalidate()
        link = nil
        linkView = nil
        linkScreenID = nil
        activeBackend = .timer
        guard timer?.isValid != true else { return }
        installTimer()
    }

    /// Stops the loop and releases the frame callback.
    func stop() {
        if let sleepObserver { notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }
        sleepObserver = nil
        wakeObserver = nil
        resumesOnWake = false
        timer?.invalidate()
        timer = nil
        link?.invalidate()
        link = nil
        linkView = nil
        linkScreenID = nil
        activeBackend = .timer
        handler = nil
        timedHandler = nil
    }

    fileprivate func fire(at time: CFTimeInterval) {
        timedHandler?(time)
        handler?()
    }

    private func installSleepWakeObservers() {
        sleepObserver = notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, self.activeBackend == .displayLink else { return }
                self.fallbackToTimer()
                self.resumesOnWake = true
            }
        }
        wakeObserver = notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, self.resumesOnWake else { return }
                self.resumesOnWake = false
                guard let resumed = self.wakeProvider?() else { return }
                self.resumeAfterWake(on: resumed.0, screenID: resumed.1)
            }
        }
    }

    private func resumeAfterWake(on view: NSView?, screenID: Int?) {
        guard isRunning, activeBackend == .timer, let view, screenID != nil else { return }
        _ = installLink(on: view, screenID: screenID)
    }

    private func deactivateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func installTimer() {
        let timer = Timer(
            timeInterval: interval,
            target: target,
            selector: #selector(HUDRenderLoopTarget.fire(_:)),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    private func installLink(on view: NSView, screenID: Int?) -> Bool {
        guard let link = linkFactory?(view, target, #selector(HUDRenderLoopTarget.linkFired(_:)))
        else { return false }
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        deactivateTimer()
        self.link?.invalidate()
        self.link = link
        self.linkView = view
        self.linkScreenID = screenID
        activeBackend = .displayLink
        return true
    }
}
