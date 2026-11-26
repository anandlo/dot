import AppKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

@MainActor
final class VisualizerCGRendererTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    func testAllVisualizersRenderNonEmptyAtLiveAndSwatchSizesAndStayUnderBudget() throws {
        let feed = VisualizerFeed.seeded(at: VisualizerTile.stillTime, leadSeconds: 5.0)
        let sizes = [CGSize(width: 520, height: 44), CGSize(width: 64, height: 22)]
        let materials: [HUDMaterial] = [.black, .glass]

        for visualizer in HUDVisualizer.allCases {
            for material in materials {
                for size in sizes {
                    let frame = VisualizerFrame(
                        visualizer: visualizer,
                        material: material,
                        history: feed.history,
                        spectrumHistory: feed.ring,
                        time: VisualizerTile.stillTime,
                        level: 0.68,
                        phase: feed.phase,
                        pulse: 0.25,
                        ceiling: 1,
                        reveal: 1,
                        reduceMotion: false,
                        highlight: true
                    )
                    let image = try renderCGImage(frame: frame, size: size, scale: 2.0)
                    let nonZero = try countNonEmptyPixels(in: image)
                    XCTAssertGreaterThan(
                        nonZero,
                        20,
                        "empty CG render for \(visualizer.rawValue) (\(material.rawValue)) at \(size)"
                    )
                }
            }
        }

        let liveSize = CGSize(width: 520, height: 44)
        for visualizer in HUDVisualizer.allCases {
            let benchFeed = VisualizerFeed.seeded(at: VisualizerTile.stillTime, leadSeconds: 5.0)
            let scratch = VisualizerRenderScratch()
            var totalMS = 0.0
            let iterations = 60
            for idx in 0..<iterations {
                let moment = VisualizerTile.stillTime + Double(idx) / 60.0
                benchFeed.advance(to: moment)
                let frame = VisualizerFrame(
                    visualizer: visualizer,
                    material: .black,
                    history: benchFeed.history,
                    spectrumHistory: benchFeed.ring,
                    time: moment,
                    level: 0.68,
                    phase: benchFeed.phase,
                    pulse: 0.25,
                    ceiling: 1,
                    reveal: 1,
                    reduceMotion: false,
                    highlight: true
                )
                let scale: CGFloat = 2.0
                let ctx = try makeBitmapContext(size: liveSize, scale: scale, background: nil)
                let started = CACurrentMediaTime()
                VisualizerCGRenderer.draw(frame, in: ctx, size: liveSize, scratch: scratch)
                totalMS += (CACurrentMediaTime() - started) * 1000
            }
            let avgMS = totalMS / Double(iterations)
            print("STEP12-CG-TIMING \(visualizer.rawValue): avg=\(String(format: "%.3f", avgMS))ms")
            let debugBudgetMS: Double = switch visualizer {
            case .stretch: 6.0
            case .silk, .haloEdge: 3.5
            case .matrix: 8.0
            case .filament: 16.0
            }
            XCTAssertLessThan(
                avgMS,
                debugBudgetMS,
                "\(visualizer.rawValue) exceeded \(debugBudgetMS) ms Debug (-Onone) budget: \(avgMS) ms"
            )
        }
    }

    func testExportStep12VisualComparisonsWhenRequested() throws {
        guard let outputDir = ProcessInfo.processInfo.environment["DOT_RENDER_STEP12_DIR"],
              !outputDir.isEmpty else {
            return
        }
        let dirURL = URL(fileURLWithPath: outputDir, isDirectory: true)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let feed = VisualizerFeed.seeded(at: VisualizerTile.stillTime, leadSeconds: 5.0)
        let cardBG = CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            components: [0.06, 0.06, 0.075, 1.0]
        )!
        let liveSize = CGSize(width: 520, height: 44)
        let swatchSize = CGSize(width: 64, height: 22)

        for visualizer in HUDVisualizer.allCases {
            let frame = VisualizerFrame(
                visualizer: visualizer,
                material: .black,
                history: feed.history,
                spectrumHistory: feed.ring,
                time: VisualizerTile.stillTime,
                level: 0.68,
                phase: feed.phase,
                pulse: 0.25,
                ceiling: 1,
                reveal: 1,
                reduceMotion: false,
                highlight: true
            )
            let cgLive = try renderCGImage(frame: frame, size: liveSize, scale: 2.0, background: cardBG)
            try writePNG(cgLive, to: dirURL.appendingPathComponent("cg-\(visualizer.rawValue)-520.png"))

            let cgSwatch = try renderCGImage(frame: frame, size: swatchSize, scale: 2.0, background: cardBG)
            try writePNG(cgSwatch, to: dirURL.appendingPathComponent("cg-\(visualizer.rawValue)-64.png"))

            let swiftUIView = ZStack {
                Color(red: 0.06, green: 0.06, blue: 0.075)
                HUDWaveform(
                    visualizer: visualizer,
                    halfHeights: [],
                    history: feed.history,
                    spectrumHistory: feed.ring,
                    phase: feed.phase,
                    time: VisualizerTile.stillTime,
                    level: 0.68,
                    pulse: 0.25,
                    ceiling: 1,
                    reveal: 1,
                    highlight: true,
                    reduceMotionOverride: false,
                    material: .black
                )
            }
            .frame(width: liveSize.width, height: liveSize.height)

            let renderer = ImageRenderer(content: swiftUIView)
            renderer.scale = 2.0
            if let swiftUIImage = renderer.cgImage {
                try writePNG(swiftUIImage, to: dirURL.appendingPathComponent("swiftui-\(visualizer.rawValue)-520.png"))
            }
        }

        let hud = HUD(offscreen: true)
        defer { hud.hide() }
        hud.material = .black
        hud.showTranscript(
            text: HUDPreview.longTranscript,
            delivery: .pasted,
            elapsed: "0:12"
        )
        hud.debugRootView.layoutSubtreeIfNeeded()
        for _ in 0..<6 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            hud.debugRootView.layoutSubtreeIfNeeded()
        }
        let host = hud.debugRootView
        let bounds = host.bounds
        if bounds.width > 0, bounds.height > 0,
           let rep = host.bitmapImageRepForCachingDisplay(in: bounds) {
            host.cacheDisplay(in: bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: dirURL.appendingPathComponent("hud-transcript-long.png"))
            }
        }

        // Export Filament loudness progression across ember (-55), red-hot (-30),
        // vermilion/amber (-20), warm gold (-10), and white-hot peak (0 dBFS).
        let filamentCardSize = CGSize(width: 180, height: 32)
        for material in [HUDMaterial.black, .glass] {
            let bg = material == .black
                ? cardBG
                : CGColor(
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    components: [0.35, 0.37, 0.42, 1.0]
                )!
            for dbfs in [-55, -30, -20, -10, 0] {
                let meter = VoiceMeter()
                meter.setCalibration(nil)
                var history: [Double] = []
                var spectrum: [AudioSpectrumFrame] = []
                for step in 0...Int(3.5 * Waveform.sampleRate) {
                    meter.push(decibels: Double(dbfs), now: Double(step) / Waveform.sampleRate)
                    meter.copyOrderedHistory(into: &history)
                    let shape = meter.shape
                    spectrum.append(AudioSpectrumFrame(bands: (shape, shape, shape, shape, shape)))
                }
                let frame = VisualizerFrame(
                    visualizer: .filament,
                    material: material,
                    history: history,
                    spectrumHistory: spectrum,
                    time: 4.0,
                    level: history.last ?? 0,
                    phase: 0,
                    pulse: 0.25,
                    ceiling: 1,
                    reveal: 1,
                    reduceMotion: false,
                    highlight: true
                )
                let cgImg = try renderCGImage(frame: frame, size: filamentCardSize, scale: 2.0, background: bg)
                try writePNG(
                    cgImg,
                    to: dirURL.appendingPathComponent("cg-filament-\(material.rawValue)-\(dbfs)dbfs.png")
                )
                let swiftUIView = ZStack {
                    Color(cgColor: bg)
                    HUDWaveform(
                        visualizer: .filament,
                        halfHeights: [],
                        history: history,
                        spectrumHistory: spectrum,
                        phase: 0,
                        time: 4.0,
                        level: history.last ?? 0,
                        pulse: 0.25,
                        ceiling: 1,
                        reveal: 1,
                        highlight: true,
                        reduceMotionOverride: false,
                        material: material
                    )
                }
                .frame(width: filamentCardSize.width, height: filamentCardSize.height)
                let swiftRenderer = ImageRenderer(content: swiftUIView)
                swiftRenderer.scale = 2.0
                if let swiftImg = swiftRenderer.cgImage {
                    try writePNG(
                        swiftImg,
                        to: dirURL.appendingPathComponent("swiftui-filament-\(material.rawValue)-\(dbfs)dbfs.png")
                    )
                }
            }
        }
    }

    private func makeBitmapContext(
        size: CGSize,
        scale: CGFloat,
        background: CGColor?
    ) throws -> CGContext {
        let width = max(1, Int((size.width * scale).rounded(.up)))
        let height = max(1, Int((size.height * scale).rounded(.up)))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw NSError(domain: "VisualizerCGRendererTests", code: 1)
        }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        if let background {
            ctx.setFillColor(background)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return ctx
    }

    private func renderCGImage(
        frame: VisualizerFrame,
        size: CGSize,
        scale: CGFloat,
        background: CGColor? = nil
    ) throws -> CGImage {
        let ctx = try makeBitmapContext(size: size, scale: scale, background: background)
        VisualizerCGRenderer.draw(frame, in: ctx, size: size)
        return try XCTUnwrap(ctx.makeImage())
    }

    private func countNonEmptyPixels(in image: CGImage) throws -> Int {
        guard let provider = image.dataProvider, let data = provider.data else {
            return 0
        }
        let length = CFDataGetLength(data)
        let bytes = CFDataGetBytePtr(data)!
        var count = 0
        var offset = 3
        while offset < length {
            if bytes[offset] > 8 {
                count += 1
            }
            offset += 4
        }
        return count
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "VisualizerCGRendererTests", code: 2)
        }
        try data.write(to: url)
    }

    func testLiveVisualizerNSViewWindowRemovalDoesNotStealSinkAndRebindIsIdempotent() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        window.contentView = container

        let sink = VisualizerFrameSink()
        let feed = VisualizerFeed.seeded(at: VisualizerTile.stillTime, leadSeconds: 5.0)
        var initialBuildsA = 0
        var initialBuildsB = 0
        func makeFrame() -> VisualizerFrame {
            VisualizerFrame(
                visualizer: .matrix,
                material: .black,
                history: feed.history,
                spectrumHistory: feed.ring,
                time: VisualizerTile.stillTime,
                level: 0.5,
                phase: feed.phase,
                pulse: 0.25,
                ceiling: 1,
                reveal: 1,
                reduceMotion: false,
                highlight: true
            )
        }

        let viewA = LiveVisualizerNSView(frame: NSRect(x: 0, y: 0, width: 64, height: 22))
        container.addSubview(viewA)
        viewA.bind(sink: sink, makeInitialFrame: {
            initialBuildsA += 1
            return makeFrame()
        })
        XCTAssertTrue(sink.debugHasAttachedLayer)
        XCTAssertEqual(initialBuildsA, 1)

        let viewB = LiveVisualizerNSView(frame: NSRect(x: 80, y: 0, width: 64, height: 22))
        container.addSubview(viewB)
        viewB.bind(sink: sink, makeInitialFrame: {
            initialBuildsB += 1
            return makeFrame()
        })
        let layerB = try XCTUnwrap(viewB.layer as? LiveVisualizerLayer)
        XCTAssertTrue(sink.isAttached(to: layerB))
        XCTAssertEqual(initialBuildsB, 0, "sink already has latestFrame from viewA")

        // Removing the departing view and dismantling it must not detach viewB's layer.
        viewA.removeFromSuperview()
        viewA.unbind()
        XCTAssertTrue(sink.debugHasAttachedLayer)
        XCTAssertTrue(sink.isAttached(to: layerB))

        // Re-binding viewB to the same sink is a no-op and does not push again.
        let beforeBuilds = initialBuildsB
        viewB.bind(sink: sink, makeInitialFrame: {
            initialBuildsB += 1
            return makeFrame()
        })
        XCTAssertEqual(initialBuildsB, beforeBuilds)
        XCTAssertTrue(sink.isAttached(to: layerB))
    }

    @MainActor
    func testLiveDotLayerRendersNonEmptyAndWindowRemovalDoesNotStealSink() throws {
        let dotSize = CGSize(width: 36, height: 36)
        let dotLayer = LiveDotLayer()
        dotLayer.bounds = CGRect(origin: .zero, size: dotSize)
        dotLayer.contentsScale = 2.0
        dotLayer.enqueue(LiveDotFrame(level: 0.7, pulse: 0.35, material: .black, reduceMotion: false))
        let dotCtx = try makeBitmapContext(size: dotSize, scale: 2.0, background: nil)
        dotLayer.draw(in: dotCtx)
        let dotImage = try XCTUnwrap(dotCtx.makeImage())
        XCTAssertGreaterThan(try countNonEmptyPixels(in: dotImage), 20)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 60))
        window.contentView = container

        let sink = LiveDotSink()
        let initialFrame = LiveDotFrame(level: 0.6, pulse: 0.25, material: .black, reduceMotion: false)
        var initialBuildsA = 0
        var initialBuildsB = 0

        let viewA = LiveDotNSView(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        container.addSubview(viewA)
        viewA.bind(sink: sink, makeInitialFrame: {
            initialBuildsA += 1
            return initialFrame
        })
        XCTAssertEqual(initialBuildsA, 1)
        XCTAssertNotNil(sink.latestFrame)

        let viewB = LiveDotNSView(frame: NSRect(x: 40, y: 0, width: 36, height: 36))
        container.addSubview(viewB)
        viewB.bind(sink: sink, makeInitialFrame: {
            initialBuildsB += 1
            return initialFrame
        })
        let layerB = try XCTUnwrap(viewB.layer as? LiveDotLayer)
        XCTAssertTrue(sink.isAttached(to: layerB))
        XCTAssertEqual(initialBuildsB, 0)

        viewA.removeFromSuperview()
        viewA.unbind()
        XCTAssertTrue(sink.isAttached(to: layerB))
    }
}
