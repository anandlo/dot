import AppKit
import CoreGraphics
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// Renders the settled and pouring card for the shadow comparison. The test is
/// driven only when SHADOW_RENDER_DIR is set, so the normal suite does not write
/// files.
@MainActor
final class ShadowComparisonTests: XCTestCase {
    func testShadowRenders() throws {
        let directory = ProcessInfo.processInfo.environment["SHADOW_RENDER_DIR"]
        let label = ProcessInfo.processInfo.environment["SHADOW_RENDER_LABEL"] ?? "render"
        try XCTSkipIf(directory == nil, "SHADOW_RENDER_DIR is not set")
        let root = URL(fileURLWithPath: directory!, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FontFixture.register()

        let screen = HUDEmergence.Screen(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 24, width: 1512, height: 938),
            safeTop: 32,
            leftArea: CGRect(x: 0, y: 950, width: 645.5, height: 32),
            rightArea: CGRect(x: 824.5, y: 950, width: 645.5, height: 32)
        )
        let placement = HUDEmergence.placement(
            screen: screen,
            panelSize: HUD.panelSize,
            topInset: 10,
            shadowPadding: HUD.shadowPadding
        )
        let rest = HUDEmergence.Rest(
            rect: CGRect(origin: .zero, size: HUDState.recordingCard.size),
            cornerRadius: HUDTheme.cornerRadius
        )
        let source = placement.scene.source(inCardOf: HUDState.recordingCard.size)

        let cases: [(String, Double?, HUDMaterial)] = [
            ("settled", nil, .black),
            ("settled", nil, .glass),
            ("pour-25", 0.25, .black),
            ("pour-25", 0.25, .glass),
            ("pour-50", 0.50, .black),
            ("pour-50", 0.50, .glass),
            ("pour-75", 0.75, .black),
            ("pour-75", 0.75, .glass),
        ]

        for (name, targetMix, material) in cases {
            let model = HUDModel()
            model.mode = .recording(elapsed: "0:07")
            model.cardSize = HUDState.recordingCard.size
            model.isVisible = true
            model.presence = 1
            model.content = 1
            model.visualizer = .matrix
            model.material = material
            model.level = 0.68
            model.ceiling = 1
            model.reveal = 1
            model.pulse = 0.25
            model.time = 2.4
            let emergence: HUDEmergence.Scene?
            if let targetMix {
                let progress = Self.progress(for: targetMix, source: source, rest: rest)
                model.emergence = progress
                var placed = placement.scene
                placed.source.rect = placed.source.rect.offsetBy(
                    dx: -placement.panelFrame.minX,
                    dy: 0
                )
                emergence = placed
            } else {
                model.emergence = 1
                emergence = nil
            }

            let view = HUDView(
                model: model,
                showsShadow: true,
                animated: false,
                actions: HUDPreview.previewActions,
                emergence: emergence
            )
            .padding(HUD.shadowPadding)
            .frame(width: HUD.panelSize.width, height: HUD.panelSize.height)
            .environment(\.displayScale, 2)
            .environment(\.colorScheme, .dark)
            let data = try Self.png(of: view, size: HUD.panelSize)
            let file = root.appendingPathComponent("\(label)-\(name)-\(material.rawValue).png")
            try data.write(to: file, options: .atomic)
        }
    }

    private static func progress(
        for target: Double,
        source: HUDEmergence.Source,
        rest: HUDEmergence.Rest
    ) -> Double {
        var best = 0.0
        var distance = Double.greatestFiniteMagnitude
        var progress = 0.0
        while progress <= 1.2 {
            let mix = HUDEmergence.shape(
                progress: progress,
                source: source,
                rest: rest
            ).mix
            let gap = abs(mix - target)
            if gap < distance {
                distance = gap
                best = progress
            }
            progress += 0.001
        }
        return best
    }

    private static func png(of view: some View, size: CGSize) throws -> Data {
        let hosting = NSHostingView(rootView: AnyView(
            view.frame(width: size.width, height: size.height)
        ))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * 2,
            pixelsHigh: Int(size.height) * 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { throw TestError.bitmap }
        bitmap.size = size
        hosting.cacheDisplay(in: NSRect(origin: .zero, size: size), to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw TestError.encoding
        }
        return data
    }

    enum TestError: Error {
        case bitmap
        case encoding
    }
}
