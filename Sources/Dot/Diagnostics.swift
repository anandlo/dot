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
    private var timer: Timer?
    private var last = CACurrentMediaTime()
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
        guard timer == nil else { return }
        last = CACurrentMediaTime()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let milliseconds = (now - last) * 1000
        last = now
        guard milliseconds > threshold else { return }
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
