import DotCore
import SwiftUI

/// A voice, drawn as ink laid down by a moving nib.
///
/// Not a row of bars and not a waveform band with a shadow. Three attempts got
/// here, and each failure is a rule:
///
/// - **Bars are an equaliser.** Every bar is an object, so the eye counts objects
///   instead of following a signal, and it reads as lines bouncing.
/// - **One smooth envelope reads as a lozenge.** A band whose width swells once
///   across the whole strip looks like a landscape, because speech is not one
///   swell: it is words with silence between them.
/// - **A line alone reads as a scribble.** Which is what this replaced.
///
/// So the drawing is clusters. A word is a burst of ink; the pauses between words
/// collapse the stroke to a hairline that never breaks, because the app is still
/// listening; and the ink pools at the centre line and thins toward the edges the
/// way a pen pools where it turns. The nib is the app's dot, and it is the thing
/// doing the writing.
///
/// The oldest ink has dried, so the stroke fades toward the far end. That fade is
/// the only thing in the drawing that is not the signal.
struct VoiceInk: View {
    /// Whether the nib moves. Headless renders turn it off.
    var animated = true
    /// The ink's colour. The card is always dark, so the drawing cannot take the
    /// window's ink: on a light window that would be dark ink on a dark card.
    var tint: Color = DotTheme.ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Group {
                if animated && !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        canvas(size: size, time: context.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    // Reduce Motion, and every render, get one held moment.
                    canvas(size: size, time: VoiceInkFigure.stillTime)
                }
            }
            // Ink dries: the older end of the stroke is lighter. A mask is used
            // rather than a thinner ink so the same drawing works in both
            // appearances without knowing which one it is in.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.46), location: 0),
                        .init(color: .black.opacity(0.90), location: 0.46),
                        .init(color: .black, location: 0.78)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        .accessibilityHidden(true)
    }

    private func canvas(size: CGSize, time: Double) -> some View {
        Canvas { context, canvasSize in
            guard canvasSize.width > 16, canvasSize.height > 12 else { return }
            let bw: CGFloat = 2.6
            let pitch: CGFloat = 5.4
            let mid = canvasSize.height / 2
            let reach = canvasSize.height * 0.40
            let count = Int(ceil(canvasSize.width / pitch))
            let subPhase = CGFloat(SpeechSchedule.phase(at: time))

            for i in 0..<count {
                let x = canvasSize.width - bw - (CGFloat(i) + subPhase) * pitch
                if x < 0 { break }
                let u = Double(count - 1 - i) / Double(max(1, count - 1))
                let material = VoiceInkFigure.material(at: u, time: time)
                let speech = VoiceInkFigure.speech(at: material)
                let hh = max(1.4, pow(CGFloat(speech), 0.85) * reach)
                let rect = CGRect(x: x, y: mid - hh, width: bw, height: hh * 2)
                let path = Path(roundedRect: rect, cornerRadius: bw / 2)
                let opacity = 0.28 + 0.68 * speech
                context.fill(path, with: .color(tint.opacity(opacity)))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The drawing at one moment, apart from the view that shows it, so the geometry
/// can be measured without rendering a window.
enum VoiceInkFigure {
    /// The seconds of voice the width holds.
    static let window = 4.6
    /// How much voice passes a point each second.
    static let speed = 0.40
    /// How far the stroke reaches from the centre line, as a fraction of the
    /// half-height. Speech fills the strip: a timid excursion is what made the
    /// previous drawing look small.
    static let reachScale = 0.36
    /// The moment a still frame holds.
    ///
    /// Not arbitrary: at most moments the strip is half silence, which is
    /// honest for speech and looks like an empty card in a screenshot. This one
    /// was chosen by measuring how much of the width carries ink.
    static let stillTime = 0.5
    /// The stroke's half-height in silence, in fractions of the strip's height.
    ///
    /// Not zero. Dot listens while it is held, and a line that disappears in the
    /// pauses says it stopped.
    static let silenceScale = 0.018

    /// How wide the voice is at a moment, from `0` to `1`.
    ///
    /// Three scales at once: a phrase is being spoken, a word inside it, and the
    /// syllables inside that. The word gate is what separates ink from ink; with
    /// it the strip reads as speech, and without it as a swelling band.
    static func speech(at material: Double) -> Double {
        let phrase = gate(at: material)
        let word = SpeechShape.field(material * 3.6, 21.0)
        // A word has an edge: below the threshold the app is not hearing one, and
        // that edge is what breaks the strip into ink instead of one long band.
        // The ramp is wide because a narrow one clips and leaves flat tops.
        let said = smoothstep(clamp((word - 0.30) / 0.16))
        // A vowel holds its pressure and a consonant does not, so the top of a
        // word is a ragged plateau rather than a peak. Sharp edge, rough top:
        // without the edge the strip is a lozenge, and without the roughness the
        // edge is a rectangle.
        let lobe = 0.74 + 0.26 * SpeechShape.field(material * 7.0, 4.0)
        return clamp(pow(phrase * said * lobe, 0.80) * 0.96)
    }

    /// Whether a phrase is being spoken, from `0` to `1`.
    private static func gate(at material: Double) -> Double {
        smoothstep(clamp((SpeechShape.loudness(at: material * 0.80 + 13) - 0.40) / 0.24))
    }

    /// A hair of asymmetry between the two edges, from `-0.5` to `0.5`.
    ///
    /// A waveform mirrored about its axis is a drawing of a waveform. Voices are
    /// not symmetrical, and the eye notices this one even when it cannot say why.
    static func lean(at position: Double, material: Double) -> Double {
        (SpeechShape.field(position * 3.5, material * 4.0) - 0.5) * 0.16
    }

    /// The part of the voice a column shows at a moment.
    ///
    /// The term is added, not subtracted: at a fixed column the material read
    /// grows as time passes, which means the ink that was there has moved away
    /// from the nib and further left. Subtracting drew a wave travelling towards
    /// the pen while the ink behind it faded with age - two statements about
    /// which end is old that contradicted each other, and the eye reads the
    /// motion first.
    static func material(at position: Double, time: Double) -> Double {
        time * speed + window * span(at: position)
    }

    /// How much of the strip's history a column covers, from `0` to `1`.
    ///
    /// Uneven on purpose. The ink at the leading edge covers more voice per
    /// column than the ink at the tail, so the newest part of the stroke moves
    /// slowly and the oldest sweeps away - the same settling the tour's card has.
    /// A stroke where every column covers the same instant moves at one speed
    /// for as long as it is on screen, and one speed is what makes an animation
    /// look drawn by a machine.
    static func span(at position: Double) -> Double {
        let place = min(max(position, 0), 1)
        return 1 - (1 - place) / (1 - trailBias * place)
    }

    /// How hard the stroke compresses its own history, from `0` to nearly `1`.
    ///
    /// Mild on purpose. At `0.72` the old end of the stroke is squeezed into so
    /// few columns that it smears, and the words stop reading; the motion needs
    /// to differ between the ends without the shape losing itself.
    static let trailBias = 0.35

    /// The material the nib is reading at a moment.
    static func material(atRightOf time: Double) -> Double {
        material(at: 1, time: time)
    }

    /// The stroke's outline, and the nib that draws it.
    ///
    /// - Parameters:
    ///   - size: the strip the voice is drawn in.
    ///   - time: the running clock, in seconds.
    /// - Returns: a closed path for the ink, and the nib's centre and radius.
    static func figure(size: CGSize, time: Double) -> (ink: Path, nib: CGPoint, radius: CGFloat) {
        let mid = size.height / 2
        let reach = size.height * reachScale
        let floor = size.height * silenceScale
        // Room at the right for the nib and its halo, and none at the left: the
        // stroke runs off that edge, which is what makes it a moment rather than
        // a diagram.
        let end = size.width - max(7, size.height * 0.26)
        let steps = max(140, Int(size.width * 3))

        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        upper.reserveCapacity(steps + 1)
        lower.reserveCapacity(steps + 1)

        for index in 0...steps {
            let u = Double(index) / Double(steps)
            let material = material(at: u, time: time)
            let loud = max(floor, speech(at: material) * reach)
            let lean = lean(at: u, material: material)
            let x = end * CGFloat(u)
            upper.append(CGPoint(x: x, y: mid - loud * (1 + lean)))
            lower.append(CGPoint(x: x, y: mid + loud * (1 - lean) * 0.94))
        }

        var ink = Path()
        ink.move(to: upper[0])
        for point in upper.dropFirst() {
            ink.addLine(to: point)
        }
        for point in lower.reversed() {
            ink.addLine(to: point)
        }
        ink.closeSubpath()

        let radius = max(2.0, size.height * 0.05)
        return (ink, CGPoint(x: end + radius * 2.2, y: mid), radius)
    }

    // MARK: - Drawing

    static func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        tint: Color
    ) {
        guard size.width > 16, size.height > 12 else { return }
        let (ink, nib, radius) = figure(size: size, time: time)
        let mid = size.height / 2
        let reach = size.height * reachScale

        // Ink pools at the centre line, where the pen turns, and thins only where
        // it is about to leave the paper. Holding the body solid is what stops
        // the stroke reading as moss: it has to be a mark with an edge.
        let pool = Gradient(stops: [
            .init(color: tint.opacity(0.58), location: 0),
            .init(color: tint.opacity(0.94), location: 0.17),
            .init(color: tint, location: 0.5),
            .init(color: tint.opacity(0.94), location: 0.83),
            .init(color: tint.opacity(0.58), location: 1)
        ])
        context.fill(
            ink,
            with: .linearGradient(
                pool,
                startPoint: CGPoint(x: 0, y: mid - reach),
                endPoint: CGPoint(x: 0, y: mid + reach)
            )
        )

        // What the ink does to the paper after it lands.
        var bleed = context
        bleed.addFilter(.blur(radius: 1.1))
        bleed.fill(ink, with: .color(tint.opacity(0.07)))

        // The nib: the app's dot, with a held breath of light around it.
        var halo = context
        halo.addFilter(.blur(radius: radius * 1.6))
        halo.fill(
            Path(ellipseIn: CGRect(
                x: nib.x - radius * 2.6,
                y: nib.y - radius * 2.6,
                width: radius * 5.2,
                height: radius * 5.2
            )),
            with: .color(tint.opacity(0.16))
        )
        context.fill(
            Path(ellipseIn: CGRect(
                x: nib.x - radius,
                y: nib.y - radius,
                width: radius * 2,
                height: radius * 2
            )),
            with: .color(tint)
        )
    }

    // MARK: - Numeric helpers

    private static func clamp(_ value: Double, _ low: Double = 0, _ high: Double = 1) -> Double {
        min(max(value, low), high)
    }

    private static func smoothstep(_ value: Double) -> Double {
        let clamped = clamp(value)
        return clamped * clamped * (3 - 2 * clamped)
    }
}
