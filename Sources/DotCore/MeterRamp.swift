import Foundation

/// The amber the meter is drawn in, at one height.
///
/// The card has one colour for the voice, and it is the colour of the live dot:
/// a warm amber that goes deep at the floor and bright at a peak. The shape is
/// not porcelain and never white, because a shape that turns white at the top
/// has no colour left to say "that was loud" with, and because the owner of the
/// product remembers a meter that was amber and cannot see this one.
public struct MeterTint: Equatable, Sendable {
    /// The red component, in sRGB, from `0` to `1`.
    public let red: Double
    /// The green component, in sRGB, from `0` to `1`.
    public let green: Double
    /// The blue component, in sRGB, from `0` to `1`.
    public let blue: Double
    /// How opaque the bar is, from `0` to `1`.
    public let opacity: Double

    /// The brightest component of the tint: red, because the meter is warm.
    public var isWarm: Bool { red >= green && green >= blue }
}

/// The three altitudes of the meter's amber.
///
/// The stops are the product's own colour, `HUDTheme.live` (`#F5B944`), with a
/// deeper stop below it for a bar that has not been spoken into and a warmer
/// stop above it for a bar that is a peak of this take. Nothing here is
/// porcelain: the darkest stop is still recognisably amber and the brightest
/// keeps a blue component low enough that it can never read as white on the
/// card's ink.
public enum MeterRamp {
    /// The amber of a bar at the floor, `#C98B2A`.
    public static let deep = MeterTint(red: 0.788, green: 0.545, blue: 0.165, opacity: 1)
    /// The amber of the meter, `#F5B944`. It is the colour of the live dot.
    public static let live = MeterTint(red: 0.961, green: 0.725, blue: 0.267, opacity: 1)
    /// The warm tip of a peak, `#FFDA8B`.
    public static let tip = MeterTint(red: 1.000, green: 0.855, blue: 0.545, opacity: 1)

    /// The height a bar has to reach before it is drawn at the live amber
    /// rather than between the deep amber and it.
    public static let livePosition: Double = 0.62

    /// How far down the take's ceiling the warm tip starts.
    ///
    /// A tip is a peak *of this voice*: at `0.72` of the loudest moment the take
    /// has reached, a bar starts to warm, and at the ceiling it is as warm as it
    /// gets. A take that never gets loud therefore still has peaks the person
    /// can see, without the heights themselves being normalised.
    public static let tipOnset: Double = 0.55

    /// The tint of a bar.
    ///
    /// - Parameters:
    ///   - level: the height of the bar, from `0` to `1`.
    ///   - ceiling: the adaptive ceiling of the take, from `0` to `1`. A take
    ///     with no ceiling is drawn against the live amber's own height.
    /// - Returns: the colour and the opacity of the bar.
    public static func tint(level: Double, ceiling: Double = 1) -> MeterTint {
        let height = min(max(level, 0), 1)
        let reference = min(max(ceiling, 0.01), 1)
        let body = min(1, height / livePosition)
        let warm = smoothstep(tipOnset, 1, height / reference) * 0.85
        let base = mix(deep, live, body)
        let colour = mix(base, tip, warm)
        // A quiet bar is dim as well as short: the card's ink is dark, and a
        // floor that is drawn at full opacity reads as a bar someone spoke into.
        let opacity = 0.30 + 0.70 * min(1, height / 0.85)
        return MeterTint(
            red: colour.red,
            green: colour.green,
            blue: colour.blue,
            opacity: opacity
        )
    }

    /// One stop between two others.
    static func mix(_ from: MeterTint, _ to: MeterTint, _ amount: Double) -> MeterTint {
        let t = min(max(amount, 0), 1)
        return MeterTint(
            red: from.red + (to.red - from.red) * t,
            green: from.green + (to.green - from.green) * t,
            blue: from.blue + (to.blue - from.blue) * t,
            opacity: 1
        )
    }

    /// A smooth ramp between two edges: `0` at ``edge0``, `1` at ``edge1``.
    ///
    /// The meter uses it to warm a bar towards the tip, and the grid uses the
    /// same ramp for its halo, so a cell that is a little louder than the one
    /// beside it is a little brighter rather than either lit or dark.
    ///
    /// - Parameters:
    ///   - edge0: the value the ramp starts from.
    ///   - edge1: the value the ramp reaches.
    ///   - value: the value to place on the ramp.
    /// - Returns: the position on the ramp, from `0` to `1`.
    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
