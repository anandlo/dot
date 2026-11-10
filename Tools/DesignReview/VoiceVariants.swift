import DotCore
import SwiftUI

/// Four ways to draw a live voice, for choosing one.
///
/// Every one of them is a waveform and none of them translates sideways: a strip
/// that scrolls at a constant rate is a picture of a tape, not of a voice. These
/// are the alternatives, drawn from the same synthetic voice so the only
/// difference between them is the drawing.
enum VoiceVariant: String, CaseIterable, Identifiable {
    /// The app's dot at the centre of a ring whose radius is the voice.
    case ring
    /// Slices of the recent past receding into the card.
    case waterfall
    /// One wave drawn as a stack of contour lines.
    case engraved
    /// Two travelling waves whose sum is the voice.
    case interference

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ring: "Ring"
        case .waterfall: "Waterfall"
        case .engraved: "Engraved"
        case .interference: "Interference"
        }
    }
}

/// The synthetic voice the variants are drawn from.
///
/// One source for all four, so a comparison is a comparison of drawings.
enum VoiceSignal {
    /// How loud the voice is at a moment, from `0` to `1`.
    static func level(at time: Double) -> Double {
        let swell = SpeechShape.field(time * 0.55, 4.4)
        let detail = SpeechShape.field(time * 3.1, 17.0)
        return min(max(0.22 + 0.78 * swell * (0.45 + 0.55 * detail), 0), 1)
    }

    /// The shape of the voice across a stretch of it, from `-1` to `1`.
    ///
    /// - Parameters:
    ///   - along: where along the voice, `0` to `1`.
    ///   - time: the moment it is being looked at.
    static func shape(_ along: Double, at time: Double) -> Double {
        let fine = SpeechShape.field(along * 9 + time * 2.2, 3.0)
        let coarse = SpeechShape.field(along * 3 - time * 1.1, 9.0)
        let combined = 0.62 * fine + 0.38 * coarse
        return (combined - 0.5) * 2 * (0.35 + 0.65 * level(at: time))
    }
}

/// One of the four, drawn at whatever size it is given.
struct VoiceVariantView: View {
    let variant: VoiceVariant
    var animated = true
    /// The moment a still render holds.
    var still: Double = 3.1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    canvas(at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                canvas(at: still)
            }
        }
        .accessibilityHidden(true)
    }

    private func canvas(at time: Double) -> some View {
        Canvas { context, size in
            VoiceVariantFigure.draw(variant, in: &context, size: size, time: time)
        }
    }
}

/// The drawing of each variant at one moment.
enum VoiceVariantFigure {
    static func draw(
        _ variant: VoiceVariant,
        in context: inout GraphicsContext,
        size: CGSize,
        time: Double
    ) {
        guard size.width > 24, size.height > 16 else { return }
        switch variant {
        case .ring: drawRing(in: &context, size: size, time: time)
        case .waterfall: drawWaterfall(in: &context, size: size, time: time)
        case .engraved: drawEngraved(in: &context, size: size, time: time)
        case .interference: drawInterference(in: &context, size: size, time: time)
        }
    }

    /// Smooth speech-like heights for a moment, one per column.
    ///
    /// Push every drawing through this, so the only difference between the four
    /// is the drawing: same voice, same smoothness, same density.
    static func heights(moment: Double, columns: Int, reach: CGFloat) -> [CGFloat] {
        let raw = (0..<columns).map { column -> CGFloat in
            let along = Double(column) / Double(max(columns - 1, 1))
            let value = VoiceSignal.shape(along, at: moment)
            return CGFloat(0.22 + 0.78 * abs(value)) * reach
        }
        return Waveform.smoothed(raw, samples: columns)
    }

    // MARK: - Ring

    /// A polar waveform: radius is the level, angle is time.
    ///
    /// The app's dot sits at the centre, so the mark and the voice are one
    /// object rather than a mark beside a meter.
    private static func drawRing(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let base = min(size.width * 0.13, size.height * 0.34)
        let reach = base * 0.62
        let steps = 360
        let squashX: CGFloat = 1.22
        let squashY: CGFloat = 0.96

        func radius(at angle: Double, scale: CGFloat) -> CGFloat {
            let swell = SpeechShape.field(angle * 2.2 + time * 1.5, 5.0)
            let detail = SpeechShape.field(angle * 5.6 - time * 2.2, 12.0)
            let level = VoiceSignal.level(at: time)
            let wobble = (0.45 * swell + 0.55 * swell * detail) * (0.5 + 0.5 * level)
            return base + CGFloat(wobble) * reach * scale
        }

        func loop(scale: CGFloat) -> [CGPoint] {
            (0...steps).map { step in
                let angle = Double(step) / Double(steps) * 2 * .pi
                let r = radius(at: angle, scale: scale)
                return CGPoint(
                    x: centre.x + cos(angle) * r * squashX,
                    y: centre.y + sin(angle) * r * squashY
                )
            }
        }

        // A thin outer contour, so the edge reads as drawn rather than filled.
        let outerEdge = loop(scale: 1.14)
        var outline = Path()
        outline.move(to: outerEdge[0])
        for point in outerEdge.dropFirst() { outline.addLine(to: point) }
        outline.closeSubpath()
        context.stroke(outline, with: .color(HUDTheme.accent.opacity(0.35)), lineWidth: 1)

        let ring = loop(scale: 1.0)
        let hole = loop(scale: 0.52).reversed()
        var body = Path()
        body.move(to: ring[0])
        for point in ring.dropFirst() { body.addLine(to: point) }
        for point in hole { body.addLine(to: point) }
        body.closeSubpath()

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 7))
            layer.fill(body, with: .color(HUDTheme.accent.opacity(0.45)))
        }
        context.fill(
            body,
            with: .radialGradient(
                Gradient(colors: [
                    HUDTheme.accent.opacity(0.98),
                    HUDTheme.accent.opacity(0.62)
                ]),
                center: centre,
                startRadius: base * 0.5,
                endRadius: base + reach * 1.2
            )
        )

        let dot = base * 0.26
        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - dot, y: centre.y - dot,
                width: dot * 2, height: dot * 2
            )),
            with: .color(HUDTheme.live)
        )
    }

    // MARK: - Waterfall

    /// Slices of the recent past receding into the card.
    private static func drawWaterfall(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let slices = 6
        for depth in stride(from: slices - 1, through: 0, by: -1) {
            let scale = 1 - CGFloat(depth) * 0.075
            let width = size.width * scale
            let left = (size.width - width) / 2
            let mid = size.height * 0.50 + CGFloat(depth) * size.height * 0.062
            let reach = size.height * 0.26 * scale
            let moment = time - Double(depth) * 0.09
            let columns = max(48, Int(width / 3))
            let values = heights(moment: moment, columns: columns, reach: reach)

            var top: [CGPoint] = []
            var bottom: [CGPoint] = []
            for index in 0..<columns {
                let x = left + width * CGFloat(index) / CGFloat(columns - 1)
                top.append(CGPoint(x: x, y: mid - values[index]))
                bottom.append(CGPoint(x: x, y: mid + values[index]))
            }
            var path = Path()
            path.move(to: top[0])
            for point in top.dropFirst() { path.addLine(to: point) }
            for point in bottom.reversed() { path.addLine(to: point) }
            path.closeSubpath()

            let fade = 1 - Double(depth) / Double(slices)
            var layer = context
            layer.addFilter(.blur(radius: CGFloat(depth) * 0.45))
            layer.fill(path, with: .color(HUDTheme.accent.opacity(0.06 + 0.62 * fade * fade)))
            layer.stroke(
                path,
                with: .color(HUDTheme.accent.opacity(0.10 + 0.25 * fade)),
                lineWidth: 1
            )
        }
    }

    // MARK: - Engraved

    /// One wave as a stack of contour lines, like a printed plate.
    private static func drawEngraved(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let mid = size.height / 2
        let reach = size.height * 0.36
        let columns = max(80, Int(size.width / 2))
        let values = heights(moment: time, columns: columns, reach: reach)

        // The plate: a solid core with the wave etched across it.
        var core: [CGPoint] = []
        var coreLow: [CGPoint] = []
        for index in 0..<columns {
            let x = size.width * CGFloat(index) / CGFloat(columns - 1)
            core.append(CGPoint(x: x, y: mid - values[index] * 0.55))
            coreLow.append(CGPoint(x: x, y: mid + values[index] * 0.55))
        }
        var solid = Path()
        solid.move(to: core[0])
        for point in core.dropFirst() { solid.addLine(to: point) }
        for point in coreLow.reversed() { solid.addLine(to: point) }
        solid.closeSubpath()
        context.fill(solid, with: .color(HUDTheme.accent.opacity(0.30)))

        let lines = 14
        for line in 0..<lines {
            let fraction = Double(line) / Double(lines - 1)
            let scale = CGFloat(1 - fraction * 0.86)
            let opacity = 0.16 + 0.70 * (1 - fraction)
            var upper = Path()
            var lower = Path()
            for index in 0..<columns {
                let x = size.width * CGFloat(index) / CGFloat(columns - 1)
                let height = values[index] * scale
                let up = CGPoint(x: x, y: mid - height)
                let down = CGPoint(x: x, y: mid + height)
                if index == 0 {
                    upper.move(to: up)
                    lower.move(to: down)
                } else {
                    upper.addLine(to: up)
                    lower.addLine(to: down)
                }
            }
            context.stroke(upper, with: .color(HUDTheme.accent.opacity(opacity)), lineWidth: 1)
            context.stroke(lower, with: .color(HUDTheme.accent.opacity(opacity * 0.7)), lineWidth: 1)
        }
    }

    // MARK: - Interference

    /// Two travelling waves summed: the surface between them is the voice.
    private static func drawInterference(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let mid = size.height / 2
        let reach = size.height * 0.40
        let columns = max(120, Int(size.width / 2))

        var top: [CGPoint] = []
        var bottom: [CGPoint] = []
        for index in 0..<columns {
            let along = Double(index) / Double(max(columns - 1, 1))
            let first = SpeechShape.field(along * 5.5 + time * 1.3, 3.0)
            let second = SpeechShape.field(along * 9.0 - time * 1.9, 8.0)
            // The two trains add and cancel. Softened, not clipped: a clamp puts
            // a flat step where a voice has an edge.
            let sum = tanh((first - second) * 2.6)
            let level = VoiceSignal.level(at: time)
            let height = CGFloat(0.30 + 0.70 * abs(sum)) * CGFloat(0.45 + 0.55 * level) * reach
            let x = size.width * CGFloat(index) / CGFloat(columns - 1)
            top.append(CGPoint(x: x, y: mid - height))
            bottom.append(CGPoint(x: x, y: mid + height))
        }

        var path = Path()
        path.move(to: top[0])
        for point in top.dropFirst() { path.addLine(to: point) }
        for point in bottom.reversed() { path.addLine(to: point) }
        path.closeSubpath()

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 5))
            layer.fill(path, with: .color(HUDTheme.accent.opacity(0.33)))
        }
        let body = Gradient(stops: [
            .init(color: HUDTheme.accent.opacity(0.55), location: 0),
            .init(color: HUDTheme.accent, location: 0.5),
            .init(color: HUDTheme.accent.opacity(0.55), location: 1)
        ])
        context.fill(
            path,
            with: .linearGradient(
                body,
                startPoint: CGPoint(x: 0, y: mid - reach),
                endPoint: CGPoint(x: 0, y: mid + reach)
            )
        )
    }
}
