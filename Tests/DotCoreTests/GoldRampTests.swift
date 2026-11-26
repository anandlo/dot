import DotCore
import XCTest

/// The shared gold ramp, measured where the styles consume it.
///
/// The body of the ramp must stay saturated gold all the way to its peak: an
/// earlier ramp reached a pale tip (OKLCH chroma 0.106) and Wave reached a lemon
/// tip (hue 101 to 105 degrees). Specular is a separate spatial stop, so it is
/// measured here as the top of ``MeterRamp/hot(_:)`` and not as a body stop.
final class GoldRampTests: XCTestCase {
    private struct Stop {
        let red: Double
        let green: Double
        let blue: Double

        init(_ red: Int, _ green: Int, _ blue: Int) {
            self.red = Double(red) / 255
            self.green = Double(green) / 255
            self.blue = Double(blue) / 255
        }
    }

    private struct Gold {
        let floor: Stop
        let body: Stop
        let peak: Stop
        let specular: Stop
    }

    private let black = Gold(
        floor: Stop(0xD4, 0x93, 0x12),
        body: Stop(0xFF, 0xC4, 0x14),
        peak: Stop(0xFF, 0xD4, 0x26),
        specular: Stop(0xFF, 0xF2, 0xC2)
    )

    private let glass = Gold(
        floor: Stop(0xF2, 0xB9, 0x1C),
        body: Stop(0xFF, 0xD8, 0x38),
        peak: Stop(0xFF, 0xE1, 0x54),
        specular: Stop(0xFF, 0xF5, 0xCE)
    )

    private func gold(_ material: HUDMaterial) -> Gold {
        material == .black ? black : glass
    }

    private func assertStop(
        _ tint: MeterTint,
        _ stop: Stop,
        _ material: HUDMaterial,
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (channel, value, expected) in [
            ("red", tint.red, stop.red),
            ("green", tint.green, stop.green),
            ("blue", tint.blue, stop.blue),
        ] {
            XCTAssertEqual(
                value, expected, accuracy: 0.5 / 255,
                "\(material) \(name): \(channel) is not the gold stop",
                file: file, line: line
            )
        }
    }

    /// Every stop of every material is the owner's exact hex.
    func testExactStopsPerMaterial() {
        for material in HUDMaterial.allCases {
            let expected = gold(material)
            let stops = WaveInk.stops(for: material)
            assertStop(stops.floor, expected.floor, material, "floor")
            assertStop(stops.speech, expected.body, material, "body")
            assertStop(stops.tip, expected.peak, material, "peak")
            assertStop(MeterRamp.hot(1, material: material), expected.specular, material, "specular")
        }
    }

    /// The body stops sit at their named positions on the fixed level scale.
    func testRampPositions() {
        for material in HUDMaterial.allCases {
            let expected = gold(material)
            assertStop(WaveInk.tint(level: 0, material: material), expected.floor, material, "ramp(0)")
            assertStop(WaveInk.tint(level: 0.52, material: material), expected.body, material, "ramp(0.52)")
            assertStop(WaveInk.tint(level: 0.78, material: material), expected.peak, material, "ramp(0.78)")
        }
    }

    /// No sample of a lit body may turn lemon or pale.
    func testBodySamplesStayGold() {
        for material in HUDMaterial.allCases {
            for step in 4...20 {
                let level = Double(step) / 20
                let tint = WaveInk.tint(level: level, material: material)
                let (l, c, h) = oklch(tint)
                XCTAssertGreaterThanOrEqual(
                    h, 74, "\(material) at \(level): hue \(h) fell out of gold"
                )
                XCTAssertLessThanOrEqual(
                    h, 98, "\(material) at \(level): hue \(h) reached lemon"
                )
                XCTAssertGreaterThanOrEqual(
                    c, 0.14, "\(material) at \(level): chroma \(c) is pale"
                )
                XCTAssertGreaterThan(l, 0.60, "\(material) at \(level): body is too dark")
            }
        }
    }

    /// The interpolant is OKLab, not sRGB: the midpoint's chroma stays on the
    /// ridge between the stops instead of sagging toward grey.
    func testInterpolationIsPerceptual() {
        for material in HUDMaterial.allCases {
            let low = WaveInk.tint(level: 0.52, material: material)
            let high = WaveInk.tint(level: 0.78, material: material)
            let mid = WaveInk.tint(level: 0.65, material: material)
            let midpointChroma = (oklch(low).1 + oklch(high).1) / 2
            XCTAssertEqual(oklch(mid).1, midpointChroma, accuracy: 0.012,
                           "\(material): the ramp midpoint sagged off the OKLab ridge")
        }
    }

    // MARK: - Colour science

    private func oklch(_ tint: MeterTint) -> (Double, Double, Double) {
        let r = linear(tint.red)
        let g = linear(tint.green)
        let b = linear(tint.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let c = (a * a + bb * bb).squareRoot()
        var h = atan2(bb, a) * 180 / Double.pi
        if h < 0 { h += 360 }
        return (L, c, h)
    }

    private func linear(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
}
