import Foundation

/// A spring that is integrated with the closed-form solution.
///
/// The spring has the same semantics as SwiftUI's
/// `spring(duration:bounce:)`:
///
/// ```
/// omega = 2 * pi / duration
/// zeta  = 1 - bounce
/// ```
///
/// The state is advanced with the *exact* solution of the damped harmonic
/// oscillator, in fixed sub-steps of 1/480 s. Because the solution is exact,
/// the composition of the sub-steps over a frame is the same as one step over
/// the whole frame: the motion is identical at 60, 120 and 144 Hz, and a
/// retarget keeps the velocity, so the motion stays C1 continuous.
public struct Spring {
    /// The current value.
    public private(set) var value: Double
    /// The current velocity, in units per second.
    public private(set) var velocity: Double
    /// The value the spring moves to.
    public private(set) var target: Double
    /// How long a full move takes, in seconds.
    public private(set) var duration: Double
    /// How much the spring overshoots: `0` is critically damped.
    public private(set) var bounce: Double

    /// The length of one sub-step, in seconds.
    public static let subStep = 1.0 / 480.0

    /// Creates a spring.
    public init(value: Double = 0, target: Double = 1, duration: Double = 0.25, bounce: Double = 0) {
        self.value = value
        self.velocity = 0
        self.target = target
        self.duration = max(0.0001, duration)
        self.bounce = bounce
    }

    /// Moves the spring to a new target without losing the velocity.
    public mutating func to(target: Double, duration: Double? = nil, bounce: Double? = nil) {
        self.target = target
        if let duration {
            self.duration = max(0.0001, duration)
        }
        if let bounce {
            self.bounce = bounce
        }
    }

    /// Sets the value and the velocity outright.
    public mutating func snap(to value: Double) {
        self.value = value
        self.velocity = 0
    }

    /// Whether the spring has come to rest.
    public var isResting: Bool {
        abs(value - target) < 1e-4 && abs(velocity) < 4e-4
    }

    /// Advances the spring by `dt` seconds.
    public mutating func advance(_ dt: Double) {
        guard dt > 0 else { return }
        var remaining = dt
        while remaining > 0 {
            let interval = min(Self.subStep, remaining)
            step(by: interval)
            remaining -= interval
        }
    }

    /// Advances the spring by one sub-step, exactly.
    private mutating func step(by dt: Double) {
        let omega = 2 * Double.pi / duration
        let zeta = 1 - bounce
        let displacement = value - target

        if abs(zeta - 1) < 1e-9 {
            // Critically damped.
            let a = displacement
            let b = velocity + omega * displacement
            let decay = exp(-omega * dt)
            let newValue = target + (a + b * dt) * decay
            let newVelocity = (velocity - omega * b * dt) * decay
            value = newValue
            velocity = newVelocity
            return
        }

        if zeta < 1 {
            // Underdamped: the spring overshoots.
            let omegaD = omega * sqrt(1 - zeta * zeta)
            let a = displacement
            let b = (velocity + zeta * omega * displacement) / omegaD
            let decay = exp(-zeta * omega * dt)
            let cosT = cos(omegaD * dt)
            let sinT = sin(omegaD * dt)
            let newValue = target + decay * (a * cosT + b * sinT)
            let newVelocity = decay * (
                (-zeta * omega * a + omegaD * b) * cosT
                    + (-zeta * omega * b - omegaD * a) * sinT
            )
            value = newValue
            velocity = newVelocity
            return
        }

        // Overdamped.
        let root = omega * sqrt(zeta * zeta - 1)
        let r1 = -zeta * omega + root
        let r2 = -zeta * omega - root
        let c1 = (velocity - r2 * displacement) / (r1 - r2)
        let c2 = displacement - c1
        let e1 = exp(r1 * dt)
        let e2 = exp(r2 * dt)
        value = target + c1 * e1 + c2 * e2
        velocity = c1 * r1 * e1 + c2 * r2 * e2
    }
}
