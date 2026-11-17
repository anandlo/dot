import AppKit
import CryptoKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// The halo's motion, measured on its geometry and on its picture.
///
/// Every claim here is one of the halo's own rules: that a particle never jumps,
/// that a ring never reverses its spin, that a ring fits the canvas it was given,
/// that a silent ring tumbles, that the voice opens it, that depth decides which
/// side of the core a dot is drawn on, and that a reduced-motion frame is a
/// still. The numbers are read from ``HUDWaveform/Halo`` and driven by the
/// demonstration's own voice at 60 Hz, so a rule is checked against the voice
/// the card is designed for rather than against a formula of its own.
///
/// The take is generated in memory: the card's meter and its 60 Hz spectrum path
/// are pushed four times a sample period and the envelope is read at the sample
/// period, so each tick hands the view one new sample of a 60 Hz history, which
/// is the contract the view is written against.
@MainActor
final class HaloMotionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FontFixture.register()
    }

    /// The card's waveform canvas, in points.
    static let canvas = CGSize(width: 102, height: 26)
    /// The recording card's own waveform canvas, in points.
    ///
    /// It is the flexible middle of the recording row: the card's 316 points less
    /// two 16 point paddings, less the live dot, the two labels, the four gaps and
    /// the divider and two buttons, which leaves 124 points at
    /// `HUDTheme.waveformHeight` of height.
    static let cardCanvas = CGSize(width: 124, height: 26)
    /// A Settings tile's waveform canvas, in points.
    static let tileCanvas = CGSize(width: 200, height: 22)
    /// Where the evidence renders are written, when the run asks for them.
    static var evidence: URL? {
        guard let path = ProcessInfo.processInfo.environment["DOT_VISUALIZER_EVIDENCE"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - The voice

    /// What one 60 Hz tick of the card holds.
    struct Frame {
        var history: [Double]
        var spectrum: [AudioSpectrumFrame]
        var ceiling: Double
        var level: Double
        var phase: Double
    }

    /// One full loop of ``DictationScript``, measured the way the card measures
    /// it.
    ///
    /// The meter is pushed four times per sample period and the envelope is read
    /// once per sample period: the history therefore advances by exactly one
    /// sample a tick, which is what a 60 Hz waveform is handed. The spectrum
    /// follows the card's own 14 ms attack and 30 ms release.
    static func dictationFrames() -> [Frame] {
        let meter = VoiceMeter()
        meter.setCalibration(nil)
        var scale = SpectrumScale()
        var smoothed = AudioSpectrumFrame.zero
        var shapes: [Double] = []
        var readbacks: [(spectrum: [AudioSpectrumFrame], ceiling: Double, level: Double, phase: Double)] = []
        let steps = 4
        let ticks = Int((HUD.previewDismissDelay * Waveform.sampleRate).rounded())
        for step in 0..<(ticks * steps + 1) {
            let moment = Double(step) / (Waveform.sampleRate * Double(steps))
            let voice = DictationScript.level(at: moment)
            meter.push(decibels: -58 + voice * 50, now: moment)
            let bands = AudioSpectrumFrame(bands: (
                min(1, voice * 0.92),
                min(1, voice * 0.80),
                min(1, voice * 0.70),
                min(1, voice * 0.76),
                min(1, voice * 0.58)
            ))
            let scaled = scale.normalise(bands, dt: 1.0 / (Waveform.sampleRate * Double(steps)))
            func smooth(_ current: Double, _ next: Double) -> Double {
                let tau = next > current ? 0.014 : 0.03
                let dt = 1.0 / (Waveform.sampleRate * Double(steps))
                return current + (next - current) * (1 - exp(-dt / tau))
            }
            smoothed = AudioSpectrumFrame(bands: (
                smooth(smoothed.bands.0, scaled.bands.0),
                smooth(smoothed.bands.1, scaled.bands.1),
                smooth(smoothed.bands.2, scaled.bands.2),
                smooth(smoothed.bands.3, scaled.bands.3),
                smooth(smoothed.bands.4, scaled.bands.4)
            ))
            shapes.append(meter.shape)
            guard step % steps == 0 else { continue }
            let spectrum = Array(repeating: smoothed, count: Waveform.historyLength)
            readbacks.append((spectrum, meter.ceiling, meter.level, meter.phase))
        }
        let samples = stride(from: 0, to: shapes.count, by: steps).map { shapes[$0] }
        return readbacks.enumerated().map { index, readback in
            let end = min(samples.count, index + 1)
            let start = max(0, end - Waveform.historyLength)
            var history = [Double](repeating: 0, count: Waveform.historyLength)
            let values = Array(samples[start..<end])
            for (offset, value) in values.enumerated() {
                history[Waveform.historyLength - values.count + offset] = value
            }
            return Frame(
                history: history,
                spectrum: readback.spectrum,
                ceiling: readback.ceiling,
                level: readback.level,
                phase: readback.phase
            )
        }
    }

    /// A take that never drops, for the loud end of the range.
    static func constantFrame(level: Double, ceiling: Double) -> Frame {
        Frame(
            history: Array(repeating: level, count: Waveform.historyLength),
            spectrum: Array(
                repeating: AudioSpectrumFrame(bands: (level, level, level, level, level)),
                count: Waveform.historyLength
            ),
            ceiling: ceiling,
            level: level,
            phase: 0
        )
    }

    /// A room with nothing in it.
    static func silentFrame() -> Frame {
        Frame(
            history: Array(repeating: 0, count: Waveform.historyLength),
            spectrum: Array(repeating: .zero, count: Waveform.historyLength),
            ceiling: 1,
            level: 0,
            phase: 0
        )
    }

    // MARK: - The geometry of one tick

    /// One ring at one moment, read the way the view reads it.
    struct RingState {
        var energy: Double
        var orientation: HUDWaveform.Halo.Orientation
        var kick: Double
        var speed: Double
        var angles: [Double]
        var points: [CGPoint]
        var depths: [Double]
    }

    static func state(ring: Int, frame: Frame, time: Double, size: CGSize = canvas) -> RingState {
        let energy = HUDWaveform.Halo.ringEnergy(ring, history: frame.history)
        let orientation = HUDWaveform.Halo.orientation(
            ring: ring,
            time: time,
            energy: energy,
            width: size.width,
            height: size.height
        )
        let kick = HUDWaveform.Halo.kick(ring: ring, history: frame.history)
        let speed = HUDWaveform.Halo.angularSpeed(ring: ring, history: frame.history)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        var angles: [Double] = []
        var points: [CGPoint] = []
        var depths: [Double] = []
        for index in 0..<HUDWaveform.Halo.particleCounts[ring] {
            let angle = HUDWaveform.Halo.particleAngle(ring: ring, index: index, kick: kick, time: time)
            let spot = HUDWaveform.Halo.point(orientation: orientation, theta: angle, centre: centre)
            angles.append(angle)
            points.append(spot.point)
            depths.append(spot.depth)
        }
        return RingState(
            energy: energy,
            orientation: orientation,
            kick: kick,
            speed: speed,
            angles: angles,
            points: points,
            depths: depths
        )
    }

    /// The vertical half extent of a ring's projected circle, in points.
    static func extent(of orientation: HUDWaveform.Halo.Orientation) -> Double {
        let radius = Double(orientation.radius)
        let node = orientation.node
        let room = pow(sin(node), 2) + pow(cos(orientation.inclination) * cos(node), 2)
        return radius * room.squareRoot()
    }

    /// The projected width of a ring, in points.
    ///
    /// The horizontal half extent of the projected circle is `a` times the root of
    /// `cos^2 node + cos^2 iota sin^2 node`, so the width is twice that.
    static func width(of orientation: HUDWaveform.Halo.Orientation) -> Double {
        let radius = Double(orientation.radius)
        let node = orientation.node
        let room = pow(cos(node), 2) + pow(cos(orientation.inclination) * sin(node), 2)
        return 2 * radius * room.squareRoot()
    }

    /// The furthest a point of the ring can travel between two ticks, in points.
    static func worstStep(
        between frame: Frame,
        and next: Frame,
        time: Double,
        ring: Int,
        size: CGSize = canvas
    ) -> (step: Double, index: Int) {
        let first = state(ring: ring, frame: frame, time: time, size: size)
        let second = state(ring: ring, frame: next, time: time + 1 / Waveform.sampleRate, size: size)
        var worst = 0.0
        var index = 0
        for particle in 0..<first.points.count {
            let dx = Double(second.points[particle].x - first.points[particle].x)
            let dy = Double(second.points[particle].y - first.points[particle].y)
            let step = (dx * dx + dy * dy).squareRoot()
            if step > worst {
                worst = step
                index = particle
            }
        }
        return (worst, index)
    }

    // MARK: - Pixels

    func rasterise(_ content: some View, size: CGSize) throws -> NSBitmapImageRep {
        try rasterise(content, size: size, scale: 2)
    }

    /// Rasterises a view at the points per point asked for, off every display.
    func rasterise(_ content: some View, size: CGSize, scale: Int) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let hosting = NSHostingView(
            rootView: content
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
                .environment(\.displayScale, CGFloat(scale))
        )
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), "the render could not be allocated")
        bitmap.size = size
        if let data = bitmap.bitmapData {
            memset(data, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        hosting.cacheDisplay(in: NSRect(origin: .zero, size: size), to: bitmap)
        window.contentView = nil
        window.orderOut(nil)
        return bitmap
    }

    func alpha(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> Double {
        guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh,
              let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        else { return 0 }
        return colour.alphaComponent
    }

    /// The furthest row of ink from the canvas's centre line, in points.
    func halfExtent(_ bitmap: NSBitmapImageRep, threshold: Double = 0.02) -> Double {
        let centre = Double(bitmap.pixelsHigh) / 2
        var furthest = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where alpha(bitmap, x, y) > threshold {
                furthest = max(furthest, abs(Double(y) + 0.5 - centre) / 2)
                break
            }
        }
        return furthest
    }

    /// The waveform on its own, on a transparent canvas.
    func plain(
        _ frame: Frame,
        time: Double,
        reduceMotion: Bool = false,
        size: CGSize = HaloMotionTests.canvas
    ) -> some View {
        HUDWaveform(
            visualizer: .haloEdge,
            halfHeights: [],
            history: frame.history,
            spectrumHistory: frame.spectrum,
            phase: frame.phase,
            time: time,
            level: frame.level,
            pulse: 0.25,
            ceiling: frame.ceiling,
            reveal: 1,
            reduceMotionOverride: reduceMotion
        )
        .frame(width: size.width, height: size.height)
    }

    /// The brightness of one pixel of a render: its sRGB components weighted the
    /// way the render suite weights them.
    ///
    /// It is the pixel's colour rather than its alpha, which is what a claim about
    /// a white-hot centre is about, and it is the weighted sum of the components
    /// that ``MatrixRenderTests/luminance(_:at:scale:)`` reads a dot's brightness
    /// with rather than the linearised ratio the glass suite measures contrast by.
    /// The two differ on a warm colour: the shine's centre reads 0.92 here and
    /// 0.84 linearised, and it is a brightness that is being claimed.
    func luminance(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> Double {
        guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh,
              let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        else { return 0 }
        return 0.2126 * colour.redComponent
            + 0.7152 * colour.greenComponent
            + 0.0722 * colour.blueComponent
    }

    /// The halo's core on its own, without a ring, through the call the card's
    /// layer order makes for its `.core` layer.
    func coreOnly(_ frame: Frame, time: Double, size: CGSize) -> some View {
        let waveform = HUDWaveform(
            visualizer: .haloEdge,
            halfHeights: [],
            history: frame.history,
            spectrumHistory: frame.spectrum,
            phase: frame.phase,
            time: time,
            level: frame.level,
            pulse: 0.25,
            ceiling: frame.ceiling,
            reveal: 1
        )
        return Canvas { context, canvasSize in
            waveform.drawHaloCore(context: context, size: canvasSize)
        }
        .frame(width: size.width, height: size.height)
    }

    /// The sun on the recording card's own black surface, drawn by a spring of the
    /// given frequency and damping.
    ///
    /// The surface is the card's rather than a flat black so the picture is the one
    /// the card draws: the band is cut from a render of ``HUDSurface`` at the rect
    /// the card's canvas occupies.
    ///
    /// - Parameters:
    ///   - frame: the voice of the moment.
    ///   - time: the moment, in seconds.
    ///   - hertz: the spring's frequency, in hertz.
    ///   - damping: the spring's damping, as a share of critical damping.
    ///   - size: the canvas's size, in points.
    ///   - surface: the card's surface, cut to the canvas's shape.
    func springCore(
        _ frame: Frame,
        time: Double,
        hertz: Double,
        damping: Double,
        size: CGSize,
        surface: NSImage
    ) -> some View {
        let waveform = HUDWaveform(
            visualizer: .haloEdge,
            halfHeights: [],
            history: frame.history,
            spectrumHistory: frame.spectrum,
            phase: frame.phase,
            time: time,
            level: frame.level,
            pulse: 0.25,
            ceiling: frame.ceiling,
            reveal: 1
        )
        return ZStack {
            Image(nsImage: surface)
                .resizable()
                .frame(width: size.width, height: size.height)
            Canvas { context, canvasSize in
                waveform.drawHaloCore(
                    context: context,
                    size: canvasSize,
                    hertz: hertz,
                    damping: damping
                )
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// The sun on the recording card's own black surface, drawn by the spring the
    /// card ships.
    ///
    /// It is the pair of ``springCore(_:time:hertz:damping:size:surface:)`` that
    /// proves the seam: a cell of the ladder whose numbers are the shipped ones
    /// draws the same bytes as this view, which reaches the sun through
    /// ``HUDWaveform/drawHaloCore(context:size:)`` and the constants alone.
    func shippedCore(
        _ frame: Frame,
        time: Double,
        size: CGSize,
        surface: NSImage
    ) -> some View {
        let waveform = HUDWaveform(
            visualizer: .haloEdge,
            halfHeights: [],
            history: frame.history,
            spectrumHistory: frame.spectrum,
            phase: frame.phase,
            time: time,
            level: frame.level,
            pulse: 0.25,
            ceiling: frame.ceiling,
            reveal: 1
        )
        return ZStack {
            Image(nsImage: surface)
                .resizable()
                .frame(width: size.width, height: size.height)
            Canvas { context, canvasSize in
                waveform.drawHaloCore(context: context, size: canvasSize)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// The recording card at the size it ships, on the material asked for.
    func card(
        _ frame: Frame,
        time: Double,
        material: HUDMaterial = .black,
        reduceMotion: Bool = false
    ) -> some View {
        let size = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.material = material
        model.mode = .recording(elapsed: "0:07")
        model.cardSize = size
        model.visualizer = .haloEdge
        model.history = frame.history
        model.spectrumHistory = frame.spectrum
        model.ceiling = frame.ceiling
        model.level = frame.level
        model.phase = frame.phase
        model.time = time
        model.pulse = 0.25
        model.reveal = 1
        return HUDView(
            model: model,
            showsShadow: false,
            animated: false,
            actions: HUDPreview.previewActions,
            reduceMotionOverride: reduceMotion
        )
        .frame(width: size.width, height: size.height)
    }

    // MARK: - H1a: the angle never jumps

    /// No particle's angle jumps: at every tick of the loop, every particle of
    /// every ring turns by no more than the ring's fastest reported speed allows,
    /// with five per cent of room for the one sample the outer rings lose at the
    /// tail of their three-second window.
    ///
    /// This is the property the old `speed * time` phase could not have: there a
    /// change of the voice multiplied unwrapped time and moved every particle by
    /// a whole lap at once.
    func testHaloAnglesNeverJump() {
        let frames = Self.dictationFrames()
        let step = 1 / Waveform.sampleRate
        for ring in 0..<HUDWaveform.Halo.ringCount {
            var fastest = 0.0
            for frame in frames {
                fastest = max(fastest, abs(HUDWaveform.Halo.angularSpeed(ring: ring, history: frame.history)))
            }
            let bound = 1.05 * fastest * step + 1e-9
            var worst = 0.0
            for tick in 0..<(frames.count - 1) {
                let first = Self.state(ring: ring, frame: frames[tick], time: Double(tick) * step)
                let second = Self.state(ring: ring, frame: frames[tick + 1], time: Double(tick + 1) * step)
                for particle in 0..<first.angles.count {
                    let turn = abs(second.angles[particle] - first.angles[particle])
                    worst = max(worst, turn)
                    XCTAssertLessThanOrEqual(
                        turn,
                        bound,
                        "ring \(ring) particle \(particle) turned \(turn) rad at tick \(tick), over \(bound)"
                    )
                }
            }
            print(String(
                format: "HALO H1a ring %d fastest %.3f rad/s, bound %.5f rad a tick, worst turn %.5f rad",
                ring,
                fastest,
                bound,
                worst
            ))
        }
    }

    // MARK: - H1b: the picture never jumps

    /// The picture never jumps either: between two ticks of the loop every
    /// particle of every ring moves less than three and a half points on the
    /// screen.
    ///
    /// The residual travel is the radius following a syllable's attack, which is
    /// the picture widening on the syllable rather than a discontinuity: it is
    /// bounded by the twenty millisecond attack the meter gives the shape.
    func testHaloParticlesNeverJump() {
        let frames = Self.dictationFrames()
        var worst = 0.0
        var worstRing = 0
        var worstTick = 0
        for ring in 0..<HUDWaveform.Halo.ringCount {
            for tick in 0..<(frames.count - 1) {
                let step = Self.worstStep(
                    between: frames[tick],
                    and: frames[tick + 1],
                    time: Double(tick) / Waveform.sampleRate,
                    ring: ring
                )
                if step.step > worst {
                    worst = step.step
                    worstRing = ring
                    worstTick = tick
                }
            }
        }
        print(String(
            format: "HALO H1b worst step %.3f pt on ring %d at tick %d (%.2f s)",
            worst,
            worstRing,
            worstTick,
            Double(worstTick) / Waveform.sampleRate
        ))
        XCTAssertLessThan(
            worst,
            3.5,
            "a particle of ring \(worstRing) moved \(worst) pt in one tick at "
                + "\(Double(worstTick) / Waveform.sampleRate) s"
        )
    }

    // MARK: - H2: never reverses

    /// A ring never reverses: the analytic angular speed keeps the sign of its
    /// own revolutions at every tick of the loop, and through a take that stops
    /// dead after three seconds at full energy, which is the hardest the push can
    /// fade.
    func testHaloRingNeverReverses() {
        let frames = Self.dictationFrames()
        for ring in 0..<HUDWaveform.Halo.ringCount {
            let sign: Double = HUDWaveform.Halo.revolutions[ring] < 0 ? -1 : 1
            var slowest = Double.infinity
            for frame in frames {
                let speed = HUDWaveform.Halo.angularSpeed(ring: ring, history: frame.history)
                XCTAssertGreaterThan(speed * sign, 0, "ring \(ring) reversed in the loop")
                slowest = min(slowest, abs(speed))
            }
            // Three seconds at full energy and then nothing: the newest sample
            // falls to zero while the tail of the push is still full, which is
            // the largest subtraction the window can make.
            var stopped = Double.infinity
            for step in 0..<120 {
                var history = [Double](repeating: 0, count: Waveform.historyLength)
                for index in 0..<(Waveform.historyLength - step) { history[index] = 1 }
                let speed = HUDWaveform.Halo.angularSpeed(ring: ring, history: history)
                XCTAssertGreaterThan(speed * sign, 0, "ring \(ring) reversed when the voice stopped")
                stopped = min(stopped, abs(speed))
            }
            let spin = 2 * Double.pi * abs(HUDWaveform.Halo.revolutions[ring])
            print(String(
                format: "HALO H2 ring %d spin %.3f rad/s, slowest %.3f, "
                    + "slowest after a stop %.3f, push at most %.3f",
                ring,
                spin,
                slowest,
                stopped,
                HUDWaveform.Halo.kickGain
            ))
            XCTAssertLessThanOrEqual(
                HUDWaveform.Halo.kickGain,
                spin,
                "the push is wider than the spin of ring \(ring)"
            )
        }
    }

    /// The speed the trails are drawn from is the derivative of the angle the
    /// particles are drawn at: over one tick the angle moves by exactly the speed
    /// the ring reports for that tick, so a trail is the motion rather than a
    /// second guess at it.
    ///
    /// The identity holds on every tick now that the push reads the envelope on a
    /// fixed scale: while it read the take's ceiling, a tick that moved the
    /// ceiling rescaled the whole sum and the two disagreed.
    func testHaloSpeedIsTheDerivativeOfTheSpin() {
        let frames = Self.dictationFrames()
        let rate = Waveform.sampleRate
        // Ring zero reads the newest moment of the voice. The two outer rings
        // read a moment four and eight ticks older, so the oldest sample of
        // their three-second window is older than the history and their sum is
        // short by that one sample; the identity is asserted where it is exact.
        for tick in 0..<(frames.count - 1) {
            let first = Self.state(ring: 0, frame: frames[tick], time: Double(tick) / rate)
            let second = Self.state(ring: 0, frame: frames[tick + 1], time: Double(tick + 1) / rate)
            let measured = (second.angles[0] - first.angles[0]) * rate
            XCTAssertEqual(
                measured,
                second.speed,
                accuracy: 1e-9,
                "at tick \(tick) the angle moved at \(measured), the speed says \(second.speed)"
            )
        }
        print("HALO derivative identity holds on all \(frames.count - 1) ticks")
    }

    // MARK: - H3: fits the canvas

    /// Every ring fits: its projected half extent stays inside the room the
    /// canvas keeps, every dot it draws stands inside the canvas with its own
    /// radius, and the loudest moment of the demonstration paints nothing in the
    /// outermost half point of the card's canvas.
    ///
    /// The fit is asserted on all three canvases: the recording card's
    /// `124 x 26`, the motion suite's `102 x 26` and the tile's `200 x 22`. The
    /// tile is the hardest one, because at that aspect ratio the widest ring needs
    /// a tilt flatter than ``Halo/edgeOnDegrees``, and the fit is what the tumble
    /// closes toward there.
    func testHaloRingsFitTheCanvas() throws {
        let frames = Self.dictationFrames()
        for size in [Self.canvas, Self.tileCanvas, Self.cardCanvas] {
            let limit = Double(HUDWaveform.Halo.extentLimit(height: size.height))
            for ring in 0..<HUDWaveform.Halo.ringCount {
                var widest = 0.0
                var tightest = Double.infinity
                for tick in 0..<frames.count {
                    let state = Self.state(
                        ring: ring,
                        frame: frames[tick],
                        time: Double(tick) / Waveform.sampleRate,
                        size: size
                    )
                    widest = max(widest, Self.extent(of: state.orientation))
                    for particle in 0..<state.points.count {
                        let band = HUDWaveform.Halo.particleBand(
                            ring: ring,
                            index: particle,
                            spectrum: frames[tick].spectrum
                        )
                        let radius = Double(HUDWaveform.Halo.particleRadius(
                            band: band,
                            depth: state.depths[particle]
                        ))
                        let point = state.points[particle]
                        let left = Double(point.x) - radius
                        let right = Double(size.width) - Double(point.x) - radius
                        let top = Double(point.y) - radius
                        let bottom = Double(size.height) - Double(point.y) - radius
                        let room = min(min(left, top), min(right, bottom))
                        tightest = min(tightest, room)
                        XCTAssertGreaterThan(
                            room,
                            0,
                            "ring \(ring) painted \(radius) pt outside "
                                + "a canvas of \(size.width) by \(size.height)"
                        )
                    }
                }
                print(String(
                    format: "HALO H3 %.0fx%.0f ring %d extent %.3f of limit %.3f, closest dot %.2f pt inside",
                    size.width,
                    size.height,
                    ring,
                    widest,
                    limit,
                    tightest
                ))
                XCTAssertLessThanOrEqual(
                    widest,
                    limit + 0.01,
                    "ring \(ring) stood \(widest) pt off the centre line "
                        + "on a canvas of \(size.width) by \(size.height)"
                )
            }
        }

        // The loudest moment of the demonstration, on the card's canvas.
        let loud = frames[min(frames.count - 1, Int((6.963 * Waveform.sampleRate).rounded()))]
        let bitmap = try rasterise(
            plain(loud, time: 6.963),
            size: Self.canvas
        )
        var top = 0.0
        var bottom = 0.0
        for x in 0..<bitmap.pixelsWide {
            top = max(top, alpha(bitmap, x, 0))
            bottom = max(bottom, alpha(bitmap, x, bitmap.pixelsHigh - 1))
        }
        print(String(
            format: "HALO H3 loudest half extent %.2f pt, outer half point alpha top %.4f bottom %.4f",
            halfExtent(bitmap),
            top,
            bottom
        ))
        XCTAssertLessThan(top, 0.02, "the loudest halo painted the top half point of its canvas")
        XCTAssertLessThan(bottom, 0.02, "the loudest halo painted the bottom half point of its canvas")
    }

    // MARK: - H4: tumble in silence

    /// A silent halo moves: over twelve seconds of an empty room the inner ring's
    /// own extent swings by at least a fifth of its widest, and every ring's node
    /// swings at least twelve degrees peak to peak.
    ///
    /// The floor is the minor-axis one's consequence rather than a weaker claim.
    /// A ring may no longer close past the tilt where its minor axis is
    /// ``Halo/minorFloorShare`` of the room, and on the inner ring that takes the
    /// flattest third of its tumble away by design: the swing that is left is a
    /// quarter of its widest height, which is what 0.22 holds. The outer rings are
    /// exempt from the extent clause, and the reason is the canvas rather than the
    /// tumble: at silence their own fit is 68.5 to 80.7 degrees, already at or past
    /// what the minor floor allows, so the tilt they may still close through is 9.5
    /// degrees on the second ring and 1.8 on the fifth. Their motion is the node
    /// and the tilt, both of which are reported. A ring is reported as clamped when
    /// the canvas held its roll back, because a clamped ring's node peak is the
    /// fit's rather than the precession's.
    func testHaloRingTumblesInSilence() {
        let silence = Self.silentFrame()
        for ring in 0..<HUDWaveform.Halo.ringCount {
            var low = Double.infinity
            var high = -Double.infinity
            var lowNode = Double.infinity
            var highNode = -Double.infinity
            var lowTilt = Double.infinity
            var highTilt = -Double.infinity
            var clamped = false
            for step in 0...360 {
                let time = Double(step) / 30
                let state = Self.state(ring: ring, frame: silence, time: time)
                let extent = Self.extent(of: state.orientation)
                low = min(low, extent)
                high = max(high, extent)
                lowNode = min(lowNode, state.orientation.node)
                highNode = max(highNode, state.orientation.node)
                lowTilt = min(lowTilt, state.orientation.inclination)
                highTilt = max(highTilt, state.orientation.inclination)
                let raw = HUDWaveform.Halo.rawNode(ring: ring, time: time, energy: 0)
                if abs(raw) > abs(state.orientation.node) + 1e-12 { clamped = true }
            }
            let swing = (high - low) / high
            let nodeSwing = (highNode - lowNode) * 180 / .pi
            let tiltSwing = (highTilt - lowTilt) * 180 / .pi
            print(String(
                format: "HALO H4 ring %d extent %.3f to %.3f (%.1f %% of its widest), "
                    + "tilt %.1f deg of tumble, node %.2f deg peak to peak, clamped %@, extent clause %@",
                ring,
                low,
                high,
                swing * 100,
                tiltSwing,
                nodeSwing,
                clamped ? "yes" : "no",
                ring == 0 ? "held" : "exempt"
            ))
            if ring == 0 {
                XCTAssertGreaterThanOrEqual(
                    swing,
                    0.22,
                    "ring 0 only varied by \(swing * 100) % of its widest"
                )
            }
            XCTAssertGreaterThanOrEqual(nodeSwing, 12, "ring \(ring)'s node only swung \(nodeSwing) deg")
        }
    }

    // MARK: - H5: the voice takes the tumble away and widens the ring

    /// The voice takes most of a ring's tumble away and widens it: at full energy a
    /// ring keeps no more than four tenths of the tilt travel it has in silence, and
    /// every ring is at least one and a bit times as wide at its own loudest moment
    /// as at its own quietest.
    ///
    /// The excursion is read from ``HUDWaveform/Halo/excursion(energy:tumble:)``,
    /// which is the value the drawing uses, over the whole loop and every tumble
    /// phase. The width is the projected horizontal extent of the ring, `2a` times
    /// the root of `cos^2 node + cos^2 iota sin^2 node`, so it is the measurement of
    /// the picture rather than of the radius alone. The two moments are the ticks
    /// where that ring's own energy is the highest and the lowest, rather than two
    /// fixed moments of the script, because a ring reads the voice up to a third of
    /// a second late: with five rings the outermost reads samples sixteen to
    /// twenty-one ticks behind, so a pause at a fixed moment is not a pause for it.
    func testHaloVoiceOpensTheRings() {
        let frames = Self.dictationFrames()
        for ring in 0..<HUDWaveform.Halo.ringCount {
            var ratio = 0.0
            for tick in 0..<frames.count {
                let time = Double(tick) / Waveform.sampleRate
                let phase = HUDWaveform.Halo.tumble(ring: ring, time: time)
                let loud = HUDWaveform.Halo.excursion(energy: 1, tumble: phase)
                let quiet = HUDWaveform.Halo.excursion(energy: 0, tumble: phase)
                ratio = max(ratio, quiet > 0 ? loud / quiet : 0)
            }
            let halfTurn = HUDWaveform.Halo.excursion(energy: 0, tumble: 0.5)

            // This ring's own loudest and quietest moments of the loop.
            var loudTick = 0
            var quietTick = 0
            var loudEnergy = -Double.infinity
            var quietEnergy = Double.infinity
            for tick in 0..<frames.count {
                let energy = HUDWaveform.Halo.ringEnergy(
                    ring,
                    history: frames[tick].history)
                if energy > loudEnergy {
                    loudEnergy = energy
                    loudTick = tick
                }
                if energy < quietEnergy {
                    quietEnergy = energy
                    quietTick = tick
                }
            }
            let loudTime = Double(loudTick) / Waveform.sampleRate
            let quietTime = Double(quietTick) / Waveform.sampleRate
            let loud = Self.state(ring: ring, frame: frames[loudTick], time: loudTime)
            let pause = Self.state(ring: ring, frame: frames[quietTick], time: quietTime)
            let loudWidth = Self.width(of: loud.orientation)
            let pauseWidth = Self.width(of: pause.orientation)
            print(String(
                format: "HALO H5 ring %d keeps %.1f %% of its tumble at full energy "
                    + "(%.3f against %.3f at mid tumble), width %.2f pt at %.3f s "
                    + "(energy %.3f) against %.2f pt at %.3f s (energy %.3f), %.2fx",
                ring,
                ratio * 100,
                0.40 * halfTurn,
                halfTurn,
                loudWidth,
                loudTime,
                loud.energy,
                pauseWidth,
                quietTime,
                pause.energy,
                pauseWidth > 0 ? loudWidth / pauseWidth : 0
            ))
            for tick in 0..<frames.count {
                let phase = HUDWaveform.Halo.tumble(ring: ring, time: Double(tick) / Waveform.sampleRate)
                XCTAssertLessThanOrEqual(
                    HUDWaveform.Halo.excursion(energy: 1, tumble: phase),
                    0.40 * HUDWaveform.Halo.excursion(energy: 0, tumble: phase),
                    "ring \(ring) keeps more than four tenths of its tumble at full energy"
                )
            }
            XCTAssertGreaterThanOrEqual(
                loudWidth,
                1.15 * pauseWidth,
                "ring \(ring) is only \(loudWidth / pauseWidth) times as wide at its "
                    + "loudest tick as at its quietest"
            )
        }
    }

    // MARK: - H6: depth decides the layer

    /// Depth decides the layer: the draw order is the one the occlusion needs,
    /// and a dot is in the near half exactly when its depth is positive, so both
    /// halves of every ring carry particles and neither side of the core can hold
    /// a dot that belongs to the other.
    func testHaloDepthDecidesTheLayer() {
        let order = HUDWaveform.Halo.layerOrder
        let back = (0..<HUDWaveform.Halo.ringCount).reversed().map { HUDWaveform.HaloLayer.ringBack($0) }
        let front = (0..<HUDWaveform.Halo.ringCount).map { HUDWaveform.HaloLayer.ringFront($0) }
        XCTAssertEqual(order, back + [.core] + front, "the halo's draw order changed")

        let frames = Self.dictationFrames()
        for ring in 0..<HUDWaveform.Halo.ringCount {
            var near = 0
            var far = 0
            var atTheEdge = 0
            for tick in stride(from: 0, to: frames.count, by: 7) {
                let state = Self.state(
                    ring: ring,
                    frame: frames[tick],
                    time: Double(tick) / Waveform.sampleRate
                )
                for (particle, depth) in state.depths.enumerated() {
                    let projected = HUDWaveform.Halo.point(
                        orientation: state.orientation,
                        theta: state.angles[particle],
                        centre: .zero
                    )
                    XCTAssertEqual(
                        projected.depth,
                        depth,
                        accuracy: 1e-12,
                        "the depth of ring \(ring) is not the one drawn"
                    )
                    if depth > 0 { near += 1 }
                    else if depth < 0 { far += 1 }
                    else { atTheEdge += 1 }
                }
            }
            print(String(
                format: "HALO H6 ring %d near %.0f %%, far %.0f %%, on the edge %.0f %%, layer %@ / %@",
                ring,
                Double(near) / Double(near + far + atTheEdge) * 100,
                Double(far) / Double(near + far + atTheEdge) * 100,
                Double(atTheEdge) / Double(near + far + atTheEdge) * 100,
                String(describing: HUDWaveform.HaloLayer.ringBack(ring)),
                String(describing: HUDWaveform.HaloLayer.ringFront(ring))
            ))
            XCTAssertGreaterThan(near, 0, "ring \(ring) never reached the near half")
            XCTAssertGreaterThan(far, 0, "ring \(ring) never reached the far half")
        }

        // The near pole stands below the centre and the far pole above it: the
        // two halves are the two hemispheres of one circle.
        let orientation = HUDWaveform.Halo.orientation(
            ring: 2,
            time: 4.2,
            energy: 0.6,
            width: Self.canvas.width,
            height: Self.canvas.height
        )
        let near = HUDWaveform.Halo.point(orientation: orientation, theta: .pi / 2, centre: .zero)
        let far = HUDWaveform.Halo.point(orientation: orientation, theta: 3 * .pi / 2, centre: .zero)
        XCTAssertEqual(near.depth, -far.depth, accuracy: 1e-12, "the two hemispheres are not one depth")
        XCTAssertGreaterThan(near.depth, 0, "the near pole is behind the core")
        XCTAssertLessThan(far.depth, 0, "the far pole is in front of the core")
    }

    // MARK: - H7: reduced motion is a still

    /// A halo drawn without motion is the same picture whatever the clock says,
    /// to the pixel: two reduced-motion renders of one take, five seconds apart,
    /// carry the same PNG.
    func testHaloReducedMotionIsStill() throws {
        let frames = Self.dictationFrames()
        let frame = frames[min(240, frames.count - 1)]
        let first = try rasterise(plain(frame, time: 1, reduceMotion: true), size: Self.canvas)
        let second = try rasterise(plain(frame, time: 5, reduceMotion: true), size: Self.canvas)
        let a = try XCTUnwrap(first.representation(using: .png, properties: [:]))
        let b = try XCTUnwrap(second.representation(using: .png, properties: [:]))
        var worst = 0.0
        for y in 0..<first.pixelsHigh {
            for x in 0..<first.pixelsWide {
                worst = max(worst, abs(alpha(first, x, y) - alpha(second, x, y)))
            }
        }
        print(String(
            format: "HALO H7 worst alpha difference %.6f, sha %@ / %@",
            worst,
            Self.hash(a),
            Self.hash(b)
        ))
        XCTAssertEqual(worst, 0, "the reduced-motion halo moved between two clocks")
        XCTAssertEqual(a, b, "the reduced-motion halo rendered two different files")
    }

    // MARK: - H8: a quiet halo is still a picture

    /// A quiet halo reads: in the silence render and in the pause at 4.00 s every
    /// ring stands at least 0.28 of its own radius off the centre line, and at
    /// least sixty per cent of its particles are drawn at an alpha of 0.25 or
    /// more.
    ///
    /// The measure is the ink the drawing hands each dot, which is the alpha of
    /// the fill. A dot's own centre pixel carries the same number, but a dot that
    /// overlaps a trail does not, so the model's value is the one a rule can be
    /// written on.
    func testHaloReadsWhenItIsQuiet() {
        let frames = Self.dictationFrames()
        let pause = frames[min(frames.count - 1, Int((4.00 * Waveform.sampleRate).rounded()))]
        let cases: [(String, Frame, Double)] = [
            ("silence", Self.silentFrame(), 1.0),
            ("pause", pause, 4.00),
        ]
        for (name, frame, time) in cases {
            for ring in 0..<HUDWaveform.Halo.ringCount {
                let state = Self.state(ring: ring, frame: frame, time: time)
                let radius = Double(state.orientation.radius)
                let extent = Self.extent(of: state.orientation)
                var lit = 0
                var total = 0.0
                for particle in 0..<state.depths.count {
                    let ink = HUDWaveform.Halo.particleInk(
                        depth: state.depths[particle],
                        energy: state.energy
                    )
                    if ink >= 0.25 { lit += 1 }
                    total += ink
                }
                let share = Double(lit) / Double(state.depths.count)
                print(String(
                    format: "HALO H8 %@ ring %d extent %.2f of radius %.2f (%.0f %%), "
                        + "%d of %d particles at 0.25 or more (%.0f %%), mean ink %.2f",
                    name,
                    ring,
                    extent,
                    radius,
                    extent / radius * 100,
                    lit,
                    state.depths.count,
                    share * 100,
                    total / Double(state.depths.count)
                ))
                XCTAssertGreaterThanOrEqual(
                    extent,
                    0.28 * radius,
                    "\(name): ring \(ring) is a hairline at \(extent) pt of \(radius) pt"
                )
                XCTAssertGreaterThanOrEqual(
                    share,
                    0.6,
                    "\(name): only \(share * 100) % of ring \(ring) is drawn at 0.25"
                )
            }
        }
    }

    // MARK: - H9: no ring reads as a line

    /// No ring is a line: on the recording card's `124 x 26` canvas, the motion
    /// suite's `102 x 26` and the tile's `200 x 22`, every ring of every tick of
    /// the dictation loop and of twelve seconds of silence keeps a minor
    /// semi-axis of at least ``HUDWaveform/Halo/minorFloor(height:)``, closes no
    /// flatter than the fit's own tilt or ``HUDWaveform/Halo/edgeOn``, whichever is
    /// the flatter of the two, and stays inside the room the canvas keeps.
    ///
    /// The minor semi-axis is `a cos iota`, which is the short one of the ellipse
    /// the ring draws, so the first assertion is about the picture's height rather
    /// than about its radius: a ring that passes it is an oval at least twice the
    /// floor tall, which is what separates a ring from the slanted line the
    /// widest ring used to become when the canvas forced it nearly edge-on.
    ///
    /// The tilt's limit is the fit where the fit is flatter than `edgeOn`. A ring
    /// wider than `L / cos(edgeOn)` cannot stand at `edgeOn` and stay inside the
    /// canvas at all, so its closed end is the tilt its own radius and roll solve
    /// for, and the minor floor is what keeps that ring from reading as a line.
    func testNoRingReadsAsALine() {
        let frames = Self.dictationFrames()
        let silence = Self.silentFrame()
        for size in [Self.cardCanvas, Self.canvas, Self.tileCanvas] {
            let floor = Double(HUDWaveform.Halo.minorFloor(height: size.height))
            let limit = Double(HUDWaveform.Halo.extentLimit(height: size.height))
            for ring in 0..<HUDWaveform.Halo.ringCount {
                var shortest = Double.infinity
                var shortestShare = Double.infinity
                var widestNode = 0.0
                var widestTilt = 0.0
                var widestAllowed = 0.0
                var widestExtent = 0.0
                func measure(_ frame: Frame, at time: Double) {
                    let state = Self.state(ring: ring, frame: frame, time: time, size: size)
                    let radius = Double(state.orientation.radius)
                    let tilt = state.orientation.inclination
                    let minor = radius * cos(tilt)
                    shortest = min(shortest, minor)
                    shortestShare = min(shortestShare, minor / radius)
                    widestNode = max(widestNode, abs(state.orientation.node) * 180 / .pi)
                    let fit = HUDWaveform.Halo.openInclination(
                        radius: state.orientation.radius,
                        node: state.orientation.node,
                        height: size.height
                    )
                    let allowed = max(fit, HUDWaveform.Halo.edgeOn) * 180 / .pi
                    if tilt * 180 / .pi > widestTilt {
                        widestTilt = tilt * 180 / .pi
                        widestAllowed = allowed
                    }
                    widestExtent = max(widestExtent, Self.extent(of: state.orientation))
                }
                for tick in 0..<frames.count {
                    measure(frames[tick], at: Double(tick) / Waveform.sampleRate)
                }
                for step in 0...360 {
                    measure(silence, at: Double(step) / 30)
                }
                print(String(
                    format: "HALO H9 %.0fx%.0f ring %d minor %.3f pt of floor %.3f "
                        + "(%.3f of its radius), flattest %.1f deg of its fit's %.1f "
                        + "(edgeOn %.1f), worst extent %.3f of %.3f, node %.1f deg",
                    size.width,
                    size.height,
                    ring,
                    shortest,
                    floor,
                    shortestShare,
                    widestTilt,
                    widestAllowed,
                    HUDWaveform.Halo.edgeOnDegrees,
                    widestExtent,
                    limit,
                    widestNode
                ))
                XCTAssertGreaterThanOrEqual(
                    shortest,
                    floor - 1e-9,
                    String(
                        format: "ring %d of %.0fx%.0f is only %.3f pt tall, under the %.3f floor",
                        ring,
                        size.width,
                        size.height,
                        shortest,
                        floor
                    )
                )
                XCTAssertLessThanOrEqual(
                    widestTilt,
                    widestAllowed + 1e-9,
                    String(
                        format: "ring %d of %.0fx%.0f closed to %.1f deg, flatter than the %.1f "
                            + "its fit and edgeOn allow",
                        ring,
                        size.width,
                        size.height,
                        widestTilt,
                        widestAllowed
                    )
                )
                XCTAssertLessThanOrEqual(
                    widestExtent,
                    limit + 0.01,
                    String(
                        format: "ring %d of %.0fx%.0f stood %.3f pt off the centre line of %.3f",
                        ring,
                        size.width,
                        size.height,
                        widestExtent,
                        limit
                    )
                )
            }
        }
    }

    // MARK: - H10: the core is elastic

    /// The core's radius is a spring rather than a step: over the dictation loop
    /// no two consecutive ticks move it by more than 0.9 points, at least one tick
    /// has it past the radius its own energy asks for by 0.30 points or more, it
    /// never leaves the range ``HUDWaveform/Halo/elasticCoreRadius(history:ceiling:time:)``
    /// clamps it to, and after twelve seconds of silence it has come to rest on
    /// that target.
    ///
    /// The overshoot is the elasticity: a radius that only ever approached its
    /// target would be a step with rounded corners, and the swell the sun is drawn
    /// for is the spring passing the target and coming back.
    func testTheCoreIsElastic() {
        let frames = Self.dictationFrames()
        let step = 1 / Waveform.sampleRate
        let lowest = 0.6 * Double(HUDWaveform.Halo.restCoreRadius)
        let highest = Double(HUDWaveform.Halo.restCoreRadius)
            + 1.35 * Double(HUDWaveform.Halo.coreGain)
            + Double(HUDWaveform.Halo.breathRadius)
        var previous: Double?
        var widestStep = 0.0
        var widestStepTime = 0.0
        var largestOvershoot = 0.0
        var largestOvershootTime = 0.0
        var smallest = Double.infinity
        var largest = -Double.infinity
        for tick in 0..<frames.count {
            let time = Double(tick) * step
            let radius = Double(HUDWaveform.Halo.elasticCoreRadius(
                history: frames[tick].history,
                time: time
            ))
            let energy = HUDWaveform.Halo.coreEnergy(
                history: frames[tick].history)
            let target = Double(HUDWaveform.Halo.coreRadius(energy: energy, time: time))
            smallest = min(smallest, radius)
            largest = max(largest, radius)
            if let previous {
                let change = abs(radius - previous)
                if change > widestStep {
                    widestStep = change
                    widestStepTime = time
                }
            }
            previous = radius
            if radius - target > largestOvershoot {
                largestOvershoot = radius - target
                largestOvershootTime = time
            }
        }
        // The spring's own answer to a step, so the elasticity is on the record
        // beside the voice's: a history that is silent for the first half of the
        // spring's window and full for the second half gives the spring one target
        // to chase from rest.
        var stepHistory = [Double](repeating: 0, count: Waveform.historyLength)
        let stepAt = Waveform.historyLength - HUDWaveform.Halo.coreSpringTicks / 2
        for index in stepAt..<Waveform.historyLength {
            stepHistory[index] = 1
        }
        let stepTarget = Double(HUDWaveform.Halo.coreRadius(
            energy: HUDWaveform.Halo.coreEnergy(history: stepHistory),
            time: 11
        ))
        var stepOvershoot = -Double.infinity
        let stepFrom = Double(HUDWaveform.Halo.restCoreRadius)
        for end in (Waveform.historyLength - HUDWaveform.Halo.coreSpringTicks)...Waveform.historyLength {
            let cut = Array(stepHistory[0..<end])
            let radius = Double(HUDWaveform.Halo.elasticCoreRadius(
                history: cut,
                time: 11
            ))
            let target = Double(HUDWaveform.Halo.coreRadius(
                energy: HUDWaveform.Halo.coreEnergy(history: cut),
                time: 11
            ))
            stepOvershoot = max(stepOvershoot, radius - target)
        }
        print(String(
            format: "HALO H10 a step from %.3f pt to %.3f pt is overshot by %.3f pt (%.0f %% of it)",
            stepFrom,
            stepTarget,
            stepOvershoot,
            stepOvershoot / max(0.001, stepTarget - stepFrom) * 100
        ))
        let silence = Self.silentFrame()
        let settled = Double(HUDWaveform.Halo.elasticCoreRadius(
            history: silence.history,
            time: 12
        ))
        let settledTarget = Double(HUDWaveform.Halo.coreRadius(energy: 0, time: 12))
        print(String(
            format: "HALO H10 radius %.3f to %.3f pt of [%.3f, %.3f], widest step %.3f pt at %.3f s, "
                + "widest overshoot %.3f pt at %.3f s, at 12 s of silence %.4f against %.4f (%.4f)",
            smallest,
            largest,
            lowest,
            highest,
            widestStep,
            widestStepTime,
            largestOvershoot,
            largestOvershootTime,
            settled,
            settledTarget,
            abs(settled - settledTarget)
        ))
        XCTAssertLessThanOrEqual(
            widestStep,
            0.9,
            String(format: "the core moved %.3f pt in one tick at %.3f s", widestStep, widestStepTime)
        )
        XCTAssertGreaterThanOrEqual(
            largestOvershoot,
            0.30,
            String(format: "the core's widest overshoot was only %.3f pt", largestOvershoot)
        )
        XCTAssertGreaterThanOrEqual(smallest, lowest, "the core is smaller than its clamp")
        XCTAssertLessThanOrEqual(largest, highest, "the core is larger than its clamp")
        XCTAssertLessThanOrEqual(
            abs(settled - settledTarget),
            0.05,
            "the core still differs from its target by \(abs(settled - settledTarget)) pt after 12 s"
        )
    }

    // MARK: - H11: the core glows and shines

    /// The core is a sun: the light of its glow reaches past the shine, it is
    /// gone before three radii, the middle is white hot, and its rays ink the
    /// direction they point in.
    ///
    /// The core is drawn alone through ``HUDWaveform/drawHaloCore(context:size:)``,
    /// which is the call the card's own layer order makes, so the picture measured
    /// here is the picture the card draws. The radii are measured from the centre
    /// of the canvas: `r` is the elastic radius at the moment drawn, so the glow's
    /// reach, its end and the rays' length are all read relative to the same
    /// number the drawing uses. A ray is a triangle rather than a stroke, so its
    /// ink at a point is read as the ink of the pixel the point lands on, which is
    /// where a taper narrower than a pixel puts it.
    ///
    /// The rays' contrast is asserted on absolute inputs rather than on this demo
    /// frame. The 0.08 floor was measured on energy that a peak-stretched take
    /// pushed to the top of the range; an absolute level deliberately draws a quiet
    /// voice dim, so the floor applies from ordinary speech up and -40 dBFS is held
    /// to a lower one. The demo frame's own contrast is printed as a record.
    func testTheCoreGlowsAndShines() throws {
        let frames = Self.dictationFrames()
        let time = 6.96
        let frame = frames[min(frames.count - 1, Int((time * Waveform.sampleRate).rounded()))]
        let size = Self.cardCanvas
        let bitmap = try rasterise(coreOnly(frame, time: time, size: size), size: size)
        let scale = Double(bitmap.pixelsWide) / Double(size.width)
        let centre = (x: Double(bitmap.pixelsWide) / 2, y: Double(bitmap.pixelsHigh) / 2)
        let radius = Double(HUDWaveform.Halo.elasticCoreRadius(
            history: frame.history,
            time: time
        ))
        func ink(at multiple: Double, angle: Double) -> Double {
            let x = Int((centre.x + cos(angle) * multiple * radius * scale).rounded())
            let y = Int((centre.y + sin(angle) * multiple * radius * scale).rounded())
            return alpha(bitmap, x, y)
        }
        let compass = (0..<8).map { Double($0) * Double.pi / 4 }
        let glow = compass.map { ink(at: 1.6, angle: $0) }.sorted()
        let glowMedian = glow[glow.count / 2]
        let beyond = compass.map { ink(at: 2.8, angle: $0) }.max() ?? 0
        // The render is an even number of pixels wide and tall, so no pixel sits
        // on the centre: the centre pixel is the one nearest it, a quarter of a
        // point away in each direction.
        let middle = luminance(bitmap, Int(centre.x), Int(centre.y))
        let corePixel = bitmap.colorAt(
            x: Int(centre.x),
            y: Int(centre.y)
        )?.usingColorSpace(.sRGB)
        let energy = HUDWaveform.Halo.coreEnergy(history: frame.history)
        let turn = 2 * Double.pi * time / HUDWaveform.Halo.rayTurnSeconds
        let onRay = ink(at: 1.35, angle: turn)
        let between = ink(at: 1.35, angle: turn + Double.pi / Double(HUDWaveform.Halo.rayCount))
        print(String(
            format: "HALO H11 r %.3f pt at energy %.3f, alpha at 1.6 r median %.4f of [%@], "
                + "alpha at 2.8 r at most %.4f, centre %.3f %.3f %.3f at alpha %.3f "
                + "with luminance %.4f, at 1.35 r on a ray %.4f against %.4f between rays (%.4f)",
            radius,
            energy,
            glowMedian,
            glow.map { String(format: "%.3f", $0) }.joined(separator: " "),
            beyond,
            corePixel?.redComponent ?? 0,
            corePixel?.greenComponent ?? 0,
            corePixel?.blueComponent ?? 0,
            corePixel?.alphaComponent ?? 0,
            middle,
            onRay,
            between,
            onRay - between
        ))
        XCTAssertGreaterThanOrEqual(
            glowMedian,
            0.10,
            String(format: "the glow reads %.4f at 1.6 radii", glowMedian)
        )
        XCTAssertLessThanOrEqual(beyond, 0.02, "the glow still inks \(beyond) at 2.8 radii")
        XCTAssertGreaterThanOrEqual(
            middle,
            0.85,
            String(format: "the centre's luminance is %.4f, not white hot", middle)
        )
        // The demo frame's contrast at one point is a record, not a criterion: the
        // floor belongs to absolute inputs. The 0.08 floor was measured on energy
        // that a peak-stretched take pushed to the top of the range; an absolute
        // level deliberately draws a quiet voice dim, so the floor applies from
        // ordinary speech up and -40 dBFS is held to a lower one.
        let window = LevelScale.window(for: nil)
        var contrasts: [(decibels: Double, contrast: Double)] = []
        for decibels in [-40.0, -30, -20, -10, 0] {
            let level = LevelScale.level(decibels: decibels, window: window)
            let measured = try rayContrast(
                history: [Double](repeating: level, count: Waveform.historyLength),
                ceiling: 1,
                time: time,
                spectrum: frame.spectrum,
                phase: frame.phase
            )
            contrasts.append((decibels, measured.ray - measured.gap))
            print(String(
                format: "HALO H11 absolute %.0f dBFS: r %.4f, ray %.4f, gap %.4f, contrast %.4f",
                decibels, measured.energy, measured.ray, measured.gap, measured.ray - measured.gap
            ))
        }
        for entry in contrasts {
            let floor = entry.decibels <= -40 ? 0.05 : 0.08
            XCTAssertGreaterThanOrEqual(
                entry.contrast,
                floor,
                String(format: "a ray inks %.4f more than the gap beside it at %.0f dBFS",
                       entry.contrast, entry.decibels)
            )
        }
        for index in 1..<contrasts.count {
            XCTAssertGreaterThanOrEqual(
                contrasts[index].contrast,
                contrasts[index - 1].contrast,
                String(format: "the ray's contrast falls from %.4f at %.0f dBFS to %.4f at %.0f dBFS",
                       contrasts[index - 1].contrast, contrasts[index - 1].decibels,
                       contrasts[index].contrast, contrasts[index].decibels)
            )
        }
    }

    // MARK: - H12: the cost of the halo

    /// The halo draws no more than half as slowly as the filament: the median and
    /// the ninety-fifth percentile of one card canvas frame's wall time over three
    /// hundred frames of the first five seconds, for the halo and for the filament
    /// as the reference.
    ///
    /// Two times are reported. The first is a frame's cost through a hosting view
    /// and an offscreen window built once and reused across the three hundred
    /// frames, so it covers the view swap, the layout, the display and the draw
    /// rather than the harness; the second is the drawing alone, with the view
    /// built and laid out outside the clock, which is the part the halo's extra
    /// rings and the sun are paid for in. The criterion is read on the first,
    /// because a frame is the whole call: the reference is the filament, the
    /// costliest style that ships, measured 8.33 to 8.38 ms a frame at 124 by 26
    /// on this harness. The stretch row draws in 0.29 ms, so a ratio against it
    /// measured the harness rather than the drawing once each frame stopped
    /// building its own window. The five-ring halo measured 1.61 to 1.64 ms a
    /// frame, 0.195 of the filament, against 0.92 to 0.94 ms for the three-ring
    /// halo, and the bound of half the filament allows about 2.5 times today's
    /// halo before it fails. The drawing alone is printed beside it, so the
    /// drawing's own share is on the record: the halo draws in 1.05 to 1.06 ms
    /// and the stretch row in 0.17 ms.
    func testHaloDrawCost() throws {
        let frames = Self.dictationFrames()
        let count = 300
        func frameView(_ visualizer: HUDVisualizer, _ index: Int) -> AnyView {
            let frame = frames[min(frames.count - 1, index)]
            return AnyView(HUDWaveform(
                visualizer: visualizer,
                halfHeights: [],
                history: frame.history,
                spectrumHistory: frame.spectrum,
                phase: frame.phase,
                time: Double(index) / Waveform.sampleRate,
                level: frame.level,
                pulse: 0.25,
                ceiling: frame.ceiling,
                reveal: 1
            )
            .frame(width: Self.cardCanvas.width, height: Self.cardCanvas.height))
        }
        func percentiles(_ samples: [Double]) -> (median: Double, p95: Double) {
            let sorted = samples.sorted()
            return (sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)])
        }
        func frameCost(_ visualizer: HUDVisualizer) throws -> (median: Double, p95: Double) {
            _ = NSApplication.shared
            let scale = 2
            let hosting = NSHostingView(rootView: frameView(visualizer, 0)
                .environment(\.colorScheme, .dark)
                .environment(\.displayScale, CGFloat(scale)))
            hosting.frame = NSRect(origin: .zero, size: Self.cardCanvas)
            hosting.appearance = NSAppearance(named: .darkAqua)
            let window = OffscreenWindow(size: Self.cardCanvas, styleMask: [.borderless])
            window.contentView = hosting
            window.orderFrontRegardless()
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            var samples: [Double] = []
            samples.reserveCapacity(count)
            for index in 0..<count {
                let start = CFAbsoluteTimeGetCurrent()
                hosting.rootView = frameView(visualizer, index)
                    .environment(\.colorScheme, .dark)
                    .environment(\.displayScale, CGFloat(scale))
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(Self.cardCanvas.width) * scale,
                    pixelsHigh: Int(Self.cardCanvas.height) * scale,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ), "the frame could not be allocated")
                bitmap.size = Self.cardCanvas
                if let data = bitmap.bitmapData {
                    memset(data, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
                }
                hosting.cacheDisplay(in: NSRect(origin: .zero, size: Self.cardCanvas), to: bitmap)
                samples.append(CFAbsoluteTimeGetCurrent() - start)
            }
            window.contentView = nil
            window.orderOut(nil)
            return percentiles(samples)
        }
        func drawCost(_ visualizer: HUDVisualizer) throws -> (median: Double, p95: Double) {
            _ = NSApplication.shared
            let scale = 2
            let hosting = NSHostingView(rootView: frameView(visualizer, 0)
                .environment(\.colorScheme, .dark)
                .environment(\.displayScale, CGFloat(scale)))
            hosting.frame = NSRect(origin: .zero, size: Self.cardCanvas)
            hosting.appearance = NSAppearance(named: .darkAqua)
            let window = OffscreenWindow(size: Self.cardCanvas, styleMask: [.borderless])
            window.contentView = hosting
            window.orderFrontRegardless()
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            var samples: [Double] = []
            samples.reserveCapacity(count)
            for index in 0..<count {
                hosting.rootView = frameView(visualizer, index)
                    .environment(\.colorScheme, .dark)
                    .environment(\.displayScale, CGFloat(scale))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(Self.cardCanvas.width) * scale,
                    pixelsHigh: Int(Self.cardCanvas.height) * scale,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ), "the frame could not be allocated")
                bitmap.size = Self.cardCanvas
                if let data = bitmap.bitmapData {
                    memset(data, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
                }
                let start = CFAbsoluteTimeGetCurrent()
                hosting.cacheDisplay(in: NSRect(origin: .zero, size: Self.cardCanvas), to: bitmap)
                samples.append(CFAbsoluteTimeGetCurrent() - start)
            }
            window.contentView = nil
            window.orderOut(nil)
            return percentiles(samples)
        }
        let haloFrame = try frameCost(.haloEdge)
        let stretchFrame = try frameCost(.stretch)
        let filamentFrame = try frameCost(.filament)
        let haloDraw = try drawCost(.haloEdge)
        let stretchDraw = try drawCost(.stretch)
        print(String(
            format: "HALO H12 frame median %.4f ms (p95 %.4f ms) against stretch's "
                + "%.4f ms (p95 %.4f ms), %.2f times; against the filament's %.4f ms "
                + "(p95 %.4f ms), %.3f times; drawing alone %.4f ms against %.4f ms, %.2f times",
            haloFrame.median * 1000,
            haloFrame.p95 * 1000,
            stretchFrame.median * 1000,
            stretchFrame.p95 * 1000,
            stretchFrame.median > 0 ? haloFrame.median / stretchFrame.median : .infinity,
            filamentFrame.median * 1000,
            filamentFrame.p95 * 1000,
            filamentFrame.median > 0 ? haloFrame.median / filamentFrame.median : .infinity,
            haloDraw.median * 1000,
            stretchDraw.median * 1000,
            stretchDraw.median > 0 ? haloDraw.median / stretchDraw.median : .infinity
        ))
        XCTAssertLessThanOrEqual(
            haloFrame.median,
            0.5 * filamentFrame.median,
            "the halo frame costs \(haloFrame.median / filamentFrame.median) times the filament frame"
        )
    }

    // MARK: - The spring's ladder

    /// The core's spring measured across a ladder of frequencies and dampings, so
    /// the cell the card ships can be chosen from a table rather than from a taste.
    ///
    /// Skipped unless `DOT_HALO_SPRING_LADDER` is set. Every cell is read over the
    /// dictation loop and written to `/tmp/dot-sun-spring-ladder.csv`: the largest
    /// radius above the radius that tick's own energy asks for, that overshoot as a
    /// share of the target and the moment it happens, the largest change between two
    /// ticks, how many separate overshoots pass 0.15 points, and the error left
    /// after twelve seconds of silence. Five cells are also drawn as a strip of
    /// thirteen crops, a sixtieth of a second apart, centred on that cell's widest
    /// overshoot and standing on the recording card's own black surface.
    func testHaloSpringLadder() throws {
        guard ProcessInfo.processInfo.environment["DOT_HALO_SPRING_LADDER"] != nil else {
            throw XCTSkip("DOT_HALO_SPRING_LADDER is not set")
        }
        let frames = Self.dictationFrames()
        let tickSeconds = 1 / Waveform.sampleRate
        struct Reading {
            var overshoot = 0.0
            var target = 0.0
            var time = 0.0
            var tick = 0
            var widestStep = 0.0
            var events = 0
            var settle = 0.0
        }
        func read(hertz: Double, damping: Double) -> Reading {
            var reading = Reading()
            var previous: Double?
            var above = false
            for tick in 0..<frames.count {
                let time = Double(tick) * tickSeconds
                let radius = Double(HUDWaveform.Halo.elasticCoreRadius(
                    history: frames[tick].history,
                    time: time,
                    hertz: hertz,
                    damping: damping
                ))
                let energy = HUDWaveform.Halo.coreEnergy(
                    history: frames[tick].history)
                let target = Double(HUDWaveform.Halo.coreRadius(energy: energy, time: time))
                let excess = radius - target
                if excess > reading.overshoot {
                    reading.overshoot = excess
                    reading.target = target
                    reading.time = time
                    reading.tick = tick
                }
                if excess > 0.15 {
                    if !above {
                        reading.events += 1
                    }
                    above = true
                } else {
                    above = false
                }
                if let previous {
                    reading.widestStep = max(reading.widestStep, abs(radius - previous))
                }
                previous = radius
            }
            let silence = Self.silentFrame()
            let settled = Double(HUDWaveform.Halo.elasticCoreRadius(
                history: silence.history,
                time: 12,
                hertz: hertz,
                damping: damping
            ))
            reading.settle = abs(settled - Double(HUDWaveform.Halo.coreRadius(energy: 0, time: 12)))
            return reading
        }

        let hertzes: [Double] = [5, 6, 7, 8]
        let dampings: [Double] = [0.32, 0.25, 0.20, 0.15, 0.10]
        var readings: [String: Reading] = [:]
        var rows = ["hertz,damping,overshoot_pt,overshoot_percent,time_s,"
            + "max_step_pt,events_over_0.15,settle_error_pt"]
        for hertz in hertzes {
            for damping in dampings {
                let reading = read(hertz: hertz, damping: damping)
                readings["\(hertz)-\(damping)"] = reading
                let share = reading.target > 0 ? reading.overshoot / reading.target * 100 : 0
                print(String(
                    format: "SPRING %.0f Hz damping %.2f: overshoot %.3f pt (%.1f %% of %.3f) "
                        + "at %.3f s, widest step %.3f pt, %d events over 0.15 pt, settle %.4f pt",
                    hertz,
                    damping,
                    reading.overshoot,
                    share,
                    reading.target,
                    reading.time,
                    reading.widestStep,
                    reading.events,
                    reading.settle
                ))
                rows.append(String(
                    format: "%.0f,%.2f,%.4f,%.2f,%.4f,%.4f,%d,%.5f",
                    hertz,
                    damping,
                    reading.overshoot,
                    share,
                    reading.time,
                    reading.widestStep,
                    reading.events,
                    reading.settle
                ))
            }
        }
        let csv = URL(fileURLWithPath: "/tmp/dot-sun-spring-ladder.csv")
        try (rows.joined(separator: "\n") + "\n").write(to: csv, atomically: true, encoding: .utf8)
        print("SPRING ladder written to \(csv.path)")

        // The strips: thirteen crops of the core on the card's own black surface,
        // a sixtieth of a second apart, from six ticks before the widest overshoot
        // to six after it.
        let band = CGSize(width: 40, height: 26)
        let scale = 4
        let cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        let canvas = Self.ringCanvasInCard
        let surface = try rasterise(
            HUDSurface(material: .black).frame(width: cardSize.width, height: cardSize.height),
            size: cardSize,
            scale: scale
        )
        let surfaceImage = try XCTUnwrap(surface.cgImage, "the card's surface could not be read")
        let bandImage = try XCTUnwrap(
            surfaceImage.cropping(to: CGRect(
                x: Int(canvas.minX + (canvas.width - band.width) / 2) * scale,
                y: Int(canvas.minY) * scale,
                width: Int(band.width) * scale,
                height: Int(band.height) * scale
            )),
            "the card's canvas band could not be cropped"
        )
        let directory = URL(fileURLWithPath: "/tmp/dot-sun-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bandSurface = NSImage(cgImage: bandImage, size: band)
        func compose(_ slots: [NSBitmapImageRep]) throws -> NSBitmapImageRep {
            let strip = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(band.width) * scale * slots.count,
                pixelsHigh: Int(band.height) * scale,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), "the spring strip could not be allocated")
            strip.size = CGSize(width: band.width * CGFloat(slots.count), height: band.height)
            if let data = strip.bitmapData {
                memset(data, 0, strip.bytesPerRow * strip.pixelsHigh)
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: strip)
            for (index, slot) in slots.enumerated() {
                slot.draw(in: NSRect(
                    x: CGFloat(index) * band.width,
                    y: 0,
                    width: band.width,
                    height: band.height
                ))
            }
            NSGraphicsContext.restoreGraphicsState()
            return strip
        }
        for (hertz, damping) in [(7.0, 0.32), (6.0, 0.20), (6.0, 0.15), (5.0, 0.15), (8.0, 0.15)] {
            let reading = try XCTUnwrap(readings["\(hertz)-\(damping)"])
            let first = max(0, reading.tick - 6)
            let ticks = (0..<13).map { min(frames.count - 1, first + $0) }
            let strip = try compose(try ticks.map { tick in
                try rasterise(
                    springCore(
                        frames[tick],
                        time: Double(tick) * tickSeconds,
                        hertz: hertz,
                        damping: damping,
                        size: band,
                        surface: bandSurface
                    ),
                    size: band,
                    scale: scale
                )
            })
            let name = String(format: "spring-%.0f-%.2f.png", hertz, damping)
            let data = try XCTUnwrap(strip.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            print(String(
                format: "SPRING strip %@ %dx%d px sha256 %@, ticks %.3f to %.3f s of %.0f Hz damping %.2f",
                name,
                strip.pixelsWide,
                strip.pixelsHigh,
                Self.hash(data),
                Double(first) * tickSeconds,
                Double(first + ticks.count - 1) * tickSeconds,
                hertz,
                damping
            ))

            // The cell the card ships is the card's own picture: the same thirteen
            // ticks drawn through the constants alone must be the same bytes.
            guard hertz == HUDWaveform.Halo.coreSpringHertz,
                  damping == HUDWaveform.Halo.coreSpringDamping
            else { continue }
            let shipped = try compose(try ticks.map { tick in
                try rasterise(
                    shippedCore(
                        frames[tick],
                        time: Double(tick) * tickSeconds,
                        size: band,
                        surface: bandSurface
                    ),
                    size: band,
                    scale: scale
                )
            })
            let shippedData = try XCTUnwrap(shipped.representation(using: .png, properties: [:]))
            print("SPRING the shipped spring draws \(name) as \(Self.hash(shippedData))")
            XCTAssertEqual(
                shippedData,
                data,
                "the shipped constants and the \(hertz) Hz \(damping) cell are not one picture"
            )
        }
    }

    // MARK: - The scope of the change

    /// The four styles this change does not touch draw the same frames on both
    /// materials at the two judged moments.
    ///
    /// The test prints the SHA-256 of each frame rather than asserting one: the
    /// frames it is compared with are the frames the tree before the change drew,
    /// which are not in this tree, and they are read from a run of the same test
    /// on that tree. The four styles are the guard that the halo's work stayed in
    /// the halo.
    func testTheOtherStylesKeepTheirFrames() throws {
        let frames = Self.dictationFrames()
        for visualizer in [HUDVisualizer.stretch, .filament, .silk, .matrix] {
            for moment in [1.50, 6.96] {
                let frame = frames[min(frames.count - 1, Int((moment * Waveform.sampleRate).rounded()))]
                for material in [HUDMaterial.black, .glass] {
                    let view = HUDWaveform(
                        visualizer: visualizer,
                        halfHeights: [],
                        history: frame.history,
                        spectrumHistory: frame.spectrum,
                        phase: frame.phase,
                        time: moment,
                        level: frame.level,
                        pulse: 0.25,
                        ceiling: frame.ceiling,
                        reveal: 1,
                        material: material,
                        glassLift: HUDTheme.visualizerGlassLift
                    )
                    .frame(width: Self.canvas.width, height: Self.canvas.height)
                    print("STYLE \(visualizer) \(material) t\(moment) \(try frameHash(view, size: Self.canvas))")
                }
            }
        }
    }

    /// The SHA-256 of a frame, so two frames can be compared as files.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Evidence

extension HaloMotionTests {
    /// Writes the halo's evidence renders for a design review: six recording
    /// cards, a motion strip, and the silence and reduced-motion pairs.
    ///
    /// Skipped unless `DOT_VISUALIZER_EVIDENCE` names a directory. Every frame is
    /// drawn at twice the points. There is no dark glass card in the shared
    /// evidence, so the six card renders are written on the black material only,
    /// which is the material the shared evidence uses.
    func testHaloEvidenceRenders() throws {
        guard let directory = Self.evidence else {
            throw XCTSkip("DOT_VISUALIZER_EVIDENCE is not set")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frames = Self.dictationFrames()
        let cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        let script: [Double] = [0.75, 1.50, 2.50, 4.00, 6.96, 9.00]
        for moment in script {
            let frame = frames[min(frames.count - 1, Int((moment * Waveform.sampleRate).rounded()))]
            try write(
                card(frame, time: moment),
                size: cardSize,
                named: String(format: "halo-card-black-t%.2f.png", moment),
                to: directory
            )
        }

        // The five ring picture on the black material at four times the points,
        // so the sun and the rings can be read in detail, and the silent card
        // beside them.
        for moment in [1.50, 4.00, 6.96, 10.00] {
            let frame = frames[min(frames.count - 1, Int((moment * Waveform.sampleRate).rounded()))]
            try write(
                card(frame, time: moment),
                size: cardSize,
                named: String(format: "halo5-black-t%.2f.png", moment),
                to: directory,
                scale: 4
            )
        }
        try write(
            card(Self.silentFrame(), time: 3.00),
            size: cardSize,
            named: "halo5-black-silence-t3.00.png",
            to: directory,
            scale: 4
        )

        // The tick of the loop where the flattest ring is at its flattest: the
        // moment the picture is nearest to drawing a line, which is the frame the
        // minor-axis floor is judged on.
        var flattest = (share: Double.infinity, tick: 0, ring: 0)
        for tick in 0..<frames.count {
            let time = Double(tick) / Waveform.sampleRate
            for ring in 0..<HUDWaveform.Halo.ringCount {
                let state = Self.state(
                    ring: ring,
                    frame: frames[tick],
                    time: time,
                    size: Self.cardCanvas
                )
                let share = cos(state.orientation.inclination)
                if share < flattest.share {
                    flattest = (share, tick, ring)
                }
            }
        }
        let flattestTime = Double(flattest.tick) / Waveform.sampleRate
        try write(
            card(frames[flattest.tick], time: flattestTime),
            size: cardSize,
            named: "halo5-black-flattest.png",
            to: directory,
            scale: 4
        )
        print(String(
            format: "HALO evidence halo5-black-flattest.png tick %.3f s ring %d b/a %.3f",
            flattestTime,
            flattest.ring,
            flattest.share
        ))

        // Twelve crops of the core, a sixtieth of a second apart, laid side by
        // side: one cycle of the elastic swell, cropped to the forty points of
        // canvas the sun lives in.
        let crop = CGSize(width: 40, height: 26)
        let cropScale = 4
        let swellStart = 6.80
        let swellCount = 12
        let swell = try (0..<swellCount).map { index -> CGImage in
            let moment = swellStart + Double(index) / 60
            let frame = frames[min(frames.count - 1, Int((moment * Waveform.sampleRate).rounded()))]
            let bitmap = try rasterise(
                plain(frame, time: moment, size: Self.cardCanvas),
                size: Self.cardCanvas,
                scale: cropScale
            )
            let image = try XCTUnwrap(bitmap.cgImage, "the core frame could not be read as pixels")
            let box = CGRect(
                x: Int((Self.cardCanvas.width - crop.width) / 2) * cropScale,
                y: 0,
                width: Int(crop.width) * cropScale,
                height: Int(crop.height) * cropScale
            )
            return try XCTUnwrap(image.cropping(to: box), "the core region could not be cropped")
        }
        let swellStrip = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(crop.width) * cropScale * swellCount,
            pixelsHigh: Int(crop.height) * cropScale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), "the core strip could not be allocated")
        swellStrip.size = CGSize(width: crop.width * CGFloat(swellCount), height: crop.height)
        if let data = swellStrip.bitmapData {
            memset(data, 0, swellStrip.bytesPerRow * swellStrip.pixelsHigh)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: swellStrip)
        for (index, image) in swell.enumerated() {
            NSImage(cgImage: image, size: crop).draw(in: NSRect(
                x: CGFloat(index) * crop.width,
                y: 0,
                width: crop.width,
                height: crop.height
            ))
        }
        NSGraphicsContext.restoreGraphicsState()
        let swellData = try XCTUnwrap(swellStrip.representation(using: .png, properties: [:]))
        try swellData.write(
            to: directory.appendingPathComponent("halo5-core-strip.png"),
            options: .atomic
        )
        print(String(
            format: "HALO evidence halo5-core-strip.png %dx%d px, %d crops of %.0fx%.0f pt from %.2f to %.3f s",
            swellStrip.pixelsWide,
            swellStrip.pixelsHigh,
            swellCount,
            crop.width,
            crop.height,
            swellStart,
            swellStart + Double(swellCount - 1) / 60
        ))

        // Twelve frames a fifteenth of a second apart from the loudest phrase,
        // laid side by side so the motion reads as one picture.
        let start = 6.50
        let count = 12
        let framesOfStrip = try (0..<count).map { index -> NSBitmapImageRep in
            let moment = start + Double(index) / 15
            let frame = frames[min(frames.count - 1, Int((moment * Waveform.sampleRate).rounded()))]
            return try rasterise(plain(frame, time: moment), size: Self.canvas)
        }
        let strip = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Self.canvas.width) * 2 * count,
            pixelsHigh: Int(Self.canvas.height) * 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), "the strip could not be allocated")
        strip.size = CGSize(width: Self.canvas.width * CGFloat(count), height: Self.canvas.height)
        if let data = strip.bitmapData {
            memset(data, 0, strip.bytesPerRow * strip.pixelsHigh)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: strip)
        for (index, frame) in framesOfStrip.enumerated() {
            let rect = NSRect(
                x: CGFloat(index) * Self.canvas.width,
                y: 0,
                width: Self.canvas.width,
                height: Self.canvas.height
            )
            _ = frame.draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        let stripData = try XCTUnwrap(strip.representation(using: .png, properties: [:]))
        try stripData.write(to: directory.appendingPathComponent("halo-strip.png"), options: .atomic)

        // Silence moves and a reduced-motion still does not: the pair at 1.0 s
        // and 5.0 s is written both ways.
        let silence = Self.silentFrame()
        let held = frames[min(frames.count - 1, Int((4.00 * Waveform.sampleRate).rounded()))]
        var hashes: [String: String] = [:]
        for moment in [1.0, 5.0] {
            let silentData = try write(
                plain(silence, time: moment),
                size: Self.canvas,
                named: String(format: "halo-silence-t%.2f.png", moment),
                to: directory
            )
            let reducedData = try write(
                plain(held, time: moment, reduceMotion: true),
                size: Self.canvas,
                named: String(format: "halo-reduced-t%.2f.png", moment),
                to: directory
            )
            hashes[String(format: "silence-t%.2f", moment)] = Self.hash(silentData)
            hashes[String(format: "reduced-t%.2f", moment)] = Self.hash(reducedData)
        }
        for name in hashes.keys.sorted() {
            print("HALO evidence \(name) sha256 \(hashes[name] ?? "")")
        }
        XCTAssertNotEqual(
            hashes["silence-t1.00"],
            hashes["silence-t5.00"],
            "the silent halo is a still rather than a tumble"
        )
        XCTAssertEqual(
            hashes["reduced-t1.00"],
            hashes["reduced-t5.00"],
            "the reduced-motion halo moved between two clocks"
        )
        XCTAssertEqual(Set(hashes.values).count, 3, "two different states wrote one picture")
        print("HALO evidence strip sha256 \(Self.hash(stripData))")
    }

    /// Renders a view into the evidence directory and returns its PNG data.
    @discardableResult
    func write(
        _ content: some View,
        size: CGSize,
        named name: String,
        to directory: URL,
        scale: Int = 2
    ) throws -> Data {
        let bitmap = try rasterise(content, size: size, scale: scale)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        print(String(
            format: "HALO evidence %@ %dx%d px sha256 %@",
            name,
            bitmap.pixelsWide,
            bitmap.pixelsHigh,
            Self.hash(data)
        ))
        return data
    }
}

// MARK: - Glass

extension HaloMotionTests {
    /// The halo on the Glass material, over the two backdrops the glass suite
    /// measures its own ink against.
    ///
    /// The material is composited by the window server rather than by the app, so
    /// this uses the same harness as `GlassSurfaceTests`: a borderless transparent
    /// window at the offscreen origin, the real card inside it, and the
    /// compositor's own picture read back. Nothing is ever drawn on a display.
    ///
    /// Two numbers are judged. The brightest element the halo draws has to read at
    /// three to one against the material behind it, taken the way the glass suite
    /// takes the label's: the median luminance of the canvas is the material and the
    /// brightest pixel is the ink (the ninety-fifth percentile is printed beside it,
    /// because the core is a handful of pixels). The ink's own footprint has to move
    /// the luminance by a mean of 0.04 where it draws, measured against the same card
    /// in silence. The whole-canvas mean is printed as well, for the record: on a
    /// card whose canvas is mostly empty it is a measure of the empty part.
    func testHaloGlassEvidence() throws {
        guard let directory = Self.evidence else {
            throw XCTSkip("DOT_VISUALIZER_EVIDENCE is not set")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frames = Self.dictationFrames()
        let canvas = CGSize(width: 400, height: 160)
        let cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        let cardRect = CGRect(
            x: (canvas.width - cardSize.width) / 2,
            y: (canvas.height - cardSize.height) / 2,
            width: cardSize.width,
            height: cardSize.height
        )
        let moments: [(String, Frame, Double)] = [
            ("t1.50", frames[min(frames.count - 1, Int((1.50 * Waveform.sampleRate).rounded()))], 1.50),
            ("t6.96", frames[min(frames.count - 1, Int((6.96 * Waveform.sampleRate).rounded()))], 6.96),
            ("silence", Self.silentFrame(), 6.96),
        ]
        for (backdrop, luma) in [("bright", 0.92), ("dark", 0.12)] {
            var pictures: [String: WindowCapture.Pixels] = [:]
            for (name, frame, time) in moments {
                let picture = try captureGlass(
                    backdrop: luma,
                    overlay: card(frame, time: time, material: .glass),
                    size: canvas
                )
                let url = directory.appendingPathComponent("halo-glass-\(backdrop)-\(name).png")
                XCTAssertTrue(
                    WindowCapture.write(picture, to: url),
                    "halo-glass-\(backdrop)-\(name).png was not written"
                )
                pictures[name] = picture
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
                print(String(
                    format: "HALO glass %@ %dx%d px, %d bytes",
                    url.lastPathComponent,
                    picture.width,
                    picture.height,
                    bytes ?? 0
                ))

                // The five ring picture on the glass material, over the two pages
                // the rings were chosen on. The capture is the window server's, so
                // the pixels per point are the display's rather than a render's.
                let kept = (backdrop == "bright" && (name == "t1.50" || name == "t6.96"))
                    || (backdrop == "dark" && name == "t6.96")
                if kept {
                    let five = directory.appendingPathComponent(
                        "halo5-glass-\(backdrop)-\(name).png"
                    )
                    XCTAssertTrue(
                        WindowCapture.write(picture, to: five),
                        "\(five.lastPathComponent) was not written"
                    )
                    print(String(
                        format: "HALO evidence %@ %dx%d px",
                        five.lastPathComponent,
                        picture.width,
                        picture.height
                    ))
                }
            }
            guard let voice = pictures["t6.96"], let silence = pictures["silence"] else {
                return XCTFail("the glass capture returned no picture")
            }
            let box = WindowCapture.Rect.points(
                cardRect,
                scaleX: CGFloat(voice.width) / canvas.width,
                scaleY: CGFloat(voice.height) / canvas.height
            )
            let region = Self.canvasRegion(in: box)
            let lit = Self.luma(of: voice, region: region)
            let quiet = Self.luma(of: silence, region: region)
            let voicePicture = Self.luma(of: voice, region: region)
            let difference = Self.meanLumaDifference(voice, silence, region: region)
            let changed = Self.changedShare(voice, silence, region: region)
            print(String(
                format: "HALO glass %@: canvas %dx%d px, material %.4f, brightest %.4f "
                    + "= %.2f:1 (p95 %.4f = %.2f:1), voice mean %.4f, silence mean %.4f",
                backdrop,
                region.width,
                region.height,
                lit.background,
                lit.peak,
                (lit.peak + 0.05) / (lit.background + 0.05),
                lit.ink,
                (lit.ink + 0.05) / (lit.background + 0.05),
                voicePicture.mean,
                quiet.mean
            ))
            print(String(
                format: "HALO glass %@: mean canvas luminance difference %.4f, "
                    + "%.1f %% of the canvas changes by more than 0.02, mean over that share %.4f",
                backdrop,
                difference,
                changed.share * 100,
                changed.mean
            ))
            XCTAssertGreaterThanOrEqual(
                (lit.peak + 0.05) / (lit.background + 0.05),
                3.0,
                "the brightest element reads at \((lit.peak + 0.05) / (lit.background + 0.05)):1 "
                    + "on the \(backdrop) backdrop"
            )
            XCTAssertGreaterThanOrEqual(
                changed.mean,
                0.04,
                "the ink covers only \(changed.mean) of local luminance change on the "
                    + "\(backdrop) backdrop"
            )
        }
    }

    /// A picture of the window server's compositing of a view over a flat backdrop.
    func captureGlass<Overlay: View>(
        backdrop luma: Double,
        overlay: Overlay,
        size: CGSize
    ) throws -> WindowCapture.Pixels {
        let view = ZStack {
            Color(red: luma, green: luma, blue: luma)
            overlay
        }
        .frame(width: size.width, height: size.height)
        let window = WindowCapture.show(view, size: size)
        defer { WindowCapture.hide(window) }
        let picture = try XCTUnwrap(
            WindowCapture.capture(window),
            "the window server returned no picture of the window"
        )
        try WindowCapture.requireUsableCapture(picture)
        return picture
    }

    /// The waveform's own band inside the card, in the capture's pixels.
    ///
    /// The card lays the waveform out as the flexible middle of its row, between
    /// the clock and the two buttons, at the height of the waveform canvas, so the
    /// band is the middle third of the card's width and the middle half of its
    /// height.
    static func canvasRegion(in box: WindowCapture.Rect) -> WindowCapture.Rect {
        WindowCapture.Rect(
            x: box.x + Int(Double(box.width) * 0.32),
            y: box.y + Int(Double(box.height) * 0.25),
            width: max(1, Int(Double(box.width) * 0.36)),
            height: max(1, Int(Double(box.height) * 0.50))
        )
    }

    /// The material's luminance in a region, its brightest element and its mean.
    static func luma(
        of picture: WindowCapture.Pixels,
        region: WindowCapture.Rect
    ) -> (background: Double, ink: Double, peak: Double, mean: Double) {
        var values: [Double] = []
        values.reserveCapacity(region.width * region.height)
        for y in region.y..<(region.y + region.height) {
            for x in region.x..<(region.x + region.width) {
                values.append(WindowCapture.luminance(picture.pixel(x, y)))
            }
        }
        guard let peak = values.max() else { return (0, 0, 0, 0) }
        values.sort()
        let background = values[values.count / 2]
        let ink = values[min(values.count - 1, Int(Double(values.count) * 0.95))]
        return (background, ink, peak, values.reduce(0, +) / Double(values.count))
    }

    /// The share of a region two pictures differ in, and the mean there.
    static func changedShare(
        _ first: WindowCapture.Pixels,
        _ second: WindowCapture.Pixels,
        region: WindowCapture.Rect
    ) -> (share: Double, mean: Double) {
        var total = 0.0
        var count = 0
        var pixels = 0
        for y in region.y..<(region.y + region.height) {
            for x in region.x..<(region.x + region.width) {
                pixels += 1
                let difference = abs(
                    WindowCapture.luminance(first.pixel(x, y))
                        - WindowCapture.luminance(second.pixel(x, y))
                )
                if difference > 0.02 {
                    total += difference
                    count += 1
                }
            }
        }
        return (pixels > 0 ? Double(count) / Double(pixels) : 0, count > 0 ? total / Double(count) : 0)
    }

    /// The mean absolute luminance difference between two pictures in one region.
    static func meanLumaDifference(
        _ first: WindowCapture.Pixels,
        _ second: WindowCapture.Pixels,
        region: WindowCapture.Rect
    ) -> Double {
        var total = 0.0
        var count = 0
        for y in region.y..<(region.y + region.height) {
            for x in region.x..<(region.x + region.width) {
                total += abs(
                    WindowCapture.luminance(first.pixel(x, y))
                        - WindowCapture.luminance(second.pixel(x, y))
                )
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }
}

// MARK: - The ring's ink on the glass material

extension HaloMotionTests {
    /// The rect of the waveform canvas inside the card, in points.
    ///
    /// It is the flexible middle of the recording row: the card's 316 points less
    /// two 16 point paddings, less the live dot, the two labels, the four gaps and
    /// the divider and two buttons, which leaves 124 points of width, at
    /// `HUDTheme.waveformHeight` of height, centred in the card's 54 points. The
    /// rect is confirmed against the picture: on the bright page the widest ring's
    /// ink spans 169.75 to 252.25 points of the capture, and the model at this
    /// rect puts it at 170.16 to 251.84.
    nonisolated static let ringCanvasInCard = CGRect(x: 107, y: 14, width: 124, height: 26)

    /// A point of a ring's track, and the depth the model draws it at.
    struct RingPoint {
        var point: CGPoint
        var depth: Double
    }

    /// Every point of the three rings' tracks at one moment, in a picture's points.
    static func ringPoints(
        frame: Frame,
        time: Double,
        canvasRect: CGRect
    ) -> [RingPoint] {
        let centre = CGPoint(x: canvasRect.midX, y: canvasRect.midY)
        var points: [RingPoint] = []
        for ring in 0..<HUDWaveform.Halo.ringCount {
            let energy = HUDWaveform.Halo.ringEnergy(
                ring,
                history: frame.history)
            let orientation = HUDWaveform.Halo.orientation(
                ring: ring,
                time: time,
                energy: energy,
                width: canvasRect.width,
                height: canvasRect.height
            )
            for step in 0..<360 {
                let theta = 2 * Double.pi * Double(step) / 360
                let spot = HUDWaveform.Halo.point(
                    orientation: orientation,
                    theta: theta,
                    centre: centre
                )
                points.append(RingPoint(point: spot.point, depth: spot.depth))
            }
        }
        return points
    }

    /// What the halo's rings read as on one capture of the card.
    struct RingReading {
        /// The brightest ring pixel's luminance over the material's, at the
        /// `+ 0.05` the glass suite takes its ratios with.
        var contrast: Double
        /// The pixels the ring lifts off the empty canvas by more than 0.04.
        var count: Int
        /// The median of those pixels' luminance over the material's.
        var median: Double
        /// Their mean warmth `(r - b) / r`, which is judged on the dark page.
        var warmth: Double
        /// The mean ink of the pixels nearest the near half of a ring.
        var near: Double
        /// The mean ink of the pixels nearest the far half of a ring.
        var far: Double
    }

    /// The four numbers the ring's ink is judged on, inside the canvas and
    /// outside the core.
    ///
    /// The material is the median WCAG luminance of the same card with its canvas
    /// drawing nothing, which is the card's own surface and none of its content.
    /// The core is excluded at the radius the model draws it and three points of
    /// room, which is the disc the halo's rim used to reach. The sun's glow reaches
    /// further than that, so the pixels it inks inside the rings' band are counted
    /// with the rings rather than with the core, and the two floors are read on that
    /// picture.
    ///
    /// - Parameters:
    ///   - picture: the window server's capture of the card on the glass material.
    ///   - reference: the same card with the canvas drawing nothing.
    ///   - cardRect: the card's rect in the capture's points.
    ///   - canvasSize: the window's size in points.
    ///   - frame: the voice the card was drawn with.
    ///   - time: the moment it was drawn at.
    /// - Returns: the ring's brightest pixel, its inked footprint and its warmth,
    ///   and the ink of the two halves of the rings.
    func ringReading(
        _ picture: WindowCapture.Pixels,
        against reference: WindowCapture.Pixels,
        cardRect: CGRect,
        canvasSize: CGSize,
        frame: Frame,
        time: Double
    ) -> RingReading {
        let scaleX = Double(picture.width) / Double(canvasSize.width)
        let scaleY = Double(picture.height) / Double(canvasSize.height)
        let rect = Self.ringCanvasInCard.offsetBy(dx: cardRect.minX, dy: cardRect.minY)
        let x0 = Int((rect.minX * scaleX).rounded())
        let y0 = Int((rect.minY * scaleY).rounded())
        let width = Int((rect.width * scaleX).rounded())
        let height = Int((rect.height * scaleY).rounded())

        let coreEnergy = HUDWaveform.Halo.coreEnergy(
            history: frame.history)
        let discRadius = Double(HUDWaveform.Halo.coreRadius(energy: coreEnergy, time: time)) + 3
        let rings = Self.ringPoints(frame: frame, time: time, canvasRect: rect)

        var materialValues: [Double] = []
        materialValues.reserveCapacity(width * height)
        var peak = 0.0
        var ratios: [Double] = []
        var warmth: [Double] = []
        var near: [Double] = []
        var far: [Double] = []
        for y in y0..<(y0 + height) {
            let pointY = (Double(y) + 0.5) / scaleY
            for x in x0..<(x0 + width) {
                let pointX = (Double(x) + 0.5) / scaleX
                let referenceLuma = WindowCapture.luminance(reference.pixel(x, y))
                materialValues.append(referenceLuma)
                let dx = pointX - rect.midX
                let dy = pointY - rect.midY
                guard (dx * dx + dy * dy).squareRoot() > discRadius else { continue }
                let luma = WindowCapture.luminance(picture.pixel(x, y))
                peak = max(peak, luma)
                guard luma > referenceLuma + 0.04 else { continue }
                ratios.append(luma / max(referenceLuma, 0.0001))
                let colour = picture.unpremultiplied(x, y)
                let red = colour.0 / 255
                let blue = colour.2 / 255
                warmth.append((red - blue) / max(red, 0.001))
                var nearest = Double.infinity
                var depth = 0.0
                for ring in rings {
                    let rx = Double(ring.point.x) - pointX
                    let ry = Double(ring.point.y) - pointY
                    let distance = rx * rx + ry * ry
                    if distance < nearest {
                        nearest = distance
                        depth = ring.depth
                    }
                }
                guard nearest.squareRoot() <= 3 else { continue }
                let ink = luma - referenceLuma
                if depth > 0 {
                    near.append(ink)
                } else {
                    far.append(ink)
                }
            }
        }
        materialValues.sort()
        ratios.sort()
        return RingReading(
            contrast: (peak + 0.05) / ((materialValues.isEmpty ? 0 : materialValues[materialValues.count / 2]) + 0.05),
            count: ratios.count,
            median: ratios.isEmpty ? 0 : ratios[ratios.count / 2],
            warmth: warmth.isEmpty ? .nan : warmth.reduce(0, +) / Double(warmth.count),
            near: near.isEmpty ? .nan : near.reduce(0, +) / Double(near.count),
            far: far.isEmpty ? .nan : far.reduce(0, +) / Double(far.count)
        )
    }

    /// The rings on the glass material, measured over the two pages they were
    /// chosen on, and the frames the measurement is read on.
    ///
    /// The floors are the measured values of the ladder's chosen cell with a
    /// little room: at the loudest moment over a bright page the ring's brightest
    /// pixel has to read 2.45 to 1 against the material and the median of the
    /// pixels it inks 1.60 to 1; at the first phrase it has to read 2.95 to 1;
    /// over a dark page its warmth has to stay above 0.20, which is what keeps the
    /// ink amber rather than white; and over the bright page the near half of the
    /// rings has to carry 1.5 times the far half's ink, so the depth shading the
    /// depth in `particleInk` draws survives the gain.
    ///
    /// The capture is the window server's, because the material is the server's,
    /// and the material and the mask both come from the same card with its canvas
    /// drawing nothing. The frames are written to `DOT_VISUALIZER_EVIDENCE`, and
    /// the test skips without it, the way the other glass evidence does.
    func testTheRingsReadOnGlass() throws {
        guard let directory = Self.evidence else {
            throw XCTSkip("DOT_VISUALIZER_EVIDENCE is not set")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frames = Self.dictationFrames()
        let canvas = CGSize(width: 400, height: 160)
        let cardSize = CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
        let cardRect = CGRect(
            x: (canvas.width - cardSize.width) / 2,
            y: (canvas.height - cardSize.height) / 2,
            width: cardSize.width,
            height: cardSize.height
        )
        let moments: [(String, Double)] = [("t1.50", 1.50), ("t6.96", 6.96)]
        var readings: [String: RingReading] = [:]
        for (backdrop, luma) in [("bright", 0.92), ("dark", 0.12)] {
            let reference = try captureGlass(
                backdrop: luma,
                overlay: HUDSurface(material: .glass)
                    .frame(width: cardSize.width, height: cardSize.height),
                size: canvas
            )
            for (name, time) in moments {
                let frame = frames[
                    min(frames.count - 1, Int((time * Waveform.sampleRate).rounded()))
                ]
                let picture = try captureGlass(
                    backdrop: luma,
                    overlay: card(frame, time: time, material: .glass),
                    size: canvas
                )
                let url = directory.appendingPathComponent("halo-glass-\(backdrop)-\(name).png")
                XCTAssertTrue(
                    WindowCapture.write(picture, to: url),
                    "\(url.lastPathComponent) was not written"
                )
                // The material and the mask are read pixel for pixel from the
                // reference, so the two captures have to be the same window at
                // the same scale. A window server that hands back a picture of
                // one of them at another size is a broken measurement rather
                // than a ring, and it is caught here.
                XCTAssertEqual(
                    reference.width,
                    picture.width,
                    "the reference and the card are captures at different scales"
                )
                XCTAssertEqual(
                    reference.height,
                    picture.height,
                    "the reference and the card are captures at different scales"
                )
                guard reference.width == picture.width,
                      reference.height == picture.height
                else { continue }
                let reading = ringReading(
                    picture,
                    against: reference,
                    cardRect: cardRect,
                    canvasSize: canvas,
                    frame: frame,
                    time: time
                )
                readings["\(backdrop)-\(name)"] = reading
                print(String(
                    format: "RING glass %@ %@: M1 %.3f, M2 %d px median %.3f, "
                        + "M3 %.3f, M4 %.3f/%.3f = %.2f",
                    backdrop,
                    name,
                    reading.contrast,
                    reading.count,
                    reading.median,
                    reading.warmth,
                    reading.near,
                    reading.far,
                    reading.near / reading.far
                ))
            }
        }

        // The card over the reference photograph's blue wave, at the loudest
        // moment, which is the frame the owner read the rings on.
        if let wave = Self.waveImage {
            let room = CGSize(
                width: cardSize.width + 2 * Self.waveMargin,
                height: cardSize.height + 2 * Self.waveMargin
            )
            let frame = frames[
                min(frames.count - 1, Int((6.96 * Waveform.sampleRate).rounded()))
            ]
            let view = ZStack {
                Image(decorative: wave, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: room.width, height: room.height)
                    .clipped()
                card(frame, time: 6.96, material: .glass)
            }
            .frame(width: room.width, height: room.height)
            let window = WindowCapture.show(view, size: room)
            defer { WindowCapture.hide(window) }
            if let picture = WindowCapture.capture(window) {
                try WindowCapture.requireUsableCapture(picture)
                let url = directory.appendingPathComponent("wave-halo-t6.96.png")
                XCTAssertTrue(
                    WindowCapture.write(picture, to: url),
                    "\(url.lastPathComponent) was not written"
                )
                print(String(
                    format: "RING wave t6.96 %dx%d px at %.1fx",
                    picture.width,
                    picture.height,
                    Double(picture.width) / Double(room.width)
                ))
            }
        } else {
            print("RING wave t6.96 was not written: the reference photograph is not there")
        }

        let loudBright = try XCTUnwrap(readings["bright-t6.96"], "the bright frame was not measured")
        let firstBright = try XCTUnwrap(readings["bright-t1.50"], "the first phrase was not measured")
        let loudDark = try XCTUnwrap(readings["dark-t6.96"], "the dark frame was not measured")

        XCTAssertGreaterThanOrEqual(
            loudBright.contrast,
            2.45,
            "the rings read at \(loudBright.contrast):1 at the loudest moment on the bright page"
        )
        XCTAssertGreaterThanOrEqual(
            loudBright.median,
            1.60,
            "the rings' median ink is \(loudBright.median) on the bright page"
        )
        XCTAssertGreaterThanOrEqual(
            firstBright.contrast,
            2.95,
            "the rings read at \(firstBright.contrast):1 at the first phrase on the bright page"
        )
        XCTAssertGreaterThanOrEqual(
            loudDark.warmth,
            0.20,
            "the rings' warmth is \(loudDark.warmth) on the dark page, which is white rather than amber"
        )
        XCTAssertGreaterThanOrEqual(
            loudBright.near / loudBright.far,
            1.5,
            "the near half of the rings carries only \(loudBright.near / loudBright.far) "
                + "times the far half's ink on the bright page"
        )
    }

    /// The reference photograph's blue wave, cut the way the lift suite cuts it.
    static let waveImage: CGImage? = {
        guard let image = NSImage(contentsOf: URL(fileURLWithPath: "/tmp/dot-ref-glass.png"))
        else { return nil }
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else { return nil }
        return cgImage.cropping(to: CGRect(x: 0, y: 520, width: 560, height: 460))
    }()

    /// The margin the wave frame keeps around the card, in points.
    nonisolated static let waveMargin: CGFloat = 60
}

// MARK: - The scope of the ring's ink

extension HaloMotionTests {
    /// The two moments the scope of the change is proved on.
    nonisolated static let ringMoments: [Double] = [1.50, 6.96]
    /// The recording card's size, in points.
    nonisolated static var ringCardSize: CGSize {
        CGSize(width: HUDState.recordingWidth, height: HUDState.recordingHeight)
    }
    /// A style's own canvas, in points, the one the lift suite hashes.
    nonisolated static let ringCanvasSize = CGSize(width: 102, height: 26)

    /// The ring's lift and gain reach the glass material and nothing else.
    ///
    /// The black card's rings are the ink every style was drawn for, and the two
    /// values correct for the light the clear glass puts behind the canvas, so an
    /// opaque card is the same picture at the values the card ships and at the
    /// neutral pair. The same holds for the two styles the change does not touch:
    /// their glass frames are the same bytes at any value, which is what keeps a
    /// number meant for the halo from repainting a bar or a filament.
    ///
    /// The frames are also compared byte for byte with the frames the tree before
    /// the change drew, when `DOT_HALO_BASE_FRAMES` or the default directory holds
    /// them: the black card frames of the four styles this change does not
    /// repaint, at the two judged moments, and the glass canvases of two of them.
    /// The halo's own pair is printed beside them rather than compared, because
    /// the halo is the style the change is for. The comparison is skipped
    /// when those frames are not on the machine, the way the reference photograph
    /// is, because they are a record of one tree rather than a fixture of this one.
    func testTheRingInkIsGlassOnly() throws {
        var snapshots: [Double: VisualizerRedesignTests.Snapshot] = [:]
        for time in Self.ringMoments {
            snapshots[time] = VisualizerRedesignTests.previewSnapshot(at: time)
        }

        for time in Self.ringMoments {
            let snapshot = try XCTUnwrap(snapshots[time])
            let black = try frameHash(
                cardFrame(snapshot, .haloEdge, time: time, material: .black),
                size: Self.ringCardSize
            )
            for (lift, gain) in [(0.0, 1.0), (1.0, 0.0), (0.0, 4.0)] {
                let moved = try frameHash(
                    cardFrame(
                        snapshot,
                        .haloEdge,
                        time: time,
                        material: .black,
                        ringLift: lift,
                        ringGain: gain
                    ),
                    size: Self.ringCardSize
                )
                XCTAssertEqual(
                    black,
                    moved,
                    "the black halo moved at a lift of \(lift) and a gain of \(gain)"
                )
            }
            let glass = try frameHash(
                cardFrame(snapshot, .haloEdge, time: time, material: .glass),
                size: Self.ringCardSize
            )
            let neutral = try frameHash(
                cardFrame(
                    snapshot,
                    .haloEdge,
                    time: time,
                    material: .glass,
                    ringLift: 0,
                    ringGain: 1
                ),
                size: Self.ringCardSize
            )
            XCTAssertNotEqual(
                glass,
                neutral,
                "the glass halo drew the same frame at the neutral ring values"
            )
            print("GUARD halo t\(time): black \(black), glass \(glass) against \(neutral) at neutral")
        }

        for visualizer in [HUDVisualizer.stretch, .filament] {
            for time in Self.ringMoments {
                let snapshot = try XCTUnwrap(snapshots[time])
                let glass = try frameHash(
                    canvasFrame(snapshot, visualizer, time: time),
                    size: Self.ringCanvasSize
                )
                let moved = try frameHash(
                    canvasFrame(
                        snapshot,
                        visualizer,
                        time: time,
                        ringLift: 1,
                        ringGain: 4
                    ),
                    size: Self.ringCanvasSize
                )
                XCTAssertEqual(glass, moved, "\(visualizer) read the halo's ring values")
                print("GUARD \(visualizer) glass t\(time): \(glass) at every ring value")
            }
        }

        try compareWithTheBaseFrames(snapshots: snapshots)
    }

    /// The frames this tree draws against the frames the tree before it drew.
    func compareWithTheBaseFrames(
        snapshots: [Double: VisualizerRedesignTests.Snapshot]
    ) throws {
        guard let path = DotMigration.environment("HALO_BASE_FRAMES") else {
            print("GUARD HALO_BASE_FRAMES is not set, so nothing was compared")
            return
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            print("GUARD base frames are not at \(directory.path), so nothing was compared")
            return
        }
        for visualizer in HUDVisualizer.allCases {
            for time in Self.ringMoments {
                let snapshot = try XCTUnwrap(snapshots[time])
                let name = String(format: "black-%@-t%.2f.png", Self.slug(visualizer), time)
                let mine = try frameData(
                    cardFrame(snapshot, visualizer, time: time, material: .black),
                    size: Self.ringCardSize
                )
                let theirs = try Data(contentsOf: directory.appendingPathComponent(name))
                print("GUARD \(name) work \(Self.hash(mine)) base \(Self.hash(theirs))")
                if visualizer != .haloEdge {
                    XCTAssertEqual(
                        Self.hash(mine),
                        Self.hash(theirs),
                        "\(name) is not the frame the tree before the change drew"
                    )
                }
            }
        }
        for visualizer in [HUDVisualizer.stretch, .filament] {
            for time in Self.ringMoments {
                let snapshot = try XCTUnwrap(snapshots[time])
                let name = String(format: "glass-%@-t%.2f.png", Self.slug(visualizer), time)
                let mine = try frameData(
                    canvasFrame(snapshot, visualizer, time: time),
                    size: Self.ringCanvasSize
                )
                let theirs = try Data(contentsOf: directory.appendingPathComponent(name))
                print("GUARD \(name) work \(Self.hash(mine)) base \(Self.hash(theirs))")
                XCTAssertEqual(
                    Self.hash(mine),
                    Self.hash(theirs),
                    "\(name) is not the frame the tree before the change drew"
                )
            }
        }
    }

    /// The file-name stem of a visualizer.
    static func slug(_ visualizer: HUDVisualizer) -> String {
        visualizer.title.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// The real recording card of one style, at one moment, on one material.
    ///
    /// The ring's values are passed only when a test asks for a pair of its own,
    /// so the frame the card ships is drawn exactly as the app draws it.
    /// The card's model for one style at one moment.
    static func cardModel(
        _ snapshot: VisualizerRedesignTests.Snapshot,
        _ visualizer: HUDVisualizer,
        time: Double,
        material: HUDMaterial
    ) -> HUDModel {
        let model = HUDModel()
        model.isVisible = true
        model.presence = 1
        model.content = 1
        model.material = material
        model.mode = .recording(elapsed: "0:07")
        model.cardSize = ringCardSize
        model.visualizer = visualizer
        model.history = snapshot.history
        model.spectrumHistory = snapshot.spectrum
        model.ceiling = snapshot.ceiling
        model.level = snapshot.level
        model.phase = snapshot.phase
        model.time = time
        model.pulse = 0.25
        model.reveal = 1
        return model
    }

    /// The real recording card of one style, at one moment, on one material.
    @ViewBuilder
    func cardFrame(
        _ snapshot: VisualizerRedesignTests.Snapshot,
        _ visualizer: HUDVisualizer,
        time: Double,
        material: HUDMaterial,
        ringLift: Double? = nil,
        ringGain: Double? = nil
    ) -> some View {
        let model = Self.cardModel(snapshot, visualizer, time: time, material: material)
        Group {
            if let ringLift, let ringGain {
                HUDView(
                    model: model,
                    showsShadow: false,
                    animated: false,
                    actions: HUDPreview.previewActions,
                    glassRingLift: ringLift,
                    glassRingInkGain: ringGain
                )
            } else {
                HUDView(
                    model: model,
                    showsShadow: false,
                    animated: false,
                    actions: HUDPreview.previewActions
                )
            }
        }
        .frame(width: Self.ringCardSize.width, height: Self.ringCardSize.height)
    }

    /// One style's canvas on the glass material, at twice the points.
    func canvasFrame(
        _ snapshot: VisualizerRedesignTests.Snapshot,
        _ visualizer: HUDVisualizer,
        time: Double,
        ringLift: Double? = nil,
        ringGain: Double? = nil
    ) -> some View {
        HUDWaveform(
            visualizer: visualizer,
            halfHeights: [],
            history: snapshot.history,
            spectrumHistory: snapshot.spectrum,
            phase: snapshot.phase,
            time: time,
            level: snapshot.level,
            pulse: 0.25,
            ceiling: snapshot.ceiling,
            reveal: 1,
            material: .glass,
            glassLift: HUDTheme.visualizerGlassLift,
            glassRingLift: ringLift ?? HUDWaveform.Halo.glassRingLift,
            glassRingInkGain: ringGain ?? HUDWaveform.Halo.glassRingInkGain
        )
        .frame(width: Self.ringCanvasSize.width, height: Self.ringCanvasSize.height)
    }

    /// One view's PNG bytes at twice the points.
    func frameData(_ content: some View, size: CGSize) throws -> Data {
        let bitmap = try rasterise(content, size: size)
        return try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:]),
            "the frame could not be written as a PNG"
        )
    }

    /// One view's SHA-256, so two frames can be compared as files.
    func frameHash(_ content: some View, size: CGSize) throws -> String {
        Self.hash(try frameData(content, size: size))
    }
}

// MARK: - The ray energy ladder

extension HaloMotionTests {
    /// The rays' contrast against the gaps between them, at a core energy.
    ///
    /// Six rays, a 3 x 3 pixel patch at 1.35 core radii on each ray axis and the
    /// same patch at the half-way angle between two rays, averaged over the rays.
    /// The three controls are returned with it so a caller can prove they did not
    /// move.
    ///
    /// - Parameters:
    ///   - history: the envelope, oldest first, unscaled.
    ///   - ceiling: the take's ceiling, for the tint.
    ///   - time: the clock, in seconds, the rays are read at.
    ///   - spectrum: the bands of the frame, which the core does not read.
    ///   - phase: where inside the newest sample the frame sits.
    /// - Returns: the ray ink, the gap ink, and the radius, glow and centre.
    func rayContrast(
        history: [Double],
        ceiling: Double,
        time: Double,
        spectrum: [AudioSpectrumFrame],
        phase: Double
    ) throws -> (ray: Double, gap: Double, radius: Double, glow: Double, centre: Double, energy: Double) {
        let size = Self.cardCanvas
        let rays = HUDWaveform.Halo.rayCount
        let frame = Frame(
            history: history,
            spectrum: spectrum,
            ceiling: ceiling,
            level: history.last ?? 0,
            phase: phase
        )
        let bitmap = try rasterise(coreOnly(frame, time: time, size: size), size: size)
        let pixels = Double(bitmap.pixelsWide) / Double(size.width)
        let centre = (x: Double(bitmap.pixelsWide) / 2, y: Double(bitmap.pixelsHigh) / 2)
        let radius = Double(HUDWaveform.Halo.elasticCoreRadius(history: history, time: time))
        let turn = 2 * Double.pi * time / HUDWaveform.Halo.rayTurnSeconds
        func patch(_ multiple: Double, _ angle: Double) -> Double {
            let x = Int((centre.x + cos(angle) * multiple * radius * pixels).rounded())
            let y = Int((centre.y + sin(angle) * multiple * radius * pixels).rounded())
            var total = 0.0
            var count = 0
            for dy in -1...1 {
                for dx in -1...1 {
                    total += alpha(bitmap, x + dx, y + dy)
                    count += 1
                }
            }
            return count == 0 ? 0 : total / Double(count)
        }
        var rayInk = 0.0
        var gapInk = 0.0
        for ray in 0..<rays {
            let axis = turn + 2 * Double.pi * Double(ray) / Double(rays)
            rayInk += patch(1.35, axis)
            gapInk += patch(1.35, axis + Double.pi / Double(rays))
        }
        return (
            rayInk / Double(rays),
            gapInk / Double(rays),
            radius,
            (0..<8).map { patch(1.6, Double($0) * Double.pi / 4) }.reduce(0, +) / 8,
            luminance(bitmap, Int(centre.x), Int(centre.y)),
            HUDWaveform.Halo.coreEnergy(history: history)
        )
    }

    /// The ray's ink against the exponent its energy is raised to.
    ///
    /// The rays are inked from ``HUDWaveform/Halo/coreEnergy(history:)``, which is
    /// ``VisualizerMath/displayEnergy(_:)`` of the newest six samples of the voice.
    /// Before the height was made absolute that number was stretched towards the
    /// take's own peak, and the ray's contrast floor of `0.08` was measured on the
    /// stretched picture. On the absolute number the same fixture inks `0.0510`, so
    /// the floor is a question about the ray's curve rather than about the height.
    ///
    /// This is a measurement, not a decision: for each exponent `g` it reports the
    /// ray's contrast in the fixture ``testTheCoreGlowsAndShines`` measures, the
    /// same contrast at five steady loudnesses, and whether the two loudest are
    /// apart by enough to be told apart. The code ships `g = 1.00`, which is the
    /// energy as it is.
    func testTheRayEnergyLadder() throws {
        let variant = ProcessInfo.processInfo.environment["DOT_RAY_VARIANT"] ?? "A1"
        let time = 6.96
        let rays = HUDWaveform.Halo.rayCount
        let window = LevelScale.window(for: nil)
        let frames = Self.dictationFrames()
        let frame = frames[min(frames.count - 1, Int((time * Waveform.sampleRate).rounded()))]
        print(String(format: "RAY variant %@ rays %d window %.2f...%.2f dBFS", variant, rays, window.bottomDBFS, window.topDBFS))

        /// One input's row, from the shared harness.
        func row(_ name: String, history: [Double], ceiling: Double) throws
            -> (ray: Double, gap: Double, radius: Double, glow: Double, centre: Double) {
            let measured = try rayContrast(
                history: history,
                ceiling: ceiling,
                time: time,
                spectrum: frame.spectrum,
                phase: frame.phase
            )
            print(String(
                format: "RAY %@ %@ r %.4f ceiling %.4f ray %.4f gap %.4f contrast %.4f radius %.3f glow %.4f centre %.4f",
                variant, name, measured.energy, ceiling, measured.ray, measured.gap,
                measured.ray - measured.gap, measured.radius, measured.glow, measured.centre
            ))
            return (measured.ray, measured.gap, measured.radius, measured.glow, measured.centre)
        }

        let fixture = try row("fixture", history: frame.history, ceiling: frame.ceiling)
        var rows: [(name: String, ray: Double, gap: Double, radius: Double, glow: Double, centre: Double)] = []
        for decibels in [-40.0, -30, -20, -10, 0] {
            let level = LevelScale.level(decibels: decibels, window: window)
            let histories = [Double](repeating: level, count: Waveform.historyLength)
            let measured = try row(String(format: "%.0f", decibels), history: histories, ceiling: 1)
            rows.append((String(format: "%.0f", decibels), measured.ray, measured.gap, measured.radius, measured.glow, measured.centre))
        }
        let apart = rows[4].ray - rows[3].ray
        print(String(format: "RAY %@ summary fixture contrast %.4f 0vs-10 %.4f %@", variant,
                     fixture.ray - fixture.gap, apart, apart >= 0.03 ? "apart" : "not apart"))
        XCTAssertEqual(rows.count, 5, "a loudness was not measured")
    }
}
