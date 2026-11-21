import Foundation

/// The ink of the Wave row, on the two materials the card draws.
///
/// It has its own stops rather than sharing the meter's: a bar that is short is
/// still a bright yellow, so the row reads as light on the card instead of as a
/// trace someone left there. The stops are interpolated in sRGB components, the
/// same way ``MeterRamp`` mixes its own, and the opacity rises faster than the
/// height so a quiet bar is present without being loud.
public enum WaveInk {
    /// The height of the speech stop.
    public static let speechPosition: Double = 0.52
    /// The height at which the tip stop is fully reached.
    public static let tipPosition: Double = 0.70

    /// The floor of the Black card's row, `#E5AD1A`.
    public static let blackFloor = MeterTint(
        red: 229.0 / 255, green: 173.0 / 255, blue: 26.0 / 255, opacity: 1
    )
    /// The speech stop of the Black card's row, `#FFD43B`.
    public static let blackSpeech = MeterTint(
        red: 1, green: 212.0 / 255, blue: 59.0 / 255, opacity: 1
    )
    /// The tip of the Black card's row, `#FFE94A`.
    public static let blackTip = MeterTint(
        red: 1, green: 233.0 / 255, blue: 74.0 / 255, opacity: 1
    )

    /// The floor of the Glass card's row, `#F2C229`.
    public static let glassFloor = MeterTint(
        red: 242.0 / 255, green: 194.0 / 255, blue: 41.0 / 255, opacity: 1
    )
    /// The speech stop of the Glass card's row, `#FFE24D`.
    public static let glassSpeech = MeterTint(
        red: 1, green: 226.0 / 255, blue: 77.0 / 255, opacity: 1
    )
    /// The tip of the Glass card's row, `#FFF23D`.
    public static let glassTip = MeterTint(
        red: 1, green: 242.0 / 255, blue: 61.0 / 255, opacity: 1
    )

    /// The three stops a material draws with.
    public static func stops(for material: HUDMaterial) -> (
        floor: MeterTint, speech: MeterTint, tip: MeterTint
    ) {
        switch material {
        case .black: return (blackFloor, blackSpeech, blackTip)
        case .glass: return (glassFloor, glassSpeech, glassTip)
        }
    }

    /// The tint of one bar, from its height on the fixed `0...1` scale.
    public static func tint(level: Double, material: HUDMaterial) -> MeterTint {
        let height = min(max(level, 0), 1)
        let stops = stops(for: material)
        let colour: MeterTint
        if height <= speechPosition {
            colour = MeterRamp.mix(stops.floor, stops.speech, height / speechPosition)
        } else {
            colour = MeterRamp.mix(
                stops.speech,
                stops.tip,
                MeterRamp.smoothstep(speechPosition, tipPosition, height)
            )
        }
        let rise = material == .black ? 0.55 : 0.45
        let base = material == .black ? 0.34 : 0.55
        let gain = material == .black ? 0.66 : 0.45
        return MeterTint(
            red: colour.red,
            green: colour.green,
            blue: colour.blue,
            opacity: base + gain * min(1, height / rise)
        )
    }
}
