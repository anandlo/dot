import DotCore
import SwiftUI

/// The audio visualizer in the recording HUD card.
///
/// Supports 5 distinct modern design styles configurable by the user:
/// - `.stretch`: Resting dots that stretch into organic capsules on springs.
/// - `.filament`: Precision discrete capsule bars scrolling in phase.
/// - `.silk`: Multi-frequency harmonic braided ribbons.
/// - `.matrix`: Real-time dot-matrix spectrogram.
/// - `.haloEdge`: Minimal center line with perimeter conic aura.
struct HUDWaveform: View {
    var visualizer: HUDVisualizer = .stretch
    /// The half height of every column, in points.
    let halfHeights: [CGFloat]
    /// Raw 60 Hz envelope history (`0` to `1`), oldest first.
    var history: [Double] = []
    /// Real-time 60 Hz 5-band acoustic spectrum history, oldest first.
    var spectrumHistory: [AudioSpectrumFrame] = []
    /// Sub-sample phase (`0` to `<1`) for sub-pixel scrolling.
    var phase: Double = 0
    /// Continuous unwrapped time in seconds.
    var time: Double = 0
    /// The voice level, from `0` to `1`.
    var level: Double = 0
    /// The phase of the live animation, from `0` to `1`.
    var pulse: Double = 0

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

    /// Returns the `0...1` envelope sample `offsetFromNewest` ticks ago (`0` = newest).
    private func sample(offsetFromNewest offset: Int) -> Double {
        if !history.isEmpty {
            let idx = history.count - 1 - offset
            guard idx >= 0, idx < history.count else { return 0 }
            return min(1.0, max(0.0, history[idx]))
        }
        guard !halfHeights.isEmpty else { return level }
        let idx = max(0, min(halfHeights.count - 1, halfHeights.count - 1 - offset))
        let maxH = max(1.0, (HUDTheme.waveformHeight / 2) - Waveform.minimumHalfHeight)
        return Double(min(1.0, max(0.0, (halfHeights[idx] - Waveform.minimumHalfHeight) / maxH)))
    }

    private var effectiveTime: Double {
        time > 0 ? time : pulse * 4.4
    }

    // MARK: - 02 Stretch (Hero Pick)

    private func drawStretch(context: GraphicsContext, size: CGSize) {
        let count = 15
        let bw: CGFloat = 3.0
        let gap: CGFloat = 4.0
        let total = CGFloat(count) * bw + CGFloat(count - 1) * gap
        let x0 = (size.width - total) / 2
        let mid = size.height / 2
        let reach = mid - 1.2
        let center = Double(count - 1) / 2.0

        // Extract real multi-band energies from the live microphone trajectory:
        // - Low band (vowel body): smoothed over recent ~80ms
        // - Mid band (formants): smoothed over recent ~50ms
        // - High band (sibilants/transients): frame-to-frame voice flux + level
        let s0 = sample(offsetFromNewest: 0)
        let s1 = sample(offsetFromNewest: 2)
        let s2 = sample(offsetFromNewest: 4)
        let s3 = sample(offsetFromNewest: 6)
        let s4 = sample(offsetFromNewest: 8)
        let liveLevel = max(level, s0)
        let lowBand = (s0 + s1 + s2 + s3 + s4) / 5.0
        let midBand = (s0 + s1 + s2) / 3.0
        let flux = min(1.0, abs(s0 - s1) * 2.2 + abs(s1 - s2) * 1.4)
        let highBand = min(1.0, flux * 0.55 + liveLevel * 0.45)

        for index in 0..<count {
            let distFromCenter = abs(index - count / 2)
            let dist = center > 0 ? abs(Double(index) - center) / center : 0
            let bell = exp(-dist * dist * 1.45)

            // Each bar samples the actual live audio history radiating outward from center,
            // so motion is 100% driven by real voice energy rather than a hardcoded oscillator.
            let delayedSample = sample(offsetFromNewest: distFromCenter * 2)
            let neighborSample = sample(offsetFromNewest: max(0, distFromCenter * 2 - 1))
            let localVoice = 0.65 * delayedSample + 0.35 * neighborSample

            // Blend low (center), mid (shoulders), and high (outer edges) with local voice history
            let bandEnergy = bell * max(liveLevel, lowBand) * 0.65
                + localVoice * 0.45
                + (1.0 - abs(dist - 0.45)) * 0.30 * midBand
                + pow(dist, 0.85) * 0.35 * highBand

            // Subtle spatial formant contour per bar (static harmonic weighting, only active when speaking)
            let harmonicWeight = 0.84 + 0.16 * cos(Double(index) * 1.15)
            let drive = min(1.0, max(0.0, bandEnergy * harmonicWeight))
            let curved = drive > 0.015 ? pow(CGFloat(drive), 0.85) : 0
            let hh = max(bw / 2, bw / 2 + curved * (reach - bw / 2))

            let rect = CGRect(
                x: x0 + CGFloat(index) * (bw + gap),
                y: mid - hh,
                width: bw,
                height: hh * 2
            )
            let path = Path(roundedRect: rect, cornerRadius: bw / 2)

            let alpha = 0.36 + 0.64 * Double(curved)
            let color = curved > 0.74
                ? HUDTheme.accentTip.opacity(alpha)
                : HUDTheme.accent.opacity(alpha)
            context.fill(path, with: .color(color))
        }
    }

    // MARK: - 01 Filament (Pro Audio)

    private func drawFilament(context: GraphicsContext, size: CGSize) {
        let bw: CGFloat = 2.4
        let pitch: CGFloat = 4.8
        let mid = size.height / 2
        let reach = mid - 1.4
        let bars = max(1, Int(ceil(size.width / pitch)))
        let histCount = max(1, history.count)

        for index in 0..<bars {
            let x = size.width - bw - CGFloat(index) * pitch
            if x < -bw { break }

            // Direct 1-to-1 time-scroll mapping (2 ticks = 33ms per bar) so bars
            // scroll naturally from right to left across the entire HUD island.
            let centerOffset = min(max(0, histCount - 1), index * 2)
            let a0 = sample(offsetFromNewest: centerOffset)
            let a1 = sample(offsetFromNewest: min(histCount - 1, centerOffset + 1))
            var raw = max(a0, (a0 + a1) * 0.5)
            if !spectrumHistory.isEmpty {
                let sIdx = max(0, spectrumHistory.count - 1 - min(spectrumHistory.count - 1, index * 2))
                let sp = spectrumHistory[sIdx]
                let specPeak = max(sp.bands.0, sp.bands.1, sp.bands.2, sp.bands.3, sp.bands.4)
                raw = max(raw, specPeak)
            }

            let val = min(1.0, max(0.0, raw))
            let hh = val > 0.015 ? max(1.2, pow(CGFloat(val), 0.85) * reach) : 1.2

            let rect = CGRect(x: x, y: mid - hh, width: bw, height: hh * 2)
            let path = Path(roundedRect: rect, cornerRadius: bw / 2)
            let opacity = val > 0.02 ? (0.65 + 0.35 * val) : 0.32
            context.fill(path, with: .color(HUDTheme.accentTip.opacity(opacity)))
        }
    }

    // MARK: - 04 Silk (Harmonic Ribbons)

    private func drawSilk(context: GraphicsContext, size: CGSize) {
        let mid = size.height / 2
        let reach = mid - 1.8
        let t = effectiveTime

        let s0 = max(level, sample(offsetFromNewest: 0))
        let s2 = sample(offsetFromNewest: 3)
        let s5 = sample(offsetFromNewest: 7)
        let flux = min(1.0, abs(s0 - s2) * 2.0 + s0 * 0.65)

        // Ribbon amplitude is driven directly by live voice level (rests flat in silence),
        // with calm, natural phase drift rather than fast hardcoded oscillation.
        let ribbons: [(freq: Double, speed: Double, band: Double, isAmber: Bool, alpha: Double, width: CGFloat)] = [
            (1.20, 0.42, s0 * 0.92, false, 0.78, 1.5),
            (1.95, -0.50, (s0 + s2) * 0.48, false, 0.46, 1.15),
            (2.85, 0.65, flux * 0.80, false, 0.34, 1.0),
            (1.55, -0.35, (s0 + s5) * 0.52, true, 0.84, 1.4),
        ]

        var additive = context
        additive.blendMode = .plusLighter

        let steps = max(24, Int(size.width / 2.0))
        for (idx, ribbon) in ribbons.enumerated() {
            var path = Path()
            let amp = CGFloat(min(1.0, ribbon.band)) * reach
            let ph = t * ribbon.speed + Double(idx) * 1.1

            for s in 0...steps {
                let u = Double(s) / Double(steps)
                let x = CGFloat(u) * size.width
                // Pinned at left and right edges with a smooth bell window
                let win = pow(sin(Double.pi * u), 2.2)
                let wave = 0.72 * sin(u * Double.pi * 2.0 * ribbon.freq * 2.0 + ph)
                    + 0.28 * cos(u * Double.pi * 3.4 - ph * 0.7)
                let y = mid + amp * CGFloat(win * wave)

                if s == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            let color = ribbon.isAmber
                ? HUDTheme.live.opacity(ribbon.alpha)
                : HUDTheme.accent.opacity(ribbon.alpha)
            additive.stroke(path, with: .color(color), lineWidth: ribbon.width)
        }
    }

    // MARK: - 05 Matrix (Spectrogram Grid)

    private func drawMatrix(context: GraphicsContext, size: CGSize) {
        let rows = 5
        let colPitch: CGFloat = 4.6
        let cols = max(1, Int(ceil(size.width / colPitch)))
        let rowPitch = size.height / CGFloat(rows)
        let histCount = max(1, history.count)
        let specCount = spectrumHistory.count

        let brightCore = Color.white
        let brightAmber = Color(red: 1.0, green: 0.80, blue: 0.28)
        let brightPorcelain = Color(red: 1.0, green: 0.985, blue: 0.96)

        for col in 0..<cols {
            let x = size.width - colPitch / 2.0 - CGFloat(col) * colPitch
            if x < -colPitch { break }

            // Direct 1-to-1 time-scroll mapping (2 ticks = 33ms per column) so every
            // syllable scrolls naturally from right to left across the entire HUD island
            // without warping when the HUD widens.
            let baseOffset = min(max(0, histCount - 1), col * 2)

            // Read the real 5-band acoustic spectrum frame recorded at this exact moment in time
            let specFrame: AudioSpectrumFrame? = {
                guard specCount > 0 else { return nil }
                let idx = specCount - 1 - min(specCount - 1, col * 2)
                let idxNext = max(0, idx - 1)
                let a = spectrumHistory[idx]
                let b = spectrumHistory[idxNext]
                return AudioSpectrumFrame(bands: (
                    max(a.bands.0, (a.bands.0 + b.bands.0) * 0.5),
                    max(a.bands.1, (a.bands.1 + b.bands.1) * 0.5),
                    max(a.bands.2, (a.bands.2 + b.bands.2) * 0.5),
                    max(a.bands.3, (a.bands.3 + b.bands.3) * 0.5),
                    max(a.bands.4, (a.bands.4 + b.bands.4) * 0.5)
                ))
            }()

            let s0 = sample(offsetFromNewest: baseOffset)
            let s1 = sample(offsetFromNewest: min(histCount - 1, baseOffset + 1))
            let s2 = sample(offsetFromNewest: min(histCount - 1, baseOffset + 2))
            let s3 = sample(offsetFromNewest: min(histCount - 1, baseOffset + 4))
            let instEnergy = max(s0, (s0 + s1) * 0.5)
            let transientAttack = min(1.0, abs(s0 - s1) * 3.8 + abs(s1 - s2) * 2.4)
            let lowBody = (s0 + s1 + s2 + s3) * 0.25

            for row in 0..<rows {
                let y = rowPitch * (CGFloat(row) + 0.5)

                // Use the genuine 5-band frequency spectrum from the microphone tap,
                // where all 5 rows (0: high sibilance, 1: upper formants, 2: core presence,
                // 3: vowel body, 4: chest fundamental) have equal opportunity to light up
                // based on the actual pitch and consonant/vowel content of the user's voice!
                let bandWeight: Double
                if let spec = specFrame, (spec.bands.0 + spec.bands.1 + spec.bands.2 + spec.bands.3 + spec.bands.4) > 0.01 {
                    bandWeight = spec[row]
                } else {
                    switch row {
                    case 0:
                        bandWeight = transientAttack * 0.70 + instEnergy * 0.35
                    case 1:
                        bandWeight = instEnergy * 0.65 + transientAttack * 0.30
                    case 2:
                        bandWeight = instEnergy * 0.75
                    case 3:
                        bandWeight = lowBody * 0.70 + instEnergy * 0.25
                    default:
                        bandWeight = lowBody * 0.75
                    }
                }

                let rawEnergy = min(1.0, max(0.0, bandWeight))
                let cellEnergy = CGFloat(rawEnergy > 0.02 ? pow(rawEnergy, 1.15) : 0.0)
                let radius = 0.75 + cellEnergy * 1.35

                // Soft luminous bloom behind peak resonant cells
                if cellEnergy > 0.55 {
                    let glowRadius = radius * 1.85
                    let glowRect = CGRect(
                        x: x - glowRadius,
                        y: y - glowRadius,
                        width: glowRadius * 2,
                        height: glowRadius * 2
                    )
                    let glowPath = Path(ellipseIn: glowRect)
                    let glowColor = cellEnergy > 0.72 ? brightAmber : brightPorcelain
                    let glowAlpha = Double((cellEnergy - 0.40) * 0.40)
                    context.fill(glowPath, with: .color(glowColor.opacity(glowAlpha)))
                }

                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                let path = Path(ellipseIn: rect)

                if cellEnergy > 0.72 {
                    // Formant harmonic peak: radiant amber/gold
                    let alpha = Double(min(1.0, 0.85 + 0.15 * cellEnergy))
                    context.fill(path, with: .color(brightAmber.opacity(alpha)))
                    if cellEnergy > 0.86 {
                        let coreR = radius * 0.48
                        let coreRect = CGRect(x: x - coreR, y: y - coreR, width: coreR * 2, height: coreR * 2)
                        context.fill(
                            Path(ellipseIn: coreRect),
                            with: .color(brightCore.opacity(0.95))
                        )
                    }
                } else if cellEnergy > 0.35 {
                    // Vocal presence & harmonics: warm bright ivory / cream
                    let alpha = Double(min(1.0, 0.60 + 0.35 * cellEnergy))
                    context.fill(path, with: .color(brightPorcelain.opacity(alpha)))
                } else if cellEnergy > 0.12 {
                    // Ambient voice activity & room decay: subtle porcelain
                    let alpha = Double(min(1.0, 0.35 + 0.35 * cellEnergy))
                    context.fill(path, with: .color(brightPorcelain.opacity(alpha)))
                } else {
                    // Quiet resting grid dots
                    context.fill(path, with: .color(brightPorcelain.opacity(0.20)))
                }
            }
        }
    }

    // MARK: - 07 Halo Edge Center Line

    private func drawHaloEdgeCenter(context: GraphicsContext, size: CGSize) {
        let mid = size.height / 2
        let liveLevel = CGFloat(max(level, sample(offsetFromNewest: 0)))

        // Subtle axial hairline
        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: mid))
        axis.addLine(to: CGPoint(x: size.width, y: mid))
        context.stroke(axis, with: .color(HUDTheme.ink.opacity(0.14 + Double(liveLevel) * 0.14)), lineWidth: 1)

        // Quiet micro-beads along the center axis driven purely by live audio history
        let count = 13
        let step = size.width / CGFloat(count + 1)
        let center = CGFloat(count + 1) / 2.0
        for i in 1...count {
            let x = CGFloat(i) * step
            let dist = abs(CGFloat(i) - center) / center
            let bell = exp(-dist * dist * 1.6)
            let localSample = CGFloat(sample(offsetFromNewest: abs(i - 7) * 2))
            let energy = max(liveLevel * 0.6 + localSample * 0.4, localSample) * bell
            let r = 0.9 + energy * 1.35
            let dot = Path(ellipseIn: CGRect(x: x - r, y: mid - r, width: r * 2, height: r * 2))
            let color = energy > 0.48
                ? HUDTheme.live.opacity(0.45 + Double(energy) * 0.55)
                : HUDTheme.accent.opacity(0.28 + Double(energy) * 0.60)
            context.fill(dot, with: .color(color))
        }
    }
}

/// The glowing conic perimeter border used by the Halo Edge visualizer.
///
/// Placed outside `.clipShape` on `HUDView` so the outer amber/porcelain bloom
/// radiates cleanly around the island's silhouette and scales with voice level.
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
                .init(color: HUDTheme.accent.opacity(0.90 * intensity), location: 0.30),
                .init(color: HUDTheme.live.opacity(0.08 * intensity), location: 0.48),
                .init(color: HUDTheme.accent.opacity(0.75 * intensity), location: 0.68),
                .init(color: HUDTheme.live.opacity(0.92 * intensity), location: 0.85),
                .init(color: HUDTheme.live.opacity(0.05 * intensity), location: 1.00),
            ]),
            center: .center,
            angle: .degrees(angleDegrees)
        )
    }

    var body: some View {
        ZStack {
            // Soft outer & inner conic bloom
            RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
                .stroke(conicGradient, lineWidth: 2.2 + CGFloat(level) * 2.6)
                .blur(radius: 3.5 + CGFloat(level) * 5.5)
                .opacity(0.55 + level * 0.45)

            // Crisp perimeter light filament
            RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
                .strokeBorder(conicGradient, lineWidth: 1.35 + CGFloat(level) * 1.05)
        }
        .allowsHitTesting(false)
    }
}
