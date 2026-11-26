import Foundation

/// The Wave row's opacity curve, read from the shared gold ramp.
///
/// Wave used to own warmer, lemon-tipped RGB stops. Its stops now come from
/// ``MeterRamp`` with the other three styles; what stays here is the row's own
/// level-to-alpha curve, which rises faster than its height so a quiet bar is
/// present without being loud.
public enum WaveInk {
    /// The level at which the row reaches its speech gold.
    public static let speechPosition: Double = 0.52
    /// The level at which the row is at its brightest ordinary gold.
    public static let tipPosition: Double = 0.70

    /// The floor of the Black card's row.
    public static var blackFloor: MeterTint { MeterRamp.stops(for: .black).floor }
    /// The speech gold of the Black card's row.
    public static var blackSpeech: MeterTint { MeterRamp.stops(for: .black).body }
    /// The peak gold of the Black card's row.
    public static var blackTip: MeterTint { MeterRamp.stops(for: .black).peak }
    /// The floor of the Glass card's row.
    public static var glassFloor: MeterTint { MeterRamp.stops(for: .glass).floor }
    /// The speech gold of the Glass card's row.
    public static var glassSpeech: MeterTint { MeterRamp.stops(for: .glass).body }
    /// The peak gold of the Glass card's row.
    public static var glassTip: MeterTint { MeterRamp.stops(for: .glass).peak }

    /// The three body stops a material draws with, from the shared ramp.
    public static func stops(for material: HUDMaterial) -> (
        floor: MeterTint, speech: MeterTint, tip: MeterTint
    ) {
        let ramp = MeterRamp.stops(for: material)
        return (ramp.floor, ramp.body, ramp.peak)
    }

    /// The tint of one bar, from its height on the fixed `0...1` scale.
    public static func tint(level: Double, material: HUDMaterial) -> MeterTint {
        let height = min(max(level, 0), 1)
        let colour = MeterRamp.rgb(level: height, material: material)
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
