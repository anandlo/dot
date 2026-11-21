import AppKit
import CryptoKit
import DotCore
import SwiftUI
import XCTest
@testable import Dot

/// The Wave row's own ink, measured on the row with its card behind it.
///
/// Every picture here is a window-server capture of an offscreen window at twice
/// the points, so the glass is the material the app actually draws. The history is
/// frozen: the right half of the row holds one level and the left half is the tail
/// it left behind, so a cell is a measurement of an ink rather than of a clock.
@MainActor
final class WaveInkTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    // MARK: - The cells

    enum Surface: String, CaseIterable {
        case black
        case glassDark
        case glassWhite

        var material: HUDMaterial { self == .black ? .black : .glass }

        var backdrop: GlassBackdrop {
            switch self {
            case .black: return .solid(0.12)
            case .glassDark: return .solid(0.12)
            case .glassWhite: return .solid(0.92)
            }
        }
    }

    enum Level: String, CaseIterable {
        case quiet, speech, loud

        var value: Double {
            switch self {
            case .quiet: return 0.20
            case .speech: return 0.45
            case .loud: return 0.85
            }
        }
    }

    static let canvas = CGSize(width: 102, height: 26)
    static let cardCanvas = CGSize(width: 400, height: 160)
    static let scale = 2

    /// A frozen envelope: the rightmost forty-four samples hold the level, the
    /// older ones are silence, and the fixed clock places the boundary in the
    /// middle of the row.
    static func history(level: Double) -> [Double] {
        var values = [Double](repeating: 0, count: 180)
        for index in 136..<values.count { values[index] = level }
        return values
    }

    // MARK: - The thresholds

    func testContrastThresholds() throws {
        var measured: [String: Double] = [:]
        for surface in Surface.allCases {
            let bare = try capture(surface: surface, level: nil)
            for level in Level.allCases {
                let picture = try capture(surface: surface, level: level)
                guard let bounds = WindowCapture.changedBounds(picture, bare) else {
                    XCTFail("\(surface.rawValue) \(level.rawValue): the row drew no ink")
                    continue
                }
                let cell = Self.crop(picture, to: Self.waveRect(bounds, in: picture))
                let clean = Self.crop(bare, to: Self.waveRect(bounds, in: picture))
                let bg = Self.median(Self.background(clean))
                let fg = Self.percentile(Self.foreground(cell, bare: clean), 0.90)
                measured["\(surface.rawValue)-\(level.rawValue)"] =
                    (max(bg, fg) + 0.05) / (min(bg, fg) + 0.05)
            }
        }
        func require(_ key: String, _ floor: Double) {
            let value = measured[key] ?? 0
            XCTAssertGreaterThanOrEqual(
                value, floor,
                "\(key): the proposed Wave ink reads \(String(format: "%.2f", value)) to 1"
            )
        }
        require("black-quiet", 3.0)
        require("black-speech", 7.0)
        require("black-loud", 12.0)
        require("glassDark-quiet", 3.0)
        require("glassDark-speech", 6.0)
        require("glassWhite-speech", 2.4)
        require("glassWhite-loud", 3.0)
    }

    /// The colour a full-ink bar actually puts on the Black card.
    ///
    /// At 0.55 the Black ramp has reached full opacity and is still within two
    /// levels of the speech stop, so the middle of a right-hand bar is the stop
    /// rather than the dimmer gradient at its tips.
    func testRenderedBlackSpeechIsTheStop() throws {
        let height = 0.55
        let bare = try capture(surface: .black, height: nil)
        let picture = try capture(surface: .black, height: height)
        guard let bounds = WindowCapture.changedBounds(picture, bare) else {
            XCTFail("the frozen Black row drew no ink")
            return
        }
        let rect = Self.waveRect(bounds, in: picture)
        let cell = Self.crop(picture, to: rect)
        let clean = Self.crop(bare, to: rect)
        var peak = 0.0
        var pixels: [(Double, Double, Double)] = []
        for y in cell.height / 6 ..< cell.height - cell.height / 6 {
            for x in cell.width / 2 ..< cell.width - Int(Double(cell.width) * 0.12) {
                let ink = cell.pixel(x, y)
                let luminance = WindowCapture.luminance(ink)
                guard luminance - WindowCapture.luminance(clean.pixel(x, y)) > 0.01 else { continue }
                peak = max(peak, luminance)
                pixels.append(ink)
            }
        }
        XCTAssertFalse(pixels.isEmpty, "no bar pixels were found in the Black row")
        let full = pixels.filter { WindowCapture.luminance($0) >= peak - 0.005 }
        XCTAssertFalse(full.isEmpty, "no full-ink pixels were found in the Black row")
        let red = full.map { $0.0 }.reduce(0, +) / Double(full.count) / 255
        let green = full.map { $0.1 }.reduce(0, +) / Double(full.count) / 255
        let blue = full.map { $0.2 }.reduce(0, +) / Double(full.count) / 255
        let stop = WaveInk.blackSpeech
        let tolerance = 2.0 / 255
        XCTAssertEqual(red, stop.red, accuracy: tolerance, "rendered red is not the speech stop")
        XCTAssertEqual(green, stop.green, accuracy: tolerance, "rendered green is not the speech stop")
        XCTAssertEqual(blue, stop.blue, accuracy: tolerance, "rendered blue is not the speech stop")
        print(String(
            format: "WAVEINKPIXEL black speech %.5f %.5f %.5f over %d full-ink pixels",
            red, green, blue, full.count
        ))
    }

    /// The Wave row's ink is a value assertion on the colour the row draws, and
    /// a byte assertion on two glass canvases that differ only in the lift.
    func testWaveOnGlassHasNoLift() throws {
        let level = 0.45
        let expected = WaveInk.tint(level: level, material: .glass)
        let drawn = NSColor(HUDWaveform.stretchInk(level: level, material: .glass))
        let rgb = try XCTUnwrap(drawn.usingColorSpace(.deviceRGB))
        XCTAssertEqual(Double(rgb.redComponent), expected.red, accuracy: 0.002)
        XCTAssertEqual(Double(rgb.greenComponent), expected.green, accuracy: 0.002)
        XCTAssertEqual(Double(rgb.blueComponent), expected.blue, accuracy: 0.002)
        XCTAssertEqual(Double(rgb.alphaComponent), expected.opacity, accuracy: 0.002)

        func canvas(lift: Double) throws -> Data {
            let view = HUDWaveform(
                visualizer: .stretch,
                halfHeights: [],
                history: Self.history(level: level),
                phase: 0,
                time: 2,
                level: level,
                ceiling: 1,
                reveal: 1,
                material: .glass,
                glassLift: lift
            )
            .frame(width: Self.canvas.width, height: Self.canvas.height)
            let bitmap = try Self.rasterise(view)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        let unlifted = try canvas(lift: 0)
        let lifted = try canvas(lift: 1)
        XCTAssertEqual(
            Self.hash(unlifted), Self.hash(lifted),
            "the card's glass lift reached the Wave row"
        )
    }

    /// The tips of the bars carry more ink than their middles; the age fade is
    /// the one share of ink that this change leaves alone.
    func testStretchInkShares() {
        XCTAssertEqual(HUDWaveform.Stretch.tipInk, 0.85, accuracy: 1e-12)
        XCTAssertEqual(HUDWaveform.Stretch.floorInk, 0.16, accuracy: 1e-12)
    }

    /// The Settings tile and the card ask for the same material.
    func testTilePassesTheMaterial() {
        let feed = VisualizerFeed()
        for material in HUDMaterial.allCases {
            let tile = VisualizerTile.waveform(
                .stretch, from: feed, at: 1.2, halfHeights: [], material: material
            )
            XCTAssertEqual(tile.material, material)
        }
    }

    // MARK: - The picture

    private func capture(surface: Surface, level: Level?) throws -> WindowCapture.Pixels {
        try capture(surface: surface, height: level?.value)
    }

    private func capture(surface: Surface, height: Double?) throws -> WindowCapture.Pixels {
        let view = ZStack {
            surface.backdrop
            card(height: height, material: surface.material)
        }
        .frame(width: Self.cardCanvas.width, height: Self.cardCanvas.height)
        let window = WindowCapture.show(view, size: Self.cardCanvas)
        defer { WindowCapture.hide(window) }
        let picture = try XCTUnwrap(
            WindowCapture.capture(window),
            "the window server returned no picture of the card"
        )
        try WindowCapture.requireUsableCapture(picture, requiresContent: height != nil)
        return picture
    }

    private func card(height: Double?, material: HUDMaterial) -> some View {
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.material = material
        model.mode = .recording(elapsed: "0:07")
        model.cardSize = CGSize(
            width: HUDState.recordingWidth,
            height: HUDState.recordingHeight
        )
        model.visualizer = .stretch
        model.history = height.map(Self.history(level:)) ?? []
        model.spectrumHistory = []
        model.ceiling = 1
        model.level = height ?? 0
        model.phase = 0
        model.time = 2
        model.pulse = 0.25
        model.reveal = 1
        return HUDView(
            model: model,
            showsShadow: false,
            animated: false,
            actions: HUDPreview.previewActions
        )
        .frame(width: model.cardSize.width, height: model.cardSize.height)
    }

    // MARK: - Measurement

    /// The row's rect in a capture, widened to the whole canvas and its margin.
    private static func waveRect(
        _ bounds: WindowCapture.Rect,
        in picture: WindowCapture.Pixels
    ) -> WindowCapture.Rect {
        let halfHeight = Int((13 * picture.scale).rounded())
        let top = max(0, bounds.midY - halfHeight)
        let bottom = min(picture.height, bounds.midY + halfHeight)
        return WindowCapture.Rect(
            x: max(0, bounds.x - 8),
            y: top,
            width: min(picture.width - max(0, bounds.x - 8), bounds.width + 16),
            height: bottom - top
        )
    }

    private static func crop(
        _ picture: WindowCapture.Pixels,
        to rect: WindowCapture.Rect
    ) -> WindowCapture.Pixels {
        var pixels = [UInt8]()
        pixels.reserveCapacity(rect.width * rect.height * 4)
        for y in rect.y ..< min(picture.height, rect.y + rect.height) {
            for x in rect.x ..< min(picture.width, rect.x + rect.width) {
                let index = (y * picture.width + x) * 4
                pixels.append(contentsOf: picture.data[index ..< index + 4])
            }
        }
        return WindowCapture.Pixels(
            width: rect.width,
            height: min(picture.height, rect.y + rect.height) - rect.y,
            data: pixels,
            scale: picture.scale
        )
    }

    /// The middle of the unlit canvas: the row before any bar is drawn on it.
    private static func background(_ cell: WindowCapture.Pixels) -> [Double] {
        var values: [Double] = []
        let x0 = cell.width / 10
        let x1 = cell.width - cell.width / 10
        let y0 = cell.height / 6
        let y1 = cell.height - cell.height / 6
        for y in y0 ..< y1 {
            for x in x0 ..< x1 {
                values.append(WindowCapture.luminance(cell.pixel(x, y)))
            }
        }
        return values
    }

    /// The bar pixels of the right half, without the live edge's glow.
    ///
    /// A pixel is ink when it is brighter than the same pixel of the row before
    /// any bar was drawn: a percentile over the whole region would read the
    /// surface between the bars at a quiet level, where bars cover little of it.
    private static func foreground(
        _ cell: WindowCapture.Pixels,
        bare: WindowCapture.Pixels
    ) -> [Double] {
        var values: [Double] = []
        let x0 = cell.width / 2
        let x1 = cell.width - Int(Double(cell.width) * 0.12)
        let y0 = cell.height / 6
        let y1 = cell.height - cell.height / 6
        for y in y0 ..< y1 {
            for x in x0 ..< x1 {
                let ink = WindowCapture.luminance(cell.pixel(x, y))
                let surface = WindowCapture.luminance(bare.pixel(x, y))
                if ink - surface > 0.01 { values.append(ink) }
            }
        }
        return values
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    private static func rasterise(_ content: some View) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let hosting = NSHostingView(
            rootView: content
                .frame(width: Self.canvas.width, height: Self.canvas.height)
                .environment(\.colorScheme, .dark)
                .environment(\.displayScale, CGFloat(Self.scale))
        )
        hosting.frame = NSRect(origin: .zero, size: Self.canvas)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = OffscreenWindow(size: Self.canvas, styleMask: [.borderless])
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Self.canvas.width) * Self.scale,
            pixelsHigh: Int(Self.canvas.height) * Self.scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = Self.canvas
        if let data = bitmap.bitmapData {
            memset(data, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        hosting.cacheDisplay(
            in: NSRect(origin: .zero, size: Self.canvas),
            to: bitmap
        )
        window.contentView = nil
        window.orderOut(nil)
        return bitmap
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
