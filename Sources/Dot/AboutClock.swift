import Foundation
import Observation

/// The one monotonic timebase the About plate uses.
///
/// Seconds since boot, in milliseconds. Every anchor, deadline and frame time
/// is on this scale; a wall-clock adjustment or a daylight-saving change cannot
/// move the entrance or a spring. A hosted test injects its own reader.
enum AboutTimebase {
    /// The production reading, in milliseconds.
    nonisolated static func now() -> Double {
        ProcessInfo.processInfo.systemUptime * 1000
    }
}

/// Cancels one scheduled wake.
///
/// The scheduler owns the timer; the token is only a handle the pause loop can
/// drop when the deadline it was waiting for has moved.
@MainActor
final class AboutWakeToken {
    var onCancel: (() -> Void)?
}

/// Schedules one wake after a delay.
///
/// The production scheduler is a main-run-loop timer; a test supplies a manual
/// one so the pause loop can be driven without sleeping or a display link.
@MainActor
protocol AboutWakeScheduling: AnyObject {
    func wake(
        afterMilliseconds milliseconds: Double,
        _ fire: @escaping @MainActor () -> Void
    ) -> AboutWakeToken

    func cancel(_ token: AboutWakeToken)
}

/// The main-run-loop timer the page uses outside tests.
@MainActor
final class AboutTimerWakeScheduler: AboutWakeScheduling {
    func wake(
        afterMilliseconds milliseconds: Double,
        _ fire: @escaping @MainActor () -> Void
    ) -> AboutWakeToken {
        let token = AboutWakeToken()
        let interval = max(0, milliseconds / 1000)
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { fire() }
        }
        // Common mode keeps the wake on time while a scroll or a tracking
        // drag holds the run loop in its event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        token.onCancel = { timer.invalidate() }
        return token
    }

    func cancel(_ token: AboutWakeToken) {
        token.onCancel?()
        token.onCancel = nil
    }
}

/// The one task that pauses the matrix leaf.
///
/// It sleeps until the clock's current deadline, wakes, re-reads the clock and
/// only pauses when `AboutMotionClock.isSettled` agrees. Events replace the
/// stored clock and deadline; a later deadline leaves the sleep alone, an
/// earlier one wakes the same task, and a pointer move never creates a task.
@MainActor
final class AboutPauseLoop {
    private let now: @MainActor @Sendable () -> Double
    private let scheduler: AboutWakeScheduling
    private var clock = AboutMotionClock()
    private var deadline: Double?
    private var task: Task<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    private var token: AboutWakeToken?
    private var scheduledAt: Double?
    private var pendingWake = false

    private(set) var taskCount = 0
    private(set) var paused = true
    var onPaused: (@MainActor (Bool) -> Void)?

    init(
        now: @escaping @MainActor @Sendable () -> Double,
        scheduler: AboutWakeScheduling
    ) {
        self.now = now
        self.scheduler = scheduler
    }

    /// Replaces the clock and deadline, waking the loop only for an earlier
    /// deadline or when it is parked.
    func update(clock: AboutMotionClock, deadline: Double?) {
        self.clock = clock
        self.deadline = deadline
        guard task != nil else {
            start()
            return
        }
        if paused {
            wake()
            return
        }
        guard let deadline else {
            wake()
            return
        }
        if let scheduledAt, deadline >= scheduledAt { return }
        wake()
    }

    /// Stops the loop. A later `update` starts a new one.
    func cancel() {
        task?.cancel()
        wake()
        task = nil
    }

    private func start() {
        guard task == nil else { return }
        taskCount += 1
        task = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        while !Task.isCancelled {
            let time = now()
            if clock.isSettled(at: time) {
                setPaused(true)
                await park()
            } else {
                setPaused(false)
                let next = clock.settleDeadline() ?? (time + 1)
                await sleep(until: max(next, time + 0.001))
            }
        }
    }

    private func sleep(until time: Double) async {
        await withCheckedContinuation { continuation in
            if pendingWake {
                pendingWake = false
                continuation.resume()
                return
            }
            self.continuation = continuation
            scheduledAt = time
            let delay = max(0, time - now())
            let newToken = scheduler.wake(afterMilliseconds: delay) { [weak self] in
                self?.wake()
            }
            if self.continuation == nil {
                // A scheduler that fired synchronously already consumed the
                // continuation; do not leave a second wake behind.
                scheduler.cancel(newToken)
            } else {
                token = newToken
            }
        }
        scheduledAt = nil
    }

    private func park() async {
        await withCheckedContinuation { continuation in
            if pendingWake {
                pendingWake = false
                continuation.resume()
                return
            }
            self.continuation = continuation
            scheduledAt = nil
        }
    }

    private func wake() {
        pendingWake = true
        if let token {
            scheduler.cancel(token)
            self.token = nil
        }
        guard let continuation else { return }
        self.continuation = nil
        pendingWake = false
        continuation.resume()
    }

    private func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        onPaused?(value)
    }
}

/// The one store the About plate's motion state lives in.
///
/// Every event writes here and nowhere else: a tracking move, an exit, a
/// focus change, the update check's start and result, the entrance and the
/// Reduce Motion answer. The page's body never reads these values; only the
/// leaves that draw them observe the store. A page body therefore stays put
/// while the pointer moves, and a pointer move runs no SwiftUI layout for the
/// page.
///
/// The store owns the pause loop and the entrance's end. Both wait on the
/// injected scheduler, so a hosted test drives them by moving its clock and
/// firing the scheduler rather than by sleeping.
@Observable
@MainActor
final class AboutMotionStore {
    let now: @MainActor @Sendable () -> Double
    private let scheduler: AboutWakeScheduling

    /// The millisecond the entrance's first sampled frame stamped, or `nil`
    /// while the entrance is pending or settled.
    ///
    /// The epoch is not observed. The root stamps it inside the first frame it
    /// evaluates and reads it back in the same evaluation; no view needs to be
    /// invalidated by the write. `entranceRunning` is the observed start and
    /// end signal.
    @ObservationIgnored private var entranceEpoch: Double?
    var entranceStartedAt: Double? { entranceEpoch }
    /// Whether the entrance is still drawing.
    private(set) var entranceRunning = false
    private(set) var pointer: AboutPointerTimeline?
    private(set) var update: AboutUpdateTimeline = .idle
    private(set) var focus: AboutFocusTarget?
    private(set) var ripples: [AboutRippleAnchor] = []
    /// Whether the person asked for stillness. Writing it settles the entrance
    /// and drops the pointer.
    private(set) var reduceMotion = false
    /// Whether the pause loop has found every effect still.
    private(set) var paused = true
    /// Bumped on every event. The matrix leaf observes it so a move, a result
    /// or a focus change redraws the leaf even when a `TimelineView` is not
    /// re-evaluating its content.
    private(set) var revision = 0
    /// The pause loop, exposed so a probe can read its task count.
    private(set) var loop: AboutPauseLoop?

    /// Reports a pause-state change to a probe.
    var onPaused: (@MainActor (Bool) -> Void)?
    /// Reports an entrance change to a probe.
    var onEntranceChanged: (@MainActor (Double?, Bool) -> Void)?

    /// A row-hover point, kept off the page's state so a move within a row
    /// does not invalidate the page.
    @ObservationIgnored var lastHoverPoint: CGPoint?

    @ObservationIgnored private var attached = false
    @ObservationIgnored private var entranceFinished = false
    @ObservationIgnored private var entranceToken: AboutWakeToken?

    init(
        now: @escaping @MainActor @Sendable () -> Double,
        scheduler: AboutWakeScheduling
    ) {
        self.now = now
        self.scheduler = scheduler
    }

    /// The frame input at `time`, built from the one set of anchors.
    func input(at time: Double) -> AboutMotionInput {
        clock.input(at: time)
    }

    /// The entrance-only frame at `time`.
    ///
    /// It reads the entrance anchors and the Reduce Motion answer and nothing
    /// else, so a content group or a row that consumes it cannot be
    /// invalidated by a pointer move, an update result or a focus change.
    func entranceInput(at time: Double) -> AboutMotionInput {
        AboutMotionInput(
            entranceElapsed: entranceRunning
                ? entranceEpoch.map { max(0, time - $0) }
                : nil,
            reduceMotion: reduceMotion
        )
    }

    /// Stamps the entrance epoch at the first frame the root actually samples.
    ///
    /// Attaching only marks the entrance as requested. The first root
    /// evaluation supplies its frame time, so that frame is exactly t = 0 and
    /// paints the start pose even if the window took time to present. The
    /// write is outside observation; the frame that stamps also reads the
    /// epoch immediately. The pause loop stays parked while the root clock
    /// drives the entrance and is updated when the entrance settles.
    func stampEntrance(at time: Double) {
        guard entranceRunning, entranceEpoch == nil else { return }
        entranceEpoch = time
        cancelEntranceToken()
        entranceToken = scheduler.wake(
            afterMilliseconds: AboutMotion.Matrix.settleAfter
        ) { [weak self] in
            self?.settleEntrance()
        }
        onEntranceChanged?(time, true)
    }

    /// The event-anchored clock the model reads.
    var clock: AboutMotionClock {
        AboutMotionClock(
            entranceStartedAt: entranceRunning ? entranceEpoch : nil,
            pointer: pointer,
            update: update,
            focus: focus,
            ripples: ripples,
            reduceMotion: reduceMotion
        )
    }

    /// Whether the pointer currently has a patch to draw. An exit reports
    /// false at once; the fade itself is still on the clock until it ends.
    var pointerIsActive: Bool {
        pointer.map { $0.amplitudeTo > 0 } ?? false
    }

    // MARK: Attach and detach

    /// Starts the loop if it is not running and, on a first attach, the
    /// entrance. Reattaching the same page reuses the store and never replays
    /// an entrance that already ran.
    func attach() {
        guard !attached else {
            syncLoop()
            return
        }
        attached = true
        startLoop()
        beginEntranceIfNeeded()
        syncLoop()
    }

    /// Stops the loop and drops everything a detached host must not keep.
    func detach() {
        guard attached else { return }
        attached = false
        loop?.cancel()
        loop = nil
        cancelEntranceToken()
        entranceEpoch = nil
        entranceRunning = false
        entranceFinished = true
        pointer = nil
        ripples.removeAll()
        bump()
        onEntranceChanged?(nil, false)
        setPaused(true)
    }

    private func startLoop() {
        guard loop == nil else { return }
        let loop = AboutPauseLoop(now: now, scheduler: scheduler)
        loop.onPaused = { [weak self] value in self?.setPaused(value) }
        self.loop = loop
        loop.update(clock: clock, deadline: clock.settleDeadline())
    }

    private func syncLoop() {
        guard attached, let loop else { return }
        loop.update(clock: clock, deadline: clock.settleDeadline())
    }

    private func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        onPaused?(value)
    }

    // MARK: Entrance

    private func beginEntranceIfNeeded() {
        guard !reduceMotion, !entranceFinished else { return }
        let time = now()
        if let last = AboutEntranceGate.lastStartedAt,
           time - last < AboutEntranceGate.minimumGap {
            entranceFinished = true
            return
        }
        entranceEpoch = nil
        entranceRunning = true
        AboutEntranceGate.lastStartedAt = time
        bump()
        onEntranceChanged?(nil, true)
    }

    private func cancelEntranceToken() {
        if let entranceToken {
            scheduler.cancel(entranceToken)
            self.entranceToken = nil
        }
    }

    /// Settles the entrance now: no offset, no dim, no clock. Used by its own
    /// end, by a press or a key, and by Reduce Motion.
    func settleEntrance() {
        cancelEntranceToken()
        guard entranceRunning || entranceEpoch != nil else {
            entranceFinished = true
            return
        }
        entranceEpoch = nil
        entranceRunning = false
        entranceFinished = true
        bump()
        onEntranceChanged?(nil, false)
        syncLoop()
    }

    /// The page's press, key and action path.
    func finishEntrance() {
        guard !entranceFinished || entranceRunning else { return }
        settleEntrance()
    }

    // MARK: Events

    func setReduceMotion(_ value: Bool) {
        guard reduceMotion != value else { return }
        reduceMotion = value
        if value {
            pointer = nil
            ripples.removeAll()
            settleEntrance()
        }
        bump()
        syncLoop()
    }

    func setFocus(_ target: AboutFocusTarget?) {
        guard focus != target else { return }
        focus = target
        if target != nil { pointer = nil }
        bump()
        syncLoop()
    }

    func movePointer(_ point: CGPoint, at time: Double) {
        guard !reduceMotion else { return }
        if let current = pointer {
            if current.amplitudeTo == 0,
               time >= current.amplitudeTime + AboutPointerTimeline.fadeDuration {
                pointer = AboutPointerTimeline(point: point, at: time)
            } else {
                var next = current
                next.retarget(to: point, at: time)
                pointer = next
            }
        } else {
            pointer = AboutPointerTimeline(point: point, at: time)
        }
        bump()
        syncLoop()
    }

    func exitPointer(at time: Double) {
        guard var current = pointer, current.amplitudeTo > 0 else { return }
        current.exit(at: time)
        pointer = current
        bump()
        syncLoop()
    }

    func beginCheck(at time: Double) {
        update = .checking(startedAt: time)
        bump()
        syncLoop()
    }

    /// The checking elapsed at `time`, if a check is in flight.
    func checkingElapsed(at time: Double) -> Double? {
        guard case .checking(let startedAt) = update else { return nil }
        return max(0, time - startedAt)
    }

    func finishCheck(_ timeline: AboutUpdateTimeline) {
        update = timeline
        bump()
        syncLoop()
    }

    /// Launches a damped concentric acoustic ripple from `point` at `time`.
    func emitRipple(at point: CGPoint, at time: Double) {
        guard !reduceMotion else { return }
        ripples.removeAll { time - $0.startedAt >= AboutMotion.Matrix.rippleDuration || time < $0.startedAt }
        ripples.append(AboutRippleAnchor(origin: point, startedAt: time))
        if ripples.count > AboutMotion.Matrix.maxRipples {
            ripples.removeFirst(ripples.count - AboutMotion.Matrix.maxRipples)
        }
        bump()
        syncLoop()
    }

    private func bump() {
        revision &+= 1
    }
}
