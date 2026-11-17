import DotCore
import SwiftUI

/// The arithmetic every style shares.
///
/// These are pure functions of measurements, so they live outside the view:
/// the drawing is a `Canvas` closure and the styles' own rules are nested
/// types, neither of which can carry the view's actor isolation.
enum VisualizerMath {
    /// How many samples of the envelope history one second holds.
    static let sampleRate: Double = Waveform.sampleRate

    /// The display value of one measurement, on this voice's own range.
    ///
    /// A quiet speaker's loudest moment is drawn at the top of the shape: the
    /// value is divided by the ceiling the take has reached, with a floor under
    /// the divisor so a take that has not been loud yet is not multiplied into
    /// a wall of amber. The `0.85` keeps a little room above the loudest
    /// syllable for the peak mark, which is drawn above the shape and never
    /// inside it.
    static func displayEnergy(_ value: Double, ceiling: Double) -> Double {
        min(1, max(0, value) * 0.85 / max(0.30, ceiling))
    }

    /// The colour of one stop of the meter's ramp, at an opacity of its own.
    ///
    /// - Parameters:
    ///   - tint: the colour of the stop, in sRGB components and its own opacity.
    ///   - opacity: how opaque the stop is drawn.
    ///   - lift: how far the stop's colour is mixed toward the card's ink before
    ///     it is drawn, from `0` to `1`.
    /// - Returns: the stop's colour at the given opacity. At a lift of zero it is
    ///   the tint itself, component for component, so a canvas that asks for no
    ///   lift draws the picture it always drew. The glass material asks for
    ///   ``HUDTheme/visualizerGlassLift`` and the black material asks for nothing,
    ///   see ``HUDWaveform/material``.
    static func ramp(_ tint: MeterTint, opacity: Double, lift: Double = 0) -> Color {
        let alpha = min(max(opacity, 0), 1)
        let amount = min(max(lift, 0), 1)
        guard amount > 0 else {
            return Color(red: tint.red, green: tint.green, blue: tint.blue).opacity(alpha)
        }
        let ink = HUDTheme.inkRGB
        return Color(
            red: tint.red + (ink.red - tint.red) * amount,
            green: tint.green + (ink.green - tint.green) * amount,
            blue: tint.blue + (ink.blue - tint.blue) * amount
        ).opacity(alpha)
    }

    /// A hold: the largest value of each sample's own window, for a style drawn
    /// without motion.
    ///
    /// - Parameters:
    ///   - values: the history, oldest first.
    ///   - ticks: how many samples the hold lasts.
    /// - Returns: one held value per sample, oldest first.
    static func peakHold(_ values: [Double], ticks: Int) -> [Double] {
        guard !values.isEmpty, ticks > 0 else { return values }
        return values.indices.map { index in
            let end = min(values.count, index + ticks)
            return values[index..<end].max() ?? values[index]
        }
    }
}

/// The audio visualizer in the recording HUD card.
///
/// Five styles, chosen in Settings:
///
/// - `.stretch`: mirrored capsule bars on a fixed time grid. A bar is born at
///   the right edge at the loudness of the fifty milliseconds it holds, and the
///   row slides left at seventy-two points a second, each bar dimming and
///   thinning as it ages, so the card is a scrolling trace of the take.
/// - `.filament`: a bare spiral tungsten filament of three irregular strands
///   lying across the canvas. Its temperature follows the voice through a short
///   thermal lag, from ember red at rest to white hot at a peak; the
///   fundamental heats the middle of the coil and the sibilants its ends.
/// - `.silk`: four ribbons weaving through each other, each a band whose
///   thickness and whose distance from the centre line are travelling waves and
///   whose amplitude is the last second of the voice, tapered to a point at both
///   ends.
/// - `.matrix`: a dot-matrix spectrogram.
/// - `.haloEdge`: particles on five rings around a sun, each ring a circle seen
///   in perspective. Every ring spins at its own pace and its tilt precesses
///   around the centre and tumbles; a syllable widens the rings and pushes their
///   spin, and the push decays without ever reversing a ring. Each ring's far half
///   is drawn behind the sun and its near half in front, and the sun itself is a
///   glow, six rays and a white-hot shine whose radius answers the voice through
///   a spring.
///
/// Every style is driven by the same two inputs: the 60 Hz envelope history and
/// the 5-band spectrum. Every mark is a measurement of the voice, drawn in the
/// amber ramp of ``MeterRamp`` (Filament in its own blackbody colours), deep at
/// the floor, the live amber at speech and warm at a peak. The shape rests at a hairline when nothing is being said, so
/// the card is alive without pretending to hear a voice in an empty room.
///
/// Height is linear from zero everywhere in this file: a level of `0.01` is a
/// hundredth of the shape, never a switch. Silence is therefore the calmest
/// state rather than a floor with a threshold over it.
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
    /// A reduce-motion setting a still render can pass without a system
    /// preference. The card's own view carries the same override.
    var reduceMotionOverride: Bool? = nil
    /// The material of the card the canvas stands on.
    ///
    /// It is the one input that decides whether the lit ink is lifted: the clear
    /// glass behind the canvas is a light surface that the amber was not measured
    /// on, and the black material is the surface every mark in this file was
    /// drawn for. See ``HUDTheme/visualizerGlassLift``.
    var material: HUDMaterial = .black
    /// How far the lit ink is mixed toward the card's ink on the glass material.
    ///
    /// It is ``HUDTheme/visualizerGlassLift`` and the app passes nothing else: a
    /// test varies it to prove that the lift never reaches the black material.
    var glassLift: Double = HUDTheme.visualizerGlassLift
    /// How far the halo's ring ink is mixed toward the card's ink on the glass
    /// material.
    ///
    /// It is ``HUDWaveform/Halo/glassRingLift`` and the app passes nothing else:
    /// a test varies it on the ladder the ring's brightness is chosen from.
    var glassRingLift: Double = HUDWaveform.Halo.glassRingLift
    /// How much more opaque the halo's ring ink is drawn on the glass material.
    ///
    /// It is ``HUDWaveform/Halo/glassRingInkGain`` and the app passes nothing
    /// else: a test varies it on the ladder the ring's brightness is chosen from.
    var glassRingInkGain: Double = HUDWaveform.Halo.glassRingInkGain

    /// Whether the person asked for reduced motion, as the environment says.
    ///
    /// A style with travel draws its form with the travel removed and the
    /// amplitude held, so the shape is still a measurement of the voice and
    /// still still.
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// The motion setting the shape obeys.
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

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
                drawHalo(context: context, size: size)
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

    /// How far this canvas's lit ink is mixed toward the card's ink.
    ///
    /// It is zero on the black material whatever ``glassLift`` holds: the lift is
    /// a correction for the light the glass puts behind the canvas, and an opaque
    /// card has none. That is what keeps the black card's renders the same
    /// picture they were.
    private var lift: Double {
        material == .glass ? min(max(glassLift, 0), 1) : 0
    }

    /// One lit colour of a style, on this canvas's material.
    private func lit(_ tint: MeterTint) -> Color {
        VisualizerMath.ramp(tint, opacity: tint.opacity, lift: lift)
    }

    /// The colour of one lit mark of this frame, on this canvas's material.
    private func tint(_ value: Double) -> Color {
        lit(MeterRamp.tint(level: value, ceiling: ceiling))
    }

    /// How far the halo's rings are mixed toward the card's ink.
    ///
    /// It is zero on the black material whatever ``glassRingLift`` holds, for the
    /// reason ``lift`` is zero there: the lift corrects for the light the clear
    /// glass puts behind the canvas, and an opaque card has no such light. That
    /// is what keeps the black card's rings the ink they always were.
    private var ringLift: Double {
        material == .glass ? min(max(glassRingLift, 0), 1) : 0
    }

    /// How much more opaque the halo's rings are drawn.
    ///
    /// It is one on the black material whatever ``glassRingInkGain`` holds, so
    /// the black card's rings keep their own opacities exactly. Each ring
    /// opacity is multiplied by this and the product is clamped to one, see
    /// ``drawRing(context:ring:front:frame:centre:clock:)``.
    private var ringInkGain: Double {
        material == .glass ? max(glassRingInkGain, 0) : 1
    }

    // MARK: - 01 Stretch (Scrolling Mirror)

    /// The rules of the stretch row, and the row itself.
    ///
    /// The shape is a mirror that scrolls: a bar is born at the right edge at the
    /// loudness of the moment it holds, the voice already in the row slides left at
    /// a steady pace, and the ink dims and thins as it ages, so the newest moment
    /// is the brightest and the oldest is a trace of the take.
    ///
    /// The row is pinned to the clock rather than to the canvas: a bar's place is a
    /// function of the moment it holds and of the tick the frame was drawn on, so
    /// the row moves by a fraction of a pitch per frame, and the row of a wider
    /// canvas is the same row with more of its past in view. Every rule here is a
    /// pure function of the inputs, so a render draws the row the card draws and
    /// the numbers behind the row can be measured without a screen.
    enum Stretch {
        // MARK: The time grid

        /// How many samples of the history one bar holds.
        ///
        /// Three ticks at sixty hertz is fifty milliseconds: a syllable's worth of
        /// voice rather than a sample's worth of noise, and short enough that a bar
        /// is still one moment of the take.
        static let windowTicks = 3

        /// How many samples the edge's spring is integrated over.
        static let springTicks = 24

        /// The natural frequency of the edge's spring, in hertz.
        static let springFrequency: Double = 6.0

        /// The damping ratio of the edge's spring.
        ///
        /// A ratio of zero rings for ever and a ratio of one never swings past its
        /// target; `0.62` overshoots by about eight per cent, which is a bar that
        /// grows a little past its syllable and settles back inside it.
        static let springDamping: Double = 0.62

        /// How many sub-steps of the spring one sample is integrated in.
        ///
        /// A semi-implicit Euler step of a six hertz spring at one step per sample
        /// turns the spring's phase by `0.63` radians, and at that size the rule's
        /// own numerical damping is worth about a third of a damping ratio: the
        /// overshoot the spring exists for is swallowed and a step input peaks at
        /// one per cent instead of eight. Twelve sub-steps keep the rule and bring
        /// the peak of a step input to within half a per cent of the analytic
        /// answer.
        static let springSubSteps = 12

        /// The highest a sprung bar is drawn, as a multiple of its own level.
        ///
        /// The overshoot of the edge is what gives a syllable its swing, and it is
        /// the only part of the row that can stand above the height its level asks
        /// for.
        static let springCeiling: Double = 1.06

        /// How many bars a still row's hold remembers.
        static let stillHold = 12

        /// How far a frame may sit past a tick's boundary and still belong to it,
        /// in ticks.
        ///
        /// The clocks are doubles, and a frame that lands a rounding error before a
        /// boundary would otherwise read as the tick behind it: the row would then
        /// step two ticks in one frame and none in the next.
        static let boundaryTolerance = 1e-9

        // MARK: The pitch

        /// The width of a bar at the right edge, in points.
        static let barWidth: CGFloat = 2.0

        /// The gap between two bars at the right edge, in points.
        static let gap: CGFloat = 1.6

        /// The distance between two bars' centres, in points.
        ///
        /// It is `3.6` points, and it is also the distance one bar travels in one
        /// window: the row scrolls at seventy-two points a second, one pitch per
        /// fifty milliseconds, whatever the width of the canvas.
        static let pitch: CGFloat = barWidth + gap

        /// The room the row keeps at the right edge, in points.
        static let rightInset: CGFloat = 2.0

        // MARK: The height

        /// The height of a bar with nothing in it, in points.
        ///
        /// Silence is a hairline and never a dot: the row at rest is a fine dashed
        /// line that scrolls, so an empty room is still a card that is listening.
        static let minHeight: CGFloat = 1.0

        /// The height of a bar at the top of its range, in points.
        static let maxHeight: CGFloat = 24.0

        // MARK: The age

        /// Where a bar's ink starts to arrive, as a share of the canvas's width.
        ///
        /// A bar is at its dimmest on the left edge and at its brightest a little
        /// past half way, so the right of the row is the voice as it is and the
        /// left of the row is the trace it leaves.
        static let fadeStart: Double = 0
        static let fadeEnd: Double = 0.55

        /// The share of its ink the oldest bar keeps.
        static let floorInk: Double = 0.16

        /// The share of its width the oldest bar keeps.
        static let floorWidthShare: CGFloat = 0.70

        /// The share of its ink a bar keeps at its own two tips.
        static let tipInk: Double = 0.72

        // MARK: The live edge

        /// The width of the live edge's glow, as a multiple of the bar's own.
        static let glowWidthShare: CGFloat = 1.8

        /// The height of the live edge's glow, as a multiple of the bar's own.
        static let glowHeightShare: CGFloat = 1.15

        /// The tallest the live edge's glow is drawn, in points.
        ///
        /// The glow is measured from the height of the bar rather than from the
        /// level, so it is the one part of the row that could leave the canvas: a
        /// bar at the top of its range is twenty-four points before the spring and
        /// twenty-five and a third at the very top of its overshoot, and the canvas
        /// is twenty-six. The glow is held to twenty-five, which leaves half a
        /// point above and below it at the loudest moment of the loudest take.
        static let glowHeightLimit: CGFloat = 25.0

        /// The ink of the live edge's glow at the top of its range.
        static let glowInk: Double = 0.32

        // MARK: - The row

        /// One bar of the row, as the row draws it.
        ///
        /// The bar carries its own geometry and its own level, so the view is one
        /// loop of fills and every rule of the row can be measured on the values:
        /// where the bar is, how wide, how tall, how bright, and which window of
        /// the voice it holds.
        struct Bar: Equatable {
            /// The window of the voice the bar holds, counted on the absolute
            /// clock. The live edge is the window that has not closed yet.
            let window: Int
            /// Where the bar's centre stands, in points from the left edge.
            let centre: CGFloat
            /// How wide the bar is drawn, in points.
            let width: CGFloat
            /// How tall the bar is drawn, in points.
            let height: CGFloat
            /// The share of its ink the bar carries, faded by its age.
            let ink: Double
            /// The level the bar is drawn at, after the spring and the reveal.
            let value: Double
            /// Whether the bar is the live edge, the window that is still filling.
            let isLive: Bool
        }

        /// The index of the newest sample of the history, counted from the start of
        /// the clock.
        ///
        /// The counter is `time * 60 - phase` floored. The subtraction is what
        /// keeps the row continuous: `time` is the display's clock and `phase` is
        /// the meter's own fraction of a tick, and the two are not aligned, so
        /// flooring the display's clock alone and adding the meter's phase to it
        /// would step the row by a third of a pitch every frame the two disagree.
        /// Taking the phase back off first lands on the tick the frame belongs to,
        /// and `tick / 3 + phase / 3` is then the meter's clock divided by three
        /// windows, which rises without a step. With the two clocks in step the
        /// answer is the plain `time * 60` floor.
        static func newestSample(at time: Double, phase: Double) -> Int {
            Int((time * VisualizerMath.sampleRate - min(max(phase, 0), 1) + boundaryTolerance).rounded(.down))
        }

        /// How many samples of the newest window have arrived, from `0` to `2`.
        ///
        /// The answer is the newest sample's index modulo the window's length, and
        /// the counter behind it is never reset: grouping the samples in threes from
        /// the start of the clock is what makes the grid a property of the take
        /// rather than of the frame, so a window closes at the same moments however
        /// often the card is redrawn.
        static func arrived(_ tick: Int) -> Int {
            let remainder = tick % windowTicks
            return remainder < 0 ? remainder + windowTicks : remainder
        }

        /// How many windows of the voice have closed.
        ///
        /// The window that ends at sample `tick` is the one numbered
        /// `tick / windowTicks`, so the count of closed windows is the quotient and
        /// ``arrived(_:)`` is the remainder. The two together place the newest
        /// sample on the grid, which is why the row never loses its place.
        static func closedWindows(_ tick: Int) -> Int {
            Int((Double(tick) / Double(windowTicks)).rounded(.down))
        }

        /// How far the live window has run, from `0` to less than `1`.
        ///
        /// It is the sub-tick position of the row: `progress = (tick mod 3 +
        /// phase) / 3`, where the modulo is taken on the absolute tick counter, so
        /// the three ticks of a window each add a third and `phase` splits the last
        /// of them. The row therefore moves `1.2` points on every tick, and between
        /// two ticks by the share of the phase that separates them, so a window
        /// that closes leaves the row exactly where the next one picks it up.
        static func progress(tick: Int, phase: Double) -> Double {
            (Double(arrived(tick)) + min(max(phase, 0), 1)) / Double(windowTicks)
        }

        /// How many ticks back the newest closed window ended at that moment.
        ///
        /// The edge of the row three ticks ago was not the window the edge holds
        /// now: a window closes every three ticks, so the series the spring follows
        /// steps back a window at a time. The answer is the smallest offset that is
        /// at least `back` ticks old and on the grid, which is `back` plus the
        /// distance from `back` up to the next sample the window closes on.
        static func edgeOffset(back: Int, arrived: Int) -> Int {
            let shift = (arrived - back % windowTicks) % windowTicks
            return back + (shift < 0 ? shift + windowTicks : shift)
        }

        /// Where the centre of a bar of this rank stands, in points from the left
        /// edge of the canvas.
        ///
        /// Rank `0` is the window that has just closed and rank `-1` is the live
        /// edge, so one rule places both: a bar stands one pitch plus its own
        /// progress to the left of the bar in front of it, and the live edge
        /// emerges from the right inset as its window fills.
        static func centre(rank: Int, progress: Double, canvas: CGFloat) -> CGFloat {
            (canvas - rightInset) - (CGFloat(rank) + 1 + CGFloat(progress)) * pitch
        }

        /// Whether a bar at this centre is still part of the picture.
        ///
        /// A bar leaves by its own width rather than by its centre: the last bar on
        /// the left is drawn while any of it is still inside the canvas.
        static func isVisible(centre: CGFloat) -> Bool {
            centre > -barWidth
        }

        /// How much of the canvas's width a bar has crossed, from `0` at the left
        /// edge to `1` at the right.
        static func age(centre: CGFloat, canvas: CGFloat) -> Double {
            guard canvas > 0 else { return 1 }
            return min(max(Double(centre / canvas), 0), 1)
        }

        /// The share of its ink a bar of this age carries.
        static func ink(age: Double) -> Double {
            floorInk + (1 - floorInk) * MeterRamp.smoothstep(fadeStart, fadeEnd, age)
        }

        /// The share of its width a bar of this age keeps.
        static func widthShare(age: Double) -> CGFloat {
            floorWidthShare + (1 - floorWidthShare) * CGFloat(MeterRamp.smoothstep(fadeStart, fadeEnd, age))
        }

        /// How tall a bar of this level is drawn, in points.
        static func height(_ level: Double) -> CGFloat {
            let value = min(max(level, 0), springCeiling)
            return minHeight + (maxHeight - minHeight) * CGFloat(value)
        }

        /// How tall the live edge's glow is drawn, in points.
        static func glowHeight(_ height: CGFloat) -> CGFloat {
            min(glowHeightShare * height, glowHeightLimit)
        }

        /// The level of the window of the voice whose newest sample is `offset`
        /// ticks back, before the spring and the reveal.
        ///
        /// - Parameters:
        ///   - offset: how many ticks back the window's newest sample is.
        ///   - history: the envelope, oldest first.
        ///   - ceiling: the loudest moment of the take.
        ///   - reveal: how much of the shape has arrived, from `0` to `1`.
        /// - Returns: the window's peak on the take's own range, or zero for a
        ///   window the history no longer holds, which is the answer
        ///   ``VisualizerBars/sample(history:offsetFromNewest:)`` gives.
        static func windowLevel(offset: Int, history: [Double], ceiling: Double, reveal: Double) -> Double {
            let start = max(0, offset)
            var peak = 0.0
            for tap in 0..<windowTicks {
                peak = max(peak, VisualizerBars.sample(history: history, offsetFromNewest: start + tap))
            }
            return normalised(peak, ceiling: ceiling, reveal: reveal)
        }

        /// The level of the window that is still filling, from the samples that
        /// have arrived in it.
        ///
        /// A window that has only just opened has no sample of its own, and a bar
        /// born at the edge at nothing would drop the newest height of the row once
        /// every three frames. It therefore holds the newest sample of the take,
        /// which is the last thing the voice said, until a sample of its own
        /// arrives.
        static func liveLevel(history: [Double], ceiling: Double, reveal: Double, arrived: Int) -> Double {
            var peak = 0.0
            for offset in 0..<max(1, arrived) {
                peak = max(peak, VisualizerBars.sample(history: history, offsetFromNewest: offset))
            }
            return normalised(peak, ceiling: ceiling, reveal: reveal)
        }

        /// How far up the row a peak of the envelope stands.
        ///
        /// The measure is the take's own, and the reveal scales the answer so a
        /// shape that is arriving grows out of the axis rather than appearing at
        /// the height the last frame left behind.
        private static func normalised(_ peak: Double, ceiling: Double, reveal: Double) -> Double {
            let shown = VisualizerMath.displayEnergy(peak, ceiling: ceiling) * min(max(reveal, 0), 1)
            return min(1, max(0, shown))
        }

        /// The displacement of a damped spring following a series of levels.
        ///
        /// The rule is semi-implicit Euler at the sample rate, sub-stepped so that
        /// the numerical damping of the rule does not eat the overshoot the spring
        /// is for. It is a fixed number of steps over a fixed number of samples with
        /// no state carried between frames, so the same history always gives the
        /// same answer and a render at a given moment is reproducible.
        ///
        /// - Parameter levels: the level the edge held at each tick, oldest first.
        ///   The first element is where the spring starts from rest, so a series
        ///   that is flat from its first sample draws the same flat line.
        /// - Returns: one displacement per element, clamped to `0...springCeiling`.
        static func spring(_ levels: [Double]) -> [Double] {
            guard let start = levels.first else { return [] }
            let omega = 2 * Double.pi * springFrequency
            let step = 1 / (VisualizerMath.sampleRate * Double(springSubSteps))
            var displaced = start
            var velocity = 0.0
            var answer: [Double] = [min(max(start, 0), springCeiling)]
            answer.reserveCapacity(levels.count)
            for target in levels.dropFirst() {
                for _ in 0..<springSubSteps {
                    let acceleration = omega * omega * (target - displaced) - 2 * springDamping * omega * velocity
                    velocity += acceleration * step
                    displaced += velocity * step
                }
                answer.append(min(max(displaced, 0), springCeiling))
            }
            return answer
        }

        /// Where the spring has come to after following a series.
        static func springValue(_ levels: [Double]) -> Double {
            spring(levels).last ?? 0
        }

        /// The bars one frame draws, newest first.
        ///
        /// - Parameters:
        ///   - history: the 60 Hz envelope, oldest first.
        ///   - ceiling: the loudest moment of the take.
        ///   - phase: where inside the newest sample the frame sits, from `0` to
        ///     less than `1`.
        ///   - time: unwrapped elapsed seconds.
        ///   - reveal: how much of the shape has arrived, from `0` to `1`.
        ///   - canvas: the width of the canvas, in points.
        ///   - reduceMotion: whether the row is drawn without its motion.
        /// - Returns: the bars to draw, newest first, without the bars that have
        ///   left the canvas.
        static func bars(
            history: [Double],
            ceiling: Double,
            phase: Double,
            time: Double,
            reveal: Double,
            canvas: CGFloat,
            reduceMotion: Bool
        ) -> [Bar] {
            guard canvas > 0, !history.isEmpty else { return [] }
            if reduceMotion {
                return stillBars(history: history, ceiling: ceiling, reveal: reveal, canvas: canvas)
            }
            let tick = newestSample(at: time, phase: phase)
            let filled = arrived(tick)
            let closed = closedWindows(tick)
            let scroll = progress(tick: tick, phase: phase)

            // The edge of the row over the last twenty-four ticks, then the same
            // series with its newest reading replaced by the window that is still
            // filling: the two share twenty-three of their twenty-four steps, so the
            // bar being born at the edge starts where the bar that has just closed
            // stands and moves away from it with the sound.
            let trail = (0..<springTicks).reversed().map { back in
                windowLevel(
                    offset: edgeOffset(back: back, arrived: filled),
                    history: history,
                    ceiling: ceiling,
                    reveal: reveal
                )
            }
            let closedLevel = springValue(trail)
            var liveTrail = trail
            liveTrail[liveTrail.count - 1] = liveLevel(
                history: history,
                ceiling: ceiling,
                reveal: reveal,
                arrived: filled
            )
            let liveEdge = springValue(liveTrail)

            var row: [Bar] = []
            let liveCentre = centre(rank: -1, progress: scroll, canvas: canvas)
            if isVisible(centre: liveCentre) {
                row.append(bar(closed + 1, at: liveCentre, level: liveEdge, canvas: canvas, isLive: true))
            }
            var rank = 0
            while true {
                let x = centre(rank: rank, progress: scroll, canvas: canvas)
                guard isVisible(centre: x) else { break }
                // The window of the voice a bar holds: the newest one has just
                // closed, and each older bar is one window further into the past.
                let held = rank == 0
                    ? closedLevel
                    : windowLevel(
                        offset: filled + rank * windowTicks,
                        history: history,
                        ceiling: ceiling,
                        reveal: reveal
                    )
                row.append(bar(closed - rank, at: x, level: held, canvas: canvas, isLive: false))
                rank += 1
            }
            return row
        }

        /// A still row: the held voice, at rest on the grid, with no spring.
        ///
        /// A row drawn without motion must not depend on the clock, or the shape
        /// would move on a card that was asked not to. Its bars therefore stand
        /// where a window stands when it has just closed, and each bar is the
        /// loudest it has been over the windows to its left, so a still of a
        /// dictation keeps the peaks of the phrase rather than one frame of them.
        static func stillBars(history: [Double], ceiling: Double, reveal: Double, canvas: CGFloat) -> [Bar] {
            var levels: [Double] = []
            while isVisible(centre: centre(rank: levels.count, progress: 0, canvas: canvas)) {
                levels.append(windowLevel(
                    offset: levels.count * windowTicks,
                    history: history,
                    ceiling: ceiling,
                    reveal: reveal
                ))
            }
            let held = VisualizerMath.peakHold(levels, ticks: stillHold)
            return levels.indices.map { rank in
                bar(
                    rank,
                    at: centre(rank: rank, progress: 0, canvas: canvas),
                    level: held[rank],
                    canvas: canvas,
                    isLive: false
                )
            }
        }

        /// One bar of the row at a place, measured against the canvas.
        ///
        /// The age of a bar is read from its own centre, so the fade and the
        /// thinning are one statement about where the bar is rather than two about
        /// how old it is: a bar that has travelled half the canvas is half way
        /// through its fade whatever the canvas's width.
        private static func bar(
            _ window: Int,
            at centre: CGFloat,
            level: Double,
            canvas: CGFloat,
            isLive: Bool
        ) -> Bar {
            let crossed = age(centre: centre, canvas: canvas)
            return Bar(
                window: window,
                centre: centre,
                width: barWidth * widthShare(age: crossed),
                height: height(level),
                ink: ink(age: crossed),
                value: level,
                isLive: isLive
            )
        }
    }

    private func drawStretch(context: GraphicsContext, size: CGSize) {
        let row = Stretch.bars(
            history: history,
            ceiling: ceiling,
            phase: phase,
            time: effectiveTime,
            reveal: shownReveal,
            canvas: size.width,
            reduceMotion: reduceMotion
        )
        guard !row.isEmpty else { return }
        let mid = size.height / 2

        // Oldest first, so the bar being born at the edge is drawn over the ones it
        // is born beside.
        for bar in row.reversed() {
            // The level is already normalised to the take, so the colour is
            // read on the full ramp rather than on the take's ceiling twice.
            let colour = lit(MeterRamp.tint(level: bar.value, ceiling: 1))

            // The glow is the one part of the row that is light rather than ink: it
            // is added to the surface under the bar, so the live edge reads as the
            // lamp at the end of the row instead of as a brighter bar.
            if bar.isLive {
                let glowWidth = bar.width * Stretch.glowWidthShare
                let glowHeight = Stretch.glowHeight(bar.height)
                var glow = context
                glow.blendMode = .plusLighter
                glow.fill(
                    Path(
                        roundedRect: CGRect(
                            x: bar.centre - glowWidth / 2,
                            y: mid - glowHeight / 2,
                            width: glowWidth,
                            height: glowHeight
                        ),
                        cornerRadius: min(glowWidth, glowHeight) / 2
                    ),
                    with: .color(colour.opacity(Stretch.glowInk * bar.value))
                )
            }

            let rect = CGRect(
                x: bar.centre - bar.width / 2,
                y: mid - bar.height / 2,
                width: bar.width,
                height: bar.height
            )
            // The bar is lit from its middle: the gradient down its own rect is what
            // makes a column of one colour read as a capsule with rounded ends
            // rather than as a rectangle of paint. A bar shorter than it is wide is
            // a dash, and its corners are halved with its height so it stays a dash
            // instead of becoming a dot.
            context.fill(
                Path(roundedRect: rect, cornerRadius: min(bar.width, bar.height) / 2),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: colour.opacity(Stretch.tipInk * bar.ink), location: 0),
                        .init(color: colour.opacity(bar.ink), location: 0.5),
                        .init(color: colour.opacity(Stretch.tipInk * bar.ink), location: 1),
                    ]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )
        }
    }

    // MARK: - 02 Filament (Bare Spiral Filament)

    /// The geometry, the light and the colour of the bare filament.
    ///
    /// The picture is the glowing wire on its own, with no glass and no base: three
    /// strands of tungsten wound into a spindle that is thick through the middle of
    /// the canvas and converges to a point at each end, lying across the card's own
    /// dark surface. The strands differ in radius, in how many turns they make and
    /// in which way they wind, so they cross one another the way the strands of a
    /// real Edison filament do, and each of them is wound with an irregularity that
    /// never changes from frame to frame: the wire is a physical object, and a shape
    /// that breathes with the clock would read as a drawing of a wire rather than as
    /// one.
    ///
    /// The brightness of the wire is not its temperature alone. A helix seen from
    /// the side is compressed where it turns back, so the same length of glowing
    /// wire covers less of the screen there and more of it is seen through each
    /// point of the picture: that ratio of the wire's own length to its shadow's is
    /// what makes a real filament brightest along the top and the bottom of each
    /// loop, and it is what ``edge(threeD:screen:)`` measures. The wire is then
    /// drawn in four passes, from a wide blurred halo down to the white-hot core of
    /// the hottest stretches, all of them added to the card's surface.
    enum Filament {
        // MARK: Geometry

        /// The inset of the coil from each end of the canvas, in points.
        ///
        /// The wire converges to a point at both ends, and the point has to be far
        /// enough from the edge of the canvas that its glow is not cut by it.
        static let spanInset: CGFloat = 5
        /// How many strands are wound into the filament.
        static let strandCount = 3
        /// How far past the wire's own outline its halo reaches before it has faded
        /// into the card, in points.
        ///
        /// It is measured from the rendered picture: a blur of ``haloRadius`` carries
        /// a visible tail for about this far, and it is the room the coil has to
        /// leave at the top and the bottom of the canvas.
        static let haloReach: CGFloat = 4.8
        /// The margin the drawing keeps from the edge of the canvas, in points.
        static let canvasMargin: CGFloat = 0.5
        /// The radius of the widest strand at the middle of the spindle, in points.
        static let radiusMax: CGFloat = 8.2
        /// The share of the radius each strand takes.
        ///
        /// Three strands of one radius would lie on top of each other and read as
        /// one thick wire: the shares are what make the filament a bundle.
        static let radiusScales: [Double] = [1.00, 0.80, 0.58]
        /// The pitch of each strand: how far along the span one turn advances, in
        /// points.
        ///
        /// A pitch in points rather than a count of turns is what keeps the density
        /// of the wire the same on a wide canvas and on a narrow one, and it is what
        /// makes the turns close enough together that neighbouring loops overlap and
        /// the wire reads as a coil rather than as a wave.
        static let pitches: [CGFloat] = [8.4, 7.2, 6.2]
        /// Which way each strand winds.
        ///
        /// The second strand winds the other way, so the first two cross each other
        /// at the rate their turns add up rather than at the rate they differ: that
        /// is the criss-cross of the reference photograph.
        static let handedness: [Double] = [1, -1, 1]
        /// Where each strand starts round its own helix, in radians.
        static let phases: [Double] = [0.0, 2.1, 4.2]
        /// How far a loop swings along the span, as a share of the wire's own
        /// radius.
        ///
        /// A helix seen exactly side-on is a sinusoid, and a sinusoid is not what a
        /// coil looks like: the wire has to come round towards the person for a whole
        /// loop to be drawn. Swinging the loop across the span by its own radius does
        /// that, and because the swing follows the radius the loops shrink towards
        /// the converging ends of the spindle.
        static let loopShare: CGFloat = 0.62
        /// The exponent that gives the spindle its shape.
        ///
        /// `sin(pi u)^0.55` is a spindle that holds its width across most of the
        /// span and comes to a point at both ends; an exponent of one is an ellipse,
        /// which is fat at the ends and reads as a lens rather than as wire.
        static let spindleExponent: Double = 0.55
        /// The frequencies of the three waves the wire's irregularity is made of,
        /// in cycles across the span.
        static let irregularityFrequencies: [Double] = [1.7, 4.3, 9.1]
        /// The weight of each of those waves.
        static let irregularityWeights: [Double] = [1.0, 0.6, 0.35]
        /// The phase each of those waves is given for a strand and a channel, in
        /// radians per seed.
        ///
        /// A seed of `strand * 3 + channel` is what keeps the three strands' shapes,
        /// angles and offsets unrelated: they share one fixed field of irregularity
        /// rather than each carrying a copy of it.
        static let irregularityPhases: [Double] = [1.37, 2.71, 0.53]
        /// What the sum of the three waves is divided by, so the field is `1` at its
        /// own extreme.
        static let irregularityNormaliser: Double = 1.95
        /// How much of the radius the wire's own irregularity moves, as a share.
        static let radiusWobble: Double = 0.20
        /// How far the wire's angle is thrown off its uniform winding, in radians.
        static let angleWobble: Double = 0.55
        /// How far the axis of a strand wanders from the canvas's centre line, in
        /// points.
        static let axisWobble: Double = 0.45
        /// The samples one turn of a strand is drawn with.
        ///
        /// A loop has tight curvature where it turns round, and a coarser sampling
        /// cuts the corner off it: thirty-six points a turn is what draws the loop
        /// rather than the polygon round it.
        static let stepsPerTurn = 36
        /// How far the wire shivers with its own heat, in points.
        static let shimmerGain: Double = 0.10
        /// The rate of the shiver, in hertz.
        static let shimmerRate: Double = 1.9
        /// How much the shiver lags from one end of the wire to the other, in
        /// radians per unit of span, and from one strand to the next.
        static let shimmerStep: Double = 5

        // MARK: Heat

        /// How many samples of the history the wire's temperature is integrated
        /// over.
        static let lagSamples = 48
        /// The time the wire takes to reach a temperature it is given, in seconds.
        static let attackTau: Double = 0.035
        /// The time the wire takes to lose that temperature, in seconds.
        static let releaseTau: Double = 0.220
        /// How many ticks a still frame's temperature holds, at sixty a second.
        static let stillHoldTicks = 30
        /// How many temperatures along the span are computed.
        static let heatSamples = 48
        /// The kernel the heat spreads along the wire with, and how often it is
        /// applied.
        static let conduction: [Double] = [0.25, 0.5, 0.25]
        static let conductionPasses = 2
        /// The temperature the wire keeps in silence.
        ///
        /// A filament with no current in it is still a wire, and a wire that
        /// vanished between two words would be a picture of a voice rather than of
        /// an object: at `0.14` it is a deep ember, visible and clearly unlit.
        static let ember: Double = 0.14
        /// How much of the wire's heat range above the ember the voice drives.
        static let emberGain: Double = 0.86
        /// The reading at which the wire is as hot as it gets.
        ///
        /// It is the ceiling ``VisualizerMath/displayEnergy(_:ceiling:)`` puts on
        /// the loudest moment of a take, and therefore what a mix of the envelope
        /// and the bands reaches at a peak.
        static let fullReading: Double = 0.85
        /// The exponent the mixed reading is raised to.
        static let temperatureExponent: Double = 0.75
        /// The share of its temperature the wire keeps at the very ends of the
        /// spindle, and how much of the rest the envelope gives back.
        ///
        /// A real filament is cooler where it turns back at its supports, and the
        /// spindle's own taper is the shape of that: without it the two ends of the
        /// coil are the same colour as its middle and the object loses its
        /// perspective.
        static let taperFloor: Double = 0.35
        static let taperGain: Double = 0.65
        /// The exponent the spindle is raised to for the taper.
        static let taperExponent: Double = 0.5

        // MARK: Colour

        /// One altitude of the blackbody ramp.
        struct Blackbody {
            /// The temperature, from `0` at a cold wire to `1` at a warm white.
            var heat: Double
            /// The red component, in sRGB, from `0` to `1`.
            var red: Double
            /// The green component, in sRGB, from `0` to `1`.
            var green: Double
            /// The blue component, in sRGB, from `0` to `1`.
            var blue: Double
            /// How opaque the wire is at this temperature.
            var alpha: Double
        }

        /// The colours a tungsten wire has as it is heated, from an ember to white.
        ///
        /// There is no grey stop: the wire of this filament is never unlit, so the
        /// ramp starts at the dull red of a wire that has almost gone out.
        static let blackbody: [Blackbody] = [
            Blackbody(heat: 0.00, red: 0.20, green: 0.03, blue: 0.01, alpha: 0.0),
            Blackbody(heat: 0.12, red: 0.50, green: 0.10, blue: 0.03, alpha: 0.85),
            Blackbody(heat: 0.30, red: 0.80, green: 0.24, blue: 0.05, alpha: 1),
            Blackbody(heat: 0.50, red: 1.00, green: 0.50, blue: 0.14, alpha: 1),
            Blackbody(heat: 0.70, red: 1.00, green: 0.70, blue: 0.38, alpha: 1),
            Blackbody(heat: 0.88, red: 1.00, green: 0.84, blue: 0.64, alpha: 1),
            Blackbody(heat: 1.00, red: 1.00, green: 0.93, blue: 0.84, alpha: 1),
        ]

        // MARK: Light

        /// The blur radius of the halo, in points.
        static let haloRadius: CGFloat = 3.2
        /// The stroke width the halo is taken from, in points.
        static let haloWidth: CGFloat = 2.6
        /// The share of ink the halo carries at the top of the heat range.
        static let haloInk: Double = 0.30
        /// The exponent the halo falls off with.
        static let haloExponent: Double = 1.4
        /// The blur radius of the glow, in points.
        static let glowRadius: CGFloat = 1.0
        /// The stroke width the glow is taken from, in points.
        static let glowWidth: CGFloat = 1.3
        /// The share of ink the glow carries at the top of the heat range.
        static let glowInk: Double = 0.75
        /// The exponent the glow falls off with.
        static let glowExponent: Double = 1.1
        /// How much of the glow a point of the wire gets with no compression of the
        /// wire there, and how much the compression adds.
        static let glowEdgeFloor: Double = 0.7
        static let glowEdgeGain: Double = 0.3
        /// The width of the wire itself, in points.
        static let wireWidth: CGFloat = 0.55
        /// The share of the width and of the ink the far half of the wire takes.
        static let backWidthShare: CGFloat = 0.8
        static let backInk: Double = 0.70
        /// How much the compression of the wire raises its own colour.
        static let wireEdgeGain: Double = 0.12
        /// The heat above which the wire carries a white-hot core.
        static let coreOnset: Double = 0.5
        /// The width of the white-hot core, in points.
        static let coreWidth: CGFloat = 0.28
        /// The core's own colour: white with a hair of the card's warmth in it.
        static let coreRed: Double = 1.00
        static let coreGreen: Double = 0.96
        static let coreBlue: Double = 0.88
        /// How much of the core a compressed point of the wire gets, and how much
        /// the compression adds.
        static let coreEdgeFloor: Double = 0.6
        static let coreEdgeGain: Double = 0.4
        /// The depth above which a turnaround carries its shine point.
        static let glintDepth: Double = 0.15
        /// The radius of a shine point with no heat in the wire, and how much the
        /// heat adds, in points.
        static let glintRadius: CGFloat = 0.9
        static let glintGain: CGFloat = 0.8
        /// The share of ink a shine point carries at the top of the heat range.
        static let glintInk: Double = 0.85
        /// The shine point's colour, which is the nearest the picture comes to a
        /// specular white.
        static let glintRed: Double = 1.00
        static let glintGreen: Double = 0.97
        static let glintBlue: Double = 0.90
        /// The width of the light the whole coil throws on the card, as a share of
        /// the span, and its height, in points.
        static let ambientWidthShare: CGFloat = 0.92
        static let ambientHeight: CGFloat = 24
        /// The share of ink the ambient light carries at the top of the heat range.
        static let ambientInk: Double = 0.16
        /// The exponent the ambient light falls off with.
        static let ambientExponent: Double = 1.6
        /// How many heat samples the wire's strokes are batched into per side.
        ///
        /// A frame strokes one path per batch rather than one per run of wire, so
        /// four passes over three strands cost a few hundred paths and not a few
        /// thousand.
        static let batchBins = 24
        /// The compression of the wire at which the ramp of ``edge(threeD:screen:)``
        /// saturates, and the span it is normalised over.
        static let edgeFloor: Double = 1
        static let edgeCeiling: Double = 2.6
        static let edgeNormaliser: Double = 1.6

        // MARK: Geometry

        /// Where the coil sits on a canvas.
        struct Geometry {
            /// The canvas the coil is drawn on, in points.
            var size: CGSize
            /// The line the coil lies on, in points from the top of the canvas.
            var centreY: CGFloat
            /// The first and the last point of the span, in points across.
            var start: CGFloat
            var end: CGFloat
        }

        /// The coil on a canvas of this size.
        static func geometry(for size: CGSize) -> Geometry {
            let start = spanInset
            return Geometry(
                size: size,
                centreY: size.height / 2,
                start: start,
                end: max(start + 1, size.width - spanInset)
            )
        }

        /// How much of the specified radius a canvas of this height can hold.
        ///
        /// The wire throws a halo that reaches about ``haloReach`` points past its
        /// own outline, and light that reaches the edge of the canvas is a band
        /// across it rather than light: the coil is scaled to leave the halo its
        /// room, and on a canvas tall enough for the full size the scale is one.
        ///
        /// - Parameter height: the canvas's height, in points.
        static func fit(forHeight height: CGFloat) -> CGFloat {
            let reach = radiusMax * CGFloat(1 + radiusWobble) + axisWobble
            guard reach > 0 else { return 1 }
            let room = height / 2 - canvasMargin - haloReach
            return min(1, max(0.2, room / reach))
        }

        /// The fixed irregularity of one strand's shape, from `-1` to `1`.
        ///
        /// It is a sum of three waves of different frequencies, so the wander of the
        /// wire is neither a single slow bow nor a fast jitter: it is the
        /// combination a hand-wound coil has, and it never changes with the clock.
        ///
        /// - Parameters:
        ///   - u: the position along the span, from `0` to `1`.
        ///   - strand: which strand is being drawn.
        ///   - index: the channel, `0` for the radius, `1` for the angle and `2` for
        ///     the axis.
        static func irregularity(_ u: Double, strand: Int, index: Int) -> Double {
            let seed = Double(strand * 3 + index)
            var sum = 0.0
            for wave in 0..<3 {
                let phase = seed * irregularityPhases[wave]
                sum += irregularityWeights[wave]
                    * sin(2 * Double.pi * irregularityFrequencies[wave] * u + phase)
            }
            return sum / irregularityNormaliser
        }

        /// The spindle's width at a position, from `0` at the ends to `1` at the
        /// middle.
        static func spindle(_ u: Double) -> Double {
            pow(max(0, sin(Double.pi * min(1, max(0, u)))), spindleExponent)
        }

        /// The share of its temperature the wire keeps at a position.
        ///
        /// It is the spindle's own shape with a floor under it: the ends of the coil
        /// are the coolest part of it, and a floor keeps them a visible ember rather
        /// than a wire that has gone out.
        static func taper(_ u: Double) -> Double {
            taperFloor + taperGain * pow(spindle(u), taperExponent)
        }

        /// The radius of a strand's helix at a position, in points.
        ///
        /// - Parameters:
        ///   - u: the position along the span, from `0` to `1`.
        ///   - strand: which strand is being drawn.
        ///   - fit: how much of the full radius the canvas can hold, see
        ///     ``fit(forHeight:)``.
        static func radius(_ u: Double, strand: Int, fit: CGFloat = 1) -> CGFloat {
            let scale = radiusScales[min(strand, radiusScales.count - 1)]
            let wobble = 1 + radiusWobble * irregularity(u, strand: strand, index: 0)
            return radiusMax * fit * CGFloat(scale * spindle(u) * wobble)
        }

        /// How many turns a strand makes across a span of this length.
        ///
        /// - Parameters:
        ///   - strand: which strand is being drawn.
        ///   - span: the length of the span, in points.
        static func turns(strand: Int, span: CGFloat) -> Double {
            let pitch = pitches[min(strand, pitches.count - 1)]
            guard pitch > 0 else { return 1 }
            return Double(max(0, span) / pitch)
        }

        /// The angle of a strand round its own helix at a position, in radians.
        ///
        /// - Parameters:
        ///   - u: the position along the span, from `0` to `1`.
        ///   - strand: which strand is being drawn.
        ///   - turns: how many turns the strand makes across the span.
        static func angle(_ u: Double, strand: Int, turns: Double) -> Double {
            let direction = handedness[min(strand, handedness.count - 1)]
            let start = phases[min(strand, phases.count - 1)]
            return direction * 2 * Double.pi * turns * u
                + start
                + angleWobble * irregularity(u, strand: strand, index: 1)
        }

        /// How far a strand's axis wanders from the centre line at a position, in
        /// points.
        static func axisOffset(_ u: Double, strand: Int, fit: CGFloat = 1) -> CGFloat {
            axisWobble * fit * CGFloat(irregularity(u, strand: strand, index: 2))
        }

        /// How much of the wire the screen shows at one step, from `0` to `1`.
        ///
        /// A helix compressed into its own shadow is seen through more wire at every
        /// point, and that is the whole of the effect the reference photograph has:
        /// the loops are brightest where they turn back and dimmest where they run
        /// straight down the middle of the picture.
        ///
        /// - Parameters:
        ///   - threeD: the wire's own length over one step, in points.
        ///   - screen: the length of that step on the canvas, in points.
        /// - Returns: the normalised compression, `0` where the wire lies flat
        ///   against the canvas and `1` where it is compressed by
        ///   ``edgeCeiling``.
        static func edge(threeD: CGFloat, screen: CGFloat) -> Double {
            guard screen > 0.0001 else { return 1 }
            let ratio = min(edgeCeiling, max(edgeFloor, Double(threeD / screen)))
            return (ratio - edgeFloor) / edgeNormaliser
        }

        // MARK: Heat

        /// The light the wire has at a temperature, at an opacity of its own.
        ///
        /// The passes give their own opacity, so the ramp's own alpha is not part of
        /// what they draw: the ramp supplies the hues of the blackbody and the pass
        /// supplies how much of them is seen through a blur or a stroke width.
        ///
        /// - Parameters:
        ///   - heat: the temperature of the wire, from `0` to `1`.
        ///   - ink: how opaque the wire is here, from `0` to `1`.
        static func light(heat: Double, ink: Double) -> Color {
            let stop = components(heat: heat)
            return Color(red: stop.red, green: stop.green, blue: stop.blue)
                .opacity(min(1, max(0, ink)))
        }

        /// The light the wire has at a temperature, as the ramp's own colour.
        static func color(heat: Double, ink: Double = 1) -> Color {
            let stop = components(heat: heat)
            return Color(red: stop.red, green: stop.green, blue: stop.blue)
                .opacity(min(1, max(0, stop.alpha * ink)))
        }

        /// The four components of the blackbody ramp at a temperature.
        ///
        /// The interpolation is linear in sRGB between two neighbouring stops, so
        /// the ramp the drawing uses is the ramp a test measures: a temperature
        /// between two stops is a mix of those two colours and never a third one.
        ///
        /// - Parameter heat: the temperature of the wire, from `0` to `1`. A
        ///   temperature outside the ramp reads its nearest end.
        static func components(heat: Double) -> (red: Double, green: Double, blue: Double, alpha: Double) {
            guard let first = blackbody.first, let last = blackbody.last else {
                return (0, 0, 0, 0)
            }
            let value = min(1, max(0, heat))
            if value <= first.heat { return (first.red, first.green, first.blue, first.alpha) }
            if value >= last.heat { return (last.red, last.green, last.blue, last.alpha) }
            for index in 1..<blackbody.count {
                let high = blackbody[index]
                guard value <= high.heat else { continue }
                let low = blackbody[index - 1]
                let span = high.heat - low.heat
                let fraction = span > 0 ? (value - low.heat) / span : 0
                return (
                    low.red + (high.red - low.red) * fraction,
                    low.green + (high.green - low.green) * fraction,
                    low.blue + (high.blue - low.blue) * fraction,
                    low.alpha + (high.alpha - low.alpha) * fraction
                )
            }
            return (last.red, last.green, last.blue, last.alpha)
        }

        /// One band of one frame of the spectrum, on the card's own scale.
        ///
        /// The rows are read exactly the way ``HUDWaveform/drawMatrix`` reads them:
        /// the frame's own band, lifted by the frame before it so that a syllable's
        /// edge is a shoulder rather than a cliff, and clamped to the band's range.
        /// The lift is what keeps the top row from stepping from nothing to a
        /// fricative between two frames, which the wire would show as a blink.
        ///
        /// - Parameters:
        ///   - spectrum: the 60 Hz spectrum history, oldest first.
        ///   - index: the frame to read, clamped to the history.
        ///   - row: the band, `0` the sibilants and `4` the fundamental.
        static func band(_ spectrum: [AudioSpectrumFrame], index: Int, row: Int) -> Double {
            guard !spectrum.isEmpty else { return 0 }
            let at = min(spectrum.count - 1, max(0, index))
            let now = spectrum[at][row]
            let before = spectrum[max(0, at - 1)][row]
            return min(1, max(0, max(now, (now + before) * 0.5)))
        }

        /// The temperature of every band of the wire at the newest sample.
        ///
        /// Each band is integrated forward over the last ``lagSamples`` frames from
        /// a cold wire. The rows are read in the order the recorder measures them,
        /// row `0` the sibilants and row `4` the fundamental, and the wire maps a
        /// position onto them in ``heatProfile(history:spectrum:ceiling:reveal:reduceMotion:)``.
        static func bandHeat(_ spectrum: [AudioSpectrumFrame], reduceMotion: Bool) -> [Double] {
            guard !spectrum.isEmpty else { return [0, 0, 0, 0, 0] }
            let first = max(0, spectrum.count - lagSamples)
            let frames = Array(first..<spectrum.count)
            return (0..<5).map { row in
                let raw = frames.map { band(spectrum, index: $0, row: row) }
                return reduceMotion ? held(raw) : thermalLag(raw)
            }
        }

        /// The temperature of the wire as a whole at the newest sample.
        static func envelopeHeat(_ history: [Double], ceiling: Double, reduceMotion: Bool) -> Double {
            guard !history.isEmpty else { return 0 }
            let raw = history.suffix(lagSamples).map { VisualizerMath.displayEnergy($0, ceiling: ceiling) }
            return reduceMotion ? held(Array(raw)) : thermalLag(Array(raw))
        }

        /// The largest raw value of the most recent ticks.
        ///
        /// A style drawn without motion shows the wire at one moment of the voice's
        /// own recent past, and a hold is what keeps a still frame from being the
        /// picture of the gap between two syllables.
        static func held(_ raw: [Double]) -> Double {
            VisualizerMath.peakHold(raw, ticks: stillHoldTicks).last ?? 0
        }

        /// The temperature a wire settles at, from a cold start.
        ///
        /// Tungsten heats in ``attackTau`` and cools in ``releaseTau``, and the
        /// difference between the two is the whole of the movement: a syllable
        /// lights its part of the wire before the syllable is over, and the wire is
        /// still red after the word has ended.
        static func thermalLag(_ values: [Double], dt: Double = 1 / VisualizerMath.sampleRate) -> Double {
            let attack = 1 - exp(-max(0, dt) / attackTau)
            let release = 1 - exp(-max(0, dt) / releaseTau)
            var heat = 0.0
            for value in values {
                heat += (value - heat) * (value > heat ? attack : release)
            }
            return heat
        }

        /// The reading a mixed position of the wire has put it at.
        ///
        /// The envelope arrives already normalised to ``fullReading`` at the loudest
        /// moment of the take, so a mix of the envelope and one band tops out three
        /// quarters of the way up the ramp. Dividing by that reading puts the
        /// loudest mixed reading of the take at the top of the range, and the
        /// exponent lifts the middle of it with it, so an ordinary syllable is
        /// orange rather than deep red and only a peak is white.
        static func temperature(_ reading: Double) -> Double {
            pow(min(1, max(0, reading / fullReading)), temperatureExponent)
        }

        /// The temperature along the wire, from the left point of the spindle to the
        /// right one.
        ///
        /// The ends of the wire are where the sibilants are and the middle of it is
        /// where the fundamental is, so a position reads its own band by walking the
        /// five rows from the centre outwards: `4 - 8 |u - 0.5|` is row `4` at the
        /// centre and row `0` at either end, and a position between two rows is the
        /// straight line between them. That reading becomes a temperature through
        /// ``temperature(_:)`` on top of the ember the wire always carries, the
        /// temperatures are conducted along the wire, and the whole of it is then
        /// tapered towards the ends of the spindle.
        static func heatProfile(
            history: [Double],
            spectrum: [AudioSpectrumFrame],
            ceiling: Double,
            reveal: Double,
            reduceMotion: Bool
        ) -> [Double] {
            let envelope = envelopeHeat(history, ceiling: ceiling, reduceMotion: reduceMotion)
            let bands = bandHeat(spectrum, reduceMotion: reduceMotion)
            let shown = min(1, max(0, reveal))
            var profile = (0..<heatSamples).map { sample -> Double in
                let u = Double(sample) / Double(max(1, heatSamples - 1))
                let row = 4 - 8 * abs(u - 0.5)
                let low = min(4, max(0, Int(row.rounded(.down))))
                let high = min(4, max(0, Int(row.rounded(.up))))
                let fraction = row - row.rounded(.down)
                let band = bands[low] * (1 - fraction) + bands[high] * fraction
                let reading = temperature(0.5 * envelope + 0.5 * band)
                return shown * (ember + emberGain * reading)
            }
            for _ in 0..<conductionPasses {
                profile = conduct(profile)
            }
            return profile.indices.map { index in
                let u = Double(index) / Double(max(1, heatSamples - 1))
                return min(1, max(0, profile[index] * taper(u)))
            }
        }

        /// One pass of the wire's own conduction.
        static func conduct(_ profile: [Double]) -> [Double] {
            guard profile.count > 1 else { return profile }
            let last = profile.count - 1
            return profile.indices.map { index in
                let left = profile[max(0, index - 1)]
                let right = profile[min(last, index + 1)]
                return conduction[0] * left + conduction[1] * profile[index] + conduction[2] * right
            }
        }

        /// The temperature of the wire at a position along it.
        static func heat(at u: Double, in profile: [Double]) -> Double {
            guard let first = profile.first else { return 0 }
            guard profile.count > 1 else { return first }
            let position = min(1, max(0, u)) * Double(profile.count - 1)
            let low = Int(position.rounded(.down))
            guard low < profile.count - 1 else { return profile[profile.count - 1] }
            let fraction = position - Double(low)
            return profile[low] * (1 - fraction) + profile[low + 1] * fraction
        }

        /// The temperature of the coil as a whole, from `0` to `1`.
        ///
        /// The ambient light the coil throws is read from it, so the card around the
        /// wire warms with the voice rather than only the wire itself.
        static func mean(_ profile: [Double]) -> Double {
            profile.isEmpty ? 0 : profile.reduce(0, +) / Double(profile.count)
        }

        // MARK: The wire

        /// One sample of one strand: where the wire is, how hot it is, and how much
        /// of it the screen shows there.
        struct Node {
            /// The position along the span, from `0` at the left end to `1` at the
            /// right one.
            var u: Double
            /// The point on the canvas the wire passes through, in points.
            var point: CGPoint
            /// Which side of the helix the point is on: positive is nearer the
            /// person.
            var depth: Double
            /// Where the point sits round its own helix, `-1` at the bottom of a loop
            /// and `1` at the top of one.
            var sine: Double
            /// The temperature of the wire there, from `0` to `1`.
            var heat: Double
            /// How much wire the screen shows there, from `0` to `1`.
            var edge: Double
            /// Whether the point is on the near half of the helix.
            var isFront: Bool { depth > 0 }
        }

        /// One stroke of the wire: a stretch of one strand on one side of the helix,
        /// carrying one temperature.
        struct Piece {
            /// Whether the stretch is on the near half of the helix.
            var isFront: Bool
            /// The temperature of the wire along the stretch.
            var heat: Double
            /// How much wire the screen shows along the stretch.
            var edge: Double
            /// The stretch's path on the canvas.
            var path: Path
        }

        /// The wire of one frame.
        struct Coil {
            /// The strokes, the far half's first within each heat sample.
            var pieces: [Piece]
            /// Every strand's samples, in order.
            var nodes: [[Node]]
        }

        /// The samples of one strand.
        ///
        /// - Parameters:
        ///   - strand: which strand is being drawn.
        ///   - bulb: the geometry of the coil.
        ///   - profile: the temperature along the span.
        ///   - time: the clock the shiver of the wire is read against.
        ///   - reduceMotion: whether the wire is still.
        /// - Returns: the strand's samples, from the left end of the span to the
        ///   right one.
        static func nodes(
            strand: Int,
            in bulb: Geometry,
            heat profile: [Double],
            time: Double,
            reduceMotion: Bool
        ) -> [Node] {
            let span = bulb.end - bulb.start
            let turnCount = turns(strand: strand, span: span)
            let count = max(2, Int((turnCount * Double(stepsPerTurn)).rounded()))
            let fit = fit(forHeight: bulb.size.height)
            var points: [CGPoint] = []
            var depths: [Double] = []
            var sines: [Double] = []
            var heights: [CGFloat] = []
            var depths3D: [CGFloat] = []
            var heats: [Double] = []
            points.reserveCapacity(count + 1)
            for index in 0...count {
                let u = Double(index) / Double(count)
                let radius = radius(u, strand: strand, fit: fit)
                let theta = angle(u, strand: strand, turns: turnCount)
                let sine = sin(theta)
                // The swing across the span is what turns the side-on sinusoid into
                // a drawn loop: the wire comes round towards the person instead of
                // running flat through the picture.
                let swing = radius * loopShare * CGFloat(cos(theta))
                let point = CGPoint(
                    x: bulb.start + span * CGFloat(u) + swing,
                    y: bulb.centreY + axisOffset(u, strand: strand, fit: fit) + radius * CGFloat(sine)
                )
                points.append(point)
                heights.append(point.y)
                depths.append(cos(theta))
                sines.append(sine)
                // The wire is a curve in space: its depth from the person is the
                // helix's own radius, not the unit depth its side is read from, or
                // the arc length would mix points with a number that has no unit.
                depths3D.append(radius * CGFloat(cos(theta)))
                heats.append(heat(at: u, in: profile))
            }

            var steps = [Double](repeating: 0, count: count)
            for index in 0..<count {
                let dx = points[index + 1].x - points[index].x
                let dy = heights[index + 1] - heights[index]
                let dz = depths3D[index + 1] - depths3D[index]
                let threeD = sqrt(dx * dx + dy * dy + dz * dz)
                let screen = sqrt(dx * dx + dy * dy)
                steps[index] = edge(threeD: threeD, screen: screen)
            }

            return (0...count).map { index in
                let u = Double(index) / Double(count)
                let shiver = reduceMotion
                    ? 0
                    : shimmerGain * heats[index]
                        * sin(2 * Double.pi * (shimmerRate * time + shimmerStep * u + Double(strand)))
                let before = steps[max(0, index - 1)]
                let after = steps[min(count - 1, index)]
                return Node(
                    u: u,
                    point: CGPoint(x: points[index].x, y: points[index].y + CGFloat(shiver)),
                    depth: depths[index],
                    sine: sines[index],
                    heat: heats[index],
                    edge: (before + after) / 2
                )
            }
        }

        /// The wire of a bulb, sampled and batched for one frame.
        ///
        /// Each strand is cut into the runs that are on the near side of its helix
        /// and the runs that are on the far side, and each run is then cut again by
        /// the heat sample it lies in: a frame strokes one path per batch, so four
        /// passes over three strands cost a few hundred paths rather than a few
        /// thousand.
        static func coil(
            in bulb: Geometry,
            heat profile: [Double],
            time: Double,
            reduceMotion: Bool
        ) -> Coil {
            var strands: [[Node]] = []
            var pieces: [Piece] = []
            for strand in 0..<strandCount {
                let nodes = nodes(strand: strand, in: bulb, heat: profile, time: time, reduceMotion: reduceMotion)
                strands.append(nodes)
                guard nodes.count > 1 else { continue }
                var start = 0
                for index in 1...nodes.count {
                    let ends = index == nodes.count || nodes[index].isFront != nodes[start].isFront
                    guard ends else { continue }
                    // The run that is ending carries the step across the silhouette
                    // as well. Without it the wire is cut at the top of every loop,
                    // where it is about to turn away from the person, and a cut in a
                    // glowing wire reads as a break rather than as a turn: the step
                    // is drawn once, in the colour of the side it is leaving.
                    let last = index == nodes.count ? index - 1 : index
                    appendPieces(from: nodes, range: start...last, into: &pieces)
                    start = index
                }
            }
            return Coil(pieces: pieces, nodes: strands)
        }

        /// Cuts one run of the wire into the strokes of one heat sample each.
        ///
        /// - Parameters:
        ///   - nodes: every sample of the strand.
        ///   - range: the indices of the run.
        ///   - pieces: the strokes of the frame, appended to.
        static func appendPieces(from nodes: [Node], range: ClosedRange<Int>, into pieces: inout [Piece]) {
            guard range.upperBound > range.lowerBound else { return }
            var start = range.lowerBound
            while start < range.upperBound {
                let bin = binIndex(nodes[start].u)
                var end = start + 1
                while end < range.upperBound, binIndex(nodes[end].u) == bin {
                    end += 1
                }
                var path = Path()
                path.move(to: nodes[start].point)
                for index in (start + 1)...end {
                    path.addLine(to: nodes[index].point)
                }
                pieces.append(Piece(
                    isFront: nodes[start].isFront,
                    heat: (nodes[start].heat + nodes[end].heat) / 2,
                    edge: (nodes[start].edge + nodes[end].edge) / 2,
                    path: path
                ))
                start = end
            }
        }

        /// The heat sample a position falls in.
        static func binIndex(_ u: Double) -> Int {
            min(batchBins - 1, max(0, Int(u * Double(batchBins))))
        }

        /// The strokes that carry the white-hot core.
        ///
        /// The drawing and the tests read the same list: a test that asks whether the
        /// core is drawn is asking about the strokes the card makes rather than
        /// about a pixel that a halo could have brightened.
        static func corePieces(_ coil: Coil) -> [Piece] {
            coil.pieces.filter { $0.heat > coreOnset }
        }

        /// The shine points of the near half: the turnarounds of every front run.
        ///
        /// A loop of the wire turns back at its top and at its bottom, and that is
        /// where the reference photograph shows a point of specular light rather than
        /// a length of wire.
        static func glints(_ coil: Coil) -> [Node] {
            var points: [Node] = []
            for nodes in coil.nodes {
                guard nodes.count > 2 else { continue }
                for index in 1..<(nodes.count - 1) {
                    let node = nodes[index]
                    guard node.depth > glintDepth else { continue }
                    let before = nodes[index - 1].sine
                    let after = nodes[index + 1].sine
                    let isPeak = node.sine > before && node.sine > after
                    let isTrough = node.sine < before && node.sine < after
                    guard isPeak || isTrough else { continue }
                    points.append(node)
                }
            }
            return points
        }

        /// The transform that turns a circle of a box's width into the box's own
        /// ellipse.
        ///
        /// A radial gradient is a circle, and a circle filled into an ellipse keeps
        /// its circular profile: it would reach clear at the top and the bottom of
        /// the box and end in a hard edge there. The stretch is applied to a drawing
        /// layer instead, so the gradient itself is elliptical.
        static func stretch(_ box: CGRect) -> CGAffineTransform {
            let scale = box.width > 0 ? box.height / box.width : 1
            return CGAffineTransform(translationX: 0, y: box.midY)
                .scaledBy(x: 1, y: scale)
                .translatedBy(x: 0, y: -box.midY)
        }
    }

    /// The bare filament: three strands of glowing wire, drawn in four passes.
    ///
    /// Every pass is added to the card's own surface, so the wire is light rather
    /// than paint: the halo is the light it throws into the card's darkness, the
    /// glow is the light around the wire, the wire is the wire, and the core is the
    /// white of the hottest stretches. The far half of each strand is stroked before
    /// the near half in every pass, and dimmer, so the coil has a front and a back.
    private func drawFilament(context: GraphicsContext, size: CGSize) {
        let bulb = Filament.geometry(for: size)
        let shown = min(1, max(0, shownReveal))
        guard shown > 0, bulb.end - bulb.start > 12 else { return }

        let profile = Filament.heatProfile(
            history: history,
            spectrum: spectrumHistory,
            ceiling: ceiling,
            reveal: shown,
            reduceMotion: reduceMotion
        )
        let meanHeat = Filament.mean(profile)
        let coil = Filament.coil(
            in: bulb,
            heat: profile,
            time: effectiveTime,
            reduceMotion: reduceMotion
        )

        var surface = context
        surface.opacity = shown
        surface.clip(to: Path(CGRect(origin: .zero, size: size)))

        // The light the coil throws on the card around it. It goes down first: a
        // wash added over the wire would be light in front of the object rather than
        // light coming off it.
        func drawAmbient() {
            guard meanHeat > 0.02 else { return }
            let height = min(Filament.ambientHeight, size.height - 2)
            guard height > 0 else { return }
            let box = CGRect(
                x: size.width / 2 - (bulb.end - bulb.start) * Filament.ambientWidthShare / 2,
                y: bulb.centreY - height / 2,
                width: (bulb.end - bulb.start) * Filament.ambientWidthShare,
                height: height
            )
            var layer = surface
            layer.blendMode = .plusLighter
            layer.drawLayer { light in
                light.blendMode = .plusLighter
                light.concatenate(Filament.stretch(box))
                light.fill(
                    Path(ellipseIn: CGRect(
                        x: box.midX - box.width / 2,
                        y: box.midY - box.width / 2,
                        width: box.width,
                        height: box.width
                    )),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: Filament.light(
                                heat: meanHeat,
                                ink: Filament.ambientInk * pow(meanHeat, Filament.ambientExponent)
                            ), location: 0),
                            .init(color: Filament.light(heat: meanHeat, ink: 0), location: 1),
                        ]),
                        center: CGPoint(x: box.midX, y: box.midY),
                        startRadius: 0,
                        endRadius: box.width / 2
                    )
                )
            }
        }

        /// One pass of the wire over both halves of every strand.
        ///
        /// - Parameters:
        ///   - width: the stroke width of the near half, in points.
        ///   - radius: the blur radius of the pass, or `nil` for a sharp one.
        ///   - ink: how opaque the near half of a stroke is.
        ///   - colour: the colour of a stroke at its own heat and compression.
        func drawPass(
            _ pieces: [Filament.Piece],
            width: CGFloat,
            radius: CGFloat?,
            ink: (Filament.Piece) -> Double,
            colour: (Filament.Piece) -> Color
        ) {
            // `drawLayer` calls its closure synchronously on this thread, so the
            // two closures never cross an isolation boundary; Swift 6.3's release
            // build cannot see that and reports the capture as a data race.
            nonisolated(unsafe) let ink = ink
            nonisolated(unsafe) let colour = colour
            var layer = surface
            layer.blendMode = .plusLighter
            // A filter added to a context applies to every drawing operation after
            // it, so a pass of a hundred strokes behind one filter would be a
            // hundred blurs: the strokes go into a layer of their own and the filter
            // is put over that layer's single composite.
            layer.drawLayer { canvas in
                if let radius {
                    canvas.addFilter(.blur(radius: radius))
                    canvas.drawLayer { inner in
                        inner.blendMode = .plusLighter
                        stroke(pieces, into: inner, width: width, ink: ink, colour: colour)
                    }
                    return
                }
                canvas.blendMode = .plusLighter
                stroke(pieces, into: canvas, width: width, ink: ink, colour: colour)
            }
        }

        /// Every stroke of one pass, the far half of the wire first.
        func stroke(
            _ pieces: [Filament.Piece],
            into canvas: GraphicsContext,
            width: CGFloat,
            ink: (Filament.Piece) -> Double,
            colour: (Filament.Piece) -> Color
        ) {
            for piece in pieces where !piece.isFront {
                let value = ink(piece) * Filament.backInk
                guard value > 0.002 else { continue }
                canvas.stroke(
                    piece.path,
                    with: .color(colour(piece).opacity(value)),
                    style: StrokeStyle(
                        lineWidth: width * Filament.backWidthShare,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
            for piece in pieces where piece.isFront {
                let value = ink(piece)
                guard value > 0.002 else { continue }
                canvas.stroke(
                    piece.path,
                    with: .color(colour(piece).opacity(value)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
                )
            }
        }

        // The shine points at the turnarounds: the nearest the picture comes to a
        // specular highlight, and the one thing that says the wire is round. They
        // share one layer because a layer per point would cost more than every other
        // pass of the frame together.
        func drawGlints() {
            guard meanHeat > 0.02 else { return }
            let points = Filament.glints(coil)
            guard !points.isEmpty else { return }
            var layer = surface
            layer.blendMode = .plusLighter
            layer.drawLayer { light in
                light.blendMode = .plusLighter
                for node in points {
                    let radius = Filament.glintRadius + Filament.glintGain * CGFloat(node.heat)
                    let ink = Filament.glintInk * node.heat * (node.isFront ? 1 : Filament.backInk)
                    guard ink > 0.002, radius > 0 else { continue }
                    let box = CGRect(
                        x: node.point.x - radius,
                        y: node.point.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    light.fill(
                        Path(ellipseIn: box),
                        with: .radialGradient(
                            Gradient(stops: [
                                .init(color: Color(
                                    red: Filament.glintRed,
                                    green: Filament.glintGreen,
                                    blue: Filament.glintBlue
                                ).opacity(min(1, ink)), location: 0),
                                .init(color: Color(
                                    red: Filament.glintRed,
                                    green: Filament.glintGreen,
                                    blue: Filament.glintBlue
                                ).opacity(0), location: 1),
                            ]),
                            center: node.point,
                            startRadius: 0,
                            endRadius: radius
                        )
                    )
                }
            }
        }

        drawAmbient()

        drawPass(
            coil.pieces,
            width: Filament.haloWidth,
            radius: Filament.haloRadius,
            ink: { Filament.haloInk * pow($0.heat, Filament.haloExponent) },
            colour: { Filament.light(heat: $0.heat, ink: 1) }
        )
        drawPass(
            coil.pieces,
            width: Filament.glowWidth,
            radius: Filament.glowRadius,
            ink: {
                Filament.glowInk * pow($0.heat, Filament.glowExponent)
                    * (Filament.glowEdgeFloor + Filament.glowEdgeGain * $0.edge)
            },
            colour: { Filament.light(heat: $0.heat, ink: 1) }
        )
        drawPass(
            coil.pieces,
            width: Filament.wireWidth,
            radius: nil,
            ink: { _ in 1 },
            colour: {
                Filament.light(
                    heat: min(1, $0.heat + Filament.wireEdgeGain * $0.edge),
                    ink: 1
                )
            }
        )
        drawPass(
            Filament.corePieces(coil),
            width: Filament.coreWidth,
            radius: nil,
            ink: {
                (($0.heat - Filament.coreOnset) / (1 - Filament.coreOnset))
                    * (Filament.coreEdgeFloor + Filament.coreEdgeGain * $0.edge)
            },
            colour: { _ in
                Color(
                    red: Filament.coreRed,
                    green: Filament.coreGreen,
                    blue: Filament.coreBlue
                )
            }
        )

        drawGlints()
    }

    // MARK: - 04 Silk (Four Twisting Ribbons)

    /// The geometry and the rules of the silk ribbons.
    ///
    /// The picture is four ribbons weaving through each other, not a set of
    /// lines and not one outline: each ribbon is a band whose thickness and
    /// whose distance from the centre line are two travelling waves, so the four
    /// cross over and under one another as the clock moves. The voice is their
    /// amplitude and their width at once: a ribbon is thick where the voice was
    /// loud and a hairline where it was quiet, and the taper at both ends leaves
    /// the canvas as a point rather than being cut off by it.
    ///
    /// The voice itself is the window's envelope reduced to sixty-four controls
    /// by taking the largest sample of each group, smoothed once with a binomial
    /// kernel, read through a Catmull-Rom spline and scaled to the take's own
    /// ceiling. A silent card is four hairlines drifting against the centre
    /// line, which is the calmest state the style has rather than nothing.
    enum Silk {
        /// The horizontal inset at each end, in points.
        static let inset: CGFloat = 6
        /// How many controls the window's envelope is reduced to.
        static let controlCount = 64
        /// How many 60 Hz samples of the voice the ribbons show.
        ///
        /// The card's ring holds three seconds, but a picture drawn across three
        /// seconds is a picture of the take rather than of the voice: the recent
        /// moment is squeezed into its last third. One second and a tenth is the
        /// span the card's scrolling styles show, so the five read the same
        /// window.
        static let windowSeconds: Double = 1.1
        /// How many 60 Hz samples that window holds.
        static var windowTicks: Int { Int(windowSeconds * VisualizerMath.sampleRate) }
        /// The binomial kernel one pass of smoothing applies, over sixteen.
        static let kernel: [Double] = [1, 4, 6, 4, 1]
        /// How long a sample is held when the motion is reduced, in seconds.
        static let holdSeconds: Double = 0.25
        /// How many points across the width a ribbon is built from.
        static let sampleCount = 96
        /// The smallest display value a ribbon is drawn at.
        ///
        /// Silence is a hairline rather than a line of zero thickness: a card
        /// that is listening has to show that it is listening without pretending
        /// to hear a voice in an empty room.
        static let silentFloor: Double = 0.04
        /// The power the sine taper is raised to at each end.
        static let taperExponent: Double = 0.8
        /// How many ribbons weave through each other.
        static let ribbonCount = 5
        /// Thickness cycles across the width, one per ribbon.
        static let thicknessCycles: [Double] = [1.1, 1.6, 2.2, 2.9, 3.7]
        /// How fast a ribbon's thickness travels, in cycles per second.
        static let thicknessSpeed: [Double] = [0.22, -0.31, 0.40, -0.27, 0.33]
        /// The phase of each ribbon's thickness, in radians.
        static let thicknessPhase: [Double] = [0, 1.3, 2.6, 3.9, 5.2]
        /// How much of the reach a ribbon's half thickness can take.
        static let thicknessShare: [Double] = [0.95, 0.80, 0.65, 0.50, 0.40]
        /// Centreline cycles across the width, one per ribbon.
        static let centreCycles: [Double] = [0.8, 1.3, 1.9, 2.4, 3.0]
        /// How fast a ribbon's centreline travels, in cycles per second.
        static let centreSpeed: [Double] = [0.18, -0.22, 0.27, -0.16, 0.21]
        /// The phase of each ribbon's centreline, in radians.
        static let centrePhase: [Double] = [0.6, 2.1, 3.4, 5.0, 0.2]
        /// How much of the reach a ribbon's centreline can take.
        static let centreShare: [Double] = [0.34, 0.30, 0.26, 0.22, 0.18]
        /// The ramp position each ribbon's fill is read at.
        static let fillStops: [Double] = [0.20, 0.40, 0.62, 0.82, 1.0]
        /// The opacity of a ribbon's top edge.
        static let topInk: [Double] = [0.26, 0.26, 0.28, 0.30, 0.34]
        /// The opacity of a ribbon's bottom edge.
        static let bottomInk: [Double] = [0.10, 0.10, 0.10, 0.12, 0.14]
        /// The ramp position each ribbon's rim is read at.
        static let rimStops: [Double] = [0.35, 0.55, 0.75, 0.90, 1.0]
        /// The opacity of each ribbon's rim.
        static let rimInk: [Double] = [0.55, 0.65, 0.75, 0.85, 0.95]
        /// The width of the rim's stroke, in points.
        static let rimWidth: CGFloat = 1.0
        /// The half thickness below which a ribbon carries no rim, in points.
        static let rimMinimumHalfThickness: CGFloat = 0.25

        /// The reach of a ribbon from the centre line, in points.
        static func reach(forHeight height: CGFloat) -> CGFloat {
            max(1, height / 2 - 1)
        }

        /// The taper at a position across the ribbons: `0` at each end, `1` in
        /// the middle.
        static func edge(_ u: Double) -> Double {
            pow(max(0, sin(Double.pi * min(1, max(0, u)))), taperExponent)
        }

        /// The window's envelope, one control per group of samples.
        ///
        /// The group is the largest sample it holds: a syllable is a peak, and
        /// an average would draw the ribbon below the voice that made it. A
        /// window shorter than the control count still fills every control, so
        /// the first frame of a recording is a whole shape rather than a
        /// half-drawn one.
        ///
        /// - Parameter window: the envelope, oldest first.
        /// - Returns: one value per control, oldest first.
        static func controls(from window: [Double]) -> [Double] {
            guard !window.isEmpty else { return Array(repeating: 0, count: controlCount) }
            let count = window.count
            return (0..<controlCount).map { control in
                let start = min(count - 1, control * count / controlCount)
                let end = max(start + 1, (control + 1) * count / controlCount)
                return window[start..<min(count, end)].max() ?? window[start]
            }
        }

        /// One pass of the binomial kernel, with clamped ends.
        static func smoothed(_ values: [Double]) -> [Double] {
            guard values.count > 2 else { return values }
            let total = kernel.reduce(0, +)
            return values.indices.map { index in
                var sum = 0.0
                for (tap, weight) in kernel.enumerated() {
                    let source = index + tap - kernel.count / 2
                    let clamped = min(values.count - 1, max(0, source))
                    sum += values[clamped] * Double(weight)
                }
                return sum / Double(total)
            }
        }

        /// The window's controls for a frame, before they are read at a position.
        ///
        /// - Parameters:
        ///   - history: the envelope, oldest first, at 60 Hz.
        ///   - reduceMotion: whether the reading is held rather than travelled.
        /// - Returns: one value per control, oldest first.
        static func windowControls(history: [Double], reduceMotion: Bool) -> [Double] {
            let held = reduceMotion
                ? VisualizerMath.peakHold(history, ticks: Int(holdSeconds * VisualizerMath.sampleRate))
                : history
            return smoothed(controls(from: Array(held.suffix(windowTicks))))
        }

        /// The value of the spline through the controls at a position across the
        /// ribbons, from `0` at the left end to `1` at the right.
        ///
        /// The curve passes through every control and its first derivative is
        /// continuous at every control, so a syllable is a shoulder in the
        /// ribbon rather than a corner.
        static func spline(_ values: [Double], at u: Double) -> Double {
            guard values.count > 1 else { return values.first ?? 0 }
            let last = values.count - 1
            let position = min(1, max(0, u)) * Double(last)
            let segment = min(last - 1, max(0, Int(position)))
            let t = position - Double(segment)
            let p0 = values[max(0, segment - 1)]
            let p1 = values[segment]
            let p2 = values[segment + 1]
            let p3 = values[min(last, segment + 2)]
            return 0.5 * (
                2 * p1
                + (-p0 + p2) * t
                + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t
            )
        }

        /// The display value of the voice at a position across the ribbons.
        ///
        /// - Parameters:
        ///   - controls: the window's controls, oldest first.
        ///   - u: the position across the ribbons, from `0` to `1`.
        ///   - ceiling: the loudest moment of the take.
        /// - Returns: the display value, never below ``silentFloor``.
        static func energy(_ controls: [Double], at u: Double, ceiling: Double) -> Double {
            max(silentFloor, VisualizerMath.displayEnergy(spline(controls, at: u), ceiling: ceiling))
        }

        /// The half thickness of a ribbon at a position and a moment.
        static func halfThickness(
            ribbon: Int,
            u: Double,
            energy: Double,
            reach: CGFloat,
            time: Double
        ) -> CGFloat {
            let theta = 2 * Double.pi * (thicknessCycles[ribbon] * u - thicknessSpeed[ribbon] * time)
                + thicknessPhase[ribbon]
            let wave = 0.15 + 0.85 * abs(cos(theta))
            return reach * thicknessShare[ribbon] * energy * edge(u) * wave
        }

        /// The offset of a ribbon's centreline from the canvas's middle, in
        /// points.
        static func centreOffset(
            ribbon: Int,
            u: Double,
            energy: Double,
            reach: CGFloat,
            time: Double
        ) -> CGFloat {
            let theta = 2 * Double.pi * (centreCycles[ribbon] * u - centreSpeed[ribbon] * time)
                + centrePhase[ribbon]
            return reach * centreShare[ribbon] * energy * edge(u) * sin(theta)
        }
    }

    private func drawSilk(context: GraphicsContext, size: CGSize) {
        let mid = size.height / 2
        let reach = Silk.reach(forHeight: size.height)
        let controls = Silk.windowControls(history: history, reduceMotion: reduceMotion)
        let inset = min(Silk.inset, size.width / 2)
        let width = size.width - inset * 2
        guard width > 1 else { return }
        let clock = reduceMotion ? 0 : effectiveTime
        let count = Silk.sampleCount
        let last = Double(count - 1)

        // The voice at every point the ribbons are built from, so the four read
        // one measurement rather than four samplings of it.
        var energies: [Double] = []
        energies.reserveCapacity(count)
        for index in 0..<count {
            energies.append(Silk.energy(controls, at: Double(index) / last, ceiling: ceiling))
        }

        let gradientStart = CGPoint(x: 0, y: mid - reach)
        let gradientEnd = CGPoint(x: 0, y: mid + reach)

        // Ribbon zero first, ribbon three on top.
        for ribbon in 0..<Silk.ribbonCount {
            var top: [CGPoint] = []
            var bottom: [CGPoint] = []
            var halfThickness: [CGFloat] = []
            top.reserveCapacity(count)
            bottom.reserveCapacity(count)
            halfThickness.reserveCapacity(count)
            for index in 0..<count {
                let u = Double(index) / last
                let energy = energies[index]
                let x = inset + CGFloat(u) * width
                let centre = mid + Silk.centreOffset(
                    ribbon: ribbon,
                    u: u,
                    energy: energy,
                    reach: reach,
                    time: clock
                )
                let half = Silk.halfThickness(
                    ribbon: ribbon,
                    u: u,
                    energy: energy,
                    reach: reach,
                    time: clock
                )
                top.append(CGPoint(x: x, y: centre - half))
                bottom.append(CGPoint(x: x, y: centre + half))
                halfThickness.append(half)
            }

            // The band between the two contours, filled with one vertical
            // gradient across the canvas's reach: the top of the gradient is the
            // ribbon's upper edge colour and its bottom the lower one, so the
            // ribbon has a lit side and a shaded side wherever it travels.
            var band = Path()
            band.move(to: top[0])
            for point in top.dropFirst() { band.addLine(to: point) }
            for point in bottom.reversed() { band.addLine(to: point) }
            band.closeSubpath()
            let colour = HUDTheme.meter(Silk.fillStops[ribbon], ceiling: ceiling)
            context.fill(
                band,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: colour.opacity(Silk.topInk[ribbon]), location: 0),
                        .init(color: colour.opacity(Silk.bottomInk[ribbon]), location: 1),
                    ]),
                    startPoint: gradientStart,
                    endPoint: gradientEnd
                )
            )

            // The rim: each contour stroked on its own, and only over the runs
            // where the ribbon is thick enough for an edge to be a line rather
            // than a smear. A hairline at silence has no rim at all.
            let rimColour = HUDTheme.meter(Silk.rimStops[ribbon], ceiling: ceiling)
            for contour in [top, bottom] {
                var run: [CGPoint] = []
                func flush() {
                    guard run.count > 1 else { run.removeAll(); return }
                    var path = Path()
                    path.move(to: run[0])
                    for point in run.dropFirst() { path.addLine(to: point) }
                    context.stroke(
                        path,
                        with: .color(rimColour.opacity(Silk.rimInk[ribbon])),
                        style: StrokeStyle(
                            lineWidth: Silk.rimWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    run.removeAll()
                }
                for index in 0..<count {
                    if halfThickness[index] >= Silk.rimMinimumHalfThickness {
                        run.append(contour[index])
                    } else {
                        flush()
                    }
                }
                flush()
            }
        }
    }


    // MARK: - 05 Matrix (Spectrogram Grid)

    /// The lattice the matrix is drawn on, and the dots one frame of it draws.
    ///
    /// The grid is the card's spectrogram, so its geometry is what the voice is
    /// read through. Five rows are as many bands as the recorder measures. The
    /// pitch is the smaller of a row's height and five points, so the rows stay
    /// square and a card of the usual height gets the five point lattice it was
    /// designed for. A dot's radius grows with its band from a quarter of the
    /// pitch to a third, so the widest dot is `0.66` of the pitch across and two
    /// neighbours keep `0.34` of the pitch between them at every level, which is
    /// what makes a loud word a grid of lamps rather than a stain.
    ///
    /// The grid slides. One dot is one sample pair of the spectrum, two meter
    /// ticks of it, and it travels one pitch per pair from the right edge to the
    /// left. The pair is indexed on the meter's absolute tick counter rather than
    /// on a slot of the ring, so a sample keeps its identity while it moves: the
    /// ring advances by a slot every tick, and a dot's slot therefore walks one
    /// place further into its own past at the same rate, which is what leaves its
    /// band unchanged for the whole of its life. The position is a function of the
    /// frame's own clock, `tick + phase`, so the grid moves by a fraction of the
    /// pitch on every display frame instead of jumping a whole column whenever the
    /// meter's ring happens to gain a sample.
    ///
    /// The clock is ``HUDWaveform/Stretch/newestSample(at:phase:)``, the one the
    /// scrolling row already reads. The meter's phase is taken back off the
    /// display's clock before the floor, which lands on the tick the frame belongs
    /// to whatever constant offset separates the two clocks; flooring the display's
    /// clock and adding the meter's phase afterwards would step the grid by a
    /// third of a pitch on every frame the two disagree.
    ///
    /// Nothing here can become a blob. A dot's body is at most a third of the pitch
    /// in radius, its halo stops at `0.45` of a pitch, and the halo is added to the
    /// card's surface with `plusLighter` and an opacity that already falls to
    /// nothing at its own bound. The bound is short of the midpoint between two
    /// neighbours by a twentieth of a pitch, so the one point where two dots face
    /// each other receives no light from either of them. The halo's ink is
    /// multiplied by the dot's own reveal as well, so a cell at the floor carries
    /// no halo at all.
    ///
    /// A dot is drawn whole or faded, never cut. The fade is measured from each
    /// side of the canvas to the edge of a half-pitch band inside it, so a dot is
    /// born with no ink at the right edge and reaches all of it after one pitch of
    /// travel, and it leaves the same way at the left. A dot whose disc the canvas
    /// would cut is not drawn.
    ///
    /// The drawing and the tests both read the dots from here, so a pixel a test
    /// samples is a pixel the card drew rather than a centre re-derived from the
    /// formula with a rounding of its own.
    enum MatrixLattice {
        /// How many bands the grid draws, one row each.
        static let rows = 5
        /// The widest pitch, in points.
        static let maximumPitch: CGFloat = 5
        /// The radius of a dot at rest, as a share of the pitch.
        static let restRadiusShare: CGFloat = 0.25
        /// How much of the pitch the radius gains at the top of the range.
        static let radiusGain: CGFloat = 0.08
        /// The radius of the widest dot, as a share of the pitch.
        static var maximumRadiusShare: CGFloat { restRadiusShare + radiusGain }
        /// How many ticks of the meter one pitch of the grid takes.
        ///
        /// The rate is the rate the spectrum was measured at: one column per two
        /// samples, so the grid scrolls at a hundred and fifty points a second on
        /// the card's five point pitch whatever its width.
        static let ticksPerPitch = 2
        /// The display value at which a dot starts to take light.
        ///
        /// A cell below it is a dot of the floor's own amber, which is what a
        /// silent card is: a grid that is drawn, and clearly not speaking.
        static let litOnset: Double = 0.07
        /// How far past ``litOnset`` a dot takes to reach its full lamp.
        ///
        /// The lamp is faded in across this span rather than switched on at the
        /// onset. A dot that goes from the floor to an opaque white centre
        /// between two frames is a flicker at the threshold: at `0.07` one frame
        /// is a dim dot and the next is a lamp, so a syllable edge draws as a
        /// step in brightness rather than as the voice arriving. Across these
        /// `0.10` of the display value, from `0.07` to `0.17`, the dot grows
        /// its light by the amount its own level says, and two neighbouring
        /// frames differ by as much as the voice between them did.
        ///
        /// It is `0.10` rather than a wider band because the fade has to be short
        /// enough that a cell at ordinary speech is at its full lamp: past
        /// `0.17` the dot is lit by its level alone, so the grid the owner asked
        /// for is not dimmed to smooth a step that only exists below a fifth of
        /// the range.
        static let litRamp: Double = 0.10
        /// The display value above which a dot counts as shining.
        static let shineOnset: Double = 0.55
        /// The reach of a dot's halo, as a share of the pitch.
        ///
        /// It is `0.45` of the pitch, which ends the halo `0.05` of a pitch, a
        /// quarter of a point on the card's lattice, short of the midpoint between
        /// two neighbours. The midpoint therefore receives no light from either of
        /// them, and the falloff that was already nothing at its own bound has a
        /// clear margin to the one place two dots meet.
        static let glowRadiusShare: CGFloat = 0.45
        /// The band of the canvas's side over which a dot fades, as a share of the
        /// pitch.
        ///
        /// It is half a pitch, the distance from the edge to the midpoint between
        /// two neighbours, and it is not the halo's own radius. A fade measured
        /// from the halo's bound would leave a dot at its full ink after `0.95` of
        /// a pitch of travel, because the halo no longer reaches the edge on the
        /// frame the dot is born on; measured from this bound, a dot is born with
        /// no ink and reaches all of it after exactly one pitch, which is the rule
        /// the grid's arrival is built on.
        static let edgeReachShare: CGFloat = 0.5
        /// The share of its full ink a halo carries at the dot's own edge.
        static let glowInk: Double = 0.35
        /// The share of that ink the halo carries half way out.
        ///
        /// It is a quarter, which with the zero at the outer edge is a quadratic
        /// falloff: the light is at the dot, the space between two dots is the
        /// card, and nothing is added far from a lamp.
        static let glowMidInk: Double = 0.25
        /// The display value from which a dot carries a glint.
        static let glintOnset: Double = 0.80
        /// How long a dot keeps its glint, in seconds.
        static let glintLife: Double = 0.25
        /// The ink of a glint at the full onset of its dot.
        static let glintInk: Double = 0.8
        /// The longest a glint is drawn, as a share of the pitch.
        static let glintLengthShare: CGFloat = 0.9
        /// The longest a glint is drawn, as a multiple of its dot's radius.
        static let glintRadiusShare: CGFloat = 2.6
        /// The width of a glint at its centre, in points.
        static let glintWidth: CGFloat = 0.6
        /// The band of the canvas's side over which a dot fades, in pitches.
        static let edgeFadeShare: CGFloat = 1

        /// One dot of the grid, as the drawing places it.
        ///
        /// The dot carries its own geometry, its own measurement and its own fade,
        /// so the view is one loop of fills and every rule of the grid can be
        /// measured on the values: where the dot is, how wide, how lit, which pair
        /// of the voice it holds and how far it has travelled.
        struct Dot: Equatable {
            /// The absolute tick of the sample pair the dot holds.
            ///
            /// A grid drawn without motion has no clock, so its dots count their
            /// pairs back from the newest one and the field is negative.
            let sampleTick: Int
            /// The column the dot stands in, counted from the newest at zero.
            let column: Int
            /// The band the dot draws.
            let row: Int
            /// Where the dot's centre stands, in points from the top left.
            let centre: CGPoint
            /// The radius of the dot's body, in points.
            let radius: CGFloat
            /// The band of the voice the dot holds, from `0` to `1`.
            let energy: Double
            /// The level the dot's lamp is drawn at: its band, weighted.
            let display: Double
            /// How much of its lamp the dot carries, from `0` to `1`.
            let reveal: Double
            /// How much of its ink the dot keeps at the canvas's sides.
            let edgeFade: Double
            /// The ink of the dot's glint, from `0` to `1`.
            let glint: Double
            /// How long the dot has been travelling, in seconds.
            let age: Double
        }

        /// The pitch of the lattice on a canvas of this height, in points.
        static func pitch(forHeight height: CGFloat) -> CGFloat {
            min(maximumPitch, height / CGFloat(rows))
        }

        /// The radius of a dot of this level, in points.
        static func radius(forPitch pitch: CGFloat, energy: Double) -> CGFloat {
            pitch * (restRadiusShare + radiusGain * CGFloat(min(1, max(0, energy))))
        }

        /// How much of its lamp a dot of this display value carries, `0...1`.
        ///
        /// It is the smoothstep across ``litOnset`` and ``litRamp``, so the light
        /// of a dot is a continuous function of its level: no level turns a lamp
        /// on, and no frame is the first frame of a lamp. Every alpha of the lamp
        /// is multiplied by it, and the highlight and the halo with them, so the
        /// dot fades in whole rather than growing a bright core over a dim disc.
        static func reveal(forDisplay display: Double) -> Double {
            MeterRamp.smoothstep(litOnset, litOnset + litRamp, display)
        }

        /// The top of the lattice: its rows sit in the middle of a taller canvas
        /// instead of being stretched apart.
        static func top(forHeight height: CGFloat) -> CGFloat {
            (height - pitch(forHeight: height) * CGFloat(rows)) / 2
        }

        /// Where the centre of one row stands, in points from the top edge.
        static func centreY(row: Int, forHeight height: CGFloat) -> CGFloat {
            top(forHeight: height) + pitch(forHeight: height) * (CGFloat(row) + 0.5)
        }

        /// The centre of one cell of the still lattice, the newest column at the
        /// right.
        ///
        /// The still lattice is the grid the card draws for a person who asked for
        /// no motion, and it is also where a frame whose clock is zero stands: a
        /// dot born at the right edge is half a pitch from it, and each column
        /// behind it is one pitch further left.
        static func centre(column: Int, row: Int, forHeight height: CGFloat, width: CGFloat) -> CGPoint {
            let pitch = pitch(forHeight: height)
            return CGPoint(
                x: width - pitch / 2 - CGFloat(column) * pitch,
                y: centreY(row: row, forHeight: height)
            )
        }

        /// How many columns of whole dots fit on a canvas.
        static func columnCount(for size: CGSize) -> Int {
            let pitch = pitch(forHeight: size.height)
            let inset = pitch * maximumRadiusShare
            guard pitch > 0 else { return 0 }
            let room = (size.width - pitch / 2 - inset) / pitch
            guard room >= 0 else { return 0 }
            return Int(room.rounded(.down)) + 1
        }

        /// Whether a dot of this radius is wholly inside the canvas.
        static func isWhole(centre: CGPoint, radius: CGFloat, in size: CGSize) -> Bool {
            centre.x - radius >= 0
                && centre.x + radius <= size.width
                && centre.y - radius >= 0
                && centre.y + radius <= size.height
        }

        /// The reach of a dot's halo, in points.
        static func glowRadius(forPitch pitch: CGFloat) -> CGFloat {
            pitch * glowRadiusShare
        }

        /// The tick of the newest whole sample pair at a moment.
        ///
        /// A dot belongs to a pair of samples, so the pair it reads is the largest
        /// even tick at or before the clock. The pairing is what makes the grid a
        /// property of the take: two runs of the same voice group their samples in
        /// pairs from the start of the same clock, so the same moment is drawn from
        /// the same pair however often the card is redrawn.
        ///
        /// The pair may not start after the newest sample the meter has closed. The
        /// ring holds that sample and the ones before it, so a pair whose first
        /// sample has not arrived cannot be read; the sum of the tick and the phase
        /// is a double, and a frame a rounding error before a boundary can round
        /// onto it. Such a frame draws the pair behind it at the end of its own
        /// travel, and the frame after the boundary draws the new pair at the start
        /// of its own, which is the same place on the canvas. That is what keeps the
        /// slide free of the step this lattice exists to remove.
        ///
        /// - Parameters:
        ///   - clock: the frame's position on the meter's clock, in ticks.
        ///   - tick: the newest sample the meter has closed.
        static func newestPairTick(clock: Double, tick: Int) -> Int {
            let pairs = Int((clock / Double(ticksPerPitch)).rounded(.down)) * ticksPerPitch
            return min(pairs, tick - tick % ticksPerPitch)
        }

        /// Where the dot of one sample pair stands, in points from the left edge.
        ///
        /// The dot is born with its halo tangent to the right edge and travels one
        /// pitch every two ticks, so its place is a continuous function of the
        /// clock: a frame between two ticks draws the grid between two columns
        /// rather than on one of them.
        static func centreX(sampleTick: Int, clock: Double, pitch: CGFloat, width: CGFloat) -> CGFloat {
            let travelled = (clock - Double(sampleTick)) / Double(ticksPerPitch)
            return width - pitch / 2 - pitch * CGFloat(travelled)
        }

        /// How long the dot of one sample pair has been travelling, in seconds.
        static func age(sampleTick: Int, clock: Double) -> Double {
            max(0, clock - Double(sampleTick)) / VisualizerMath.sampleRate
        }

        /// How much of its ink a dot at this centre keeps at the canvas's sides.
        ///
        /// The distance is taken from each side to the nearest point half a pitch
        /// in, across one pitch, so a dot has no ink on the frame it is born on and
        /// all of it once it has travelled a whole pitch inside. The halo is
        /// smaller than that bound by design, see ``glowRadiusShare``, so the light
        /// of a dot is always clear of the card's border. Nothing pops at either
        /// side, and no dot is ever drawn cut: the drawing skips a dot whose disc
        /// the canvas would cross.
        static func edgeFade(centreX: CGFloat, pitch: CGFloat, width: CGFloat) -> Double {
            guard pitch > 0 else { return 0 }
            let reach = pitch * edgeReachShare
            let distance = min(centreX - reach, width - reach - centreX)
            return MeterRamp.smoothstep(0, Double(edgeFadeShare), Double(distance / pitch))
        }

        /// The length of the glint a dot of this radius carries, in points.
        ///
        /// A glint is a spark rather than a cross: it is held inside the space a
        /// dot owns, so a bright cell cannot paint into its neighbour's column.
        static func glintLength(radius: CGFloat, pitch: CGFloat) -> CGFloat {
            min(glintLengthShare * pitch, glintRadiusShare * radius)
        }

        /// The ink of a dot's glint, from `0` to `1`.
        ///
        /// The glint is the spark of a lamp at the top of its range. It is drawn
        /// only above ``glintOnset``, and only for the first ``glintLife`` seconds
        /// of a dot's travel, so the newest syllables of a word sparkle and the
        /// trace they leave does not.
        static func glint(display: Double, age: Double, edgeFade: Double) -> Double {
            let spark = MeterRamp.smoothstep(glintOnset, 1, display)
            let fresh = 1 - MeterRamp.smoothstep(0, glintLife, age)
            return spark * glintInk * fresh * min(max(edgeFade, 0), 1)
        }
    }

    /// The ink of the card's own marks, `#FFF4E6`, which a lit dot carries in the
    /// centre of its light and in its highlight.
    private static let matrixInk = Color(red: 1.0, green: 0.957, blue: 0.902)

    /// The warm tip of the ramp mixed towards the card's ink.
    ///
    /// The mix itself is ``MeterRamp/hot(_:)``: the rewrite card's lattice draws
    /// its centres with the same one, so the two dot surfaces stay one material.
    ///
    /// - Parameter amount: how far towards the ink to go, from `0` to `1`.
    /// - Returns: the colour of the centre of a dot at that heat.
    private static func hot(_ amount: Double) -> Color {
        let tint = MeterRamp.hot(amount)
        return Color(red: tint.red, green: tint.green, blue: tint.blue)
    }

    /// The dots one frame of the grid draws, by the view's own rules.
    ///
    /// A frame draws one dot per band for every sample pair the ring still holds
    /// and the canvas can show whole. The drawing is one loop over this list, and
    /// a measurement reads the same list, so the grid a test describes is the grid
    /// the card drew rather than a second derivation of it.
    ///
    /// - Parameter size: the canvas, in points.
    /// - Returns: the dots to draw, newest first, without the dots that have left
    ///   the canvas.
    func matrixDots(in size: CGSize) -> [MatrixLattice.Dot] {
        let pitch = MatrixLattice.pitch(forHeight: size.height)
        guard pitch > 0, size.width > 0 else { return [] }

        if reduceMotion {
            // A grid asked not to move keeps the lattice the card has always
            // drawn: the newest pair in the rightmost whole column, every column
            // whole, and no dot entering or leaving, so a still of a voice does
            // not depend on the clock. Its glow is the same glow, and its glint is
            // off: a glint is a moment of a dot's travel rather than a measurement
            // of the voice.
            return (0..<MatrixLattice.columnCount(for: size)).flatMap { column in
                (0..<MatrixLattice.rows).map { row in
                    dot(
                        sampleTick: -column * MatrixLattice.ticksPerPitch,
                        offset: column * MatrixLattice.ticksPerPitch,
                        column: column,
                        row: row,
                        centre: MatrixLattice.centre(
                            column: column,
                            row: row,
                            forHeight: size.height,
                            width: size.width
                        ),
                        pitch: pitch,
                        edgeFade: 1,
                        age: 0,
                        glint: false
                    )
                }
            }
        }

        // The tick the frame belongs to, on the meter's clock, and the continuous
        // position inside the samples that follows from it.
        let tick = HUDWaveform.Stretch.newestSample(at: time, phase: phase)
        let clock = Double(tick) + min(max(phase, 0), 1)
        let newest = MatrixLattice.newestPairTick(clock: clock, tick: tick)
        let reach = MatrixLattice.glowRadius(forPitch: pitch)
        // A ring bounds how far back the grid can read: a pair it no longer holds
        // has left the canvas. The envelope fallback clamps instead of running
        // out, which is what a card with no spectrum draws at every column.
        let held = spectrumHistory.isEmpty ? Int.max : spectrumHistory.count

        var dots: [MatrixLattice.Dot] = []
        var column = 0
        while true {
            let sample = newest - column * MatrixLattice.ticksPerPitch
            let offset = tick - sample
            guard offset >= 0, offset < held else { break }
            let x = MatrixLattice.centreX(
                sampleTick: sample,
                clock: clock,
                pitch: pitch,
                width: size.width
            )
            // A dot leaves by its halo rather than by its centre, and the fade has
            // taken its ink to nothing before the halo can reach the edge, so the
            // grid neither cuts a dot nor paints on the card's border.
            guard x - reach > 0 else { break }
            let fade = MatrixLattice.edgeFade(centreX: x, pitch: pitch, width: size.width)
            for row in 0..<MatrixLattice.rows {
                let centre = CGPoint(x: x, y: MatrixLattice.centreY(row: row, forHeight: size.height))
                let energy = min(1, max(0, band(offset: offset, row: row)))
                let radius = MatrixLattice.radius(forPitch: pitch, energy: energy)
                guard MatrixLattice.isWhole(centre: centre, radius: radius, in: size) else { continue }
                dots.append(dot(
                    sampleTick: sample,
                    offset: offset,
                    column: column,
                    row: row,
                    centre: centre,
                    pitch: pitch,
                    edgeFade: fade,
                    age: MatrixLattice.age(sampleTick: sample, clock: clock),
                    glint: true
                ))
            }
            column += 1
        }
        return dots
    }

    /// One dot of the grid, measured from the band it holds.
    ///
    /// - Parameters:
    ///   - sampleTick: the tick of the sample pair the dot holds. A still grid
    ///     has no clock, so its ticks are counted back from the newest pair.
    ///   - offset: how many ticks back from the newest sample the dot's pair is.
    ///   - row: the band the dot draws.
    ///   - centre: where the dot's centre stands, in points.
    ///   - pitch: the pitch of the lattice, in points.
    ///   - edgeFade: how much of its ink the dot keeps at the canvas's sides.
    ///   - age: how long the dot has been travelling, in seconds.
    ///   - glint: whether the dot may carry a glint.
    /// - Returns: the dot, with its band, its lamp and its spark.
    private func dot(
        sampleTick: Int,
        offset: Int,
        column: Int,
        row: Int,
        centre: CGPoint,
        pitch: CGFloat,
        edgeFade: Double,
        age: Double,
        glint: Bool
    ) -> MatrixLattice.Dot {
        let energy = min(1, max(0, band(offset: offset, row: row)))
        let display = pow(energy, 1.6)
        let reveal = MatrixLattice.reveal(forDisplay: display)
        return MatrixLattice.Dot(
            sampleTick: sampleTick,
            column: column,
            row: row,
            centre: centre,
            radius: MatrixLattice.radius(forPitch: pitch, energy: energy),
            energy: energy,
            display: display,
            reveal: reveal,
            edgeFade: edgeFade,
            glint: glint ? MatrixLattice.glint(display: display, age: age, edgeFade: edgeFade) : 0,
            age: age
        )
    }

    /// The band of one cell, in this voice's own window.
    ///
    /// The spectrum is the adaptive per-band one: the card writes each band
    /// between that band's own floor and peak, so the top row and the bottom row
    /// sweep the ramp independently and a voice that has no treble is not drawn as
    /// a flat grid. A frame the recorder gated as silence is zeros in every band,
    /// and that is what a silent moment is drawn as: the grid rests at its floor
    /// rather than falling back on a shape of the envelope, which is the same
    /// picture at every row.
    ///
    /// - Parameters:
    ///   - offset: how many ticks back from the newest sample the cell's pair is.
    ///     One column of the grid is two ticks, so the column that many pairs back
    ///     is read at the offset that column's own pair stands at.
    ///   - row: the band to read.
    /// - Returns: the band's value on the take's window, lifted by the frame
    ///   before it so a syllable's edge is a shoulder rather than a cliff.
    private func band(offset: Int, row: Int) -> Double {
        let back = max(0, offset)
        if !spectrumHistory.isEmpty {
            let index = spectrumHistory.count - 1 - min(spectrumHistory.count - 1, back)
            let now = spectrumHistory[index][row]
            let before = spectrumHistory[max(0, index - 1)][row]
            return max(now, (now + before) * 0.5)
        }
        let count = max(1, history.count)
        let base = min(count - 1, back)
        let s0 = sample(offsetFromNewest: base)
        let s1 = sample(offsetFromNewest: min(count - 1, base + 1))
        let s2 = sample(offsetFromNewest: min(count - 1, base + 2))
        let s3 = sample(offsetFromNewest: min(count - 1, base + 4))
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

    /// One mark of the grid at an opacity of its own.
    ///
    /// It is the ramp's own colour with the alpha this frame asks for, so the
    /// floor at full ink, every stop of a body and every part of the halo are the
    /// same amber and only their weights differ.
    private static func matrixColour(_ tint: MeterTint, opacity: Double) -> Color {
        VisualizerMath.ramp(tint, opacity: min(1, max(0, opacity)))
    }

    /// One arm of a glint: a thin diamond from a dot's centre out to both tips.
    ///
    /// The diamond is what tapers the spark: it is ``MatrixLattice/glintWidth``
    /// wide at the centre and nothing at either tip, so the arm reads as light
    /// rather than as a stroke with an end on it.
    private static func glintArm(centre: CGPoint, horizontal: Bool, half: CGFloat, halfWidth: CGFloat) -> Path {
        var path = Path()
        if horizontal {
            path.move(to: CGPoint(x: centre.x - half, y: centre.y))
            path.addLine(to: CGPoint(x: centre.x, y: centre.y - halfWidth))
            path.addLine(to: CGPoint(x: centre.x + half, y: centre.y))
            path.addLine(to: CGPoint(x: centre.x, y: centre.y + halfWidth))
        } else {
            path.move(to: CGPoint(x: centre.x, y: centre.y - half))
            path.addLine(to: CGPoint(x: centre.x + halfWidth, y: centre.y))
            path.addLine(to: CGPoint(x: centre.x, y: centre.y + half))
            path.addLine(to: CGPoint(x: centre.x - halfWidth, y: centre.y))
        }
        path.closeSubpath()
        return path
    }

    private func drawMatrix(context: GraphicsContext, size: CGSize) {
        let pitch = MatrixLattice.pitch(forHeight: size.height)
        guard pitch > 0 else { return }
        let glowRadius = MatrixLattice.glowRadius(forPitch: pitch)
        let floorTint = MeterRamp.tint(level: 0, ceiling: ceiling)

        for dot in matrixDots(in: size) {
            // A dot with no ink at the canvas's side is the frame a dot is born on
            // and the frame it leaves on: nothing is painted, and the grid has no
            // step at either edge.
            guard dot.edgeFade > 0 else { continue }
            let fade = dot.edgeFade
            let rect = CGRect(
                x: dot.centre.x - dot.radius,
                y: dot.centre.y - dot.radius,
                width: dot.radius * 2,
                height: dot.radius * 2
            )

            // The floor: a cell with nothing in it is still a dot, drawn at the
            // floor's own amber, so the grid is a grid at rest rather than a
            // scatter of dots that appear where the voice is.
            context.fill(
                Path(ellipseIn: rect),
                with: .color(Self.matrixColour(floorTint, opacity: floorTint.opacity * fade))
            )

            // A lit dot is a lamp, not a disc of paint: it is filled from a hot
            // centre through its own colour to a slightly deeper edge, so the dot
            // itself carries the shine. The body is drawn at the alpha of a lamp
            // rather than of a wash: at ordinary speech the middle of a dot is
            // most of the way to opaque, so the grid reads as lit dots on the
            // card's dark surface instead of as a grey field.
            guard dot.reveal > 0 else { continue }
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: Self.hot(0.75 * dot.display).opacity(dot.reveal * fade), location: 0.0),
                        .init(
                            color: Self.matrixColour(
                                MeterRamp.tint(level: dot.display, ceiling: 1),
                                opacity: (0.55 + 0.40 * dot.display) * dot.reveal * fade
                            ),
                            location: 0.45
                        ),
                        .init(
                            color: Self.matrixColour(
                                MeterRamp.tint(level: dot.display, ceiling: 1),
                                opacity: (0.45 + 0.50 * dot.display) * dot.reveal * fade
                            ),
                            location: 1.0
                        ),
                    ]),
                    center: dot.centre,
                    startRadius: 0,
                    endRadius: dot.radius
                )
            )

            // The halo. It is light rather than ink: an annulus from the dot's own
            // radius to the bound of ``MatrixLattice/glowRadiusShare``, added to
            // the card's surface so the dot reads as a lamp with a warm edge
            // rather than as a bright disc with a hard rim. The quadratic falloff
            // puts a quarter of the ink half way out and nothing at the bound,
            // which stops a twentieth of a pitch short of the midpoint between two
            // neighbours, so the halo can never join two of them. A halo the
            // canvas would cut is not drawn: the body is the measurement, and the
            // light around it must not paint on the card's border.
            if dot.centre.x - glowRadius > 0, dot.centre.x + glowRadius < size.width {
                var halo = Path(
                    ellipseIn: CGRect(
                        x: dot.centre.x - glowRadius,
                        y: dot.centre.y - glowRadius,
                        width: glowRadius * 2,
                        height: glowRadius * 2
                    )
                )
                halo.addPath(Path(ellipseIn: rect))
                let ink = MatrixLattice.glowInk * dot.display * dot.reveal * fade
                var light = context
                light.blendMode = .plusLighter
                light.fill(
                    halo,
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(
                                color: Self.matrixColour(
                                    MeterRamp.tint(level: dot.display, ceiling: 1),
                                    opacity: ink
                                ),
                                location: 0.0
                            ),
                            .init(
                                color: Self.matrixColour(
                                    MeterRamp.tint(level: dot.display, ceiling: 1),
                                    opacity: ink * MatrixLattice.glowMidInk
                                ),
                                location: 0.5
                            ),
                            .init(color: .clear, location: 1.0),
                        ]),
                        center: dot.centre,
                        startRadius: dot.radius,
                        endRadius: glowRadius
                    ),
                    style: FillStyle(eoFill: true)
                )
            }

            // A lit lamp has one highlight, and it is what the eye reads as round
            // rather than flat. It is inside the dot, off its centre, and it is the
            // only porcelain the grid carries.
            if highlight {
                let sparkle = 0.38 * dot.radius
                let offset = 0.22 * dot.radius
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: dot.centre.x - offset - sparkle,
                        y: dot.centre.y - offset - sparkle,
                        width: sparkle * 2,
                        height: sparkle * 2
                    )),
                    with: .color(Self.matrixInk.opacity(0.75 * dot.display * dot.reveal * fade))
                )
            }

            // The glint: two crossed arms on a dot at the top of its range, for the
            // first quarter second of its travel. It is added to the dot as light,
            // so a peak sparkles while the contrast of the lamp underneath is left
            // as it was.
            guard dot.glint > 0 else { continue }
            let half = MatrixLattice.glintLength(radius: dot.radius, pitch: pitch) / 2
            let halfWidth = MatrixLattice.glintWidth / 2
            var spark = context
            spark.blendMode = .plusLighter
            spark.fill(
                Self.glintArm(centre: dot.centre, horizontal: true, half: half, halfWidth: halfWidth),
                with: .color(Self.matrixInk.opacity(dot.glint))
            )
            spark.fill(
                Self.glintArm(centre: dot.centre, horizontal: false, half: half, halfWidth: halfWidth),
                with: .color(Self.matrixInk.opacity(dot.glint))
            )
        }
    }

    // MARK: - 06 Halo (Orbital Rings)

    /// One part of the halo, in the order the parts are drawn.
    ///
    /// The order is the occlusion. Each ring's back half stands behind the core
    /// and its front half in front of it, so a particle that has swung round to
    /// the near side of the picture crosses the lit centre instead of being cut
    /// by it. The order is a value, so the drawing and a test read the same list
    /// rather than a render being searched for evidence of one.
    enum HaloLayer: Equatable {
        /// The half of a ring behind the core: its track, its trails and its
        /// particles.
        case ringBack(Int)
        /// The sun: its glow, its rays and its shine.
        case core
        /// The half of a ring in front of the core.
        case ringFront(Int)
    }

    /// The geometry and the rules of the halo.
    ///
    /// The picture is a sun at the centre with five rings of particles around it.
    /// Each ring is a circle in three dimensions rather than an ellipse: a node
    /// angle says where its axis points in the screen plane and an inclination
    /// says how far it is tilted out of that plane, so one ring can stand open
    /// like a plate, narrow to a needle and come back. The rings turn on their own
    /// at five different paces, each node drifts around the centre the way a
    /// gyroscope's axis does, the tilt tumbles slowly between open and edge-on,
    /// and a syllable pushes every particle a little further along its ring, the
    /// extra turn decaying instead of stopping dead. A ring widens with the voice
    /// of the moment it reads, and its fit to the canvas is solved rather than
    /// clamped twice: the roll it may lean to and the tilt it may close to are the
    /// widest two that keep it inside the height it was given while its minor
    /// axis stays a share of that height, because a ring flatter than that reads
    /// as a line rather than as a ring.
    ///
    /// Everything here is a pure function of the voice and the clock. The view
    /// keeps nothing between frames, so the same inputs are the same picture and
    /// a reduced-motion still is a still.
    enum Halo {
        /// How many rings the picture holds.
        static let ringCount = 5
        /// How many samples the core's own energy averages.
        static let coreSamples = 6
        /// How many samples one ring's energy averages.
        static let ringSampleCount = 6
        /// How many ticks separate two neighbouring rings' moments.
        static let ringStep = 4
        /// How many samples a reduce-motion frame holds.
        static let holdSamples = 30
        /// The radius of the core at silence, in points.
        static let restCoreRadius: CGFloat = 2.6
        /// How much larger the voice makes the core, in points.
        static let coreGain: CGFloat = 2
        /// The power the core's growth is eased with.
        static let coreExponent: Double = 0.7
        /// How far the core breathes at silence, in points.
        static let breathRadius: CGFloat = 0.4
        /// How long one breath takes, in seconds.
        static let breathSeconds: Double = 3.2
        /// The energy below which the core breathes.
        static let breathCeiling: Double = 0.1
        /// The frequency of the core's own spring, in hertz.
        ///
        /// The core is a sun rather than a lamp: a syllable swells it past the
        /// radius its own energy asks for and lets it settle back, which is what
        /// reads as an elastic shine instead of a number stepping. Six hertz is the
        /// cell of the measured ladder that carries the bounce the sun is drawn for:
        /// with ``coreSpringDamping`` at a fifth of critical it overshoots the
        /// radius the voice asks for by 0.3648 points at the widest of the loop's
        /// twenty-three overshoots, which is 8.43 per cent of that radius, while
        /// moving no two consecutive ticks by more than 0.4721 points. Seven hertz,
        /// which the first cut of the sun shipped at, reaches only 0.1730 points and
        /// five hertz overshoots further but swells so slowly that the sun lags the
        /// syllable it is answering.
        static let coreSpringHertz: Double = 6
        /// How far the core's spring is damped, as a share of critical damping.
        ///
        /// A fifth of critical is the ladder's cell that keeps one swell a single
        /// gesture: at six hertz it overshoots by the 8.43 per cent above and comes
        /// to rest on its target inside a third of a second, so the bounce belongs
        /// to the syllable that caused it. Damping raised to a third takes the
        /// overshoot down to 0.2250 points and lowered to a tenth leaves the sun
        /// still ringing through the syllable after the one that moved it.
        static let coreSpringDamping: Double = 0.20
        /// How many ticks of the voice the core's spring is integrated over.
        ///
        /// One second of history: long enough for a swell from the oldest tick of
        /// the window to have settled by the newest, and short enough that the
        /// core is the voice of this second rather than of the take.
        static let coreSpringTicks = 60
        /// How many steps the core's spring takes per tick of the voice.
        ///
        /// Twelve steps of a 60 Hz tick is a 720 Hz integrator against a 7 Hz
        /// spring, so the semi-implicit Euler the spring is stepped with is stable
        /// and the shape of the swell is the spring's rather than the integrator's.
        static let coreSpringSubsteps = 12
        /// How far the core's glow reaches, as a multiple of the core's radius.
        ///
        /// The glow is the light the core throws on the card rather than a second
        /// disc: it holds its ink to the share below and fades to nothing here, so
        /// the sun is bounded by light and carries no outline.
        static let glowReach: CGFloat = 2.6
        /// Where the core's glow begins to fade, as a share of its reach.
        static let glowStart: CGFloat = 0.6
        /// The opacity of the core's glow at its brightest.
        static let glowInk: Double = 0.45
        /// The share of the glow's ink it keeps at silence.
        ///
        /// A quiet card is still a lit one: the glow at rest is this share of its
        /// brightest, and the voice carries it the rest of the way.
        static let glowRestShare = 0.35
        /// How many rays the core throws.
        static let rayCount = 6
        /// Where a ray starts, as a multiple of the core's radius.
        ///
        /// A ray begins a little outside the shine's radius so the soft edge of
        /// the core is not crossed by the hard base of a triangle.
        static let rayInner: CGFloat = 0.9
        /// How far a ray reaches at rest, as a multiple of the core's radius.
        static let rayReach: CGFloat = 1.6
        /// How much further the voice stretches a ray, as a multiple of the core's
        /// radius at full stretch.
        static let rayVoiceReach: CGFloat = 0.7
        /// How much of its length every second ray keeps.
        ///
        /// Six rays of one length read as a star rather than as light. The short
        /// ones alternate with the long ones, so the sun has a rhythm and its rays
        /// stay apart while they turn.
        static let rayAlternate: CGFloat = 0.62
        /// The half width of a ray where it starts, in points.
        ///
        /// A ray is a thin triangle, this wide at its base and a point at its tip,
        /// which is what keeps it a taper rather than a spoke of one width.
        static let rayHalfWidth: CGFloat = 0.55
        /// The opacity of a ray's ink at its base.
        static let rayInk: Double = 0.55
        /// How long one turn of the rays takes, in seconds.
        static let rayTurnSeconds: Double = 30
        /// The share of the core's radius its white-hot centre fills on the glass
        /// material, from `0` at the centre to `1` at the core's edge.
        ///
        /// The material behind the canvas is a light surface, and a core drawn only
        /// in the meter's amber tops out at 2.71 to 1 on it, under the 3 to 1 the
        /// halo is held to, see ``HUDTheme/visualizerGlassLift``. The centre is
        /// therefore the card's ink at full opacity out to this share, and the amber
        /// ramp the core already had continues from it to the edge.
        static let hotCentreShare: Double = 0.35
        /// The horizontal room the rings keep clear, in points.
        static let horizontalInset: CGFloat = 4
        /// The room the canvas keeps above and below a ring, in points.
        static let verticalRoom: CGFloat = 2
        /// The extra room a tilted ring's corner keeps, in points.
        static let ringInset: CGFloat = 1.2
        /// The widest ring's share of the canvas's half width.
        static let widthShare: [CGFloat] = [0.36, 0.51, 0.66, 0.81, 0.96]
        /// The roll each ring's node precesses around, in degrees.
        static let rollDegrees: [Double] = [-8, 6, -4, 3, 0]
        /// How far the node of a ring swings either side of its roll, in degrees.
        static let precessionDegrees: Double = 9
        /// How long one pass of a ring's node takes, in seconds.
        static let precessionSeconds: [Double] = [7.3, 9.1, 11.7, 13.3, 10.3]
        /// Where each ring's node starts its pass, in radians.
        static let precessionPhases: [Double] = [0, 1.3, 2.5, 3.8, 5.0]
        /// How far the voice rolls a ring off its own node, in degrees.
        static let precessionVoiceDegrees: Double = 5
        /// Which way the voice rolls each ring: a negative one rolls the other
        /// way, so the rings do not lean together.
        static let precessionSigns: [Double] = [1, -1, 1, -1, 1]
        /// How long one tumble of a ring takes, in seconds.
        static let tumbleSeconds: [Double] = [5.3, 6.7, 8.9, 7.7, 10.1]
        /// Where each ring starts its tumble, in radians.
        static let tumblePhases: [Double] = [1, 3, 5, 2, 4]
        /// How much of its tumble a ring keeps at the open end: the rest of it
        /// closes toward edge-on.
        static let tumbleFloor: Double = 0.25
        /// How much of a ring's tumble the voice takes away, opening the ring
        /// back toward the widest tilt that fits.
        static let tumbleVoice: Double = 0.6
        /// The flattest a ring's tumble may draw it, in degrees.
        ///
        /// A ring allowed to close all the way becomes a hairline twice for every
        /// turn of its node, and the card reads as empty rather than as quiet. The
        /// tumble therefore stops here, and a ring that is this flat still stands
        /// at `cos 72` of its own radius off the centre line.
        static let edgeOnDegrees: Double = 72
        /// The flattest a ring's tumble may draw it, in radians.
        static let edgeOn = edgeOnDegrees * Double.pi / 180
        /// How many particles each ring carries.
        static let particleCounts: [Int] = [14, 18, 22, 26, 30]
        /// The revolutions per second of each ring, a negative one turning the
        /// other way.
        static let revolutions: [Double] = [0.55, -0.42, 0.33, -0.26, 0.21]
        /// How much turn one syllable adds to a ring, in radians a second at
        /// full energy.
        static let kickGain: Double = 1.2
        /// How loud one sample has to be to push a ring as hard as it can.
        ///
        /// The push reads the envelope on a fixed scale rather than on the take's
        /// own ceiling. A ceiling is one number for the whole take and it rises
        /// whenever a new peak arrives, so normalising the three seconds the push
        /// is summed over by it would rescale the past: a syllable would move
        /// every particle the moment it set a peak. A fixed reference keeps the
        /// sum a record of what was said rather than of how loud the take has
        /// been, and it is the loudness at which the picture is already fully
        /// open, so the push saturates with the shape rather than after it.
        static let kickReference: Double = 0.60
        /// How many of the newest ticks of the voice push a ring's spin at full
        /// weight.
        static let kickFullTicks = 120
        /// How many ticks after them the push fades to nothing: the window is
        /// three seconds of the voice, and its last tick adds nothing.
        static let kickRampTicks = 60
        /// The longest a pushed ring draws its trails, as a share of their
        /// resting length.
        static let trailScaleCeiling: Double = 2.2
        /// The bands each ring's particles carry.
        static let bands: [[Int]] = [[0, 1], [1, 2], [2], [2, 3], [3, 4]]
        /// How much of its scale a ring keeps at silence.
        static let restShare: Double = 0.62
        /// How much of its scale a ring gains with the voice.
        static let voiceShare: Double = 0.38
        /// The width of a ring's track, in points.
        static let trackWidth: CGFloat = 0.5
        /// How far a ring's ink is mixed toward the card's ink on the glass
        /// material.
        ///
        /// It is the lift ``VisualizerMath/ramp(_:opacity:lift:)`` takes, and the
        /// value is the ring's own rather than ``HUDTheme/visualizerGlassLift``
        /// because a ring is drawn at a fraction of the opacity a bar is: the
        /// clear glass puts the page behind the canvas, so a pale amber ring
        /// reads faint over a bright one where the full amber of a bar still
        /// reads. The black material draws at zero.
        ///
        /// The value is one cell of a ladder measured on the real card over a
        /// bright page, a dark page and the reference photograph's wave, every
        /// rung of this lift against every rung of ``glassRingInkGain``. At this
        /// cell at `3` the ring's brightest pixel reads 2.50 to 1 against the
        /// material at the loudest moment of the take and the median of the
        /// pixels it inks reads 1.65 to 1, the near half of the rings carries
        /// 1.62 times the far half's ink, and the ink keeps a warmth of 0.26 on
        /// the dark page.
        static let glassRingLift: Double = 0.65
        /// How much more opaque a ring's track, its trails and its particles are
        /// drawn on the glass material.
        ///
        /// The lift moves a faint mark's colour toward the card's ink without
        /// making the mark more present, so the gain is what carries the ring's
        /// own opacities over a bright page. It multiplies each ring opacity and
        /// the product is clamped to one, and the black material draws at one.
        ///
        /// The value comes from the same measured ladder as ``glassRingLift``. It
        /// is the rung where the clamp holds about half of the particles at the
        /// loudest moment, so the ring's median ink is still rising with the gain
        /// while the two halves of a ring stay apart: the next rung lifts the
        /// median from 1.65 to 1.76 and narrows the near half from 1.62 to 1.39
        /// times the far half. The rings are not held to the 3 to 1 the white hot
        /// centre reads at, because a ring's colour carries the meter tint's own
        /// opacity and the gain cannot push a quiet ring past about 2.5 to 1.
        static let glassRingInkGain: Double = 3.00
        /// The opacity a ring's track keeps at silence.
        ///
        /// A quiet card is still a card that is listening: the tracks are the
        /// shape of the picture, so they keep enough ink at silence to be read as
        /// rings rather than guessed at.
        static let trackFloor: Double = 0.24
        /// How much opacity the voice adds to a ring's track.
        static let trackGain: Double = 0.15
        /// How much of the near half's opacity the far half of a track keeps.
        ///
        /// A ring is a circle seen at a tilt, so its two halves are the same
        /// line at the same distance: the far half is drawn fainter to say which
        /// side of the core it passes behind, not because it is further away.
        static let backInk: Double = 0.45
        /// The biggest a particle is drawn, in points.
        static let maximumParticleRadius: CGFloat = 1.2
        /// The smallest a particle is drawn, in points.
        ///
        /// A dot's own band and its depth can take it under half a point, where a
        /// render at twice the points still shows it but the eye does not. The
        /// floor keeps every particle of a quiet picture visible as a particle.
        static let minimumParticleRadius: CGFloat = 0.7
        /// The faintest a particle's ink is drawn at, as a share of its depth.
        ///
        /// The voice dims a dot, but only so far: at silence the depth still
        /// shades the ring from its far side to its near one, and the floor is
        /// what keeps that shading a shape on the card rather than a memory of
        /// one. It sits high enough that most of a quiet ring is drawn at a
        /// quarter of full ink or more, which is the point at which a dot reads as
        /// a dot rather than as a smudge.
        static let particleInkFloor: Double = 0.51
        /// How far behind its particle each trail dot stands, in radians.
        static let trailAngles: [Double] = [0.06, 0.12, 0.18]
        /// How much of its radius each trail dot keeps.
        static let trailRadii: [Double] = [0.85, 0.70, 0.55]
        /// How much of its opacity each trail dot keeps.
        static let trailInk: [Double] = [0.50, 0.28, 0.12]
        /// How many points a ring's track is built from.
        static let trackSteps = 96

        /// The order every part of the halo is drawn in.
        ///
        /// The far ring's back half first and the near ring's last, the core
        /// between them, and the front halves from the near ring outward: what is
        /// further away is drawn first at both ends of the picture.
        static let layerOrder: [HaloLayer] = {
            let back = (0..<ringCount).reversed().map { HaloLayer.ringBack($0) }
            let front = (0..<ringCount).map { HaloLayer.ringFront($0) }
            return back + [.core] + front
        }()

        /// The display energy of `count` samples starting `offset` ticks ago.
        static func energy(offset: Int, count: Int, history: [Double], ceiling: Double) -> Double {
            guard !history.isEmpty, count > 0 else { return 0 }
            var sum = 0.0
            for tick in 0..<count {
                sum += VisualizerBars.sample(history: history, offsetFromNewest: offset + tick)
            }
            return VisualizerMath.displayEnergy(sum / Double(count), ceiling: ceiling)
        }

        /// The display energy of the core: the newest six samples of the voice.
        static func coreEnergy(history: [Double], ceiling: Double) -> Double {
            energy(offset: 0, count: coreSamples, history: history, ceiling: ceiling)
        }

        /// The display energy of one ring: six samples four ticks apart from its
        /// neighbour's.
        static func ringEnergy(_ ring: Int, history: [Double], ceiling: Double) -> Double {
            energy(offset: ring * ringStep, count: ringSampleCount, history: history, ceiling: ceiling)
        }

        /// The radius of one ring, in points.
        ///
        /// A ring is a circle of one radius in three dimensions, so its width is
        /// its own and its height comes from how far it is tilted. The radius is
        /// the ring's share of the canvas's half width, widened by the voice of
        /// the moment the ring reads.
        static func radius(ring: Int, width: CGFloat, energy: Double) -> CGFloat {
            let voice = CGFloat(restShare + voiceShare * min(1, max(0, energy)))
            return max(1, width / 2 - horizontalInset) * widthShare[ring] * voice
        }

        /// The furthest a ring's centre may stand from the centre line, in
        /// points.
        ///
        /// It is the half height less the room the canvas keeps for the shape and
        /// the room a particle keeps for itself, so a ring at the top of the fit
        /// still has its dots inside the canvas.
        static func extentLimit(height: CGFloat) -> CGFloat {
            max(0, height / 2 - verticalRoom - ringInset)
        }

        /// The shortest a ring's picture may be, as a share of the room it has.
        ///
        /// A ring is a circle seen at a tilt, so its picture is an ellipse whose
        /// major semi-axis is `a` and whose minor semi-axis is `a cos iota`. A wide
        /// ring on a short canvas is forced nearly edge-on to fit at all, and below
        /// this share of ``extentLimit(height:)`` the ellipse is a slanted line
        /// rather than a ring. The share is the height every ring is held to: on
        /// the card's 26 point canvas the limit is 9.8 points, so a ring's minor
        /// semi-axis never falls under 6.86 points and the oval it draws is at
        /// least 13.7 points tall however far its node leans.
        static let minorFloorShare: Double = 0.70

        /// The shortest a ring's minor semi-axis may be on a canvas, in points.
        ///
        /// It is ``minorFloorShare`` of the room a ring has, which is the number
        /// ``node(ring:time:energy:radius:height:)`` holds the roll to and
        /// ``inclination(ring:time:energy:radius:node:height:)`` holds the tilt to.
        static func minorFloor(height: CGFloat) -> CGFloat {
            CGFloat(minorFloorShare) * extentLimit(height: height)
        }

        /// The angle a ring's roll is drawn at before the canvas fits it, in
        /// radians.
        ///
        /// The roll is a node angle: where the ring's own axis points in the
        /// screen plane. It swings either side of the ring's own roll the way a
        /// gyroscope's axis drifts around the vertical, and the voice leans the
        /// ring a little further each syllable.
        static func rawNode(ring: Int, time: Double, energy: Double) -> Double {
            let swing = precessionDegrees
                * sin(2 * Double.pi * time / precessionSeconds[ring] + precessionPhases[ring])
            let lean = precessionVoiceDegrees * precessionSigns[ring] * min(1, max(0, energy))
            return (rollDegrees[ring] + swing + lean) * Double.pi / 180
        }

        /// The angle a ring's roll is drawn at, in radians.
        ///
        /// A ring rolled far enough would take its topmost point over the edge of
        /// the canvas, so the roll is pulled back to the widest it holds at this
        /// radius, keeping the side it leans to.
        ///
        /// The width it is held to is the room and the ring's own height together.
        /// A ring that fits by standing almost edge-on is a line rather than a
        /// ring, so the roll is the widest at which the ring can still stand at
        /// ``minorFloor(height:)``: with `L` the limit, `h` the floor and `a` the
        /// radius, the fit at the tilt where the minor axis is `h` is
        /// `a^2 sin^2 Omega + h^2 cos^2 Omega = L^2`, so
        /// `sin Omega = sqrt((L^2 - h^2) / (a^2 - h^2))`. A ring no wider than the
        /// floor has no such constraint and keeps the room's own rule,
        /// `asin(L / a)`, because it can never be as flat as a line.
        static func node(
            ring: Int,
            time: Double,
            energy: Double,
            radius: CGFloat,
            height: CGFloat
        ) -> Double {
            let raw = rawNode(ring: ring, time: time, energy: energy)
            guard radius > 0 else { return raw }
            let width = Double(radius)
            let limit = Double(extentLimit(height: height))
            let floor = Double(minorFloor(height: height))
            let widest: Double
            if width > floor {
                let room = (limit * limit - floor * floor) / (width * width - floor * floor)
                widest = asin(min(1, max(0, room)).squareRoot())
            } else {
                widest = asin(min(1, limit / width))
            }
            guard abs(raw) > widest else { return raw }
            return raw < 0 ? -widest : widest
        }

        /// The flattest a ring may be tilted at this roll and still fit, in
        /// radians.
        ///
        /// A circle of radius `a` rolled by `Omega` and tilted by `iota` stands
        /// off the centre line by `a sqrt(sin^2 Omega + cos^2 iota cos^2 Omega)`,
        /// so the tilt that just fits is the one that makes that root the limit.
        /// It is the floor under every tilt the picture uses: a ring is never
        /// drawn more open than this, because the canvas has priority over the
        /// tumble. The roll it is read at is already held to
        /// ``minorFloor(height:)``, so a tilt that fits here is never flatter than
        /// the ring's own minor axis allows and no ring closes into a line.
        static func openInclination(radius: CGFloat, node: Double, height: CGFloat) -> Double {
            guard radius > 0 else { return .pi / 2 }
            let ratio = Double(extentLimit(height: height) / radius)
            let room = max(0, ratio * ratio - pow(sin(node), 2))
            let roll = abs(cos(node))
            guard roll > 1e-9 else { return .pi / 2 }
            let cosine = min(1, max(0, room.squareRoot() / roll))
            return acos(cosine)
        }

        /// How far a ring has tumbled from its widest tilt, from `0` at the tilt
        /// it opens to and `1` at its flattest.
        static func tumble(ring: Int, time: Double) -> Double {
            0.5 + 0.5 * sin(2 * Double.pi * time / tumbleSeconds[ring] + tumblePhases[ring])
        }

        /// How far a ring's tilt travels, from `0` at its widest to `1` at its
        /// flattest, for one tumble value and one energy.
        ///
        /// ``tumbleFloor`` is the share of the travel a ring keeps even at the open
        /// end of its tumble, and ``tumbleVoice`` is the share the voice takes away
        /// on top of that: at full energy a ring keeps four tenths of the travel it
        /// has in silence.
        static func excursion(energy: Double, tumble: Double) -> Double {
            (tumbleFloor + (1 - tumbleFloor) * tumble)
                * (1 - tumbleVoice * min(1, max(0, energy)))
        }

        /// The flattest tilt a ring may stand at and keep a minor axis of
        /// ``minorFloor(height:)``, in radians.
        ///
        /// The minor semi-axis is `a cos iota`, so the tilt that brings it down to
        /// the floor is `acos(h / a)`, with `h` the floor and `a` the radius. A
        /// ring no wider than the floor has no such limit and returns zero, which
        /// leaves the fit's tilt in charge of it.
        static func flattest(radius: CGFloat, height: CGFloat) -> Double {
            let floor = Double(minorFloor(height: height))
            guard Double(radius) > floor else { return 0 }
            return acos(min(1, floor / Double(radius)))
        }

        /// The tilt of one ring, in radians: `0` face-on and ``edgeOn`` flat.
        ///
        /// At rest a ring closes toward its flattest and opens again. The voice
        /// takes away most of that excursion, so a ring that is sounding stands
        /// near the widest tilt the canvas holds rather than turning the picture
        /// into a set of lines. The closed end is the flatter of ``edgeOn`` and
        /// ``flattest(radius:height:)``: a ring too wide for ``edgeOn`` closes only
        /// as far as its own minor axis allows, so the tumble narrows instead of
        /// drawing a line, and one wider still than the floor can stand keeps the
        /// tilt the canvas gives it, because the canvas has priority.
        static func inclination(
            ring: Int,
            time: Double,
            energy: Double,
            radius: CGFloat,
            node: Double,
            height: CGFloat
        ) -> Double {
            let open = openInclination(radius: radius, node: node, height: height)
            let closed = max(open, min(edgeOn, flattest(radius: radius, height: height)))
            let travel = excursion(energy: energy, tumble: tumble(ring: ring, time: time))
            return open + (closed - open) * travel
        }

        /// A ring at a moment: its radius, its node and its tilt.
        ///
        /// The three numbers are read once and then shared by the ring's track,
        /// its trails and its particles, so one half of a ring cannot be drawn
        /// from a different measurement than the other.
        struct Orientation {
            /// The radius of the ring, in points.
            let radius: CGFloat
            /// The roll of the ring in the screen plane, in radians.
            let node: Double
            /// How far the ring is tilted out of that plane, in radians.
            let inclination: Double
        }

        /// The ring at a moment, fitted to the canvas.
        static func orientation(
            ring: Int,
            time: Double,
            energy: Double,
            width: CGFloat,
            height: CGFloat
        ) -> Orientation {
            let a = radius(ring: ring, width: width, energy: energy)
            let node = node(ring: ring, time: time, energy: energy, radius: a, height: height)
            return Orientation(
                radius: a,
                node: node,
                inclination: inclination(
                    ring: ring,
                    time: time,
                    energy: energy,
                    radius: a,
                    node: node,
                    height: height
                )
            )
        }

        /// The position of a point at an angle on a ring, and its depth.
        ///
        /// The ring is a circle in space, so a point on it is at
        /// `(a cos theta, a sin theta cos iota)` before the ring is rolled, and
        /// its depth is `sin theta sin iota`: `1` at the nearest point of the
        /// picture and `-1` at the furthest. The depth is what decides whether a
        /// dot is drawn behind the core or over it.
        static func point(
            orientation: Orientation,
            theta: Double,
            centre: CGPoint
        ) -> (point: CGPoint, depth: Double) {
            let radius = Double(orientation.radius)
            let x = radius * cos(theta)
            let y = radius * sin(theta) * cos(orientation.inclination)
            let node = orientation.node
            return (
                CGPoint(
                    x: centre.x + CGFloat(x * cos(node) - y * sin(node)),
                    y: centre.y + CGFloat(x * sin(node) + y * cos(node))
                ),
                sin(theta) * sin(orientation.inclination)
            )
        }

        /// The push one sample of the voice carries, from `0` to `1`, read at a
        /// ring's own age.
        ///
        /// A ring reads the same moment its energy comes from, four ticks older
        /// than the ring inside it, so a syllable reaches the inner ring first and
        /// travels outward. The sample is put on ``kickReference`` rather than on
        /// the take's ceiling, which is what keeps the push a function of the
        /// history alone.
        static func kickEnergy(ring: Int, offset: Int, history: [Double]) -> Double {
            let tick = offset + ring * ringStep
            let value = VisualizerBars.sample(history: history, offsetFromNewest: tick)
            return min(1, max(0, value) / kickReference)
        }

        /// How much one tick of the voice still pushes a ring's spin, from `1`
        /// at the newest tick to `0` at the oldest.
        static func kickWeight(_ tick: Int) -> Double {
            guard tick >= kickFullTicks else { return 1 }
            guard tick < kickFullTicks + kickRampTicks else { return 0 }
            return Double(kickFullTicks + kickRampTicks - 1 - tick) / Double(kickRampTicks - 1)
        }

        /// How much turn the last three seconds of the voice have added to a
        /// ring, in radians.
        ///
        /// A syllable does not move a particle to a new angle and leave it there:
        /// it pushes the particle faster for as long as it stays inside the
        /// window, and the turn it has gained fades over the oldest second of the
        /// window, so the ring is left ahead of where its own spin would have
        /// carried it and drifts back. The push is a sum over the ring's own age
        /// of the voice, which is what keeps it a pure function of the history.
        static func kick(ring: Int, history: [Double]) -> Double {
            guard !history.isEmpty else { return 0 }
            var sum = 0.0
            for tick in 0..<Waveform.historyLength {
                let weight = kickWeight(tick)
                guard weight > 0 else { continue }
                sum += weight * kickEnergy(ring: ring, offset: tick, history: history)
            }
            return kickGain * sum / VisualizerMath.sampleRate
        }

        /// The angular speed of a ring's particles, in radians a second, signed
        /// the way the ring turns.
        ///
        /// It is the exact derivative of ``particleAngle`` over one tick: the
        /// newest tick of the voice arrives at full weight while the ticks of the
        /// fading tail leave at `1 / 59` each, so the two cancel for a steady
        /// voice and nothing accumulates. The push is bounded by ``kickGain``,
        /// which is smaller than the slowest ring's own spin, so the speed never
        /// reaches zero. The trails are drawn from this rather than from a
        /// difference of two frames, because the view keeps no frame to subtract
        /// from.
        static func angularSpeed(ring: Int, history: [Double]) -> Double {
            let sign: Double = revolutions[ring] < 0 ? -1 : 1
            let spin = 2 * Double.pi * abs(revolutions[ring])
            guard !history.isEmpty else { return sign * spin }
            var leaving = 0.0
            for tick in (kickFullTicks + 1)...(kickFullTicks + kickRampTicks - 1) {
                leaving += kickEnergy(ring: ring, offset: tick, history: history)
            }
            let newest = kickEnergy(ring: ring, offset: 0, history: history)
            let push = kickGain * (newest - leaving / Double(kickRampTicks - 1))
            return sign * (spin + push)
        }

        /// How much longer a ring's trails are than its resting ones.
        static func trailScale(ring: Int, speed: Double) -> Double {
            let spin = 2 * Double.pi * abs(revolutions[ring])
            return min(trailScaleCeiling, max(1, abs(speed) / spin))
        }

        /// The angle of a particle along its ring.
        ///
        /// The particle's own share of the circle, then the ring's unwrapped
        /// spin, then the turn the voice has pushed it through: no term is
        /// `speed(voice) * time`, because that would move every particle by a
        /// whole lap the instant the voice changed.
        static func particleAngle(ring: Int, index: Int, kick: Double, time: Double) -> Double {
            let count = particleCounts[ring]
            let base = 2 * Double.pi * Double(index) / Double(count)
            let sign: Double = revolutions[ring] < 0 ? -1 : 1
            return base + sign * (2 * Double.pi * abs(revolutions[ring]) * time + kick)
        }

        /// The band a particle carries, read at its ring's own age.
        ///
        /// A particle picks its band by its own index, so the particles of one
        /// ring carry different parts of the spectrum rather than all reading the
        /// same row.
        static func particleBand(ring: Int, index: Int, spectrum: [AudioSpectrumFrame]) -> Double {
            guard !spectrum.isEmpty else { return 0 }
            let rows = bands[ring]
            let row = rows[index % rows.count]
            let position = spectrum.count - 1 - ring * ringStep
            guard position >= 0 else { return 0 }
            return min(1, max(0, spectrum[position][row]))
        }

        /// The radius of a particle, in points.
        static func particleRadius(band: Double, depth: Double) -> CGFloat {
            let near = (depth + 1) / 2
            let radius = (0.45 + 0.75 * min(1, max(0, band))) * (0.70 + 0.30 * near)
            let bounded = min(Double(maximumParticleRadius), max(Double(minimumParticleRadius), radius))
            return CGFloat(bounded)
        }

        /// The opacity of a particle, from its depth and its ring's energy.
        ///
        /// The voice's own share has a floor under it, so the depth keeps shading
        /// the ring at silence while the picture stays a picture.
        static func particleInk(depth: Double, energy: Double) -> Double {
            let near = (depth + 1) / 2
            let voice = max(0.20 + 0.80 * min(1, max(0, energy)), particleInkFloor)
            return (0.25 + 0.75 * near) * voice
        }

        /// The radius the core's own energy asks for, in points.
        ///
        /// It is the target the elastic radius chases rather than the radius the
        /// picture is drawn at: a sun whose radius steps from one measurement to
        /// the next reads as a dot being resized, so ``elasticCoreRadius(history:ceiling:time:)``
        /// is what the core is drawn from.
        static func coreRadius(energy: Double, time: Double) -> CGFloat {
            let breath = sin(2 * Double.pi * time / breathSeconds)
                * (1 - MeterRamp.smoothstep(0, breathCeiling, energy))
            return restCoreRadius
                + coreGain * CGFloat(pow(min(1, max(0, energy)), coreExponent))
                + breathRadius * CGFloat(breath)
        }

        /// The display energy of the core, read on the history cut to `length`
        /// samples.
        ///
        /// It is the value ``energy(offset:count:history:ceiling:)`` returns for the
        /// oldest `length` samples, which is the history one tick of the core's
        /// spring sees, without copying the window for every tick it is read on.
        static func coreEnergy(history: [Double], ceiling: Double, length: Int) -> Double {
            guard length > 0, !history.isEmpty else { return 0 }
            var sum = 0.0
            for offset in 0..<coreSamples {
                let index = length - 1 - offset
                guard index >= 0, index < history.count else { continue }
                sum += min(1, max(0, history[index]))
            }
            return VisualizerMath.displayEnergy(sum / Double(coreSamples), ceiling: ceiling)
        }

        /// The radius the core is drawn at, in points: the radius the voice asks
        /// for, chased by a damped spring.
        ///
        /// The spring is the sun's elasticity. It is integrated over the last
        /// ``coreSpringTicks`` ticks of the history, oldest first, and it starts at
        /// rest on the target of the oldest tick in that window with a velocity of
        /// zero, so the radius is a function of the history alone rather than of a
        /// state the view would have to keep. Each tick's target is the radius its
        /// own truncated history asks for, with the breath read at that tick's own
        /// time, and ``coreSpringSubsteps`` semi-implicit Euler steps carry the
        /// spring through one tick of `x'' = w^2 (target - x) - 2 zeta w x'`, with
        /// `w` the spring's angular frequency and `zeta` its damping.
        ///
        /// - Parameters:
        ///   - history: the envelope, oldest first.
        ///   - ceiling: the adaptive ceiling of the take.
        ///   - time: the clock, in seconds, the breath is read at.
        /// - Returns: the radius, clamped to the range the core may occupy: no
        ///   smaller than six tenths of its resting radius and no larger than its
        ///   resting radius plus a third again of its gain and one breath.
        static func elasticCoreRadius(history: [Double], ceiling: Double, time: Double) -> CGFloat {
            elasticCoreRadius(
                history: history,
                ceiling: ceiling,
                time: time,
                hertz: coreSpringHertz,
                damping: coreSpringDamping
            )
        }

        /// The radius the core is drawn at for a spring of the given frequency and
        /// damping, in points.
        ///
        /// It is ``elasticCoreRadius(history:ceiling:time:)`` with the two
        /// constants the card ships opened, so one spring can be measured against
        /// another. The drawing takes the same two numbers, and the card passes its
        /// own, so a cell of the ladder is a picture rather than a table row.
        ///
        /// - Parameters:
        ///   - history: the envelope, oldest first.
        ///   - ceiling: the adaptive ceiling of the take.
        ///   - time: the clock, in seconds, the breath is read at.
        ///   - hertz: the spring's frequency, in hertz.
        ///   - damping: the spring's damping, as a share of critical damping.
        /// - Returns: the radius, clamped to the range the core may occupy.
        static func elasticCoreRadius(
            history: [Double],
            ceiling: Double,
            time: Double,
            hertz: Double,
            damping: Double
        ) -> CGFloat {
            let window = min(coreSpringTicks, max(1, history.count))
            let angular = 2 * Double.pi * hertz
            let step = 1 / (VisualizerMath.sampleRate * Double(coreSpringSubsteps))
            func target(ticksRemaining: Int) -> Double {
                let length = history.count - ticksRemaining
                let energy = coreEnergy(history: history, ceiling: ceiling, length: length)
                let moment = time - Double(ticksRemaining) / VisualizerMath.sampleRate
                return Double(coreRadius(energy: energy, time: moment))
            }
            var position = target(ticksRemaining: window - 1)
            var velocity = 0.0
            for ticksRemaining in stride(from: window - 1, through: 0, by: -1) {
                let goal = target(ticksRemaining: ticksRemaining)
                for _ in 0..<coreSpringSubsteps {
                    let acceleration = angular * angular * (goal - position)
                        - 2 * damping * angular * velocity
                    velocity += acceleration * step
                    position += velocity * step
                }
            }
            let lowest = 0.6 * Double(restCoreRadius)
            let highest = Double(restCoreRadius) + 1.35 * Double(coreGain) + Double(breathRadius)
            return CGFloat(min(highest, max(lowest, position)))
        }

        /// The track of one half of a ring: the near half or the far half.
        ///
        /// A ring's back half is the angles whose depth is not positive, which
        /// is the half the core is drawn over, and its front half is the rest.
        static func track(orientation: Orientation, front: Bool, centre: CGPoint) -> Path {
            let start = front ? 0 : Double.pi
            let span = Double.pi
            var path = Path()
            for step in 0...trackSteps {
                let theta = start + span * Double(step) / Double(trackSteps)
                let spot = point(orientation: orientation, theta: theta, centre: centre).point
                if step == 0 {
                    path.move(to: spot)
                } else {
                    path.addLine(to: spot)
                }
            }
            return path
        }
    }

    /// One ring's frame: the measurements both halves of it are drawn from.
    ///
    /// The track, the trails and the particles of a ring share a radius, a node
    /// and a tilt. Reading them once per frame keeps the two halves of one ring
    /// one shape, and keeps the three seconds the kick is summed over out of the
    /// inner loop.
    private struct HaloRingFrame {
        /// The display energy of the moment this ring reads.
        let energy: Double
        /// The ring's radius, node and tilt at this moment.
        let orientation: Halo.Orientation
        /// How much turn the voice has pushed into the ring, in radians.
        let kick: Double
        /// The angular speed of the ring's particles, in radians a second.
        let speed: Double
    }

    private func drawHalo(context: GraphicsContext, size: CGSize) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let source = reduceMotion
            ? VisualizerMath.peakHold(history, ticks: Halo.holdSamples)
            : history
        let clock = reduceMotion ? 0 : time
        let frames = (0..<Halo.ringCount).map { ring -> HaloRingFrame in
            let energy = Halo.ringEnergy(ring, history: source, ceiling: ceiling)
            return HaloRingFrame(
                energy: energy,
                orientation: Halo.orientation(
                    ring: ring,
                    time: clock,
                    energy: energy,
                    width: size.width,
                    height: size.height
                ),
                kick: reduceMotion ? 0 : Halo.kick(ring: ring, history: source),
                speed: reduceMotion ? 0 : Halo.angularSpeed(ring: ring, history: source)
            )
        }
        for layer in Halo.layerOrder {
            switch layer {
            case .ringBack(let ring):
                drawRing(
                    context: context,
                    ring: ring,
                    front: false,
                    frame: frames[ring],
                    centre: centre,
                    clock: clock
                )
            case .core:
                drawHaloCore(context: context, size: size)
            case .ringFront(let ring):
                drawRing(
                    context: context,
                    ring: ring,
                    front: true,
                    frame: frames[ring],
                    centre: centre,
                    clock: clock
                )
            }
        }
    }

    /// The sun at the centre of the halo: its glow, its rays and its shine.
    ///
    /// The core is light rather than a disc. Under everything is the glow, the
    /// light the core throws on the card: it holds its ink out to
    /// ``HUDWaveform/Halo/glowStart`` of ``HUDWaveform/Halo/glowReach`` radii and
    /// fades to nothing at the reach, so the sun is bounded by light and has no
    /// outline. Over it are ``HUDWaveform/Halo/rayCount`` tapered rays, each a
    /// triangle filled with a gradient that dies at its tip, every second one
    /// shortened so the six read as rays rather than as a star. The shine itself
    /// is a radial gradient with a white-hot centre: the card's ink across the
    /// middle ``HUDWaveform/Halo/hotCentreShare`` of the radius on the glass
    /// material, a warm white centre on the black one, the meter's apex colour
    /// inside the first third of the radius, and the core's own tint fading to
    /// nothing at the edge, which is the soft edge that keeps it a light rather
    /// than a painted circle.
    ///
    /// The radius is elastic. ``HUDWaveform/Halo/elasticCoreRadius(history:ceiling:time:)``
    /// is a spring's answer to the radius the voice asks for, and the glow, the
    /// rays and the shine are all read from that one number, so the whole sun
    /// swells together and settles together. The rays stretch with the same
    /// spring, which is why a syllable makes the light reach further as well as
    /// brighter. A reduced-motion frame takes the static radius of the held energy
    /// at time zero, so it is a still sun rather than a spring frozen mid-swell,
    /// and its rays stand at their first angle.
    ///
    /// The method is internal rather than private because a render of the core
    /// alone is how the sun is measured: the card's layer order draws it through
    /// the same call.
    ///
    /// - Parameters:
    ///   - context: the canvas to draw into.
    ///   - size: the canvas's size, in points.
    func drawHaloCore(context: GraphicsContext, size: CGSize) {
        drawHaloCore(
            context: context,
            size: size,
            hertz: Halo.coreSpringHertz,
            damping: Halo.coreSpringDamping
        )
    }

    /// The sun drawn by a spring of the given frequency and damping.
    ///
    /// It is the same drawing as ``drawHaloCore(context:size:)`` with the two
    /// constants the card ships opened, which is how a spring is judged by its
    /// picture rather than by its numbers. The card passes its own constants and
    /// draws ``drawHaloCore(context:size:)``.
    ///
    /// - Parameters:
    ///   - context: the canvas to draw into.
    ///   - size: the canvas's size, in points.
    ///   - hertz: the spring's frequency, in hertz.
    ///   - damping: the spring's damping, as a share of critical damping.
    func drawHaloCore(context: GraphicsContext, size: CGSize, hertz: Double, damping: Double) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let source = reduceMotion
            ? VisualizerMath.peakHold(history, ticks: Halo.holdSamples)
            : history
        let energy = Halo.coreEnergy(history: source, ceiling: ceiling)
        let target = reduceMotion
            ? Halo.coreRadius(energy: energy, time: 0)
            : Halo.elasticCoreRadius(
                history: source,
                ceiling: ceiling,
                time: time,
                hertz: hertz,
                damping: damping
            )
        let radius = max(0.5, target)
        drawCoreGlow(context: context, centre: centre, radius: radius, energy: energy)
        drawCoreRays(context: context, centre: centre, radius: radius, energy: energy)
        drawCoreShine(context: context, centre: centre, radius: radius, energy: energy)
    }

    /// The light the core throws on the card, drawn under the shine.
    ///
    /// A circle ``HUDWaveform/Halo/glowReach`` radii wide, filled with a radial
    /// gradient that holds its ink out to ``HUDWaveform/Halo/glowStart`` of the
    /// reach and is fully transparent at the reach itself, so the glow ends in the
    /// card rather than on a circle. Its ink is ``HUDWaveform/Halo/glowInk`` lifted
    /// by the voice from ``HUDWaveform/Halo/glowRestShare`` of itself at silence to
    /// all of itself at the loudest moment, which is what keeps a quiet card a lit
    /// one.
    private func drawCoreGlow(
        context: GraphicsContext,
        centre: CGPoint,
        radius: CGFloat,
        energy: Double
    ) {
        let reach = Halo.glowReach * radius
        let ink = Halo.glowInk * (Halo.glowRestShare + (1 - Halo.glowRestShare) * energy)
        let colour = VisualizerMath.ramp(
            MeterRamp.tint(level: energy, ceiling: ceiling),
            opacity: ink,
            lift: lift
        )
        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - reach,
                y: centre.y - reach,
                width: reach * 2,
                height: reach * 2
            )),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: colour, location: 0),
                    .init(color: colour, location: Halo.glowStart / Halo.glowReach),
                    .init(color: colour.opacity(0), location: 1),
                ]),
                center: centre,
                startRadius: 0,
                endRadius: reach
            )
        )
    }

    /// The rays the core throws, drawn between the glow and the shine.
    ///
    /// A ray is a triangle from ``HUDWaveform/Halo/rayInner`` radii to
    /// ``HUDWaveform/Halo/rayReach``, ``HUDWaveform/Halo/rayHalfWidth`` points wide
    /// at its base and a point at its tip, filled with a linear gradient from the
    /// core's tint at ``HUDWaveform/Halo/rayInk`` at the base to the same tint at
    /// nothing at the tip. The voice lengthens the rays with the same spring as the
    /// core, by up to ``HUDWaveform/Halo/rayVoiceReach`` radii at full stretch, and
    /// every second ray keeps ``HUDWaveform/Halo/rayAlternate`` of the length it
    /// would have had. They turn once in ``HUDWaveform/Halo/rayTurnSeconds``
    /// seconds, and a reduced-motion frame draws them at their first angle.
    ///
    /// The ink is the ring's own on the glass material: a ray is a thin mark on a
    /// light surface, so its colour takes ``HUDWaveform/Halo/glassRingLift`` and its
    /// opacity ``HUDWaveform/Halo/glassRingInkGain``, and the black material draws
    /// the plain tint at the ray's own opacity.
    private func drawCoreRays(
        context: GraphicsContext,
        centre: CGPoint,
        radius: CGFloat,
        energy: Double
    ) {
        let stretch = min(1.35, max(0, (radius - Halo.restCoreRadius) / Halo.coreGain))
        let turn = reduceMotion ? 0 : 2 * Double.pi * time / Halo.rayTurnSeconds
        let ink = VisualizerMath.ramp(
            MeterRamp.tint(level: energy, ceiling: ceiling),
            opacity: min(1, Halo.rayInk * ringInkGain),
            lift: ringLift
        )
        let inner = Halo.rayInner * radius
        let reach = radius * (Halo.rayReach + Halo.rayVoiceReach * stretch)
        for ray in 0..<Halo.rayCount {
            let angle = turn + 2 * Double.pi * Double(ray) / Double(Halo.rayCount)
            let along = CGPoint(x: CGFloat(cos(angle)), y: CGFloat(sin(angle)))
            let across = CGPoint(x: -along.y, y: along.x)
            let start = CGPoint(x: centre.x + along.x * inner, y: centre.y + along.y * inner)
            let length = reach - inner
            let span = ray % 2 == 0 ? length : length * Halo.rayAlternate
            let tip = CGPoint(x: start.x + along.x * span, y: start.y + along.y * span)
            var path = Path()
            path.move(to: CGPoint(
                x: start.x + across.x * Halo.rayHalfWidth,
                y: start.y + across.y * Halo.rayHalfWidth
            ))
            path.addLine(to: CGPoint(
                x: start.x - across.x * Halo.rayHalfWidth,
                y: start.y - across.y * Halo.rayHalfWidth
            ))
            path.addLine(to: tip)
            path.closeSubpath()
            context.fill(path, with: .linearGradient(
                Gradient(stops: [
                    .init(color: ink, location: 0),
                    .init(color: ink.opacity(0), location: 1),
                ]),
                startPoint: start,
                endPoint: tip
            ))
        }
    }

    /// The body of the core: a radial gradient with a white-hot centre.
    ///
    /// The black material's shine puts the card's ink at 0.95 in the middle, the
    /// meter's warm tip inside the first third of the radius, and the core's own
    /// tint from 0.70 to an edge that fades to nothing. The glass material holds
    /// the card's ink at full opacity across
    /// ``HUDWaveform/Halo/hotCentreShare`` of the radius first, because a core
    /// drawn only in the meter's amber stands at 2.71 to 1 on the light surface
    /// behind the canvas, under the 3 to 1 the halo is held to; the tip and the
    /// tint follow from there. Neither material draws an outline, so the core is a
    /// light with a soft edge rather than a disc with a rim.
    private func drawCoreShine(
        context: GraphicsContext,
        centre: CGPoint,
        radius: CGFloat,
        energy: Double
    ) {
        let colour = tint(energy)
        let apex = VisualizerMath.ramp(MeterRamp.tip, opacity: 1, lift: lift)
        let stops: [Gradient.Stop]
        if material == .glass {
            let share = Halo.hotCentreShare
            stops = [
                .init(color: HUDTheme.inkBase, location: 0),
                .init(color: HUDTheme.inkBase, location: share),
                .init(color: apex, location: share),
                .init(color: colour, location: 0.75),
                .init(color: colour.opacity(0), location: 1),
            ]
        } else {
            stops = [
                .init(color: HUDTheme.inkBase.opacity(0.95), location: 0),
                .init(color: apex, location: 0.30),
                .init(color: colour, location: 0.70),
                .init(color: colour.opacity(0), location: 1),
            ]
        }
        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - radius,
                y: centre.y - radius,
                width: radius * 2,
                height: radius * 2
            )),
            with: .radialGradient(
                Gradient(stops: stops),
                center: centre,
                startRadius: 0,
                endRadius: radius
            )
        )
    }

    /// One half of one ring: its track, the trails of its particles and the
    /// particles themselves.
    ///
    /// The ring is the one part of the canvas whose ink is decided by the
    /// material twice: the colour is the meter's tint at
    /// ``HUDWaveform/Halo/glassRingLift`` rather than at ``lift``, and each of
    /// the four opacities the ring draws with is multiplied by ``ringInkGain``.
    /// Both corrections are the ring's own because a ring is drawn at a fraction
    /// of the opacity a bar is, and the clear glass behind the canvas is a light
    /// surface that a pale mark disappears into. On the black material the lift
    /// is zero and the gain is one, so every mark here is the ink it was.
    private func drawRing(
        context: GraphicsContext,
        ring: Int,
        front: Bool,
        frame: HaloRingFrame,
        centre: CGPoint,
        clock: Double
    ) {
        let ringTint = MeterRamp.tint(level: frame.energy, ceiling: ceiling)
        let colour = VisualizerMath.ramp(ringTint, opacity: ringTint.opacity, lift: ringLift)
        let gain = ringInkGain
        let trackInk = Halo.trackFloor + Halo.trackGain * frame.energy
        context.stroke(
            Halo.track(orientation: frame.orientation, front: front, centre: centre),
            with: .color(colour.opacity(front
                ? min(1, trackInk * gain)
                : min(1, trackInk * Halo.backInk * gain))),
            style: StrokeStyle(lineWidth: Halo.trackWidth, lineCap: .round)
        )

        let count = Halo.particleCounts[ring]
        let sign: Double = Halo.revolutions[ring] < 0 ? -1 : 1
        let trailScale = Halo.trailScale(ring: ring, speed: frame.speed)
        for index in 0..<count {
            let theta = Halo.particleAngle(ring: ring, index: index, kick: frame.kick, time: clock)
            let spot = Halo.point(orientation: frame.orientation, theta: theta, centre: centre)
            guard (spot.depth > 0) == front else { continue }
            let band = Halo.particleBand(ring: ring, index: index, spectrum: spectrumHistory)
            let radius = Halo.particleRadius(band: band, depth: spot.depth)
            let ink = min(1, Halo.particleInk(depth: spot.depth, energy: frame.energy) * gain)

            // A trail is the motion read in a still: the same dot three times
            // along the way it came from, each one smaller and fainter than the
            // last, and longer while the voice is pushing the ring. It is not
            // drawn at all when the motion is reduced, because there is then no
            // motion to read.
            if !reduceMotion {
                for (ghost, angle) in Halo.trailAngles.enumerated() {
                    let trailTheta = theta - sign * angle * trailScale
                    let trail = Halo.point(
                        orientation: frame.orientation,
                        theta: trailTheta,
                        centre: centre
                    )
                    guard (trail.depth > 0) == front else { continue }
                    let trailRadius = radius * CGFloat(Halo.trailRadii[ghost])
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: trail.point.x - trailRadius,
                            y: trail.point.y - trailRadius,
                            width: trailRadius * 2,
                            height: trailRadius * 2
                        )),
                        with: .color(colour.opacity(min(1, ink * Halo.trailInk[ghost])))
                    )
                }
            }

            context.fill(
                Path(ellipseIn: CGRect(
                    x: spot.point.x - radius,
                    y: spot.point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: .color(colour.opacity(ink))
            )
        }
    }
}
