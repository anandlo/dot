import AppKit
import DotCore
import os
import QuartzCore
import SwiftUI

/// Thread-safe handle connecting a main-actor frame producer (`HUD` or
/// `VisualizerSwatchDriver`) directly to a synchronous `CALayer` without
/// invalidating any SwiftUI state or view body.
@MainActor
final class VisualizerFrameSink {
    private weak var layer: LiveVisualizerLayer?
    private(set) var latestFrame: VisualizerFrame?
    var onLayerDraw: (@Sendable (CFTimeInterval, Double) -> Void)? {
        didSet {
            layer?.setOnDraw(onLayerDraw)
        }
    }

    var debugHasAttachedLayer: Bool { layer != nil }

    func isAttached(to layer: LiveVisualizerLayer) -> Bool {
        self.layer === layer
    }

    func attach(_ layer: LiveVisualizerLayer) {
        self.layer = layer
        layer.setOnDraw(onLayerDraw)
        if let latestFrame {
            layer.enqueue(latestFrame)
        }
    }

    func detach(_ layer: LiveVisualizerLayer) {
        guard self.layer === layer else { return }
        self.layer = nil
    }

    func push(_ frame: VisualizerFrame) {
        latestFrame = frame
        layer?.enqueue(frame)
    }
}

/// Synchronous CoreGraphics `CALayer` that rasterizes `VisualizerFrame` snapshots
/// directly during CoreAnimation commit with zero per-frame allocations.
final class LiveVisualizerLayer: CALayer {
    private let frameLock = OSAllocatedUnfairLock<VisualizerFrame?>(initialState: nil)
    private let onDrawLock = OSAllocatedUnfairLock<(@Sendable (CFTimeInterval, Double) -> Void)?>(
        initialState: nil
    )
    private let scratch = VisualizerRenderScratch()

    override init() {
        super.init()
        configure()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let source = layer as? LiveVisualizerLayer {
            let copiedFrame = source.copyFrame()
            let copiedOnDraw = source.copyOnDraw()
            frameLock.withLock { $0 = copiedFrame }
            onDrawLock.withLock { $0 = copiedOnDraw }
        }
        configure()
    }

    private func copyFrame() -> VisualizerFrame? {
        frameLock.withLock { $0 }
    }

    private func copyOnDraw() -> (@Sendable (CFTimeInterval, Double) -> Void)? {
        onDrawLock.withLock { $0 }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isGeometryFlipped = true
        drawsAsynchronously = false
        isOpaque = false
        needsDisplayOnBoundsChange = true
        actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
        ]
    }

    func setOnDraw(_ callback: (@Sendable (CFTimeInterval, Double) -> Void)?) {
        onDrawLock.withLock { $0 = callback }
    }

    func enqueue(_ frame: VisualizerFrame) {
        frameLock.withLock { $0 = frame }
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        guard let frame = frameLock.withLock({ $0 }) else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let callback = onDrawLock.withLock { $0 }
        let drawStarted = callback != nil ? CACurrentMediaTime() : 0
        VisualizerCGRenderer.draw(frame, in: ctx, size: size, scratch: scratch)
        if let callback {
            let drawEnded = CACurrentMediaTime()
            callback(drawEnded, (drawEnded - drawStarted) * 1000)
        }
    }
}

/// Non-hit-testing AppKit host view backing `LiveVisualizerLayer`.
final class LiveVisualizerNSView: NSView {
    private weak var sink: VisualizerFrameSink?
    private var makeInitialFrame: (@MainActor () -> VisualizerFrame)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer {
        LiveVisualizerLayer()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let visualizerLayer else { return }
        guard window != nil else {
            sink?.detach(visualizerLayer)
            return
        }
        updateContentsScale()
        if let sink, !sink.isAttached(to: visualizerLayer) {
            sink.attach(visualizerLayer)
            if sink.latestFrame == nil, let frame = makeInitialFrame?() {
                sink.push(frame)
            }
        }
    }

    func bind(
        sink: VisualizerFrameSink,
        makeInitialFrame: @escaping @MainActor () -> VisualizerFrame
    ) {
        let sinkChanged = self.sink !== sink
        if sinkChanged, let visualizerLayer {
            self.sink?.detach(visualizerLayer)
        }
        self.sink = sink
        self.makeInitialFrame = makeInitialFrame
        guard window != nil, let visualizerLayer else { return }
        updateContentsScale()
        if sinkChanged || !sink.isAttached(to: visualizerLayer) {
            sink.attach(visualizerLayer)
            if sink.latestFrame == nil {
                sink.push(makeInitialFrame())
            }
        }
    }

    func unbind() {
        if let visualizerLayer {
            sink?.detach(visualizerLayer)
        }
        sink = nil
        makeInitialFrame = nil
    }

    private var visualizerLayer: LiveVisualizerLayer? {
        layer as? LiveVisualizerLayer
    }

    private func updateContentsScale() {
        guard let visualizerLayer else { return }
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        if visualizerLayer.contentsScale != scale {
            visualizerLayer.contentsScale = scale
            visualizerLayer.setNeedsDisplay()
        }
    }
}

/// SwiftUI bridge that mounts a single `LiveVisualizerNSView` backed by a
/// synchronous `CALayer` and never participates in per-frame SwiftUI invalidations.
struct LiveVisualizerView: NSViewRepresentable {
    let sink: VisualizerFrameSink
    let makeInitialFrame: @MainActor () -> VisualizerFrame

    func makeNSView(context: Context) -> LiveVisualizerNSView {
        let view = LiveVisualizerNSView(frame: .zero)
        view.bind(sink: sink, makeInitialFrame: makeInitialFrame)
        return view
    }

    func updateNSView(_ nsView: LiveVisualizerNSView, context: Context) {
        nsView.bind(sink: sink, makeInitialFrame: makeInitialFrame)
    }

    static func dismantleNSView(_ nsView: LiveVisualizerNSView, coordinator: ()) {
        nsView.unbind()
    }
}

/// Immutable snapshot driving `LiveDotLayer` directly without SwiftUI layout or
/// gradient churn at 60/120 Hz.
struct LiveDotFrame: Sendable, Equatable {
    var level: Double = 0
    var pulse: Double = 0
    var material: HUDMaterial = .black
    var reduceMotion: Bool = false
}

/// Main-actor handle connecting `HUD` / `HUDFrameModel` directly to `LiveDotLayer`.
@MainActor
final class LiveDotSink {
    private weak var layer: LiveDotLayer?
    private(set) var latestFrame: LiveDotFrame?

    func isAttached(to layer: LiveDotLayer) -> Bool {
        self.layer === layer
    }

    func attach(_ layer: LiveDotLayer) {
        self.layer = layer
        if let latestFrame {
            layer.enqueue(latestFrame)
        }
    }

    func detach(_ layer: LiveDotLayer) {
        guard self.layer === layer else { return }
        self.layer = nil
    }

    func push(_ frame: LiveDotFrame) {
        latestFrame = frame
        layer?.enqueue(frame)
    }
}

/// Synchronous `CALayer` drawing the recording indicator dot, radial glow, and
/// pulsing ring on a fixed-size `36x36 pt` canvas.
final class LiveDotLayer: CALayer {
    private let frameLock = OSAllocatedUnfairLock<LiveDotFrame?>(initialState: nil)
    private static let colorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    override init() {
        super.init()
        configure()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let source = layer as? LiveDotLayer {
            let copied = source.copyFrame()
            frameLock.withLock { $0 = copied }
        }
        configure()
    }

    private func copyFrame() -> LiveDotFrame? {
        frameLock.withLock { $0 }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isGeometryFlipped = true
        drawsAsynchronously = false
        isOpaque = false
        needsDisplayOnBoundsChange = true
        actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
        ]
    }

    func enqueue(_ frame: LiveDotFrame) {
        frameLock.withLock { $0 = frame }
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        guard let frame = frameLock.withLock({ $0 }) else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let presence = min(1, max(0, frame.level))
        let baseDiameter = HUDTheme.dotDiameter

        // Glow halo matching SwiftUI LiveDot stops (0.25, 0.62, 1.0)
        let glowDiameter = baseDiameter * (1 + presence * 0.26) + (5.0 + 9.0 * presence)
        let glowRadius = glowDiameter * 0.5
        let glowAlpha = 0.30 + 0.55 * presence
        let glowTint = frame.material == .glass
            ? (red: 1.0, green: 216.0 / 255.0, blue: 56.0 / 255.0)
            : (red: 1.0, green: 196.0 / 255.0, blue: 20.0 / 255.0)

        let glowColors: [CGColor] = [
            Self.cgColor(red: glowTint.red, green: glowTint.green, blue: glowTint.blue, alpha: glowAlpha),
            Self.cgColor(red: glowTint.red, green: glowTint.green, blue: glowTint.blue, alpha: glowAlpha * 0.35),
            Self.cgColor(red: glowTint.red, green: glowTint.green, blue: glowTint.blue, alpha: 0),
        ]
        if let grad = CGGradient(
            colorsSpace: Self.colorSpace,
            colors: glowColors as CFArray,
            locations: [0.25, 0.62, 1.0]
        ) {
            ctx.drawRadialGradient(
                grad,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: glowRadius,
                options: [.drawsBeforeStartLocation]
            )
        }

        // Expanding pulse ring when motion is enabled
        if !frame.reduceMotion {
            let scale = 1.0 + frame.pulse * (1.15 + 0.45 * presence)
            let ringDiameter = baseDiameter * scale
            let ringAlpha = min(1, max(0, (0.42 + 0.30 * presence) * (1 - frame.pulse)))
            if ringAlpha > 0.002 {
                ctx.setStrokeColor(Self.cgColor(
                    red: glowTint.red,
                    green: glowTint.green,
                    blue: glowTint.blue,
                    alpha: ringAlpha
                ))
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: CGRect(
                    x: center.x - ringDiameter * 0.5,
                    y: center.y - ringDiameter * 0.5,
                    width: ringDiameter,
                    height: ringDiameter
                ))
            }
        }

        // Core dot
        let coreTint = MeterRamp.tint(level: 0.42 + 0.58 * presence, ceiling: 1, material: frame.material)
        let coreDiameter = baseDiameter * (1 + presence * 0.26)
        ctx.setFillColor(Self.cgColor(
            red: coreTint.red,
            green: coreTint.green,
            blue: coreTint.blue,
            alpha: coreTint.opacity
        ))
        ctx.fillEllipse(in: CGRect(
            x: center.x - coreDiameter * 0.5,
            y: center.y - coreDiameter * 0.5,
            width: coreDiameter,
            height: coreDiameter
        ))
    }

    private static func cgColor(red: Double, green: Double, blue: Double, alpha: Double) -> CGColor {
        CGColor(
            colorSpace: colorSpace,
            components: [
                CGFloat(red),
                CGFloat(green),
                CGFloat(blue),
                CGFloat(min(1, max(0, alpha))),
            ]
        )!
    }
}

/// Non-hit-testing AppKit host view backing `LiveDotLayer`.
final class LiveDotNSView: NSView {
    private weak var sink: LiveDotSink?
    private var makeInitialFrame: (@MainActor () -> LiveDotFrame)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer {
        LiveDotLayer()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let dotLayer else { return }
        guard window != nil else {
            sink?.detach(dotLayer)
            return
        }
        updateContentsScale()
        if let sink, !sink.isAttached(to: dotLayer) {
            sink.attach(dotLayer)
            if sink.latestFrame == nil, let frame = makeInitialFrame?() {
                sink.push(frame)
            }
        }
    }

    func bind(
        sink: LiveDotSink,
        makeInitialFrame: @escaping @MainActor () -> LiveDotFrame
    ) {
        let sinkChanged = self.sink !== sink
        if sinkChanged, let dotLayer {
            self.sink?.detach(dotLayer)
        }
        self.sink = sink
        self.makeInitialFrame = makeInitialFrame
        guard window != nil, let dotLayer else { return }
        updateContentsScale()
        if sinkChanged || !sink.isAttached(to: dotLayer) {
            sink.attach(dotLayer)
            if sink.latestFrame == nil {
                sink.push(makeInitialFrame())
            }
        }
    }

    func unbind() {
        if let dotLayer {
            sink?.detach(dotLayer)
        }
        sink = nil
        makeInitialFrame = nil
    }

    private var dotLayer: LiveDotLayer? {
        layer as? LiveDotLayer
    }

    private func updateContentsScale() {
        guard let dotLayer else { return }
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        if dotLayer.contentsScale != scale {
            dotLayer.contentsScale = scale
            dotLayer.setNeedsDisplay()
        }
    }
}

/// SwiftUI bridge mounting `LiveDotLayer` without per-frame SwiftUI invalidations.
struct LiveDotView: NSViewRepresentable {
    let sink: LiveDotSink
    let makeInitialFrame: @MainActor () -> LiveDotFrame

    func makeNSView(context: Context) -> LiveDotNSView {
        let view = LiveDotNSView(frame: .zero)
        view.bind(sink: sink, makeInitialFrame: makeInitialFrame)
        return view
    }

    func updateNSView(_ nsView: LiveDotNSView, context: Context) {
        nsView.bind(sink: sink, makeInitialFrame: makeInitialFrame)
    }

    static func dismantleNSView(_ nsView: LiveDotNSView, coordinator: ()) {
        nsView.unbind()
    }
}
