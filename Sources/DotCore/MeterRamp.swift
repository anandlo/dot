import Foundation

/// One colour of the visualizer, in sRGB components and its own opacity.
///
/// RGB and opacity are kept apart. Silk and Orbit multiply a tint's opacity by
/// their own ink, so a colour that carried Wave's level curve would be dimmed
/// twice; those styles read the RGB stops and supply their own alpha.
public struct MeterTint: Equatable, Sendable {
    /// The red component, in sRGB, from `0` to `1`.
    public let red: Double
    /// The green component, in sRGB, from `0` to `1`.
    public let green: Double
    /// The blue component, in sRGB, from `0` to `1`.
    public let blue: Double
    /// How opaque the tint is, from `0` to `1`.
    public let opacity: Double

    /// The brightest component of the tint: red, because the meter is warm.
    public var isWarm: Bool { red >= green && green >= blue }

    public init(red: Double, green: Double, blue: Double, opacity: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
    }
}

/// The four colours one material draws with.
///
/// The first three are the body ramp, from a burnished floor to a saturated
/// peak. Specular is not a fourth point on that ramp: it is a narrow spatial
/// highlight, used in the middle of a loud bar, the die of a lit dot, the rim of
/// a ribbon and the centre of the orbit's sun. Spreading it across a whole mark
/// is what made the earlier ramp read as pale butter.
public struct MeterStops: Equatable, Sendable {
    public let floor: MeterTint
    public let body: MeterTint
    public let peak: MeterTint
    public let specular: MeterTint
}

/// The one gold ramp the four visualizers share, tuned per material.
///
/// The stops are the owner's exact hex. The body holds an OKLCH chroma of at
/// least `0.14` all the way to the peak and a hue between 74 and 98 degrees, so
/// neither the pale `#FFDA8B` nor the lemon `#FFF23D` can return. Interpolation
/// is in OKLab: an sRGB mix between these stops drags the midpoint off the
/// saturated gold ridge and makes a loud bar look like paint.
public enum MeterRamp {
    /// The level at which a bar is drawn at the body stop.
    public static let bodyPosition: Double = 0.52
    /// The level at which a bar is drawn at the peak stop.
    public static let peakPosition: Double = 0.78

    /// The body and specular stops of one material.
    public static func stops(for material: HUDMaterial) -> MeterStops {
        switch material {
        case .black:
            return MeterStops(
                floor: MeterTint(red: 212 / 255, green: 147 / 255, blue: 18 / 255, opacity: 1),
                body: MeterTint(red: 1, green: 196 / 255, blue: 20 / 255, opacity: 1),
                peak: MeterTint(red: 1, green: 212 / 255, blue: 38 / 255, opacity: 1),
                specular: MeterTint(red: 1, green: 242 / 255, blue: 194 / 255, opacity: 1)
            )
        case .glass:
            return MeterStops(
                floor: MeterTint(red: 242 / 255, green: 185 / 255, blue: 28 / 255, opacity: 1),
                body: MeterTint(red: 1, green: 216 / 255, blue: 56 / 255, opacity: 1),
                peak: MeterTint(red: 1, green: 225 / 255, blue: 84 / 255, opacity: 1),
                specular: MeterTint(red: 1, green: 245 / 255, blue: 206 / 255, opacity: 1)
            )
        }
    }

    /// The pure RGB of one level of the body ramp.
    ///
    /// - Parameter level: the height on the fixed `0...1` scale.
    /// - Returns: an opaque tint, whatever the level. The caller owns the alpha.
    public static func rgb(level: Double, material: HUDMaterial) -> MeterTint {
        let height = min(max(level, 0), 1)
        let stops = stops(for: material)
        if height <= bodyPosition {
            return mix(stops.floor, stops.body, height / bodyPosition)
        }
        return mix(stops.body, stops.peak, smoothstep(bodyPosition, peakPosition, height))
    }

    /// The tint of a bar, with the meter's own level curve.
    ///
    /// Styles that multiply this colour by their own ink pass ``rgb(level:material:)``
    /// instead, so the opacity is not applied twice.
    public static func tint(level: Double, ceiling: Double, material: HUDMaterial = .black) -> MeterTint {
        let height = min(max(level, 0), 1)
        let colour = rgb(level: height, material: material)
        return MeterTint(
            red: colour.red,
            green: colour.green,
            blue: colour.blue,
            opacity: 0.30 + 0.70 * min(1, height / 0.85)
        )
    }

    /// A peak's colour mixed into the material's specular highlight.
    ///
    /// The shine is spatial, never temporal: a dot or bar at the same level
    /// always gets the same highlight. The smoothstep keeps the onset gradual.
    public static func specularBand(level: Double, material: HUDMaterial) -> MeterTint {
        let stops = stops(for: material)
        return mix(stops.peak, stops.specular, smoothstep(0.55, 0.90, level))
    }

    /// The specular stop mixed by `amount`, for the small lamps that carry one.
    public static func hot(_ amount: Double, material: HUDMaterial = .black) -> MeterTint {
        let stops = stops(for: material)
        return mix(stops.peak, stops.specular, amount)
    }

    /// One stop between two others, interpolated in OKLab.
    public static func mix(_ from: MeterTint, _ to: MeterTint, _ amount: Double) -> MeterTint {
        let t = min(max(amount, 0), 1)
        if t == 0 { return from }
        if t == 1 { return to }
        let a = oklab(from)
        let b = oklab(to)
        let mixed = OKLab(
            lightness: a.lightness + (b.lightness - a.lightness) * t,
            a: a.a + (b.a - a.a) * t,
            b: a.b + (b.b - a.b) * t
        )
        let rgb = srgb(mixed)
        return MeterTint(
            red: rgb.red,
            green: rgb.green,
            blue: rgb.blue,
            opacity: from.opacity + (to.opacity - from.opacity) * t
        )
    }

    /// A smooth ramp between two edges: `0` at ``edge0``, `1` at ``edge1``.
    public static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Colour space

    private struct OKLab {
        let lightness: Double
        let a: Double
        let b: Double
    }

    private struct RGB {
        let red: Double
        let green: Double
        let blue: Double
    }

    private static func oklab(_ tint: MeterTint) -> OKLab {
        let r = linear(tint.red)
        let g = linear(tint.green)
        let b = linear(tint.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return OKLab(
            lightness: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    private static func srgb(_ lab: OKLab) -> RGB {
        let l = lab.lightness + 0.3963377774 * lab.a + 0.2158037573 * lab.b
        let m = lab.lightness - 0.1055613458 * lab.a - 0.0638541728 * lab.b
        let s = lab.lightness - 0.0894841775 * lab.a - 1.2914855480 * lab.b
        let rl = l * l * l
        let ml = m * m * m
        let sl = s * s * s
        return RGB(
            red: encoded(4.0767416621 * rl - 3.3077115913 * ml + 0.2309699292 * sl),
            green: encoded(-1.2684380046 * rl + 2.6097574011 * ml - 0.3413193965 * sl),
            blue: encoded(-0.0041960863 * rl - 0.7034186147 * ml + 1.7076147010 * sl)
        )
    }

    private static func linear(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ component: Double) -> Double {
        let clamped = min(max(component, 0), 1)
        return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }
}
