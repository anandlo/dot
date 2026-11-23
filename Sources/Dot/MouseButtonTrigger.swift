import ApplicationServices
import CoreGraphics
import DotCore
import Foundation

/// Watches one mouse button and reports when it goes down and comes back up.
///
/// The keyboard shortcut is a Carbon hot key, which says that a key went down
/// and never that it came up, so ``KeyWatcher`` reads the release from the
/// keyboard state. A mouse button has no such gap: a session event tap sees
/// both edges as events, so nothing is polled and the release is exact.
///
/// The tap runs on a thread of its own. An active tap holds an event until it
/// answers, and it is asked about every other mouse button too; on the main
/// thread, each side button on the Mac would wait for whatever the main
/// thread was drawing, and macOS turns off a tap that answers late. The
/// thread only decides. The edges reach the main thread in the order they
/// arrived, and an edge from a tap that has since been stopped is dropped.
///
/// The tap takes the assigned button's down and up events for itself, so the
/// button stops doing what it did before, such as Back in a browser. Every
/// other event goes back untouched, and ``MouseTriggerButton/off`` builds no
/// tap at all.
///
/// Building the tap needs Accessibility. Without it the trigger waits for the
/// system's announcement that the grant changed and tries again then, so the
/// permission takes effect without relaunching Dot.
@MainActor
final class MouseButtonTrigger {
    /// What the tap does with one event.
    enum Decision: Equatable, Sendable {
        /// Not Dot's: the event goes back unchanged.
        case pass
        /// The assigned button went down. The event is consumed.
        case press
        /// The assigned button came up. The event is consumed.
        case release
        /// macOS turned the tap off; it has to be turned back on, or the next
        /// release is lost and the take never ends.
        case reenable
    }

    /// Called on the main thread when the assigned button goes down.
    var onPress: (() -> Void)?
    /// Called on the main thread when the assigned button comes up.
    var onRelease: (() -> Void)?

    /// Whether the assigned button is down, as the main thread last heard.
    ///
    /// A take may open the microphone only after its prompt is answered; by
    /// then the button can be up, and a take whose button is up has nothing
    /// left to stop it.
    private(set) var isPressActive = false

    /// Whether a button is assigned and the tap is waiting for Accessibility.
    var isWaitingForPermission: Bool { permissionObserver != nil }

    /// Builds the tap around the context it calls into. Tests replace it: a
    /// test runner cannot build a tap.
    var createTap: (UnsafeMutableRawPointer) -> CFMachPort? = MouseButtonTrigger.makeTap

    /// The announcement macOS posts when an app's Accessibility grant changes.
    static let accessibilityChanged = Notification.Name("com.apple.accessibility.api")

    /// When the grant is read again after the announcement. The announcement
    /// can arrive before `AXIsProcessTrusted` gives the new answer, so the
    /// first read waits a moment and a second read covers a slower update.
    nonisolated static let permissionReads: [TimeInterval] = [0.5, 2]

    private var context: TapContext?
    private var permissionObserver: NSObjectProtocol?
    /// Counts starts and stops, so an edge a stopped tap queued is ignored.
    private var generation = 0

    /// Builds the tap for `button`, or stops listening for `.off`.
    ///
    /// - Returns: `false` when the tap could not be built, which means the
    ///   trigger is now waiting for Accessibility.
    @discardableResult
    func start(button: MouseTriggerButton) -> Bool {
        stop()
        guard button != .off else { return true }

        let generation = self.generation
        let context = TapContext(button: button) { [weak self] edge in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.receive(edge, generation: generation)
                }
            }
        }
        guard let port = createTap(Unmanaged.passUnretained(context).toOpaque()) else {
            Log.shared.error("mouse.tap.failed", ["button": .string(button.rawValue)])
            waitForPermission(button: button)
            return false
        }
        // A new tap is already on, and an event it holds before its thread
        // runs would wait for an answer; the thread turns it on.
        CGEvent.tapEnable(tap: port, enable: false)
        context.run(port: port)
        self.context = context
        Log.shared.info("mouse.tap.started", ["button": .string(button.rawValue)])
        return true
    }

    /// Removes the tap and stops waiting for the grant. The assigned button
    /// does what it did before Dot took it.
    func stop() {
        generation += 1
        if let permissionObserver {
            DistributedNotificationCenter.default().removeObserver(permissionObserver)
            self.permissionObserver = nil
        }
        context?.stop()
        context = nil
        isPressActive = false
    }

    /// What the tap does with an event of `type` from button `eventButton`.
    ///
    /// The tap asks for other-button downs and ups only, but macOS also sends
    /// it the notices that it was turned off, and the decision answers every
    /// type so the table is the whole rule.
    nonisolated static func decision(
        for type: CGEventType,
        eventButton: Int64,
        configured: MouseTriggerButton
    ) -> Decision {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            return .reenable
        case .otherMouseDown, .otherMouseUp:
            guard let number = configured.buttonNumber, number == eventButton else { return .pass }
            return type == .otherMouseDown ? .press : .release
        default:
            return .pass
        }
    }

    private func receive(_ edge: TapContext.Edge, generation: Int) {
        guard generation == self.generation else { return }
        switch edge {
        case .press:
            isPressActive = true
            onPress?()
        case .release:
            isPressActive = false
            onRelease?()
        }
    }

    private func waitForPermission(button: MouseTriggerButton) {
        permissionObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.accessibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            for delay in Self.permissionReads {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated {
                        guard let self, self.isWaitingForPermission, AXIsProcessTrusted() else { return }
                        self.start(button: button)
                    }
                }
            }
        }
    }

    nonisolated private static func makeTap(_ userInfo: UnsafeMutableRawPointer) -> CFMachPort? {
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                return Unmanaged<TapContext>.fromOpaque(userInfo)
                    .takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: userInfo
        )
    }
}

/// The part of the trigger the tap's thread touches.
///
/// The tap holds an unretained pointer to it, so it lives as long as the
/// thread does, and the thread ends only once the tap is invalidated: no call
/// can reach it after it is gone. Its button and port are written before the
/// thread starts and never again; the run loop is the one field both threads
/// reach, and the lock guards it.
private final class TapContext: @unchecked Sendable {
    enum Edge: Sendable { case press, release }

    private let button: MouseTriggerButton
    private let deliver: @Sendable (Edge) -> Void
    private var port: CFMachPort?
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var stopped = false

    init(button: MouseTriggerButton, deliver: @escaping @Sendable (Edge) -> Void) {
        self.button = button
        self.deliver = deliver
    }

    /// Starts the thread that runs the tap.
    func run(port: CFMachPort) {
        self.port = port
        let thread = Thread { [self] in
            lock.lock()
            guard !stopped,
                  let port = self.port,
                  let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            else {
                lock.unlock()
                return
            }
            let current = CFRunLoopGetCurrent()
            runLoop = current
            CFRunLoopAddSource(current, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            lock.unlock()
            CFRunLoopRun()
        }
        thread.name = "Dot mouse trigger"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Ends the tap. Invalidating the port removes its source, which ends a
    /// run loop that has not started; stopping the loop wakes one that has.
    func stop() {
        lock.lock()
        stopped = true
        let loop = runLoop
        lock.unlock()
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    /// Answers one event on the tap's thread.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let decision = MouseButtonTrigger.decision(
            for: type,
            eventButton: event.getIntegerValueField(.mouseEventButtonNumber),
            configured: button
        )
        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .reenable:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        case .press:
            deliver(.press)
            return nil
        case .release:
            deliver(.release)
            return nil
        }
    }
}
