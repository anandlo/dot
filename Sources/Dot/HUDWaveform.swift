import DotCore
import SwiftUI

/// The audio visualizer in the recording HUD card.
///
/// Five styles, chosen in Settings:
///
/// - `.stretch`: resting dots that stretch into capsules, one bar per moment of
///   the last half second.
/// - `.filament`: discrete capsule bars scrolling in phase.
/// - `.silk`: braided harmonic ribbons whose amplitude is the voice itself.
/// - `.matrix`: a dot-matrix spectrogram.
/// - `.haloEdge`: a centre line with a conic aura around the card's perimeter.
///
/// Every style is driven by the same three inputs: the per-bar heights of the
/// recent voice (``VisualizerBars``), the envelope history and the 5-band
/// spectrum. Every bar is a measurement, so two bars of the same frame have
/// different heights whenever the voice did; and every bar is drawn in the
/// amber ramp of ``MeterRamp``, deep at the floor, the live amber at speech and
/// warm at a peak. The shape rests at a hairline when nothing is being said, so
/// the card is alive without pretending to hear a voice in an empty room.
struct HUDWaveform: View {
    var visualizer: HUDVisualizer = .stretch
    /// The half height of every column, in points.
    let halfHeights: [CGFloat]
    /// The 60 Hz envelope history, oldest first, each in `0...1`.
    var history: [Double] = []
    /// The 60 Hz 5-band spectrum history, oldest first.
    var spectrumHistory: [AudioSpectrumFrame] = []
    /// Where inside one sample period the meter sits, in `0..<1`, so scrolling
    /// moves by a fraction of a column instead of jumping a whole one.
    var phase: Double = 0
    /// Unwrapped elapsed time, in seconds. It is never reduced modulo a loop, so
    /// a harmonic style does not snap at a boundary.
    var time: Double = 0
    /// The voice level, from `0` to `1`.
    var level: Double = 0
    /// The phase of the live animation, from `0` to `1`.
    var pulse: Double = 0
    /// The loudest moment of this take, from `0` to `1`, so a peak is drawn as a
    /// peak of this voice rather than as a peak of any voice.
    var ceiling: Double = 1
    /// The per-bar heights this frame draws, from `0` to `1`, left to right.
    ///
    /// The card computes them once per tick into a buffer it keeps, so a frame
    /// costs no allocation here. An empty value means the view was drawn on its
    /// own, as a Settings swatch is, and the bars are computed from the history.
    var bars: [Double] = []
    /// How much of the shape has arrived, from `0` to `1`.
    ///
    /// It is what makes the shape grow out of the axis when a recording starts
    /// and settle back into it when the recording ends, instead of appearing at
    /// a full height it had from nowhere.
    var reveal: Double = 1
    /// Whether a shining dot carries its specular highlight.
    ///
    /// The highlight is the one part of the shine that is a picture rather than a
    /// measurement: it is drawn in the renders beside a version without it, and
    /// the picture that reads better is the one the card keeps.
    var highlight: Bool = true

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }

            switch visualizer {
            case .stretch:
                drawStretch(context: context, size: size)
            case .filament:
                drawFilament(context: context, size: size)
            case .silk:
                drawSilk(context: context, size: size)
            case .matrix:
                drawMatrix(context: context, size: size)
            case .haloEdge:
                drawHaloEdgeCenter(context: context, size: size)
            }
        }
    }

    // MARK: - Helpers

    /// The `0...1` envelope sample `offsetFromNewest` ticks ago, `0` being the
    /// newest. It reads zero outside the history rather than trapping.
    private func sample(offsetFromNewest offset: Int) -> Double {
        if !history.isEmpty {
            return VisualizerBars.sample(history: history, offsetFromNewest: offset)
        }
        guard !halfHeights.isEmpty else { return level }
        let idx = max(0, min(halfHeights.count - 1, halfHeights.count - 1 - offset))
        let maxH = max(1.0, (HUDTheme.waveformHeight / 2) - Waveform.minimumHalfHeight)
        return Double(min(1.0, max(0.0, (halfHeights[idx] - Waveform.minimumHalfHeight) / maxH)))
    }

    private var shownReveal: Double { min(max(reveal, 0), 1) }

    private var effectiveTime: Double {
        time > 0 ? time : pulse * 4.4
    }

    /// The colour of one bar of this frame.
    private func tint(_ value: Double) -> Color {
        HUDTheme.meter(value, ceiling: ceiling)
    }

    /// The bars of the stretch shape, taken from the card or computed here.
    private func stretchBars() -> [Double] {
        if bars.count == VisualizerBars.stretchCount { return bars }
        var computed: [Double] = []
        VisualizerBars.stretch(
            into: &computed,
            history: history,
            spectrum: spectrumHistory,
            reveal: shownReveal
        )
        return computed
    }

    /// The bars of a scrolling meter, taken from the card or computed here.
    private func scrollingBars(count: Int) -> [Double] {
        if bars.count == count { return bars }
        var computed: [Double] = []
        VisualizerBars.scrolling(
            into: &computed,
            count: count,
            history: history,
            spectrum: spectrumHistory,
            reveal: shownReveal
        )
        return computed
    }

    // MARK: - 02 Stretch (Hero Pick)

    private func drawStretch(context: GraphicsContext, size: CGSize) {
        let values = stretchBars()
        let count = values.count
        guard count > 0 else { return }
        let bw: CGFloat = 3.0
        let gap: CGFloat = 4.0
        let total = CGFloat(count) * bw + CGFloat(count - 1) * gap
        let x0 = (size.width - total) / 2
        let mid = size.height / 2
        let reach = max(bw / 2, mid - 1.2)

        // A bar that is a peak of this take gets a warm tip: a small bright cap
        // at each end of the capsule. The cap is the only thing on the shape
        // that does not move, and it is what makes a loud syllable read as loud
        // even when the card is small.
        let tipLevel = max(0.55, ceiling * MeterRamp.tipOnset)

        for index in 0..<count {
            let value = CGFloat(min(1, max(0, values[index])))
            // A resting bar is a dot: the shape is made of the same capsules at
            // every height, so silence leaves a row of dots rather than nothing.
            let hh = bw / 2 + value * (reach - bw / 2)
            let rect = CGRect(
                x: x0 + CGFloat(index) * (bw + gap),
                y: mid - hh,
                width: bw,
                height: hh * 2
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: bw / 2),
                with: .color(tint(Double(value)))
            )

            if Double(value) >= tipLevel {
                let cap = bw * 0.85
                for y in [mid - hh, mid + hh - cap] {
                    let capRect = CGRect(x: rect.minX, y: y, width: bw, height: cap)
                    context.fill(
                        Path(roundedRect: capRect, cornerRadius: cap / 2),
                        with: .color(HUDTheme.meter(1, ceiling: ceiling))
                    )
                }
            }
        }
    }

    // MARK: - 01 Filament (Pro Audio)

    private func drawFilament(context: GraphicsContext, size: CGSize) {
        let bw: CGFloat = 2.4
        let pitch: CGFloat = 4.8
        let mid = size.height / 2
        let reach = max(bw / 2, mid - 1.4)
        let count = max(1, Int(ceil(size.width / pitch)))
        let values = scrollingBars(count: count)

        for index in 0..<count {
            let x = size.width - bw - CGFloat(index) * pitch
            if x < -bw { break }
            guard index < values.count else { break }

            // A bar that has not been spoken into is a dot, and a bar that has
            // is a capsule: the meter grows out of a row of dots rather than
            // out of nothing.
            let val = CGFloat(min(1, max(0, values[index])))
            let hh = bw / 2 + val * (reach - bw / 2)
            let rect = CGRect(x: x, y: mid - hh, width: bw, height: hh * 2)
            context.fill(
                Path(roundedRect: rect, cornerRadius: bw / 2),
                with: .color(tint(Double(val)))
            )
        }
    }

    // MARK: - 04 Silk (Harmonic Ribbons)

    private func drawSilk(context: GraphicsContext, size: CGSize) {
        let mid = size.height / 2
        let reach = max(1, mid - 1.8)
        let t = effectiveTime
        let count = history.count

        // Four ribbons, each at its own multiple of the voice's own shape. The
        // shape is the envelope history read across the card, oldest at the left
        // and newest at the right, so a ribbon is as wide as the syllable under
        // it is loud. A ribbon drawn from the live level alone has the same width
        // all the way across, which is a decoration rather than a meter.
        let ribbons: [(freq: Double, speed: Double, lag: Double, alpha: Double, width: CGFloat)] = [
            (1.20, 0.42, 0.00, 0.90, 1.5),
            (1.95, -0.50, 0.10, 0.55, 1.15),
            (2.85, 0.65, 0.22, 0.36, 1.0),
            (1.55, -0.35, 0.05, 0.95, 1.4),
        ]

        var additive = context
        additive.blendMode = .plusLighter

        let steps = max(24, Int(size.width / 2.0))
        for (idx, ribbon) in ribbons.enumerated() {
            var path = Path()
            let ph = t * ribbon.speed + Double(idx) * 1.1

            for s in 0...steps {
                let u = Double(s) / Double(steps)
                let x = CGFloat(u) * size.width
                // The voice at this point of the card. Each ribbon reads the same
                // recording a little behind the one in front of it, which is what
                // braids them: they are the same voice seen at four lags.
                let position = min(1, max(0, u - ribbon.lag))
                let voice: CGFloat = count > 1
                    ? CGFloat(min(1, max(0, history[Int(position * Double(count - 1))])))
                    : CGFloat(level)
                // Tapered at the very edges so the ribbon leaves the card
                // instead of being cut off by it.
                let edge = 0.82 + 0.18 * pow(sin(Double.pi * u), 1.4)
                let wave = 0.72 * sin(u * Double.pi * 2.0 * ribbon.freq * 2.0 + ph)
                    + 0.28 * cos(u * Double.pi * 3.4 - ph * 0.7)
                let y = mid + voice * CGFloat(edge * wave) * reach

                if s == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            let live = Double(min(1, max(0, sample(offsetFromNewest: 0))))
            let colour = HUDTheme.meter(max(0.22, live), ceiling: ceiling)
            additive.stroke(path, with: .color(colour.opacity(ribbon.alpha)), lineWidth: ribbon.width)
        }
    }

    // MARK: - 05 Matrix (Spectrogram Grid)

    /// The ink of the card's own marks, `#FFF4E6`, which a lit dot carries in the
    /// centre of its light and in its highlight.
    private static let matrixInk = Color(red: 1.0, green: 0.957, blue: 0.902)

    /// The warm tip of the ramp mixed towards the card's ink.
    ///
    /// - Parameter amount: how far towards the ink to go, from `0` to `1`.
    /// - Returns: the colour of the centre of a dot at that heat.
    private static func hot(_ amount: Double) -> Color {
        let tip = MeterRamp.tip
        let ink = (red: 1.0, green: 0.957, blue: 0.902)
        let t = min(max(amount, 0), 1)
        return Color(
            red: tip.red + (ink.red - tip.red) * t,
            green: tip.green + (ink.green - tip.green) * t,
            blue: tip.blue + (ink.blue - tip.blue) * t
        )
    }

    private func drawMatrix(context: GraphicsContext, size: CGSize) {
        let rows = 5
        // The lattice is square, and the pitch is what keeps two dots apart.
        //
        // The grid used to be pitched by a constant column width while the dot
        // grew with the level, so at the top of the range two neighbouring dots
        // met and their halos crossed: a voice drawn in blobs rather than in
        // dots. Pitch is now the smaller of a row's height and five points, and
        // the dot never grows past a little more than a quarter of it, so a gap
        // is there by construction at every level.
        let rowPitch = size.height / CGFloat(rows)
        let pitch = min(5.0, rowPitch)
        let cols = max(1, Int(ceil(size.width / pitch)))
        // A canvas taller than the lattice is a card with room over: the five
        // rows sit in the middle of it instead of being stretched apart.
        let top = (size.height - pitch * CGFloat(rows)) / 2
        let histCount = max(1, history.count)
        let specCount = spectrumHistory.count

        /// The centre of one cell.
        func centre(column: Int, row: Int) -> CGPoint {
            CGPoint(
                x: size.width - pitch / 2.0 - CGFloat(column) * pitch,
                y: top + pitch * (CGFloat(row) + 0.5)
            )
        }

        /// The band of one cell, in this voice's own window.
        func band(column: Int, row: Int) -> Double {
            // Two ticks per column is 33 ms, so the grid scrolls at the rate the
            // audio was recorded at whatever width the card takes.
            let baseOffset = min(max(0, histCount - 1), column * 2)
            // The spectrum frame recorded at this column's moment.
            if specCount > 0 {
                let idx = specCount - 1 - min(specCount - 1, column * 2)
                let a = spectrumHistory[idx]
                let b = spectrumHistory[max(0, idx - 1)]
                let frame = AudioSpectrumFrame(bands: (
                    max(a.bands.0, (a.bands.0 + b.bands.0) * 0.5),
                    max(a.bands.1, (a.bands.1 + b.bands.1) * 0.5),
                    max(a.bands.2, (a.bands.2 + b.bands.2) * 0.5),
                    max(a.bands.3, (a.bands.3 + b.bands.3) * 0.5),
                    max(a.bands.4, (a.bands.4 + b.bands.4) * 0.5)
                ))
                if (frame.bands.0 + frame.bands.1 + frame.bands.2 + frame.bands.3 + frame.bands.4) > 0.01 {
                    return frame[row]
                }
            }
            let s0 = sample(offsetFromNewest: baseOffset)
            let s1 = sample(offsetFromNewest: min(histCount - 1, baseOffset + 1))
            let s2 = sample(offsetFromNewest: min(histCount - 1, baseOffset + 2))
            let s3 = sample(offsetFromNewest: min(histCount - 1, baseOffset + 4))
            let instEnergy = max(s0, (s0 + s1) * 0.5)
            let transientAttack = min(1.0, abs(s0 - s1) * 3.8 + abs(s1 - s2) * 2.4)
            let lowBody = (s0 + s1 + s2 + s3) * 0.25
            switch row {
            case 0: return transientAttack * 0.70 + instEnergy * 0.35
            case 1: return instEnergy * 0.65 + transientAttack * 0.30
            case 2: return instEnergy * 0.75
            case 3: return lowBody * 0.70 + instEnergy * 0.25
            default: return lowBody * 0.75
            }
        }

        // Every cell is drawn: the grid is a grid, not a scatter of dots that
        // appear where the voice is. A dot is its band, one size at every level,
        // and the level is how the dot is lit.
        for column in 0..<cols {
            for row in 0..<rows {
                let point = centre(column: column, row: row)
                let energy = min(1.0, max(0.0, band(column: column, row: row)))
                let dot = pitch * (0.21 + 0.07 * CGFloat(energy))
                let rect = CGRect(
                    x: point.x - dot,
                    y: point.y - dot,
                    width: dot * 2,
                    height: dot * 2
                )
                context.fill(Path(ellipseIn: rect), with: .color(HUDTheme.meter(0, ceiling: ceiling)))

                // A lit dot is a lamp, not a disc of paint: it is filled from a
                // hot centre through its own colour to a slightly deeper edge, so
                // the dot itself carries the shine. Nothing is drawn outside the
                // dot, which is what keeps two neighbours from becoming a blob.
                let display = pow(energy, 1.6)
                guard display > 0.15 else { continue }
                context.fill(
                    Path(ellipseIn: rect),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: Self.hot(0.75 * display).opacity(1.0), location: 0.0),
                            .init(
                                color: HUDTheme.meter(display, ceiling: 1).opacity(0.35 + 0.40 * display),
                                location: 0.45
                            ),
                            .init(
                                color: HUDTheme.meter(display, ceiling: 1).opacity(0.25 + 0.55 * display),
                                location: 1.0
                            ),
                        ]),
                        center: point,
                        startRadius: 0,
                        endRadius: dot
                    )
                )

                // A lit lamp has one highlight, and it is what the eye reads as
                // round rather than flat. It is inside the dot, off its centre,
                // and it is the only porcelain the grid carries.
                if highlight {
                    let sparkle = 0.3 * dot
                    let offset = 0.25 * dot
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: point.x - offset - sparkle,
                            y: point.y - offset - sparkle,
                            width: sparkle * 2,
                            height: sparkle * 2
                        )),
                        with: .color(Self.matrixInk.opacity(0.6 * display))
                    )
                }
            }
        }
    }

    // MARK: - 07 Halo Edge Center Line

    private func drawHaloEdgeCenter(context: GraphicsContext, size: CGSize) {
        let mid = size.height / 2
        // The newest envelope sample rather than the raw level: the history is
        // the metered, ballistic value, and the raw level in a render is a
        // constant that would draw a bright line on a silent card.
        let liveLevel = CGFloat(history.isEmpty ? level : sample(offsetFromNewest: 0))

        // The axis hairline.
        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: mid))
        axis.addLine(to: CGPoint(x: size.width, y: mid))
        context.stroke(axis, with: .color(HUDTheme.ink.opacity(0.14 + Double(liveLevel) * 0.14)), lineWidth: 1)

        // Beads along the axis, each at its own moment of the voice, oldest at
        // the left so the line reads like the recording it is drawn from.
        let count = 13
        let step = size.width / CGFloat(count + 1)
        let centre = CGFloat(count + 1) / 2.0
        for i in 1...count {
            let x = CGFloat(i) * step
            let dist = abs(CGFloat(i) - centre) / centre
            let bell = exp(-dist * dist * 1.6)
            let local = CGFloat(sample(offsetFromNewest: (count - i) * 2))
            let energy = CGFloat(min(1, Double(local * bell + liveLevel * 0.25 * bell)))
            let r = 0.9 + energy * 1.5
            let dot = Path(ellipseIn: CGRect(x: x - r, y: mid - r, width: r * 2, height: r * 2))
            context.fill(dot, with: .color(HUDTheme.meter(Double(energy), ceiling: ceiling)))
        }
    }
}

/// The conic perimeter border of the Halo Edge visualizer.
///
/// It is applied outside `HUDView`'s `.clipShape`, so the bloom surrounds the
/// island's silhouette instead of being cut off by it. Its intensity follows the
/// voice level.
struct HaloEdgeBorder: View {
    let time: Double
    let pulse: Double
    let level: Double

    private var angleDegrees: Double {
        let t = time > 0 ? time : pulse * 4.0
        return (t * 28.0).truncatingRemainder(dividingBy: 360.0)
    }

    private var intensity: Double {
        min(1.0, 0.22 + level * 0.78)
    }

    private var conicGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: [
                .init(color: HUDTheme.live.opacity(0.05 * intensity), location: 0.00),
                .init(color: HUDTheme.live.opacity(0.98 * intensity), location: 0.15),
                .init(color: HUDTheme.meter(0.88, ceiling: 1).opacity(0.92 * intensity), location: 0.30),
                .init(color: HUDTheme.live.opacity(0.08 * intensity), location: 0.48),
                .init(color: HUDTheme.meter(0.72, ceiling: 1).opacity(0.80 * intensity), location: 0.68),
                .init(color: HUDTheme.live.opacity(0.92 * intensity), location: 0.85),
                .init(color: HUDTheme.live.opacity(0.05 * intensity), location: 1.00),
            ]),
            center: .center,
            angle: .degrees(angleDegrees)
        )
    }

    var body: some View {
        ZStack {
            // The outer and inner conic bloom.
            RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
                .stroke(conicGradient, lineWidth: 2.2 + CGFloat(level) * 2.6)
                .blur(radius: 3.5 + CGFloat(level) * 5.5)
                .opacity(0.55 + level * 0.45)

            // The perimeter filament.
            RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
                .strokeBorder(conicGradient, lineWidth: 1.35 + CGFloat(level) * 1.05)
        }
        .allowsHitTesting(false)
    }
}
