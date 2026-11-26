import CoreGraphics
import Foundation
import os

/// The two controls on the plate that can hold keyboard focus.
///
/// Focus works the same way a pointer at the control's centre does: the plate
/// answers where the control is, not what the control does. The two cases are
/// separate because the control and the copy button sit in different places.
enum AboutFocusTarget: String, CaseIterable, Sendable {
    case update
    case copy
}

/// Where the update check is in time.
///
/// Each case carries the milliseconds since that state began. A result that
/// arrives while the checking fronts are still alive also carries the checking
/// elapsed at the moment it arrived, so the fronts finish their own schedule
/// instead of being cut, and a failure can fade them out from where they were.
enum AboutUpdatePhase: Equatable, Sendable {
    case idle
    case checking(elapsed: Double)
    case upToDate(elapsed: Double, frontsElapsed: Double?)
    case available(elapsed: Double, frontsElapsed: Double?)
    case unreachable(elapsed: Double, frontsElapsed: Double?)

    /// The elapsed milliseconds of an active result, or `nil` for idle.
    var elapsed: Double? {
        switch self {
        case .idle: nil
        case .checking(let elapsed),
             .upToDate(let elapsed, _),
             .available(let elapsed, _),
             .unreachable(let elapsed, _):
            elapsed
        }
    }

    /// The checking elapsed at the moment the result arrived, if a check ran.
    var frontsElapsed: Double? {
        switch self {
        case .upToDate(_, let fronts),
             .available(_, let fronts),
             .unreachable(_, let fronts):
            fronts
        case .idle, .checking:
            nil
        }
    }

    /// Whether a request is in flight.
    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}

// MARK: - Input

/// One expanding damped acoustic ripple on the About plate.
struct AboutRipple: Equatable, Sendable {
    var origin: CGPoint
    var elapsed: Double
}

/// An event-anchored ripple on the monotonic clock.
struct AboutRippleAnchor: Equatable, Sendable {
    var origin: CGPoint
    var startedAt: Double
}

/// Everything the plate's motion is a function of.
///
/// The struct holds no clock, no pointer and no window: a render and the live
/// page build the same value, and the live page keeps its clock and its spring
/// outside the model so the same input always draws the same frame.
struct AboutMotionInput: Equatable, Sendable {
    /// Milliseconds since the entrance began, or `nil` once it is settled.
    var entranceElapsed: Double?
    /// The already-sprung pointer in plate-local points, origin at the plate's
    /// top-left. During an exit this holds the centre the patch is leaving.
    var pointer: CGPoint?
    /// Milliseconds since the pointer left, while the patch fades. `nil` while
    /// the pointer is on the plate or once the fade is over.
    var pointerExitElapsed: Double?
    /// The patch's strength, zero through one. The live clock ramps it down on
    /// an exit and back up on a re-entry; a sampled frame leaves it at one.
    var pointerAmplitude: Double
    /// Whether the pointer's spring has finished travelling. A held patch
    /// whose spring has settled does not need a clock.
    var pointerSettled: Bool
    /// The row the pointer or the keyboard is on, 0 through 6.
    var engagedRow: Int?
    /// Milliseconds since that row was engaged. `nil` means it has been engaged
    /// long enough to be settled.
    var engagedElapsed: Double?
    /// The row that was engaged just before the current one, while it fades.
    var releasedRow: Int?
    /// Milliseconds since that row was released.
    var releasedElapsed: Double?
    /// The control that holds keyboard focus, if any.
    var focusedControl: AboutFocusTarget?
    /// The update check's phase and elapsed time.
    var update: AboutUpdatePhase
    /// Active damped acoustic ripples on the plate.
    var ripples: [AboutRipple]
    /// Whether the person asked for stillness.
    var reduceMotion: Bool

    init(
        entranceElapsed: Double? = nil,
        pointer: CGPoint? = nil,
        pointerExitElapsed: Double? = nil,
        pointerAmplitude: Double = 1,
        pointerSettled: Bool = true,
        engagedRow: Int? = nil,
        engagedElapsed: Double? = nil,
        releasedRow: Int? = nil,
        releasedElapsed: Double? = nil,
        focusedControl: AboutFocusTarget? = nil,
        update: AboutUpdatePhase = .idle,
        ripples: [AboutRipple] = [],
        reduceMotion: Bool = false
    ) {
        self.entranceElapsed = entranceElapsed
        self.pointer = pointer
        self.pointerExitElapsed = pointerExitElapsed
        self.pointerAmplitude = pointerAmplitude
        self.pointerSettled = pointerSettled
        self.engagedRow = engagedRow
        self.engagedElapsed = engagedElapsed
        self.releasedRow = releasedRow
        self.releasedElapsed = releasedElapsed
        self.focusedControl = focusedControl
        self.update = update
        self.ripples = ripples
        self.reduceMotion = reduceMotion
    }
}

// MARK: - Output

/// One group of content on its way in.
struct AboutContentMotion: Equatable, Sendable {
    var offset: CGPoint
    var opacity: Double

    static let settled = AboutContentMotion(offset: .zero, opacity: 1)
}

/// One of the seven rows, in the state its motion wants to draw.
struct AboutRowMotion: Equatable, Sendable {
    var contentOffset: CGPoint
    var contentOpacity: Double
    /// The 9 percent ink behind the row.
    var fillOpacity: Double
    /// The link arrow or action chevron's travel.
    var accentOffset: CGPoint
    /// One opacity per dot under the trailing group, left to right.
    var dotOpacities: [Double]

    static let settled = AboutRowMotion(
        contentOffset: .zero,
        contentOpacity: 1,
        fillOpacity: 0,
        accentOffset: .zero,
        dotOpacities: Array(repeating: 0, count: AboutMotion.Matrix.rowDotCount)
    )
}

/// One lit point of the matrix lattice.
struct AboutMatrixDot: Equatable, Sendable {
    var x: Double
    var y: Double
    /// Zero through one, after every contribution and the text knockout.
    var energy: Double
}

/// The matrix direction's dots and its update packet.
struct AboutMatrixMotion: Equatable, Sendable {
    var dots: [AboutMatrixDot]
    /// The two-column packet between the status line and the disc.
    var packetOpacity: Double

    static let resting = AboutMatrixMotion(dots: [], packetOpacity: 0)
}

/// Every value the page needs to draw one frame.
struct AboutMotionPresentation: Equatable, Sendable {
    var discOffset: CGPoint
    var title: AboutContentMotion
    var update: AboutContentMotion
    var colophon: AboutContentMotion
    var rows: [AboutRowMotion]
    var matrix: AboutMatrixMotion

    static let rowCount = 7
}

/// The part of the page outside the matrix leaf.
struct AboutContentPresentation: Equatable, Sendable {
    var discOffset: CGPoint
    var title: AboutContentMotion
    var update: AboutContentMotion
    var colophon: AboutContentMotion
    var rows: [AboutRowMotion]
}

// MARK: - Easing

/// The timing curves the model is allowed to use.
///
/// `easeOut` is the cubic `1 - (1 - t)^3`, not a bezier approximation:
/// it starts at the same slope as the usual ease-out and settles without an
/// overshoot. `easeInOut` is the smoothstep cubic `t^2 (3 - 2t)`.
enum AboutEasing {
    static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    static func linear(_ t: Double) -> Double {
        clamp(t)
    }

    static func easeOut(_ t: Double) -> Double {
        let c = clamp(t)
        return 1 - pow(1 - c, 3)
    }

    static func easeInOut(_ t: Double) -> Double {
        let c = clamp(t)
        return c * c * (3 - 2 * c)
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        guard edge1 > edge0 else { return value < edge0 ? 0 : 1 }
        let t = clamp((value - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Spring

/// A deterministic damped spring for position and velocity.
///
/// The step is the closed-form solution of the damped oscillator, not an Euler
/// integration: the same elapsed time gives the same position whether it was
/// reached in one step or four hundred, which is what lets the live view and
/// the clip renderer agree frame for frame.
struct AboutSpring: Equatable, Sendable {
    /// The undamped period in seconds, the same meaning SwiftUI gives response.
    var response: Double
    /// One is critical damping, below one overshoots.
    var dampingFraction: Double

    init(response: Double, dampingFraction: Double) {
        self.response = response
        self.dampingFraction = dampingFraction
    }

    /// One axis advanced by `dt` seconds toward `target`.
    func step(
        position: Double,
        velocity: Double,
        target: Double,
        dt: Double
    ) -> (position: Double, velocity: Double) {
        guard dt > 0, response > 0 else { return (position, velocity) }
        let x = position - target
        let v = velocity
        let omega = 2 * Double.pi / response
        let zeta = max(dampingFraction, 0)
        let decay = exp(-zeta * omega * dt)
        if zeta < 1 {
            let damped = omega * sqrt(1 - zeta * zeta)
            let cosine = cos(damped * dt)
            let sine = sin(damped * dt)
            let a = x
            let b = (v + zeta * omega * x) / damped
            let nextX = decay * (a * cosine + b * sine)
            let nextV = decay * (v * cosine - ((zeta * omega * v + omega * omega * x) / damped) * sine)
            return (nextX + target, nextV)
        }
        if zeta == 1 {
            let nextX = (x + (v + omega * x) * dt) * decay
            let nextV = (v - omega * (v + omega * x) * dt) * decay
            return (nextX + target, nextV)
        }
        let root = omega * sqrt(zeta * zeta - 1)
        let slow = -zeta * omega + root
        let fast = -zeta * omega - root
        let c1 = (v - fast * x) / (slow - fast)
        let c2 = x - c1
        let slowTerm = c1 * exp(slow * dt)
        let fastTerm = c2 * exp(fast * dt)
        return (slowTerm + fastTerm + target, slowTerm * slow + fastTerm * fast)
    }

    /// Both axes advanced by the same time toward the same target point.
    func step(
        position: CGPoint,
        velocity: CGVector,
        target: CGPoint,
        dt: Double
    ) -> (position: CGPoint, velocity: CGVector) {
        let x = step(position: position.x, velocity: velocity.dx, target: target.x, dt: dt)
        let y = step(position: position.y, velocity: velocity.dy, target: target.y, dt: dt)
        return (
            CGPoint(x: x.position, y: y.position),
            CGVector(dx: x.velocity, dy: y.velocity)
        )
    }

    /// One axis at `seconds` after an anchor, without stepping.
    func value(
        at seconds: Double,
        position: Double,
        velocity: Double,
        target: Double
    ) -> Double {
        step(position: position, velocity: velocity, target: target, dt: seconds).position
    }

    /// One axis's velocity at `seconds` after an anchor.
    func velocity(
        at seconds: Double,
        position: Double,
        velocity: Double,
        target: Double
    ) -> Double {
        step(position: position, velocity: velocity, target: target, dt: seconds).velocity
    }

    /// Both axes at `seconds` after an anchor.
    func value(
        at seconds: Double,
        position: CGPoint,
        velocity: CGVector,
        target: CGPoint
    ) -> (position: CGPoint, velocity: CGVector) {
        step(position: position, velocity: velocity, target: target, dt: seconds)
    }

    /// A conservative time after which both axes are inside the settle
    /// thresholds, in seconds from the anchor.
    ///
    /// The settle test is the same radial one `AboutPointerTimeline.isSettled`
    /// uses: 0.25 points of distance and 1 point per second of speed. The bound
    /// is the oscillator's envelope, not a frame-by-frame test:
    /// `|x| <= e^(-zeta*omega*t) * (|x0| + |v0|/omega_d)`. The larger of the
    /// position and velocity bounds is used, plus 20 ms of margin.
    func settleTime(position: Double, velocity: Double, target: Double) -> Double {
        settleTime(distance: abs(position - target), speed: abs(velocity))
    }

    /// The same deadline for a two-axis state, measured radially.
    ///
    /// Two axes each 0.20 points away are 0.28 points from the target, which is
    /// not settled, so their deadline must not be zero.
    func settleTime(distance: Double, speed: Double) -> Double {
        if distance < 0.25 && speed < 1 { return 0 }
        guard response > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        let zeta = max(dampingFraction, 0.0001)
        let damped = zeta < 1 ? omega * sqrt(1 - zeta * zeta) : omega
        let decay = zeta * omega
        guard decay > 0 else { return 1 }
        let positionEnvelope = distance + speed / max(damped, 0.0001)
        let velocityEnvelope = speed + omega * positionEnvelope
        let positionTime = log(max(positionEnvelope, 0.25) / 0.25) / decay
        // The velocity envelope carries an extra factor of omega, so the
        // deadline aims at half the speed threshold to stay conservative.
        let velocityTime = log(max(velocityEnvelope, 0.5) / 0.5) / decay
        return max(positionTime, velocityTime) + 0.02
    }
}

// MARK: - Pointer timeline

/// One pointer patch anchored in time.
///
/// A move captures the presented position and velocity at the event's time and
/// springs from there to the new point. An exit ramps the amplitude to zero
/// over 180 ms; a re-entry during the fade springs from the current position
/// and ramps the amplitude back up instead of jumping to full strength.
struct AboutPointerTimeline: Equatable, Sendable {
    var position: CGPoint
    var velocity: CGVector
    var target: CGPoint
    var anchorTime: Double
    var amplitudeFrom: Double
    var amplitudeTo: Double
    var amplitudeTime: Double
    var spring: AboutSpring

    static let fadeDuration: Double = 180
    static let settleDistance: Double = 0.25
    static let settleSpeed: Double = 1

    init(
        point: CGPoint,
        at time: Double,
        spring: AboutSpring = AboutSpring(response: 0.23, dampingFraction: 0.90)
    ) {
        position = point
        velocity = .zero
        target = point
        anchorTime = time
        amplitudeFrom = 1
        amplitudeTo = 1
        amplitudeTime = time
        self.spring = spring
    }

    func sprung(at time: Double) -> (position: CGPoint, velocity: CGVector) {
        spring.value(
            at: max(0, time - anchorTime) / 1000,
            position: position,
            velocity: velocity,
            target: target
        )
    }

    func amplitude(at time: Double) -> Double {
        guard amplitudeFrom != amplitudeTo else { return amplitudeTo }
        let progress = AboutEasing.clamp((time - amplitudeTime) / Self.fadeDuration)
        return amplitudeFrom + (amplitudeTo - amplitudeFrom) * progress
    }

    /// The time after which a present patch is still and a fading one is gone.
    ///
    /// The distance and speed are radial, the same two numbers `isSettled`
    /// compares, so the deadline and the predicate cannot disagree about a
    /// diagonal retarget.
    func settleDeadline() -> Double {
        let rampEnd = amplitudeFrom == amplitudeTo
            ? amplitudeTime
            : amplitudeTime + Self.fadeDuration
        guard amplitudeTo > 0 else { return rampEnd }
        let distance = hypot(position.x - target.x, position.y - target.y)
        let speed = hypot(velocity.dx, velocity.dy)
        let seconds = spring.settleTime(distance: distance, speed: speed)
        return max(rampEnd, anchorTime + seconds * 1000)
    }

    func isSettled(at time: Double) -> Bool {
        if amplitudeFrom != amplitudeTo, time < amplitudeTime + Self.fadeDuration {
            return false
        }
        guard amplitudeTo > 0 else { return true }
        let state = sprung(at: time)
        return hypot(state.position.x - target.x, state.position.y - target.y)
                < Self.settleDistance
            && hypot(state.velocity.dx, state.velocity.dy) < Self.settleSpeed
    }

    /// Retargets from the presented state at `time`.
    ///
    /// The spring starts from the position and velocity it presents. The
    /// amplitude only starts a new ramp when the patch is coming back from an
    /// exit; a move during an existing ramp keeps the ramp's original end time
    /// instead of restarting its 180 ms.
    mutating func retarget(to point: CGPoint, at time: Double) {
        let state = sprung(at: time)
        let strength = amplitude(at: time)
        position = state.position
        velocity = state.velocity
        target = point
        anchorTime = time
        if amplitudeTo == 0 {
            amplitudeFrom = strength
            amplitudeTo = 1
            amplitudeTime = time
        }
    }

    /// Fades the patch out from its presented strength at `time`.
    mutating func exit(at time: Double) {
        let strength = amplitude(at: time)
        amplitudeFrom = strength
        amplitudeTo = 0
        amplitudeTime = time
    }
}

// MARK: - Update timeline

/// The update check with absolute times, so a frame can be evaluated at any
/// clock value without writing state.
enum AboutUpdateTimeline: Equatable, Sendable {
    case idle
    case checking(startedAt: Double)
    case upToDate(at: Double, frontsElapsed: Double?)
    case available(at: Double, frontsElapsed: Double?)
    case unreachable(at: Double, frontsElapsed: Double?)

    func phase(at time: Double) -> AboutUpdatePhase {
        switch self {
        case .idle:
            return .idle
        case .checking(let startedAt):
            return .checking(elapsed: max(0, time - startedAt))
        case .upToDate(let at, let fronts):
            return .upToDate(elapsed: max(0, time - at), frontsElapsed: fronts)
        case .available(let at, let fronts):
            return .available(elapsed: max(0, time - at), frontsElapsed: fronts)
        case .unreachable(let at, let fronts):
            return .unreachable(elapsed: max(0, time - at), frontsElapsed: fronts)
        }
    }

    /// The time after which nothing this result started is still moving.
    ///
    /// A failure only fades fronts that are still alive; when the result
    /// arrives after the checking fronts have expired, or when no check ran,
    /// it changes nothing and must not extend the clock by its fade duration.
    func settleDeadline() -> Double? {
        func frontsRemaining(_ fronts: Double?) -> Double {
            guard let fronts else { return 0 }
            return max(0, AboutMotion.Matrix.checkingEnd - fronts)
        }
        switch self {
        case .idle:
            return nil
        case .checking(let startedAt):
            return startedAt + AboutMotion.Matrix.checkingEnd
        case .upToDate(let at, let fronts):
            return at + max(AboutMotion.Matrix.packetRise, frontsRemaining(fronts))
        case .available(let at, let fronts):
            return at + max(AboutMotion.Matrix.packetFadeIn, frontsRemaining(fronts))
        case .unreachable(let at, let fronts):
            guard let fronts, fronts < AboutMotion.Matrix.checkingEnd else { return at }
            // The renderer multiplies the front energy by the failure fade,
            // so the visible end is the earlier of the front's own end and the
            // fade's end.
            return at + min(
                AboutMotion.Matrix.failureFade,
                AboutMotion.Matrix.checkingEnd - fronts
            )
        }
    }
}

// MARK: - The live clock

/// Every time an event anchored, in milliseconds on one monotonic scale.
///
/// The page writes this only on events. A frame asks for the input at its own
/// time; nothing in the page changes while the clock runs.
struct AboutMotionClock: Equatable, Sendable {
    var entranceStartedAt: Double?
    var pointer: AboutPointerTimeline?
    var update: AboutUpdateTimeline
    var focus: AboutFocusTarget?
    var ripples: [AboutRippleAnchor]
    var reduceMotion: Bool

    init(
        entranceStartedAt: Double? = nil,
        pointer: AboutPointerTimeline? = nil,
        update: AboutUpdateTimeline = .idle,
        focus: AboutFocusTarget? = nil,
        ripples: [AboutRippleAnchor] = [],
        reduceMotion: Bool = false
    ) {
        self.entranceStartedAt = entranceStartedAt
        self.pointer = pointer
        self.update = update
        self.focus = focus
        self.ripples = ripples
        self.reduceMotion = reduceMotion
    }

    /// The frame input at `time` in milliseconds.
    func input(at time: Double) -> AboutMotionInput {
        let elapsed = entranceStartedAt.map { max(0, time - $0) }
        var point: CGPoint?
        var amplitude: Double = 1
        var settled = true
        if let pointer {
            let strength = pointer.amplitude(at: time)
            if strength > 0.001 || pointer.amplitudeTo > 0 {
                point = pointer.sprung(at: time).position
                amplitude = strength
                settled = pointer.isSettled(at: time)
            }
        }
        let activeRipples = ripples.compactMap { anchor -> AboutRipple? in
            let delta = time - anchor.startedAt
            guard delta >= 0, delta < AboutMotion.Matrix.rippleDuration else { return nil }
            return AboutRipple(origin: anchor.origin, elapsed: delta)
        }
        return AboutMotionInput(
            entranceElapsed: elapsed,
            pointer: point,
            pointerAmplitude: amplitude,
            pointerSettled: settled,
            focusedControl: focus,
            update: update.phase(at: time),
            ripples: activeRipples,
            reduceMotion: reduceMotion
        )
    }

    /// Whether every effect is still at `time`.
    func isSettled(at time: Double) -> Bool {
        guard let deadline = settleDeadline() else { return true }
        return time >= deadline
    }

    /// The last moment any running effect can still change, or nil at rest.
    func settleDeadline() -> Double? {
        guard !reduceMotion else { return nil }
        var deadlines: [Double] = []
        if let entranceStartedAt {
            deadlines.append(entranceStartedAt + AboutMotion.Matrix.settleAfter)
        }
        if let pointer, pointer.amplitudeTo > 0 || pointer.amplitudeFrom > 0 {
            deadlines.append(pointer.settleDeadline())
        }
        if let update = update.settleDeadline() {
            deadlines.append(update)
        }
        for ripple in ripples {
            deadlines.append(ripple.startedAt + AboutMotion.Matrix.rippleDuration)
        }
        return deadlines.max()
    }
}

// MARK: - Row input

/// Which input last drove the rows.
///
/// Keyboard intent wins until the pointer actually moves; a resting cursor
/// does not mask a later focus change. A row can be released by a hover end
/// while another row is being engaged, so releases are independent.
enum AboutRowInput: Equatable, Sendable {
    case pointer
    case keyboard
}

/// The one rule that decides which row is engaged.
enum AboutRowArbiter {
    static func activeRow(
        lastInput: AboutRowInput,
        hovered: Int?,
        focused: Int?
    ) -> Int? {
        switch lastInput {
        case .pointer: hovered
        case .keyboard: focused
        }
    }
}

// MARK: - The model

/// The plate's motion as a pure function of time, pointer and state.
///
/// Nothing here reads a clock, a window or a system setting: the live page
/// turns the clock and the pointer into ``AboutMotionInput`` and asks for the
/// frame it should draw. A render asks the same question with a supplied input,
/// which is why a strip and the running page cannot disagree.
enum AboutMotion {
    /// The heights and widths the model needs from the plate's layout.
    ///
    /// These mirror the settled frames the page reports: the upper band is 72
    /// points, the disc is a 66 point circle whose centre sits 25.5 points in
    /// from the plate's top-right corner, and the update column keeps 72 points
    /// of trailing room. The layout tests keep the page at those numbers.
    enum Plate {
        static let upperBandHeight: CGFloat = 72
        static let discDiameter: CGFloat = 66
        static let discCentreInset: CGFloat = 25.5
        static let trailingReserve: CGFloat = 72
        static let controlWidth: CGFloat = 132
        static let controlHeight: CGFloat = 28
        static let controlTrailingInset: CGFloat = 16
        static let controlTop: CGFloat = 6

        static func discCentre(plateSize: CGSize) -> CGPoint {
            CGPoint(
                x: plateSize.width - discCentreInset,
                y: discCentreInset
            )
        }

        static func controlCentre(plateSize: CGSize) -> CGPoint {
            CGPoint(
                x: plateSize.width - controlTrailingInset - trailingReserve - controlWidth / 2,
                y: controlTop + controlHeight / 2
            )
        }

        /// The copy button in the reference colophon: the version line is
        /// "1.0 (1)", which puts the button at 59.5 from the plate's leading
        /// edge. The trailing edge of the colophon is stable, the button is not,
        /// so the value is the reference layout's rather than a fraction.
        static func copyCentre(plateSize: CGSize) -> CGPoint {
            CGPoint(x: 68.5, y: plateSize.height - 14)
        }
    }

    // MARK: Shared entrance

    static let entranceDuration: Double = 200
    static let titleEntranceStart: Double = 35
    static let updateEntranceStart: Double = 65
    static let colophonEntranceStart: Double = 90
    static let rowEntranceStart: Double = 100
    static let rowEntranceStep: Double = 16
    static let rowEntranceDuration: Double = 170
    static let entranceRise: CGFloat = 6
    static let rowEntranceRise: CGFloat = 5
    static let entranceOpacity: Double = 0.65

    static let rowFillOpacity: Double = 0.09
    static let linkAccentOffset = CGPoint(x: 3, y: -2)
    static let actionAccentOffset = CGPoint(x: 3, y: 0)

    /// The row's fill and accent spring, and how long they take to settle.
    static let rowEngageResponse: Double = 0.22
    static let rowEngageDamping: Double = 0.88
    static let rowReleaseResponse: Double = 0.28
    static let rowReleaseDamping: Double = 0.92

    /// The point a focused control answers at.
    static func focusPoint(_ target: AboutFocusTarget, plateSize: CGSize) -> CGPoint {
        switch target {
        case .update: Plate.controlCentre(plateSize: plateSize)
        case .copy: Plate.copyCentre(plateSize: plateSize)
        }
    }

    /// The pointer a direction should follow: the real pointer, or the centre
    /// of the focused control when the keyboard is driving.
    static func resolvedPointer(_ input: AboutMotionInput, plateSize: CGSize) -> CGPoint? {
        if let pointer = input.pointer { return pointer }
        if let focused = input.focusedControl {
            return focusPoint(focused, plateSize: plateSize)
        }
        return nil
    }

    /// The row index bounded to the seven rows, if one is engaged.
    static func resolvedRow(_ input: AboutMotionInput) -> Int? {
        guard let row = input.engagedRow else { return nil }
        return min(max(row, 0), AboutMotionPresentation.rowCount - 1)
    }

    /// The released row index bounded to the seven rows, if one is fading.
    static func resolvedReleasedRow(_ input: AboutMotionInput) -> Int? {
        guard let row = input.releasedRow else { return nil }
        return min(max(row, 0), AboutMotionPresentation.rowCount - 1)
    }

    // MARK: Presentation

    /// The frame the page should draw.
    ///
    /// The three-argument form is the public contract. The four-argument form
    /// adds the title, tagline, control and status frames the matrix direction
    /// needs to keep its dots out from under text; the page measures those
    /// frames from its own layout, and a render passes the ones it measured.
    static func presentation(
        input: AboutMotionInput,
        plateSize: CGSize
    ) -> AboutMotionPresentation {
        presentation(input: input, plateSize: plateSize, knockoutFrames: [:])
    }

    /// The whole frame. `knockoutFrames` is keyed by the page's reported
    /// frames so each one travels with the entrance offset of its own group.
    static func presentation(
        input: AboutMotionInput,
        plateSize: CGSize,
        knockoutFrames: [String: CGRect]
    ) -> AboutMotionPresentation {
        let content = contentPresentation(input: input)
        return AboutMotionPresentation(
            discOffset: content.discOffset,
            title: content.title,
            update: content.update,
            colophon: content.colophon,
            rows: content.rows,
            matrix: Matrix.motion(
                input: input,
                plateSize: plateSize,
                knockoutFrames: knockoutFrames
            )
        )
    }

    /// The page content without the matrix, so the live page does not evaluate
    /// the lattice in its body.
    static func contentPresentation(input: AboutMotionInput) -> AboutContentPresentation {
        let content = contentMotion(input)
        return AboutContentPresentation(
            discOffset: Matrix.discOffset(input),
            title: content.title,
            update: content.update,
            colophon: content.colophon,
            rows: rowMotion(input)
        )
    }

    /// Whether every time-based matrix effect has finished.
    ///
    /// Settled means no entrance front running, no pointer spring or amplitude
    /// ramp moving, no checking front, no packet animation and no exit fade.
    /// Row feedback is SwiftUI animation in the rows themselves; it does not
    /// keep the matrix clock alive.
    static func isSettled(_ input: AboutMotionInput) -> Bool {
        if input.reduceMotion { return true }
        if let elapsed = input.entranceElapsed, elapsed < Matrix.settleAfter {
            return false
        }
        if input.pointer != nil {
            if !input.pointerSettled { return false }
            if let exit = input.pointerExitElapsed, exit < Matrix.exitFade { return false }
        }
        if input.ripples.contains(where: { $0.elapsed >= 0 && $0.elapsed < Matrix.rippleDuration }) {
            return false
        }
        switch input.update {
        case .idle:
            return true
        case .checking(let elapsed):
            return elapsed >= Matrix.checkingEnd
        case .upToDate(let elapsed, let fronts):
            if let fronts, fronts + elapsed < Matrix.checkingEnd { return false }
            return elapsed >= Matrix.packetRise
        case .available(let elapsed, let fronts):
            if let fronts, fronts + elapsed < Matrix.checkingEnd { return false }
            return elapsed >= Matrix.packetFadeIn
        case .unreachable(let elapsed, let fronts):
            guard let fronts, fronts < Matrix.checkingEnd else { return true }
            return elapsed >= min(Matrix.failureFade, Matrix.checkingEnd - fronts)
        }
    }

    /// The three shared entrances, or their settled values.
    static func contentMotion(_ input: AboutMotionInput) -> (
        title: AboutContentMotion,
        update: AboutContentMotion,
        colophon: AboutContentMotion
    ) {
        func group(start: Double, elapsed: Double?) -> AboutContentMotion {
            guard let elapsed, elapsed < start + entranceDuration else { return .settled }
            let progress = AboutEasing.easeOut(
                (elapsed - start) / entranceDuration
            )
            return AboutContentMotion(
                offset: CGPoint(x: 0, y: entranceRise * (1 - progress)),
                opacity: entranceOpacity + (1 - entranceOpacity) * progress
            )
        }
        guard !input.reduceMotion else {
            return (.settled, .settled, .settled)
        }
        return (
            group(start: titleEntranceStart, elapsed: input.entranceElapsed),
            group(start: updateEntranceStart, elapsed: input.entranceElapsed),
            group(start: colophonEntranceStart, elapsed: input.entranceElapsed)
        )
    }

    /// The seven rows' entrance and engagement.
    static func rowMotion(_ input: AboutMotionInput) -> [AboutRowMotion] {
        let engaged = resolvedRow(input)
        let released = resolvedReleasedRow(input)
        return (0..<AboutMotionPresentation.rowCount).map { index in
            var row = AboutRowMotion.settled
            if !input.reduceMotion, let elapsed = input.entranceElapsed,
               elapsed < rowEntranceStart + rowEntranceStep * Double(index) + rowEntranceDuration {
                let start = rowEntranceStart + rowEntranceStep * Double(index)
                let progress = AboutEasing.easeOut(
                    (elapsed - start) / rowEntranceDuration
                )
                row.contentOffset = CGPoint(x: 0, y: rowEntranceRise * (1 - progress))
                row.contentOpacity = entranceOpacity + (1 - entranceOpacity) * progress
            }

            let engagement: Double
            if engaged == index {
                engagement = engagementFactor(
                    elapsed: input.engagedElapsed,
                    engaging: true,
                    reduceMotion: input.reduceMotion
                )
                row.dotOpacities = dotOpacities(
                    elapsed: input.engagedElapsed,
                    engaging: true,
                    reduceMotion: input.reduceMotion
                )
            } else if released == index {
                engagement = engagementFactor(
                    elapsed: input.releasedElapsed,
                    engaging: false,
                    reduceMotion: input.reduceMotion
                )
                row.dotOpacities = dotOpacities(
                    elapsed: input.releasedElapsed,
                    engaging: false,
                    reduceMotion: input.reduceMotion
                )
            } else {
                engagement = 0
            }

            if engagement > 0 {
                row.fillOpacity = rowFillOpacity * engagement
                if !input.reduceMotion {
                    row.accentOffset = CGPoint(
                        x: accentOffset(forRow: index).x * engagement,
                        y: accentOffset(forRow: index).y * engagement
                    )
                }
            }
            return row
        }
    }

    /// The link rows carry the arrow; the two action rows carry a chevron.
    static func accentOffset(forRow row: Int) -> CGPoint {
        row < 5 ? linkAccentOffset : actionAccentOffset
    }

    /// The row fill and accent spring, expressed as a zero through one factor.
    static func engagementFactor(
        elapsed: Double?,
        engaging: Bool,
        reduceMotion: Bool
    ) -> Double {
        // Reduce Motion has no per-frame row state: a row is either engaged
        // or not. The live leaf animates only the fill's opacity over 120 ms.
        guard !reduceMotion else { return engaging ? 1 : 0 }
        let spring = engaging
            ? AboutSpring(response: rowEngageResponse, dampingFraction: rowEngageDamping)
            : AboutSpring(response: rowReleaseResponse, dampingFraction: rowReleaseDamping)
        guard let elapsed else { return engaging ? 1 : 0 }
        let seconds = elapsed / 1000
        let position: Double
        if engaging {
            position = spring.step(position: 0, velocity: 0, target: 1, dt: seconds).position
        } else {
            position = spring.step(position: 1, velocity: 0, target: 0, dt: seconds).position
        }
        return AboutEasing.clamp(position)
    }

    /// One opacity per dot: a 100 ms fade staggered 24 ms left to right in, a
    /// flat 120 ms fade out.
    static func dotOpacities(
        elapsed: Double?,
        engaging: Bool,
        reduceMotion: Bool
    ) -> [Double] {
        guard !reduceMotion else {
            return Array(repeating: 0, count: Matrix.rowDotCount)
        }
        return (0..<Matrix.rowDotCount).map { index in
            let progress: Double
            if engaging {
                guard let elapsed else { return Matrix.rowDotOpacity }
                let start = Matrix.rowDotStagger * Double(index)
                progress = AboutEasing.easeOut((elapsed - start) / Matrix.rowDotFadeIn)
            } else {
                guard let elapsed else { return 0 }
                progress = 1 - AboutEasing.clamp(elapsed / Matrix.rowDotFadeOut)
            }
            return Matrix.rowDotOpacity * progress
        }
    }

    // MARK: The matrix

    enum Matrix {
        static let pitch: CGFloat = 8
        static let dotDiameter: Double = 1.5
        static let dotGrowth: Double = 2
        static let dotOpacity: Double = 0.42
        static let minimumEnergy: Double = 0.02
        static let discRadius: CGFloat = Plate.discDiameter / 2
        static let entranceOffset = CGPoint(x: 18, y: -14)
        static let entranceDuration: Double = 280
        static let frontStart: Double = 65
        static let frontTravel: Double = 550
        static let frontReach: Double = 590
        static let frontSigma: Double = 18
        static let frontFade: Double = 90
        static let settleAfter: Double = 615
        static let pointerSigma: Double = 44
        static let exitFade: Double = 180
        static let checkingReach: Double = 220
        static let checkingTravel: Double = 420
        static let checkingDelay: Double = 120
        static let checkingSigma: Double = 16
        static let checkingFade: Double = 90
        /// The two checking fronts are over after this many milliseconds.
        static let checkingEnd: Double = checkingDelay + checkingTravel
        static let rowDotOpacity: Double = 0.42
        static let rowDotCount = 5
        static let rowDotFadeIn: Double = 100
        static let rowDotStagger: Double = 24
        static let rowDotFadeOut: Double = 120
        static let packetColumns = 2
        static let packetRows = 4
        static let packetDotDiameter: CGFloat = 3
        static let packetPitch: CGFloat = 6
        static let packetPeakOpacity: Double = 0.42
        static let packetHoldOpacity: Double = 0.30
        static let packetRise: Double = 200
        static let packetFadeIn: Double = 160
        static let failureFade: Double = 120
        static let rippleDuration: Double = 1100
        static let rippleSpeed: Double = 0.28
        static let rippleWavelength: Double = 38
        static let rippleBandWidth: Double = 46
        static let maxRipples = 3

        private struct LatticeKey: Hashable {
            let cols: Int
            let rows: Int
        }

        private static let latticeCache = OSAllocatedUnfairLock<[LatticeKey: [CGPoint]]>(initialState: [:])

        /// The lattice points over the whole plate, before the disc is removed.
        ///
        /// The points are inset half a pitch from every edge so a dot is never
        /// cut in half by the plate's border. The colophon band is covered
        /// too; its text is kept clear by the knockouts.
        static func lattice(plateSize: CGSize) -> [CGPoint] {
            guard
                plateSize.width.isFinite,
                plateSize.height.isFinite,
                plateSize.width > pitch,
                plateSize.height > pitch
            else { return [] }
            let cols = Int(((plateSize.width - pitch) / pitch).rounded(.down)) + 1
            let rows = Int(((plateSize.height - pitch) / pitch).rounded(.down)) + 1
            guard cols > 0, rows > 0 else { return [] }
            let key = LatticeKey(cols: cols, rows: rows)
            if let cached = latticeCache.withLock({ $0[key] }) {
                return cached
            }
            var points: [CGPoint] = []
            points.reserveCapacity(cols * rows)
            for row in 0..<rows {
                let y = pitch / 2 + CGFloat(row) * pitch
                for col in 0..<cols {
                    let x = pitch / 2 + CGFloat(col) * pitch
                    points.append(CGPoint(x: x, y: y))
                }
            }
            let built = points
            return latticeCache.withLock { cache in
                if let existing = cache[key] { return existing }
                if cache.count >= 16 { cache.removeAll(keepingCapacity: true) }
                cache[key] = built
                return built
            }
        }

        static func isInsideDisc(
            _ point: CGPoint,
            plateSize: CGSize,
            offset: CGPoint
        ) -> Bool {
            let centre = Plate.discCentre(plateSize: plateSize)
            let dx = point.x - (centre.x + offset.x)
            let dy = point.y - (centre.y + offset.y)
            return dx * dx + dy * dy < discRadius * discRadius
        }

        /// The entrance front's radius at an elapsed time.
        static func frontRadius(entranceElapsed: Double) -> Double {
            frontReach * AboutEasing.linear(
                (entranceElapsed - frontStart) / frontTravel
            )
        }

        /// The entrance front's amplitude at an elapsed time.
        static func frontAmplitude(entranceElapsed: Double) -> Double {
            guard entranceElapsed >= frontStart else { return 0 }
            let fadeStart = frontStart + frontTravel - frontFade
            guard entranceElapsed > fadeStart else { return 1 }
            return 1 - AboutEasing.linear((entranceElapsed - fadeStart) / frontFade)
        }

        static func discOffset(_ input: AboutMotionInput) -> CGPoint {
            guard !input.reduceMotion, let elapsed = input.entranceElapsed else { return .zero }
            let progress = AboutEasing.easeOut(elapsed / entranceDuration)
            return CGPoint(
                x: entranceOffset.x * (1 - progress),
                y: entranceOffset.y * (1 - progress)
            )
        }

        /// The energy at one point, before the text knockout.
        ///
        /// Every source is a Gaussian contribution summed and capped at one:
        /// the entrance front, the held pointer patch (fading after an exit)
        /// and the checking fronts, which continue from the elapsed time they
        /// had when a result arrived. `knockoutFrames` are plate-local.
        static func energy(
            at point: CGPoint,
            input: AboutMotionInput,
            plateSize: CGSize,
            knockoutFrames: [CGRect] = []
        ) -> Double {
            energy(
                at: point,
                input: input,
                plateSize: plateSize,
                knockoutFrames: knockoutFrames,
                disc: Matrix.discOffset(input),
                pointer: resolvedPointer(input, plateSize: plateSize)
            )
        }

        private static func energy(
            at point: CGPoint,
            input: AboutMotionInput,
            plateSize: CGSize,
            knockoutFrames: [CGRect],
            disc: CGPoint,
            pointer: CGPoint?
        ) -> Double {
            guard !input.reduceMotion else { return 0 }
            let centre = Plate.discCentre(plateSize: plateSize)
            let centreDistance = hypot(
                point.x - (centre.x + disc.x),
                point.y - (centre.y + disc.y)
            )
            var total: Double = 0

            if let elapsed = input.entranceElapsed {
                let radius = frontRadius(entranceElapsed: elapsed)
                let amplitude = frontAmplitude(entranceElapsed: elapsed)
                if amplitude > 0 {
                    total += amplitude * gaussian(
                        distance: centreDistance,
                        radius: radius,
                        sigma: frontSigma
                    )
                }
            }

            if let pointer {
                let exit = input.pointerExitElapsed
                if exit.map({ $0 < exitFade }) ?? true {
                    let fade = exit.map { 1 - $0 / exitFade } ?? 1
                    let life = input.pointerAmplitude * fade
                    if life > 0 {
                        let pointerDistance = hypot(point.x - pointer.x, point.y - pointer.y)
                        total += life * gaussian(
                            distance: pointerDistance,
                            radius: 0,
                            sigma: pointerSigma
                        )
                    }
                }
            }

            let fronts = checkingFronts(
                at: centreDistance,
                update: input.update
            )
            // A failure fades the checking fronts out; it must not take the
            // held pointer patch or a still-running entrance with it.
            if case .unreachable(let elapsed, _) = input.update {
                total += fronts * (1 - AboutEasing.linear(elapsed / failureFade))
            } else {
                total += fronts
            }
            if !input.ripples.isEmpty {
                total += rippleEnergy(at: point, ripples: input.ripples)
            }
            return knocked(total, point, knockoutFrames)
        }

        private static func rippleEnergy(at point: CGPoint, ripples: [AboutRipple]) -> Double {
            var total = 0.0
            for ripple in ripples {
                guard ripple.elapsed >= 0, ripple.elapsed < rippleDuration else { continue }
                let life = 1 - AboutEasing.easeOut(ripple.elapsed / rippleDuration)
                guard life > 0.001 else { continue }
                let front = rippleSpeed * ripple.elapsed
                let distance = hypot(point.x - ripple.origin.x, point.y - ripple.origin.y)
                let envelope = gaussian(distance: distance, radius: front, sigma: rippleBandWidth)
                guard envelope > 0.001 else { continue }
                let phase = 2 * Double.pi * (distance - front) / rippleWavelength
                let harmonic = 0.58 + 0.42 * cos(phase)
                total += life * envelope * harmonic * 0.92
            }
            return total
        }

        private static func checkingFronts(
            at distance: Double,
            update: AboutUpdatePhase
        ) -> Double {
            let elapsed: Double
            switch update {
            case .checking(let value):
                elapsed = value
            case .upToDate(let value, let fronts),
                 .available(let value, let fronts),
                 .unreachable(let value, let fronts):
                guard let fronts else { return 0 }
                elapsed = fronts + value
            case .idle:
                return 0
            }
            var total: Double = 0
            for index in 0..<2 {
                let local = elapsed - checkingDelay * Double(index)
                guard local > 0 else { continue }
                let radius = checkingReach * AboutEasing.linear(local / checkingTravel)
                let fadeStart = checkingTravel - checkingFade
                let amplitude: Double
                if local <= fadeStart {
                    amplitude = 1
                } else {
                    amplitude = 1 - AboutEasing.linear((local - fadeStart) / checkingFade)
                }
                guard amplitude > 0 else { continue }
                total += amplitude * gaussian(
                    distance: distance,
                    radius: radius,
                    sigma: checkingSigma
                )
            }
            return total
        }

        private static func knocked(
            _ total: Double,
            _ point: CGPoint,
            _ knockoutFrames: [CGRect]
        ) -> Double {
            guard total > 0 else { return 0 }
            var value = min(1, total)
            if !knockoutFrames.isEmpty {
                var nearest = CGFloat.greatestFiniteMagnitude
                for frame in knockoutFrames {
                    nearest = min(nearest, distance(from: point, to: frame))
                }
                // Zero through one point clear of the text, then the feather
                // reaches full strength at six points.
                value *= AboutEasing.smoothstep(1, 6, Double(nearest))
            }
            return value
        }

        private static func gaussian(distance: Double, radius: Double, sigma: Double) -> Double {
            let delta = distance - radius
            // Four sigma is far below the minimum dot energy; skipping it
            // keeps the whole-plate lattice inside the frame budget.
            guard abs(delta) < 4 * sigma else { return 0 }
            return exp(-(delta * delta) / (2 * sigma * sigma))
        }

        private static func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
            let dx = max(frame.minX - point.x, max(0, point.x - frame.maxX))
            let dy = max(frame.minY - point.y, max(0, point.y - frame.maxY))
            return hypot(dx, dy)
        }

        /// The knockout rectangles in their presented positions.
        ///
        /// A group's frame is measured in its settled place; during the
        /// entrance the pixels travel, so each frame moves by its group's
        /// entrance offset before the lattice is knocked out.
        static func presentedKnockoutFrames(
            _ frames: [String: CGRect],
            input: AboutMotionInput
        ) -> [CGRect] {
            let content = AboutMotion.contentMotion(input)
            return frames.map { name, frame in
                let offset: CGPoint
                switch name {
                case "title", "tagline":
                    offset = content.title.offset
                case "control", "status":
                    offset = content.update.offset
                default:
                    offset = content.colophon.offset
                }
                return frame.offsetBy(dx: offset.x, dy: offset.y)
            }
        }

        static func motion(
            input: AboutMotionInput,
            plateSize: CGSize,
            knockoutFrames: [String: CGRect]
        ) -> AboutMatrixMotion {
            guard !input.reduceMotion else { return .resting }
            let disc = Matrix.discOffset(input)
            let discCentre = Plate.discCentre(plateSize: plateSize)
            let discCentreX = discCentre.x + disc.x
            let discCentreY = discCentre.y + disc.y
            let discRadiusSq = discRadius * discRadius
            let pointer = resolvedPointer(input, plateSize: plateSize)
            let frames = presentedKnockoutFrames(knockoutFrames, input: input)
            let points = lattice(plateSize: plateSize)
            var dots: [AboutMatrixDot] = []
            dots.reserveCapacity(points.count / 2)
            for point in points {
                let dx = point.x - discCentreX
                let dy = point.y - discCentreY
                guard dx * dx + dy * dy >= discRadiusSq else { continue }
                let energy = energy(
                    at: point,
                    input: input,
                    plateSize: plateSize,
                    knockoutFrames: frames,
                    disc: disc,
                    pointer: pointer
                )
                guard energy >= minimumEnergy else { continue }
                dots.append(
                    AboutMatrixDot(x: point.x, y: point.y, energy: energy)
                )
            }
            return AboutMatrixMotion(
                dots: dots,
                packetOpacity: packetOpacity(input)
            )
        }

        /// The two-column packet between the status line and the disc.
        static func packetOpacity(_ input: AboutMotionInput) -> Double {
            guard !input.reduceMotion else { return 0 }
            switch input.update {
            case .upToDate(let elapsed, _):
                let half = packetRise / 2
                let progress = min(elapsed / half, (packetRise - elapsed) / half)
                return packetPeakOpacity * AboutEasing.clamp(progress)
            case .available(let elapsed, _):
                return packetHoldOpacity * AboutEasing.easeOut(elapsed / packetFadeIn)
            case .idle, .checking, .unreachable:
                return 0
            }
        }
    }
}
