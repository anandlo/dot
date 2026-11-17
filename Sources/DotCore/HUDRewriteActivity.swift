import CoreGraphics
import Foundation

/// The activity the card draws while a rewrite runs.
///
/// The card answers a click on a style with one moving part: a conic arc that
/// travels the rim of the capsule that was clicked, and the soft glow it drags
/// behind it. The arc is the work made visible where the person asked for it,
/// not beside it: nothing is added to the card's layout, no line is named, and
/// the surface does not move.
///
/// The same arc is drawn around the delivery badge in the header, from the same
/// clock and the same angle function, so the header and the chip are one
/// movement rather than two indicators that happen to run.
///
/// The numbers live here, in pure functions, so the views that draw the arc and
/// the tests that measure it cannot disagree about them without a display. Angles
/// are degrees clockwise from the top of the shape, which is the way a person
/// reads "the arc is at the top"; the gradient's own space starts at three
/// o'clock, so ``arcStops(head:trail:)`` is the one place that converts.
public enum HUDRewriteActivity {
    /// The length of one whole turn of the arc, in seconds.
    ///
    /// One full turn is slow enough to read as travel rather than as a spinner,
    /// and it keeps the phase across the first token: a rate that changed when
    /// the service answered would jump the head, which the eye reads as a
    /// restart.
    public static let arcPeriod: Double = 1.9

    /// How far the trail reaches behind the head, in degrees.
    ///
    /// A third of the rim: long enough that the direction of travel is legible
    /// in a still frame, short enough that the arc never becomes a second ring
    /// around the capsule.
    public static let arcTrailDegrees: Double = 120

    /// How far the trail reaches when the system asked for reduced motion.
    ///
    /// The parked arc is a quarter of the rim, centred on the top of the shape,
    /// so the still frame is the top-right quarter of the capsule.
    public static let reducedMotionTrailDegrees: Double = 90

    /// The head's angle when the system asked for reduced motion.
    ///
    /// A 90 degree arc centred on the top runs from 45 degrees before the top to
    /// 45 degrees after it; the head is the end the trail leads to, so it sits
    /// at the top-right end of the parked arc.
    public static let reducedMotionHeadDegrees: Double = 45

    /// The radius of the glow that follows the head, in points.
    public static let glowRadius: CGFloat = 16

    /// The opacity of the glow at its centre, on a chip's own fill.
    public static let glowOpacity: Double = 0.22

    /// The opacity of the glow at its centre on the cream selected pill.
    ///
    /// The same light on a light fill washes the pill out, so the rerun case
    /// carries a little less of it.
    public static let glowOpacityOnPill: Double = 0.14

    /// The width of the arc's stroke, in points.
    public static let arcLineWidth: CGFloat = 1.5

    /// The width of the track the arc travels on, in points.
    public static let trackLineWidth: CGFloat = 1

    /// The opacity of the track, a hairline of white on the card's surface.
    public static let trackOpacity: Double = 0.08

    /// How long the arc and the glow take to fade when the run ends.
    public static let endFadeDuration: Double = 0.14

    /// The angle of the arc's head at one reading of the card's clock.
    ///
    /// The travel is linear: at a constant rate the head is a metronome, and an
    /// eased one would make the work look like it started fast and gave up. The
    /// result is the position in one turn, so a clock of one period more returns
    /// the same angle.
    ///
    /// - Parameters:
    ///   - time: the card's clock, in seconds.
    ///   - reduceMotion: whether the system asked for reduced motion.
    /// - Returns: the head's angle in degrees, clockwise from the top, from `0`
    ///   to `360`. Reduced motion returns ``reducedMotionHeadDegrees`` and the
    ///   clock is not read at all; a clock that is not a number returns the same
    ///   parked angle rather than a position at infinity.
    public static func arcHeadAngle(time: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion, time.isFinite else { return reducedMotionHeadDegrees }
        let turns = time / arcPeriod
        let fraction = turns - turns.rounded(.down)
        return fraction * 360
    }

    /// How far the trail reaches behind the head, in degrees.
    ///
    /// - Parameter reduceMotion: whether the system asked for reduced motion.
    /// - Returns: ``arcTrailDegrees``, or the shorter parked quarter.
    public static func arcTrail(reduceMotion: Bool) -> Double {
        reduceMotion ? reducedMotionTrailDegrees : arcTrailDegrees
    }

    /// Where one angle meets the outline of a capsule.
    ///
    /// The capsule is the stadium the card draws: a rectangle whose short sides
    /// are half-circles of `min(width, height) / 2`. The point is found by
    /// casting a ray from the centre, so it lands on the outline for every angle
    /// and every size the card can hand it, and a test can hold it to that.
    ///
    /// - Parameters:
    ///   - angleDegrees: the angle in degrees, clockwise from the top.
    ///   - size: the size of the capsule, in points.
    /// - Returns: the point on the rim, in the capsule's own coordinates.
    public static func capsuleRimPoint(angleDegrees: Double, size: CGSize) -> CGPoint {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              angleDegrees.isFinite
        else { return .zero }
        let radius = min(size.width, size.height) / 2
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radians = angleDegrees * .pi / 180
        let dx = sin(radians)
        let dy = -cos(radians)
        // How much of the flat run each side keeps once the caps are cut out.
        let flatX = centre.x - radius
        let flatY = centre.y - radius

        if flatX > 0 {
            // A wide capsule: the flat runs along the top and the bottom.
            if abs(dy) > 1e-9 {
                let reach = centre.y / abs(dy)
                let x = centre.x + reach * dx
                if abs(x - centre.x) <= flatX + 1e-9 {
                    return CGPoint(x: x, y: dy < 0 ? 0 : size.height)
                }
            }
            let capX = dx < 0 ? radius : size.width - radius
            return CGPoint(x: capX + radius * dx, y: centre.y + radius * dy)
        }
        if flatY > 0 {
            // A tall capsule: the flat runs along the two sides.
            if abs(dx) > 1e-9 {
                let reach = centre.x / abs(dx)
                let y = centre.y + reach * dy
                if abs(y - centre.y) <= flatY + 1e-9 {
                    return CGPoint(x: dx < 0 ? 0 : size.width, y: y)
                }
            }
            let capY = dy < 0 ? radius : size.height - radius
            return CGPoint(x: centre.x + radius * dx, y: capY + radius * dy)
        }
        // A square is a circle.
        return CGPoint(x: centre.x + radius * dx, y: centre.y + radius * dy)
    }

    /// One stop of the conic gradient the arc is stroked with.
    ///
    /// It is a plain value rather than a SwiftUI stop so the arc's falloff can be
    /// checked without a window: ``location`` is the fraction of the gradient's
    /// sweep and ``opacity`` is what the amber is drawn at there.
    public struct ArcStop: Equatable, Sendable {
        /// The position in the gradient's sweep, from `0` to `1`.
        public let location: Double
        /// The opacity of the amber at this position, from `0` to `1`.
        public let opacity: Double

        public init(location: Double, opacity: Double) {
            self.location = location
            self.opacity = opacity
        }
    }

    /// The falloff of the arc, as conic gradient stops.
    ///
    /// The head is the amber at full strength; behind it the amber falls
    /// linearly to nothing over ``trail`` degrees; everywhere else the stops are
    /// transparent, so the stroke has no ink to draw. The gradient is used
    /// rather than a trimmed path because a trimmed stroke ends in two cut caps,
    /// and a cap on a capsule's rim is a tick the person reads as a glitch.
    ///
    /// One stop of each pair sits a thousandth of a degree past the head: that is
    /// what makes the falloff stop at the head instead of running on round the
    /// rest of the rim.
    ///
    /// - Parameters:
    ///   - head: the head's angle, in degrees clockwise from the top.
    ///   - trail: how far behind the head the amber reaches, in degrees.
    /// - Returns: the stops in ascending order, each location in `0 ... 1`.
    public static func arcStops(head: Double, trail: Double) -> [ArcStop] {
        let reach = min(max(trail.isFinite ? trail : 0, 0), 360)
        guard reach > 0, head.isFinite else {
            return [ArcStop(location: 0, opacity: 0), ArcStop(location: 1, opacity: 0)]
        }
        // The gradient measures from three o'clock; the card measures from the
        // top. This is the only place the two meet.
        let headAngle = normalized(head - 90)
        let tailAngle = normalized(headAngle - reach)

        func opacity(at angle: Double) -> Double {
            let behind = normalized(headAngle - angle)
            guard behind <= reach else { return 0 }
            return 1 - behind / reach
        }

        var points: [(angle: Double, opacity: Double)] = [
            (0, opacity(at: 0)),
            (tailAngle, 0),
            (headAngle, 1),
            (min(headAngle + 0.001, 360), 0),
            (360, opacity(at: 360)),
        ]
        points.sort { $0.angle < $1.angle }
        var stops: [ArcStop] = []
        for point in points {
            let location = point.angle / 360
            if let last = stops.last, location - last.location < 1e-6 { continue }
            stops.append(ArcStop(location: location, opacity: point.opacity))
        }
        if stops.first?.location != 0 {
            stops.insert(ArcStop(location: 0, opacity: 0), at: 0)
        }
        if stops.last?.location != 1 {
            stops.append(ArcStop(location: 1, opacity: 0))
        }
        return stops
    }

    /// How strongly the arc and its glow are drawn.
    ///
    /// It is `1` for the whole of a run and falls to nothing over
    /// ``endFadeDuration`` once the run has ended, so a completion, a cancel and
    /// a failure all leave the same way. The reading is a function of the card's
    /// clock and the timestamp of the end, not an implicit animation: the view
    /// redraws on the clock it already has, and a test can ask for the value at
    /// any moment of the fade.
    ///
    /// - Parameters:
    ///   - isRunning: whether a rewrite is still arriving.
    ///   - endedAt: when the run stopped, on the card's clock.
    ///   - time: the card's clock, in seconds.
    ///   - reduceMotion: whether the system asked for reduced motion.
    /// - Returns: the opacity of the arc and the glow, from `0` to `1`. Reduced
    ///   motion draws the arc whole for the run and takes it away with the run:
    ///   a fade is motion, and the clock is not read.
    public static func arcFade(
        isRunning: Bool,
        endedAt: Double?,
        time: Double,
        reduceMotion: Bool
    ) -> Double {
        if isRunning { return 1 }
        guard !reduceMotion, let endedAt, endedAt.isFinite, time.isFinite else { return 0 }
        let elapsed = time - endedAt
        let remaining = 1 - elapsed / endFadeDuration
        return min(max(remaining, 0), 1)
    }

    /// One angle folded into `0 ..< 360`.
    private static func normalized(_ angle: Double) -> Double {
        let turns = angle / 360
        return (turns - turns.rounded(.down)) * 360
    }
}
