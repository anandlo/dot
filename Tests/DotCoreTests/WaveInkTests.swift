import DotCore
import XCTest

/// The Wave-only ramp and its opacities, on both card materials.
final class WaveInkTests: XCTestCase {
    private struct Sample {
        let tint: MeterTint
    }

    private func samples(_ material: HUDMaterial) -> [Sample] {
        [0, WaveInk.speechPosition, WaveInk.tipPosition, 1].map {
            Sample(tint: WaveInk.tint(level: $0, material: material))
        }
    }

    private struct Colour {
        let red: Double
        let green: Double
        let blue: Double
    }

    private func stop(_ red: Double, _ green: Double, _ blue: Double) -> Colour {
        Colour(red: red, green: green, blue: blue)
    }

    private func assertColour(
        _ tint: MeterTint,
        _ stop: Colour,
        _ material: HUDMaterial,
        _ height: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (name, value, expected) in [
            ("red", tint.red, stop.red),
            ("green", tint.green, stop.green),
            ("blue", tint.blue, stop.blue),
        ] {
            XCTAssertEqual(
                value, expected, accuracy: 1e-12,
                "\(material) at \(height): \(name) is not the stop",
                file: file, line: line
            )
        }
    }

    private func assertColour(
        _ tint: MeterTint,
        _ stop: MeterTint,
        _ material: HUDMaterial,
        _ height: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (name, value, expected) in [
            ("red", tint.red, stop.red),
            ("green", tint.green, stop.green),
            ("blue", tint.blue, stop.blue),
        ] {
            XCTAssertEqual(
                value, expected, accuracy: 1e-12,
                "\(material) at \(height): \(name) is not the stop",
                file: file, line: line
            )
        }
    }

    func testBlackStopsAndOpacities() {
        XCTAssertEqual(WaveInk.speechPosition, 0.52, accuracy: 1e-12)
        XCTAssertEqual(WaveInk.tipPosition, 0.70, accuracy: 1e-12)
        let rows = samples(.black)
        assertColour(rows[0].tint, stop(229.0 / 255, 173.0 / 255, 26.0 / 255), .black, 0)
        assertColour(rows[1].tint, stop(1, 212.0 / 255, 59.0 / 255), .black, WaveInk.speechPosition)
        assertColour(rows[2].tint, stop(1, 233.0 / 255, 74.0 / 255), .black, WaveInk.tipPosition)
        assertColour(rows[3].tint, stop(1, 233.0 / 255, 74.0 / 255), .black, 1)

        XCTAssertEqual(rows[0].tint.opacity, 0.34, accuracy: 1e-12)
        XCTAssertEqual(
            rows[1].tint.opacity,
            0.34 + 0.66 * (WaveInk.speechPosition / 0.55),
            accuracy: 1e-12
        )
        XCTAssertEqual(rows[2].tint.opacity, 1, accuracy: 1e-12)
        XCTAssertEqual(rows[3].tint.opacity, 1, accuracy: 1e-12)
    }

    func testGlassStopsAndOpacities() {
        let rows = samples(.glass)
        assertColour(rows[0].tint, stop(242.0 / 255, 194.0 / 255, 41.0 / 255), .glass, 0)
        assertColour(rows[1].tint, stop(1, 226.0 / 255, 77.0 / 255), .glass, WaveInk.speechPosition)
        assertColour(rows[2].tint, stop(1, 242.0 / 255, 61.0 / 255), .glass, WaveInk.tipPosition)
        assertColour(rows[3].tint, stop(1, 242.0 / 255, 61.0 / 255), .glass, 1)

        XCTAssertEqual(rows[0].tint.opacity, 0.55, accuracy: 1e-12)
        XCTAssertEqual(
            WaveInk.tint(level: 0.225, material: .glass).opacity, 0.775, accuracy: 1e-12
        )
        XCTAssertEqual(rows[1].tint.opacity, 1, accuracy: 1e-12)
        XCTAssertEqual(rows[2].tint.opacity, 1, accuracy: 1e-12)
        XCTAssertEqual(rows[3].tint.opacity, 1, accuracy: 1e-12)
    }

    func testRampIsMonotone() {
        for material in HUDMaterial.allCases {
            var previousOpacity = -1.0
            var previousLuminance = -1.0
            for step in 0...100 {
                let height = Double(step) / 100
                let tint = WaveInk.tint(level: height, material: material)
                let luminance = 0.2126 * tint.red + 0.7152 * tint.green + 0.0722 * tint.blue
                XCTAssertGreaterThanOrEqual(
                    tint.opacity, previousOpacity,
                    "\(material) opacity fell at \(height)"
                )
                XCTAssertGreaterThanOrEqual(
                    luminance, previousLuminance,
                    "\(material) colour luminance fell at \(height)"
                )
                previousOpacity = tint.opacity
                previousLuminance = luminance
            }
        }
    }

    /// The ramp stays on its stops outside the range it is handed.
    func testLevelIsClamped() {
        for material in HUDMaterial.allCases {
            let below = WaveInk.tint(level: -2, material: material)
            let floor = WaveInk.tint(level: 0, material: material)
            let above = WaveInk.tint(level: 4, material: material)
            let ceiling = WaveInk.tint(level: 1, material: material)
            assertColour(below, floor, material, -2)
            assertColour(above, ceiling, material, 4)
            XCTAssertEqual(below.opacity, floor.opacity, accuracy: 1e-12)
            XCTAssertEqual(above.opacity, ceiling.opacity, accuracy: 1e-12)
        }
    }
}
