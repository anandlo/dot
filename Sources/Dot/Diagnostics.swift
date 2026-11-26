import AppKit
import DotCore

/// When a change was asked for, as opposed to when it happened.
///
/// The appearance tile is pressed in the settings view and the appearance is
/// applied by the delegate; the only way to say how long a person waited is to
/// carry the instant of the press across to the place that draws.
@MainActor
enum AppearanceTrace {
    /// When the appearance tile was last pressed.
    static var pickAt: CFTimeInterval?
}

/// Watches the main thread for the gaps a person feels.
///
/// Every measurement of the theme change so far has been taken on the work
/// itself - the handler, the forced draw - and all of them are fast. A gap
/// between them is invisible from inside a handler, because a handler cannot
/// run while the thread is blocked. A timer that expects to run five times a
/// second can see it: it records the difference between when it was due and
/// when it was allowed to run.
///
/// It costs one timer and one comparison per tick, and it writes a line only
/// when a frame was actually late.
@MainActor
final class MainThreadHeartbeat {
    private var timer: DispatchSourceTimer?
    private var last = CACurrentMediaTime()
    private var isStarted = false
    private var isAppActive = false
    private var isHUDActive = false
    private var isSleeping = false
    nonisolated(unsafe) private var sleepObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var appObservers: [NSObjectProtocol] = []
    /// The interval the timer asks for, in seconds.
    private let interval: TimeInterval
    /// The gap at which a person notices the app stopped answering, in
    /// milliseconds.
    private let threshold: Double

    init(interval: TimeInterval = 0.05, threshold: Double = 150) {
        self.interval = interval
        self.threshold = threshold
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        isSleeping = false
        isAppActive = NSApp.isActive
        let sleepCenter = NSWorkspace.shared.notificationCenter
        let sleepNames: [Notification.Name] = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.willSleepNotification,
        ]
        for name in sleepNames {
            sleepObservers.append(sleepCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isSleeping = true
                    self?.reconcileTimer()
                }
            })
        }
        let wakeNames: [Notification.Name] = [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.didWakeNotification,
        ]
        for name in wakeNames {
            sleepObservers.append(sleepCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isSleeping = false
                    self?.reconcileTimer()
                }
            })
        }
        let appCenter = NotificationCenter.default
        appObservers.append(appCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAppActive = true
                self?.reconcileTimer()
            }
        })
        appObservers.append(appCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAppActive = false
                self?.reconcileTimer()
            }
        })
        reconcileTimer()
    }

    func setHUDActive(_ active: Bool) {
        guard isHUDActive != active else { return }
        isHUDActive = active
        reconcileTimer()
    }

    private func reconcileTimer() {
        let shouldRun = isStarted && !isSleeping && (isAppActive || isHUDActive)
        if shouldRun {
            guard timer == nil else { return }
            last = CACurrentMediaTime()
            let source = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            let nanos = max(1_000_000, Int((interval * 1_000_000_000).rounded()))
            source.schedule(
                deadline: .now() + .nanoseconds(nanos),
                repeating: .nanoseconds(nanos),
                leeway: .milliseconds(0)
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }
            source.resume()
            self.timer = source
        } else {
            timer?.cancel()
            timer = nil
        }
    }

    deinit {
        timer?.cancel()
        let sleepCenter = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers {
            sleepCenter.removeObserver(observer)
        }
        let appCenter = NotificationCenter.default
        for observer in appObservers {
            appCenter.removeObserver(observer)
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        let sleepCenter = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers {
            sleepCenter.removeObserver(observer)
        }
        sleepObservers.removeAll()
        let appCenter = NotificationCenter.default
        for observer in appObservers {
            appCenter.removeObserver(observer)
        }
        appObservers.removeAll()
        isStarted = false
        isAppActive = false
        isHUDActive = false
        isSleeping = false
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let milliseconds = (now - last) * 1000
        last = now
        guard !isSleeping, milliseconds > threshold else { return }
        Log.shared.warn("thread.stall", ["ms": .double(milliseconds)])
    }
}

/// How long a press waited before this app was told about it.
///
/// Every measurement of the theme change starts when the press reaches a view,
/// and all of them say sixty milliseconds. If the app were asleep, or its event
/// loop busy, the waiting would happen *before* that, where no handler can see
/// it. An event carries the instant it happened, so the age of the event at
/// delivery is the number that has been missing.
@MainActor
final class InputLatency {
    private var monitor: Any?
    /// The last gap written, so a stream of events cannot fill the log.
    private var lastReport = 0.0
    /// The gap worth a line, in milliseconds.
    private let threshold: Double

    init(threshold: Double = 60) {
        self.threshold = threshold
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            MainActor.assumeIsolated {
                self.record(event)
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func record(_ event: NSEvent) {
        let age = (CACurrentMediaTime() - event.timestamp) * 1000
        guard age > threshold, event.timestamp > lastReport else { return }
        lastReport = event.timestamp
        Log.shared.warn("input.delay", [
            "ms": .double(age),
            "kind": .string(event.type == .keyDown ? "key" : "click"),
        ])
    }
}

/// Logs every display frame Dot's main thread missed while Dot was on screen.
///
/// Every animation Dot draws (the HUD, the Settings swatches, About, the
/// welcome tour, scrolling on the legacy path) is driven from the main thread,
/// so a display link on the main run loop is late by exactly the frames those
/// animations missed. The link runs in the common modes, so it keeps firing
/// while a scroll gesture is tracking, and only while Dot is frontmost or the
/// HUD is rendering. Each late callback writes one `frame.drop` line with the
/// frames missed and the animation sources that were active. A frame the
/// render server drops after the main thread delivered it on time is not seen.
@MainActor
final class FrameDropMonitor: NSObject {
    static let shared = FrameDropMonitor()

    struct Hitch: Equatable {
        let dropped: Int
        let gapMS: Double
        let frameMS: Double
    }

    /// The frames missed between two display link callbacks, or nil when the
    /// second callback came on the next frame.
    ///
    /// A gap up to one and a half frames is jitter in callback delivery, not a
    /// missed frame.
    nonisolated static func hitch(
        previous: CFTimeInterval,
        current: CFTimeInterval,
        frameDuration: CFTimeInterval
    ) -> Hitch? {
        guard frameDuration > 0, current > previous else { return nil }
        let gap = current - previous
        guard gap > frameDuration * 1.5 else { return nil }
        let dropped = max(1, Int((gap / frameDuration).rounded()) - 1)
        return Hitch(dropped: dropped, gapMS: gap * 1000, frameMS: frameDuration * 1000)
    }

    /// Lines written per minute before further hitches are only counted, so a
    /// machine that is overloaded for an hour cannot fill the log.
    static let linesPerMinute = 240

    private(set) var totalDroppedFrames = 0
    private(set) var totalHitches = 0
    private var sources: [String: Int] = [:]
    private var link: CADisplayLink?
    private weak var linkScreen: NSScreen?
    private var linkFollowsHUD = false
    /// The display the HUD panel is on; while the HUD renders, its own
    /// display's clock decides what counts as a missed frame.
    var hudScreen: @MainActor () -> NSScreen? = { nil }
    private var lastTimestamp: CFTimeInterval?
    private var isStarted = false
    private var isAppActive = false
    private var isHUDActive = false
    private var isSleeping = false
    private var budgetWindowStart: CFTimeInterval = 0
    private var linesInWindow = 0
    private var suppressedHitches = 0
    private var suppressedFrames = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Marks an animation as running, for the `sources` field of a drop.
    func begin(_ source: String) {
        sources[source, default: 0] += 1
    }

    func end(_ source: String) {
        guard let count = sources[source] else { return }
        sources[source] = count > 1 ? count - 1 : nil
    }

    var sourceLabel: String {
        var names = Set(sources.keys)
        if isHUDActive { names.insert("hud") }
        if DotScrollInteraction.isLiveScrolling { names.insert("scroll") }
        return names.isEmpty ? "idle" : names.sorted().joined(separator: ",")
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        isAppActive = NSApplication.shared.isActive
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            observe(workspace, name) { $0.isSleeping = true }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            observe(workspace, name) { $0.isSleeping = false }
        }
        let app = NotificationCenter.default
        observe(app, NSApplication.didBecomeActiveNotification) { $0.isAppActive = true }
        observe(app, NSApplication.didResignActiveNotification) { $0.isAppActive = false }
        observe(app, NSWindow.didBecomeKeyNotification) { _ in }
        observe(app, NSWindow.didChangeScreenNotification) { _ in }
        observe(app, NSApplication.didChangeScreenParametersNotification) { $0.restartLink() }
        reconcile()
    }

    func setHUDActive(_ active: Bool) {
        guard isHUDActive != active else { return }
        isHUDActive = active
        reconcile()
    }

    func stop() {
        for (center, token) in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
        isStarted = false
        reconcile()
    }

    /// Counts a hitch and writes its line, within the per-minute budget.
    func record(_ hitch: Hitch, at now: CFTimeInterval) {
        totalHitches += 1
        totalDroppedFrames += hitch.dropped
        if now - budgetWindowStart >= 60 {
            if suppressedHitches > 0 {
                Log.shared.warn("frame.drop.suppressed", [
                    "hitches": .int(suppressedHitches),
                    "dropped": .int(suppressedFrames),
                ])
            }
            budgetWindowStart = now
            linesInWindow = 0
            suppressedHitches = 0
            suppressedFrames = 0
        }
        guard linesInWindow < Self.linesPerMinute else {
            suppressedHitches += 1
            suppressedFrames += hitch.dropped
            return
        }
        linesInWindow += 1
        Log.shared.warn("frame.drop", [
            "dropped": .int(hitch.dropped),
            "gap_ms": .double((hitch.gapMS * 10).rounded() / 10),
            "frame_ms": .double((hitch.frameMS * 10).rounded() / 10),
            "display_hz": .int(hitch.frameMS > 0 ? Int((1000 / hitch.frameMS).rounded()) : 0),
            "sources": .string(sourceLabel),
            "window": .string(Self.windowLabel(NSApplication.shared.keyWindow)),
            "clock": .string(linkFollowsHUD ? "hud-display" : "key-display"),
        ])
    }

    private static func windowLabel(_ window: NSWindow?) -> String {
        guard let window else { return "none" }
        let title = window.title
        return title.isEmpty ? String(describing: type(of: window)) : title
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ change: @escaping @MainActor (FrameDropMonitor) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.reconcile()
            }
        }
        observers.append((center, token))
    }

    private func restartLink() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
    }

    private func reconcile() {
        let shouldRun = isStarted && !isSleeping && (isAppActive || isHUDActive)
        let hud = isHUDActive ? hudScreen() : nil
        let screen = hud ?? NSApplication.shared.keyWindow?.screen ?? NSScreen.main
        guard shouldRun, let screen else {
            restartLink()
            return
        }
        linkFollowsHUD = hud != nil
        if link != nil, linkScreen === screen { return }
        restartLink()
        let next = screen.displayLink(target: self, selector: #selector(linkFired(_:)))
        next.add(to: .main, forMode: .common)
        link = next
        linkScreen = screen
    }

    @objc private func linkFired(_ link: CADisplayLink) {
        #if DEBUG
        debugCallbacks += 1
        #endif
        let timestamp = link.timestamp
        defer { lastTimestamp = timestamp }
        guard let previous = lastTimestamp,
              let hitch = Self.hitch(previous: previous, current: timestamp, frameDuration: link.duration)
        else { return }
        record(hitch, at: timestamp)
    }

    #if DEBUG
    private(set) var debugCallbacks = 0
    var debugIsLinked: Bool { link != nil }
    var debugLinesInWindow: Int { linesInWindow }
    var debugSuppressedHitches: Int { suppressedHitches }

    func debugReset() {
        stop()
        sources.removeAll()
        totalDroppedFrames = 0
        totalHitches = 0
        debugCallbacks = 0
        budgetWindowStart = 0
        linesInWindow = 0
        suppressedHitches = 0
        suppressedFrames = 0
        isAppActive = false
        isHUDActive = false
        isSleeping = false
    }
    #endif
}
