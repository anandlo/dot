import AppKit
import SwiftUI

// The Dot mark: a white dot on a black plate.
//
// Every direction below is drawn from geometry, so the icon, the study sheets
// and the menu bar glyph are generated from one source and no bitmap is ever
// hand-edited.
//
// The plate is painted to the edges of its own frame. Turning that frame into
// an icon is a separate step and it has to be: macOS 14 and 15 draw an app
// icon exactly as the bundle supplies it, so an icon file that is a full-bleed
// square appears in the Dock as a hard square. ``DotIconMaster`` is that step.
// It puts the plate in the 824 of 1024 grid, cuts it with the system corner and
// leaves the margin transparent.
//
// The four directions differ in material, in what the light does, and in how
// the dot sits in the plate. They do not differ in hue: a dot on black has no
// colour to spend, and a coloured accent would only move the argument.

/// One studied direction for the mark.
enum DotMarkDirection: String, CaseIterable, Identifiable, Sendable {
    /// A matte plate, the dot printed into it.
    case ink
    /// A polished plate answering a softbox.
    case lacquer
    /// A white solid resting on the deepest plate.
    case porcelain
    /// The dot as the only light in the frame.
    case ember

    var id: String { rawValue }

    /// The name on the sheet.
    var name: String {
        switch self {
        case .ink: "Ink"
        case .lacquer: "Lacquer"
        case .porcelain: "Porcelain"
        case .ember: "Ember"
        }
    }

    /// What the plate is made of.
    var material: String {
        switch self {
        case .ink: "Velvet matte, one soft light from above, a fine grain, and a floor that falls away at the corners."
        case .lacquer: "Polished black. A broad softbox in the top third, and the foot going to true black."
        case .porcelain: "Warm graphite, deep and flat, with the floor falling away from the eye."
        case .ember: "Near-black with no finish of its own: the plate is lit by the dot and by nothing else."
        }
    }

    /// What the dot is.
    var dot: String {
        switch self {
        case .ink: "Flat white, no shading. A hairline of occlusion where it meets the plate, so it sits in the ink rather than on it."
        case .lacquer: "A small flat white, seated on a crisp dark contact: a decal on a polished surface."
        case .porcelain: "A white solid with a gentle dome and a soft cast shadow. No specular: one highlight on a disc this size is a golf ball."
        case .ember: "A white core with a hard edge and a short bloom that peaks at its own rim, so the plate is lit and the dot is never fogged."
        }
    }

    /// How it differs from the other three, in one line.
    var difference: String {
        switch self {
        case .ink: "Print: the plate carries all the light and the dot carries none."
        case .lacquer: "Reflection: the plate is a surface that answers the light."
        case .porcelain: "Object: the light lands on the dot, not only behind it."
        case .ember: "Emission: the dot is brighter than everything and there is nothing behind it."
        }
    }

    /// The dot's diameter as a fraction of the plate.
    ///
    /// Kept between a third and two fifths. A dot that reaches half the plate
    /// stops being a punctuation mark and becomes a ball on a coaster, which
    /// is the cheap version of this idea. Porcelain sits at the top of that
    /// range because it is the direction that has to hold a Dock row on its
    /// own: at 0.345 it was the emptiest tile next to Apple's icons, and the
    /// measured 0.400 reads as a mark rather than as a gap.
    var diameter: Double {
        switch self {
        case .ink: 0.365
        case .lacquer: 0.310
        case .porcelain: 0.400
        case .ember: 0.295
        }
    }

    /// The dot's centre as a fraction from the top.
    ///
    /// A disc centred in a square reads low, so every one of these is lifted.
    /// The smaller the disc, the less it has to be lifted; the emitter goes
    /// highest because light wants to come from above. Porcelain carries the
    /// largest lift for its size: its dome puts the light in the disc's upper
    /// third while its cast shadow adds weight below the disc, and the two
    /// together pull the perceived centre down. 0.481 is a 1.9% lift, which is
    /// what centres the dome rather than the circle.
    var centre: Double {
        switch self {
        case .ink: 0.483
        case .lacquer: 0.474
        case .porcelain: 0.481
        case .ember: 0.442
        }
    }

    /// Whether the plate carries a fine grain.
    ///
    /// A grain is a surface property of a matte material. A polished plate has
    /// none, and a lit one has no surface to speak of.
    var hasGrain: Bool {
        switch self {
        case .ink: true
        case .porcelain: true
        case .lacquer, .ember: false
        }
    }

    /// The strength of the plate's own fall-off at the corners.
    var vignette: Double {
        switch self {
        case .ink: 0.26
        case .lacquer: 0.20
        case .porcelain: 0.34
        case .ember: 0.42
        }
    }
}

/// Which direction the app ships.
///
/// Porcelain's plate is the plate the app ships. The dot on it is ``chosenDial``,
/// and the two are named separately because they are two decisions: the material
/// was settled first, and the dot's geometry is the part of the mark that had to
/// stop duplicating the category's own icon.
///
/// Because both are named, a bare `scripts/render-icon.sh` writes the shipped
/// mark into `Resources/`. Every review render passes `--out`, and an explicit
/// `--direction` still draws one of the four studied plates.
enum DotMark {
    /// The plate the app ships: the one the dials are drawn on.
    static let chosen: DotMarkDirection? = .porcelain

    /// The dot the app ships. Clipped: a dot larger than the plate, bled past
    /// the top and right edges so the plate's own mask does the cutting.
    static let chosenDial: DotMarkDial? = .clipped

    /// The direction a render uses when none was asked for.
    static let fallback = DotMarkDirection.ink

    /// The direction a render should draw.
    static func direction(named name: String?) -> DotMarkDirection? {
        guard let name else { return chosen ?? fallback }
        return DotMarkDirection(rawValue: name.lowercased())
    }
}

// MARK: - The plate

/// One direction's plate at one size, drawn from geometry.
///
/// The size is in points and is always rendered at scale 1, so one point is
/// one pixel: a 16 point plate is a 16 pixel master, not a downscale.
struct DotPlate: View {
    let direction: DotMarkDirection
    let size: CGFloat

    var body: some View {
        let s = size
        let geometry = DotGeometry(direction: direction, plate: s)
        ZStack {
            DotPlateSurface(direction: direction, size: s)
            seat(s, geometry)
            dot(s, geometry)
        }
        .frame(width: s, height: s)
        .compositingGroup()
    }
}

/// A direction's plate with nothing on it: material, grain and floor.
///
/// This is the part of the mark a study can hold constant while it varies the
/// dot. It is deterministic - the grain is seeded, the gradients are functions
/// of position - so a second instance masked down to a small patch is the same
/// pixels as the plate underneath it. That is what lets the eclipsed dial take
/// its bite out of the plate's own material instead of painting a dark shape
/// over the dot and hoping nobody looks closely.
struct DotPlateSurface: View {
    let direction: DotMarkDirection
    let size: CGFloat

    var body: some View {
        let s = size
        ZStack {
            plate(s)
            if direction.hasGrain, s >= 256 {
                DotGrain(size: s, amplitude: direction == .ink ? 1.0 : 0.6)
            }
            floor(s)
        }
        .frame(width: s, height: s)
    }

    // MARK: Plate

    @ViewBuilder
    private func plate(_ s: CGFloat) -> some View {
        switch direction {
        case .ink:
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: DotInk.hex(0x28282D), location: 0.00),
                        .init(color: DotInk.hex(0x202024), location: 0.20),
                        .init(color: DotInk.hex(0x18181B), location: 0.50),
                        .init(color: DotInk.hex(0x111114), location: 0.80),
                        .init(color: DotInk.hex(0x0C0C0E), location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                topLight(s, strength: 0.052)
            }

        case .lacquer:
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: DotInk.hex(0x3B3B44), location: 0.00),
                        .init(color: DotInk.hex(0x27272E), location: 0.07),
                        .init(color: DotInk.hex(0x17171B), location: 0.22),
                        .init(color: DotInk.hex(0x0C0C0F), location: 0.44),
                        .init(color: DotInk.hex(0x050506), location: 0.70),
                        .init(color: DotInk.hex(0x000000), location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // The softbox. Its lower boundary is deliberately beyond the
                // frame: a reflection whose edge can be traced is a shape, and
                // a shape inside the plate is the tell that this was drawn
                // rather than lit.
                Ellipse()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.150), location: 0.0),
                                .init(color: .white.opacity(0.085), location: 0.30),
                                .init(color: .white.opacity(0.020), location: 0.66),
                                .init(color: .white.opacity(0.0), location: 1.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: s * 3.60, height: s * 1.10)
                    .offset(y: -s * 0.62)
                    .blur(radius: s * 0.070)
            }

        case .porcelain:
            ZStack {
                // The floor stops well short of black. A plate whose foot is
                // darker than the Dock's own shadow stops reading as an object
                // resting on a surface: the lower edge dissolves into one dark
                // mass and only the dot survives. These stops hold the darkest
                // point clear of a mid-dark Dock, and they fall monotonically,
                // so the foot stays the deepest part of the plate and its edge
                // is the strongest one in the frame. Any edge light on this
                // plate belongs inside this gradient - a separate ring would
                // bring its own inner boundary and its own corner arcs.
                LinearGradient(
                    stops: [
                        .init(color: DotInk.hex(0x2B2822), location: 0.00),
                        .init(color: DotInk.hex(0x24211B), location: 0.20),
                        .init(color: DotInk.hex(0x1F1D18), location: 0.46),
                        .init(color: DotInk.hex(0x1B1915), location: 0.76),
                        .init(color: DotInk.hex(0x191714), location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                topLight(s, strength: 0.042)
            }

        case .ember:
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: DotInk.hex(0x09090C), location: 0.00),
                        .init(color: DotInk.hex(0x060608), location: 0.32),
                        .init(color: DotInk.hex(0x030304), location: 0.68),
                        .init(color: DotInk.hex(0x020203), location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                bloom(s)
            }
        }
    }

    /// One light, above centre, tilted down.
    ///
    /// This is the only "edge light" in the drawing. It lives in the plate's
    /// own gradient and has no contour and no corner arcs of its own, which is
    /// what a separate ring element would bring with it.
    private func topLight(_ s: CGFloat, strength: Double) -> some View {
        RadialGradient(
            stops: [
                .init(color: .white.opacity(strength), location: 0.0),
                .init(color: .white.opacity(strength * 0.34), location: 0.42),
                .init(color: .clear, location: 1.0),
            ],
            center: UnitPoint(x: 0.5, y: 0.02),
            startRadius: 0,
            endRadius: s * 0.98
        )
    }

    /// The floor falling away from the eye.
    ///
    /// A surface that fills the frame is darker where it turns away, and that
    /// fall-off is what separates a panel from a colour swatch. It is a radial
    /// tint with no shape, so nothing here can read as a border.
    private func floor(_ s: CGFloat) -> some View {
        RadialGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .clear, location: 0.46),
                .init(color: .black.opacity(direction.vignette * 0.55), location: 0.78),
                .init(color: .black.opacity(direction.vignette), location: 1.0),
            ],
            center: .center,
            startRadius: 0,
            endRadius: s * 0.80
        )
    }

    /// The light the dot throws onto the plate, for the emitter.
    ///
    /// The bloom peaks at the dot's own rim and decays outward, so the plate is
    /// lit and the plate's far corners stay dark. A bloom centred on the dot
    /// would be hidden by the dot; a bloom wide enough to cover the plate is
    /// the fog this direction has to avoid.
    private func bloom(_ s: CGFloat) -> some View {
        let d = DotGeometry(direction: direction, plate: s).diameter
        let radius = d * 1.26
        let rim = 0.5 / 1.26
        return Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: .white.opacity(0.000), location: 0.0),
                        .init(color: .white.opacity(0.030), location: rim * 0.94),
                        .init(color: .white.opacity(0.058), location: rim),
                        .init(color: .white.opacity(0.014), location: rim * 1.32),
                        .init(color: .white.opacity(0.0), location: 1.0),
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
            .frame(width: radius * 2, height: radius * 2)
            .offset(y: (direction.centre - 0.5) * s)
    }
}

extension DotPlate {
    // MARK: Seat

    /// How the dot meets the plate.
    ///
    /// An occlusion hugging the rim, not a drop shadow floating under it: the
    /// dark that collects where two surfaces touch is what seats an object,
    /// and an offset ellipse only ever looks like a sticker's shadow.
    @ViewBuilder
    private func seat(_ s: CGFloat, _ geometry: DotGeometry) -> some View {
        let d = geometry.diameter
        let dy = geometry.offset
        switch direction {
        case .ink:
            rimOcclusion(d: d, spread: 0.075, strength: 0.55, dy: dy)
        case .lacquer:
            rimOcclusion(d: d, spread: 0.045, strength: 0.78, dy: dy)
        case .porcelain:
            ZStack {
                // A soft cast shadow, kept short: a long one would make the
                // disc look like it is hovering, which is the opposite of
                // resting on the plate.
                Ellipse()
                    .fill(Color.black.opacity(0.46))
                    .frame(width: d * 1.02, height: d * 0.30)
                    .blur(radius: d * 0.070)
                    .offset(y: dy + d * 0.400)
                rimOcclusion(d: d, spread: 0.075, strength: 0.58, dy: dy)
            }
        case .ember:
            // A source has no contact shadow: it is not resting on anything.
            EmptyView()
        }
    }

    /// A dark tint that collects immediately outside the dot's rim.
    private func rimOcclusion(d: CGFloat, spread: Double, strength: Double, dy: CGFloat) -> some View {
        let outer = d * (1 + spread * 2)
        let solid = 1 / (1 + spread * 2)
        return Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: .black.opacity(strength), location: 0.0),
                        .init(color: .black.opacity(strength), location: solid * 0.985),
                        .init(color: .black.opacity(strength * 0.55), location: solid * 1.005),
                        .init(color: .black.opacity(0.0), location: 1.0),
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: outer / 2
                )
            )
            .frame(width: outer, height: outer)
            .offset(y: dy)
    }

    // MARK: Dot

    @ViewBuilder
    private func dot(_ s: CGFloat, _ geometry: DotGeometry) -> some View {
        let d = geometry.diameter
        let dy = geometry.offset
        switch direction {
        case .ink, .lacquer:
            // Printed: one value, no shading at all. The restraint is the
            // design; a gradient on the disc here would be the cheap version.
            Circle()
                .fill(Color.white)
                .frame(width: d, height: d)
                .offset(y: dy)

        case .porcelain:
            Circle()
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: DotInk.hex(0xFFFFFF), location: 0.00),
                            .init(color: DotInk.hex(0xFDFCFA), location: 0.28),
                            .init(color: DotInk.hex(0xF8F7F5), location: 0.56),
                            .init(color: DotInk.hex(0xEFEEEC), location: 0.80),
                            .init(color: DotInk.hex(0xE1E0DD), location: 1.00),
                        ],
                        center: UnitPoint(x: 0.5, y: 0.34),
                        startRadius: 0,
                        endRadius: d * 0.78
                    )
                )
                .frame(width: d, height: d)
                .offset(y: dy)

        case .ember:
            ZStack {
                // The core keeps a hard edge: a source is a point, and a soft
                // one is a smudge. Only the last two percent are feathered,
                // which is what keeps the bloom from having a seam.
                Circle()
                    .fill(Color.white)
                    .frame(width: d, height: d)
                    .blur(radius: d * 0.014)
            }
            .offset(y: dy)
        }
    }
}

/// The dot's size and position for one plate size.
///
/// Below 33 points the diameter is snapped to a whole pixel and the centre to
/// the half pixel that keeps both edges on a pixel boundary. A 4.7 point disc
/// on a sixteen point plate is a grey smudge with antialiasing on two sides; a
/// five point disc with edges at 5 and 10 is a disc with a hard, white edge,
/// which is the whole requirement at the size where the mark is only a dot
/// against a plate.
struct DotGeometry {
    let diameter: CGFloat
    /// The offset of the dot's centre from the plate's centre, in points.
    let offset: CGFloat

    init(direction: DotMarkDirection, plate s: CGFloat) {
        let rawDiameter = s * direction.diameter
        let rawOffset = (direction.centre - 0.5) * s
        guard s <= 32 else {
            diameter = rawDiameter
            offset = rawOffset
            return
        }
        let snapped = rawDiameter.rounded()
        diameter = snapped
        // An even diameter wants a whole pixel centre; an odd one wants a half.
        offset = snapped.truncatingRemainder(dividingBy: 2) == 0
            ? rawOffset.rounded()
            : (rawOffset - 0.5).rounded() + 0.5
    }
}

// MARK: - Grain

/// A fine, deterministic grain for the plate.
///
/// The ramp across the plate is only a few percent deep, so an eight bit
/// gradient bands. A sub-pixel grain both breaks the bands and gives the matte
/// surface something to catch the light with. It is dropped below 256 points,
/// where a grain would be one pixel of dirt.
private struct DotGrain: View {
    let size: CGFloat
    let amplitude: Double

    var body: some View {
        Canvas { context, canvas in
            var random = DotRandom(seed: 0x0D07_5EED_1234_ABCD)
            let count = min(6000, Int(canvas.width * canvas.height / 190))
            for _ in 0..<count {
                let x = random.unit() * canvas.width
                let y = random.unit() * canvas.height
                let radius = 0.40 + random.unit() * 0.70
                let light = random.unit() > 0.5
                let alpha = (0.008 + random.unit() * 0.016) * amplitude
                let color = (light ? Color.white : Color.black).opacity(alpha)
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(color)
                )
            }
        }
        .allowsHitTesting(false)
    }
}

/// A deterministic random source, so two renders of one size are identical.
private struct DotRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func unit() -> CGFloat {
        CGFloat(next() % 1_000_000) / 1_000_000
    }
}

// MARK: - The shadow

/// The icon's own drop shadow, matched to Apple's masters.
///
/// Measured on the 256 point representation of the system apps' icons, on the
/// alpha running away from the body's edges: Apple's shadow reaches 11 pixels
/// below a 206 pixel body, 9 to the sides and 7 above it, and its first pixel
/// below the body is at alpha 33 of 255. Fitted against that profile, this set
/// reproduces it to within one or two steps of alpha per pixel; the numbers it
/// replaced sat 60 percent too low, which starved the top of the shadow and
/// left the icon looking like it was sliding off its own seat.
///
/// The two drawing paths need different numbers to land on one profile.
/// CoreGraphics' `setShadow(blur:)` spreads over about 1.17 of the blur radius,
/// while SwiftUI's `.shadow(radius:)` spreads over about 1.94 of the radius, so
/// `blur` is `radius` times that ratio.
enum DotShadow {
    /// Peak alpha at the plate edge, as a fraction of black.
    static let alpha: Double = 0.22
    /// CoreGraphics blur, as a fraction of the icon's body.
    static let blur: CGFloat = radius * 1.94
    /// The same profile asked of SwiftUI, as a fraction of the body.
    static let radius: CGFloat = 0.020
    /// How far the shadow sits below the plate, as a fraction of the body.
    static let offset: CGFloat = 0.010
}

/// The light that catches the plate's edge.
///
/// A dark plate on a dark surface is a plate nobody can find. Measured on the
/// icon Apple ships for Terminal, which is the same kind of object: its
/// silhouette is 35 of 255 at the sides and 57 at the top where the plate
/// behind it is 10 to 31, so the edge carries about ten percent of white over
/// the material and holds the shape on a black desktop. Without that line the
/// pebble's lower half disappears into a near-black page and the mark reads as
/// a cream disc floating on nothing.
///
/// The line is drawn inside the silhouette and never outside it: a stroke with
/// an outer half would put its own boundary beside the plate's edge, which is
/// the separate ring this mark has always avoided.
enum DotRim {
    /// The line's width, as a fraction of the body: about two pixels at 1024.
    static let width: CGFloat = 0.0024
    /// How much white the line carries at the top, where the light comes from.
    static let top: Double = 0.13
    /// How much white it carries at the foot, where the plate turns away.
    static let foot: Double = 0.07
}

// MARK: - Presentation

/// The system's continuous-corner square, so a study shows what the Dock will.
///
/// This is the corner macOS 14 and 15 expect an app icon to carry, because they
/// apply none of their own. It is drawn by the system's own
/// `RoundedRectangle(cornerRadius:style: .continuous)` rather than by a
/// superellipse of ours: against the silhouette measured on Apple's own icons
/// the continuous corner is within one pixel at 256 over the whole curve and
/// its area is within 0.2 percent, where the exponent-fitted superellipse that
/// came before was 1.5 percent too full and up to four pixels out at a shallow
/// depth. The radius is the grid's own 185.4 of 824.
struct DotSquircle: Shape, InsettableShape {
    /// The corner radius as a fraction of the shorter edge.
    var radiusRatio: CGFloat = DotIconGrid.cornerRatio
    /// How far the shape is pulled in, for a stroke that has to sit inside it.
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let inner = rect.insetBy(dx: inset, dy: inset)
        return RoundedRectangle(
            cornerRadius: max(0, min(inner.width, inner.height) * radiusRatio),
            style: .continuous
        )
        .path(in: inner)
    }

    func inset(by amount: CGFloat) -> DotSquircle {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// The mark as it appears on a desktop: masked, and sitting in its shadow.
///
/// `size` is the plate's own edge, which is the icon's body; the view is larger
/// than that, because the grid leaves a margin around the body and a shadow
/// clipped at the frame is not a shadow. ``paddedSize(for:)`` is the canvas this
/// view actually draws in, and it is the size an icon file is written at.
struct DotIconPresentation: View {
    let direction: DotMarkDirection
    let size: CGFloat
    var showsShadow = true

    /// The margin on each side, as a fraction of the body.
    static let paddingRatio: CGFloat = DotIconGrid.paddingRatio

    /// The canvas this view draws in for a body of `size` points.
    static func paddedSize(for size: CGFloat) -> CGFloat {
        size * (1 + paddingRatio * 2)
    }

    var body: some View {
        DotPlate(direction: direction, size: size)
            .clipShape(DotSquircle())
            .shadow(
                color: .black.opacity(showsShadow ? DotShadow.alpha : 0),
                radius: size * DotShadow.radius,
                x: 0,
                y: size * DotShadow.offset
            )
            .frame(width: size, height: size)
            .padding(size * Self.paddingRatio)
    }
}

// MARK: - Menu bar glyph

/// The menu bar mark: its own drawing, not the icon at 18 points.
///
/// A template survives only on geometry and weight, so the glyph is the dot
/// again, with the cut that the plate makes on it. Black on transparent is what
/// `isTemplate` expects; the system inverts it on a dark bar and discards
/// everything but alpha, so nothing here can depend on colour.
///
/// The Clipped mark's cut is 7.5% of the plate: 1.35 px at 18 and 2.7 px at 36.
/// Whether that reads at eighteen points is the question the comparison sheet
/// answers, so the three reductions below hold the same geometry and only vary
/// how far the dot is pushed past the corner.
struct DotMenuGlyph: View {
    /// The glyph's box in points.
    var size: CGFloat = 18
    /// Which glyph to draw.
    var kind: Kind = .shipped

    enum Kind: String, CaseIterable, Sendable {
        /// The dot above its baseline rule. The previous mark's study.
        case dot
        /// The dot alone, redrawn for the menu bar. What shipped before the
        /// Clipped mark: still a disc, so it no longer says anything the icon
        /// says.
        case disc
        /// The dot with a longer rule under it, as a recording bar.
        case barred

        /// The icon's own cut: d 0.660 of the plate, and each flat takes 23%
        /// of the dot's radius, which is what a 7.5% bleed of the plate comes
        /// to on a dot that size.
        case bleed
        /// The limiting case: the disc's centre sits on the corner, so what
        /// survives is one quadrant of a much larger dot.
        case quarter

        /// The glyph Dot ships.
        static let shipped = Kind.bleed

        /// The kinds the earlier menu bar sheet studied.
        static let legacy: [Kind] = [.dot, .disc, .barred]

        /// The reductions of the Clipped mark.
        static let clipped: [Kind] = [.bleed, .quarter]

        /// What the candidate is, in the sheet's words.
        var note: String {
            switch self {
            case .dot: "A full stop on its baseline: the proportions of type."
            case .disc: "The old mark: a disc, centred, 9.2 of 18."
            case .barred: "The dot over a recording bar."
            case .bleed:
                "The icon's own numbers: d 0.660 of the plate, each flat 23% of the dot's radius. 1.4 px of flat at 18, 2.7 px at 36."
            case .quarter:
                "The centre on the corner: one quadrant of a disc of 23, arc facing the plate."
            }
        }
    }

    var body: some View {
        let u = size / 18
        ZStack {
            switch kind {
            case .dot:
                // A full stop on its baseline: eight units of dot, two of
                // air, one and a half of rule. The proportions of type.
                Circle()
                    .fill(Color.black)
                    .frame(width: 8 * u, height: 8 * u)
                    .offset(y: -3.05 * u)
                Capsule()
                    .fill(Color.black)
                    .frame(width: 11.4 * u, height: 1.5 * u)
                    .offset(y: 3.35 * u)
            case .disc:
                // Drawn for eighteen points rather than scaled from the icon:
                // 9.2 of 18, and lifted a quarter of a point, because a disc
                // centred in a square reads low exactly as a disc on a plate
                // does.
                Circle()
                    .fill(Color.black)
                    .frame(width: 9.2 * u, height: 9.2 * u)
                    .offset(y: -0.25 * u)
            case .barred:
                Circle()
                    .fill(Color.black)
                    .frame(width: 8 * u, height: 8 * u)
                    .offset(y: -1.4 * u)
                Capsule()
                    .fill(Color.black)
                    .frame(width: 13 * u, height: 1.5 * u)
                    .offset(y: 4.2 * u)
            case .bleed:
                dot(u, radius: 5.94, x: 13.41, y: 4.59)
            case .quarter:
                dot(u, radius: 11.50, x: 18.00, y: 0.00)
            }
        }
        // The box is the plate, and the plate is what cuts: a disc placed
        // outside it must be trimmed by it, never drawn over the bar beside.
        .frame(width: size, height: size)
        .clipped()
    }

    /// A disc of the mark, cut by the glyph's box and then centred in it.
    ///
    /// The centre is in units from the box's top-left, which is the same frame
    /// the icon's fractions are measured in: a glyph can be read against the
    /// 1024 master without converting anything.
    ///
    /// The cut comes first and the centring second, because the menu bar has no
    /// plate to anchor a bleed. A dot left where the plate would have cut it
    /// sits in the corner of its eighteen point slot and reads as an image that
    /// is one and a half points high; a dot whose cut is carried and whose ink
    /// is centred reads as a cropped dot. The shape is the evidence here, not
    /// its position in a frame nobody can see.
    private func dot(_ u: CGFloat, radius: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        let box = 18 * u
        let box18: CGFloat = 18
        let inkLeft = max(x - radius, 0)
        let inkRight = min(x + radius, box18)
        let inkTop = max(y - radius, 0)
        let inkBottom = min(y + radius, box18)
        let tx = (box18 / 2 - (inkLeft + inkRight) / 2) * u
        let ty = (box18 / 2 - (inkTop + inkBottom) / 2) * u
        return ZStack {
            Circle()
                .fill(Color.black)
                .frame(width: radius * 2 * u, height: radius * 2 * u)
                .offset(x: (x - box18 / 2) * u, y: (y - box18 / 2) * u)
        }
        .frame(width: box, height: box)
        .clipped()
        .offset(x: tx, y: ty)
    }
}

// MARK: - Colour

/// The plate's colours, as sRGB hex.
private enum DotInk {
    static func hex(_ value: UInt32, _ alpha: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: alpha
        )
    }
}
