import AppKit
import CryptoKit
import DotCore
import SwiftUI
import XCTest
@testable import Dot

/// The current-versus-proposed decision strip: four visualizers, three surfaces,
/// three levels. One window-server capture per cell, frozen history and a fixed
/// clock, written at the server's own scale when `DOT_RENDER_UI_DIR` is set.
@MainActor
final class VisualizerGoldStripTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    enum Surface: String, CaseIterable {
        case black
        case glassDark
        case glassWhite

        var material: HUDMaterial { self == .black ? .black : .glass }

        var backdrop: Color {
            switch self {
            case .black, .glassDark: return Color(red: 0.12, green: 0.12, blue: 0.12)
            case .glassWhite: return Color(red: 0.92, green: 0.92, blue: 0.92)
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

    private static let visualizers: [HUDVisualizer] = [.stretch, .silk, .matrix, .haloEdge]
    private static let cardCanvas = CGSize(width: 400, height: 160)
    private static let scale = 2

    static func history(level: Double) -> [Double] {
        var values = [Double](repeating: 0, count: 180)
        for index in 136..<values.count { values[index] = level }
        return values
    }

    func testRenderGoldStrips() throws {
        guard let directory = ProcessInfo.processInfo.environment["DOT_RENDER_UI_DIR"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let cells = root.appendingPathComponent("cells", isDirectory: true)
        try FileManager.default.createDirectory(at: cells, withIntermediateDirectories: true)

        var measurements: [String: [String: Double]] = [:]
        var count = 0
        for visualizer in Self.visualizers {
            for surface in Surface.allCases {
                let bare = try capture(surface: surface, visualizer: visualizer, level: nil)
                for level in Level.allCases {
                    let picture = try capture(surface: surface, visualizer: visualizer, level: level)
                    guard let bounds = WindowCapture.changedBounds(picture, bare) else {
                        XCTFail("\(visualizer) \(surface.rawValue) \(level.rawValue): no ink was drawn")
                        continue
                    }
                    let rect = Self.waveRect(bounds, in: picture)
                    let cell = Self.crop(picture, to: rect)
                    let clean = Self.crop(bare, to: rect)
                    let name = "\(visualizer.rawValue)-\(surface.rawValue)-\(level.rawValue).png"
                    XCTAssertTrue(
                        WindowCapture.write(cell, to: cells.appendingPathComponent(name)),
                        "\(name) was not written"
                    )
                    let bg = Self.median(Self.background(clean))
                    let fg = Self.percentile(Self.foreground(cell, bare: clean), 0.90)
                    let contrast = (max(bg, fg) + 0.05) / (min(bg, fg) + 0.05)
                    var row = measurements[visualizer.rawValue] ?? [:]
                    row["\(surface.rawValue)-\(level.rawValue)"] = contrast
                    measurements[visualizer.rawValue] = row
                    count += 1
                }
            }
        }
        XCTAssertEqual(count, 36, "the strip must hold four styles, three surfaces and three levels")
        let manifest: [String: Any] = [
            "scale": Self.scale,
            "cells": measurements,
            "order": [
                "visualizers": Self.visualizers.map(\.rawValue),
                "surfaces": Surface.allCases.map(\.rawValue),
                "levels": Level.allCases.map(\.rawValue),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("contrast.json"), options: .atomic)
        print("GOLDSTRIP \(count) cells at \(root.path)")
    }

    private func capture(
        surface: Surface,
        visualizer: HUDVisualizer,
        level: Level?
    ) throws -> WindowCapture.Pixels {
        let view = ZStack {
            surface.backdrop
            card(visualizer: visualizer, height: level?.value, material: surface.material)
        }
        .frame(width: Self.cardCanvas.width, height: Self.cardCanvas.height)
        let window = WindowCapture.show(view, size: Self.cardCanvas)
        defer { WindowCapture.hide(window) }
        let picture = try XCTUnwrap(
            WindowCapture.capture(window),
            "the window server returned no picture of the card"
        )
        try WindowCapture.requireUsableCapture(picture, requiresContent: level != nil)
        return picture
    }

    private func card(
        visualizer: HUDVisualizer,
        height: Double?,
        material: HUDMaterial
    ) -> some View {
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
        model.visualizer = visualizer
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

    private static func waveRect(
        _ bounds: WindowCapture.Rect,
        in picture: WindowCapture.Pixels
    ) -> WindowCapture.Rect {
        let halfHeight = Int((13 * picture.scale).rounded())
        let top = max(0, bounds.midY - halfHeight)
        let bottom = min(picture.height, bounds.midY + halfHeight)
        let x = max(0, bounds.x - 8)
        return WindowCapture.Rect(
            x: x,
            y: top,
            width: min(picture.width - x, bounds.width + 16),
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

    private static func background(_ cell: WindowCapture.Pixels) -> [Double] {
        var values: [Double] = []
        for y in cell.height / 6 ..< cell.height - cell.height / 6 {
            for x in cell.width / 10 ..< cell.width - cell.width / 10 {
                values.append(WindowCapture.luminance(cell.pixel(x, y)))
            }
        }
        return values
    }

    private static func foreground(
        _ cell: WindowCapture.Pixels,
        bare: WindowCapture.Pixels
    ) -> [Double] {
        var values: [Double] = []
        for y in cell.height / 6 ..< cell.height - cell.height / 6 {
            for x in cell.width / 2 ..< cell.width - Int(Double(cell.width) * 0.12) {
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
}
