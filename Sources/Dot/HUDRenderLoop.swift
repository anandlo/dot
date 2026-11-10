import Foundation

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
        loop.fire()
    }
}

/// The frame clock of the HUD.
///
/// A `CADisplayLink` from an `NSView` is not running until it is explicitly
/// added to a run loop, and its callbacks stop while the view is off screen.
/// The card's visibility must not depend on either condition, so the loop is a
/// plain 60 Hz timer in the common modes: it also runs while a menu tracks the
/// mouse, and it can never leave the model at its initial opacity.
@MainActor
final class HUDRenderLoop {
    /// The interval between frames.
    static let interval: TimeInterval = 1.0 / 60.0

    private let target = HUDRenderLoopTarget()
    private var timer: Timer?
    private var handler: (() -> Void)?

    init() {
        target.loop = self
    }

    /// Whether the loop is installed on the run loop.
    var isRunning: Bool { timer?.isValid == true }

    /// Starts the loop, or does nothing when it already runs.
    ///
    /// - Parameters:
    ///   - interval: the interval between frames, in seconds.
    ///   - handler: the frame callback, on the main thread.
    func start(interval: TimeInterval = HUDRenderLoop.interval, handler: @escaping () -> Void) {
        guard timer?.isValid != true else { return }
        timer?.invalidate()
        timer = nil
        self.handler = handler
        let timer = Timer(
            timeInterval: interval,
            target: target,
            selector: #selector(HUDRenderLoopTarget.fire(_:)),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops the loop and releases the frame callback.
    func stop() {
        timer?.invalidate()
        timer = nil
        handler = nil
    }

    fileprivate func fire() {
        handler?()
    }
}
