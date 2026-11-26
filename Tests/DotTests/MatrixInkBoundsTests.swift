import AppKit
import DotCore
import SwiftUI
import XCTest
@testable import Dot

/// The dot matrix keeps every pixel it lights inside its own circle.
///
/// The previous lattice drew an additive halo and crossed glint arms outside the
/// dot and grew a lit dot to 0.66 of the lattice pitch. This measures the real
/// window-server picture against a bare card at the same clock and level, so the
/// bound is a property of the pixels rather than of a drawing constant.
@MainActor
final class MatrixInkBoundsTests: XCTestCase {
    private static let canvas = CGSize(width: 102, height: 26)
    private static let windowSize = canvas

    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    func testLitDotsStayInsideTheirCircles() throws {
        let lit = Self.view(level: 0.95, lit: true)
        let bare = Self.view(level: 0.95, lit: false)
        let picture = try Self.capture(lit)
        let clean = try Self.capture(bare)
        XCTAssertEqual(picture.width, clean.width)
        XCTAssertEqual(picture.height, clean.height)

        let dots = lit.matrixDots(in: Self.canvas)
        XCTAssertGreaterThan(dots.count, 20, "the still grid drew too few dots to measure")
        let pitch = Double(HUDWaveform.MatrixLattice.pitch(forHeight: Self.canvas.height))

        var widest = 0.0
        var outside = 0
        var checked = 0
        var worstOutside = 0.0
        for dot in dots {
            let diameter = Double(dot.radius) * 2 / pitch
            widest = max(widest, diameter)
            let bound = Double(dot.radius) * Double(picture.scale) + 0.5
            // The ellipse lands on a half-pixel of the backing store, so its
            // drawn centre is measured from the picture rather than assumed from
            // the point coordinate. The bound below still allows 0.5 px of edge
            // antialias around the 0.28-pitch circle.
            let expectedX = Int(Double(dot.centre.x) * Double(picture.scale))
            let expectedY = Int(Double(dot.centre.y) * Double(picture.scale))
            var weight = 0.0
            var wx = 0.0
            var wy = 0.0
            for y in max(0, expectedY - 5)...min(picture.height - 1, expectedY + 5) {
                for x in max(0, expectedX - 5)...min(picture.width - 1, expectedX + 5) {
                    let a = picture.pixel(x, y)
                    let b = clean.pixel(x, y)
                    let delta = max(0.0, max(a.0 - b.0, a.1 - b.1, a.2 - b.2)) / 255
                    weight += delta
                    wx += delta * Double(x)
                    wy += delta * Double(y)
                }
            }
            guard weight > 0 else { continue }
            let cx = wx / weight
            let cy = wy / weight
            let x0 = max(0, Int(floor(cx - bound - 1)))
            let x1 = min(picture.width - 1, Int(ceil(cx + bound + 1)))
            let y0 = max(0, Int(floor(cy - bound - 1)))
            let y1 = min(picture.height - 1, Int(ceil(cy + bound + 1)))
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) - cx
                    let dy = Double(y) - cy
                    guard (dx * dx + dy * dy).squareRoot() > bound else { continue }
                    checked += 1
                    let a = picture.pixel(x, y)
                    let b = clean.pixel(x, y)
                    let delta = max(
                        abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)
                    ) / 255
                    worstOutside = max(worstOutside, delta)
                    if delta > 3.0 / 255 {
                        outside += 1
                    }
                }
            }
        }
        print("MATRIXBOUND dots \(dots.count), widest diameter \(String(format: "%.4f", widest)) pitch, outside pixels \(outside) of \(checked), worst \(String(format: "%.4f", worstOutside))")
        XCTAssertLessThanOrEqual(widest, 0.56, "a lit dot is wider than 0.56 of the pitch")
        XCTAssertEqual(outside, 0, "a dot painted outside its own circle")
    }

    private static func view(level: Double, lit: Bool) -> HUDWaveform {
        let bands = AudioSpectrumFrame(bands: (level, level, level, level, level))
        return HUDWaveform(
            visualizer: .matrix,
            halfHeights: [],
            history: lit ? [Double](repeating: level, count: 180) : [],
            spectrumHistory: lit
                ? [AudioSpectrumFrame](repeating: bands, count: VoiceMeter.historyLength)
                : [],
            phase: 0,
            time: 2,
            level: level,
            ceiling: 1,
            reduceMotionOverride: true
        )
    }

    private static func capture(_ content: HUDWaveform) throws -> WindowCapture.Pixels {
        let bitmap = try MatrixSlideTests.rasterise(
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.05)
                content.frame(width: canvas.width, height: canvas.height)
            },
            size: canvas,
            scale: 2
        )
        let cg = try XCTUnwrap(bitmap.cgImage, "the render has no image")
        return try XCTUnwrap(WindowCapture.pixels(from: cg, scale: 2), "the render has no pixels")
    }

}
