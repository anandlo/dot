import AppKit
import SwiftUI

// The dot, four ways, on the plate that is already decided.
//
// Porcelain's plate does not move here: same material, same floor, same corner,
// same shadow. The only variable is the dot's geometry and where it sits,
// because that is the part of the mark that has to stop being Aqua Voice's.
//
// Every dial keeps the dot's optical weight inside a narrow band (0.117 to 0.144
// of the plate's area, against Porcelain's 0.126), so a row is a choice about
// form and not about which mark is biggest. The visible area is what is held
// constant, not the diameter: a clipped dot is mostly outside the frame, and a
// bitten one has a hole in it.

/// One way of drawing the dot on Porcelain's plate.
enum DotMarkDial: String, CaseIterable, Identifiable, Sendable {
    /// Porcelain as it ships: the control, not a candidate.
    case control
    /// The dot is larger than the plate and the frame cuts it.
    case clipped
    /// The dot is off-centre by decision, not by nudge.
    case offset
    /// A second disc takes a bite out of the first.
    case eclipsed
    /// The dot is split by a terminator into a lit and a shaded half.
    case horizon

    var id: String { rawValue }

    /// The four candidates, in the order the sheet shows them.
    static let studied: [DotMarkDial] = [.clipped, .offset, .eclipsed, .horizon]

    /// The name on the sheet.
    var name: String {
        switch self {
        case .control: "Porcelain"
        case .clipped: "Clipped"
        case .offset: "Offset"
        case .eclipsed: "Eclipsed"
        case .horizon: "Horizon"
        }
    }

    /// The argument, in one sentence.
    var headline: String {
        switch self {
        case .control: "The dot in the middle, which is the icon next door."
        case .clipped: "The dot is bigger than the plate, and the frame cuts it."
        case .offset: "A full stop at the end of a line you cannot see."
        case .eclipsed: "A second disc takes a bite out of the first."
        case .horizon: "The dot has an up: a terminator splits it into lit and shaded."
        }
    }

    /// What the direction does, and what it costs.
    var detail: String {
        switch self {
        case .control:
            "Disc 0.40, centred, lifted 1.9%. Aqua Voice's icon is this same structure in the opposite value - one filled disc, dead centre, on a rounded plate - which is why the row below shows the category's default twice."
        case .clipped:
            "Drawn at 0.66 and pushed past the top and right edges, so the plate's mask does the drawing: a dot leaving the frame cannot be mistaken for a dot sitting in the middle of one. This is the widest silhouette break in the set. The seat still holds along the lower rim, which is what keeps it an object being cropped rather than a crop."
        case .offset:
            "The same 0.40 disc as today, moved to the lower right so the plate is asymmetric on purpose. Nothing is added and nothing is decorated: the only change is where the mark sits, which makes it the cheapest escape here - and the least dramatic."
        case .eclipsed:
            "The bite is cut from the plate's own material rather than painted over the dot: 26.5% of the disc is simply not there, leaving a gibbous dot with a concave edge. Nobody in the category has a concave edge. At 16 px the bite stops reading as an eclipse and becomes an irregular blob, which is the risk this direction carries."
        case .horizon:
            "Porcelain's dome says the light comes from above; the horizon makes that structural, cutting the disc into a bright upper half and a shaded lower one with a hairline of plate between them. The material claim stops being a gradient and becomes geometry - a body that has an up."
        }
    }

    /// The geometry, for the sheet's mono column.
    var spec: String {
        switch self {
        case .control:
            "d 0.400  c (0.500, 0.481)"
        case .clipped:
            "d 0.660  c (0.745, 0.255)\n7.5% past two edges"
        case .offset:
            "d 0.400  c (0.635, 0.585)"
        case .eclipsed:
            "d 0.500  c (0.500, 0.475)\nbite 26.5%"
        case .horizon:
            "d 0.420  c (0.500, 0.487)\nterminator 47%"
        }
    }

    /// The dot's diameter as a fraction of the plate.
    var diameter: Double {
        switch self {
        case .control, .offset: 0.400
        case .clipped: 0.660
        case .eclipsed: 0.500
        case .horizon: 0.420
        }
    }

    /// The dot's centre as a fraction of the plate, from the top left.
    var centre: CGPoint {
        switch self {
        case .control: CGPoint(x: 0.500, y: 0.481)
        case .clipped: CGPoint(x: 0.745, y: 0.255)
        case .offset: CGPoint(x: 0.635, y: 0.585)
        case .eclipsed: CGPoint(x: 0.500, y: 0.475)
        case .horizon: CGPoint(x: 0.500, y: 0.487)
        }
    }

    /// How far the eclipsing disc's centre sits from the dot's, in radii.
    ///
    /// An equal disc at 1.24 radii removes 26.5% of the dot: enough to make a
    /// concave edge, not so much that the mark becomes a crescent and stops
    /// being a dot.
    var biteReach: Double { 1.24 }

    /// Where the terminator sits, as a fraction of the disc's height.
    var terminator: Double { 0.47 }
}

/// The dot's size and position for one plate size.
///
/// Below 33 points the diameter and the centre snap to the pixel grid, exactly
/// as ``DotGeometry`` does for the shipped directions: a 16 point tile that
/// lands on fractional pixels is a grey smudge, and at that size the mark is
/// only a dot against a plate.
///
/// The bleed is not pulled back at the small sizes. The in-context review said
/// Clipped "passes 16 px but dominates the tile", so both were rendered and
/// masked to the system corner: at 16 the plate still owns about seven tenths
/// of the tile and reads as an L around a dot that leaves the frame, and the
/// tile's white share lands between Notes and Finder. An inset of one pixel did
/// restore plate on all four sides, and it also turned the 16 and 32 pixel
/// slots into a plain dot in a box - the two sizes where the mark has the least
/// to say, and precisely the sizes where it would stop agreeing with the 1024
/// that was approved. The geometry is the same at every size.
struct DotMarkDialGeometry {
    let diameter: CGFloat
    /// The centre's offset from the plate's centre, in points.
    let dx: CGFloat
    let dy: CGFloat

    init(dial: DotMarkDial, plate s: CGFloat) {
        let rawDiameter = s * dial.diameter
        let rawX = (dial.centre.x - 0.5) * s
        let rawY = (dial.centre.y - 0.5) * s
        guard s <= 32 else {
            diameter = rawDiameter
            dx = rawX
            dy = rawY
            return
        }
        let snapped = max(1, rawDiameter.rounded())
        let unit: CGFloat = snapped.truncatingRemainder(dividingBy: 2) == 0 ? 0 : 0.5
        diameter = snapped
        dx = (rawX - unit).rounded() + unit
        dy = (rawY - unit).rounded() + unit
    }
}

// MARK: - Drawing

/// One dial at one size, on Porcelain's plate.
///
/// The plate is drawn by the same view the shipped icon uses, so the material
/// in a study tile is the material in the product and not a re-creation of it.
struct DotMarkDialTile: View {
    let dial: DotMarkDial
    let size: CGFloat
    /// Which parts of the tile are drawn.
    ///
    /// A layered export draws the plate, the disc's seat and the disc in
    /// separate layers, because a system that lights each layer has to be given
    /// each silhouette: a disc and its shadow in one layer is a single outline,
    /// and a glass rim drawn on that outline rings the shadow rather than the
    /// disc. Every part is the same drawing at the same geometry, so the layers
    /// reassemble into the flat tile exactly.
    var parts: Parts = .all

    var body: some View {
        let s = size
        let geometry = DotMarkDialGeometry(dial: dial, plate: s)
        ZStack {
            if parts.contains(.plate) {
                DotPlateSurface(direction: .porcelain, size: s)
            }
            if parts.contains(.seat) {
                seat(geometry)
            }
            if parts.contains(.disc) {
                mark(geometry, plate: s)
            }
        }
        .frame(width: s, height: s)
        .compositingGroup()
        // A dot that bleeds past the plate has to be cut by the plate's own
        // edge, not drawn over the sheet beside it.
        .clipped()
    }

    /// The tile's parts, as the layers a layered export needs.
    struct Parts: OptionSet, Sendable {
        let rawValue: Int

        /// The plate's material.
        static let plate = Parts(rawValue: 1 << 0)
        /// The disc's seat: its cast shadow and the occlusion at its rim.
        static let seat = Parts(rawValue: 1 << 1)
        /// The disc itself.
        static let disc = Parts(rawValue: 1 << 2)
        /// The tile as a study sheet draws it.
        static let all: Parts = [.plate, .seat, .disc]
    }

    // MARK: Seat

    /// The seat, unchanged from Porcelain: a short cast shadow and a rim.
    private func seat(_ geometry: DotMarkDialGeometry) -> some View {
        let d = geometry.diameter
        let spread = 0.075
        let strength = 0.58
        let outer = d * (1 + spread * 2)
        let solid = 1 / (1 + spread * 2)
        return ZStack {
            Ellipse()
                .fill(Color.black.opacity(0.46))
                .frame(width: d * 1.02, height: d * 0.30)
                .blur(radius: d * 0.070)
                .offset(x: geometry.dx, y: geometry.dy + d * 0.400)
            Circle()
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
                .offset(x: geometry.dx, y: geometry.dy)
        }
    }

    // MARK: Mark

    @ViewBuilder
    private func mark(_ geometry: DotMarkDialGeometry, plate s: CGFloat) -> some View {
        switch dial {
        case .control, .clipped, .offset:
            disc(geometry)
        case .eclipsed:
            ZStack {
                disc(geometry)
                bite(geometry, plate: s)
            }
        case .horizon:
            horizon(geometry)
        }
    }

    /// Porcelain's dot: a white solid with a gentle dome and no specular.
    private func disc(_ geometry: DotMarkDialGeometry) -> some View {
        let d = geometry.diameter
        return Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: DialInk.hex(0xFFFFFF), location: 0.00),
                        .init(color: DialInk.hex(0xFDFCFA), location: 0.28),
                        .init(color: DialInk.hex(0xF8F7F5), location: 0.56),
                        .init(color: DialInk.hex(0xEFEEEC), location: 0.80),
                        .init(color: DialInk.hex(0xE1E0DD), location: 1.00),
                    ],
                    center: UnitPoint(x: 0.5, y: 0.34),
                    startRadius: 0,
                    endRadius: d * 0.78
                )
            )
            .frame(width: d, height: d)
            .offset(x: geometry.dx, y: geometry.dy)
    }

    /// The plate's own material, masked down to the eclipsing disc.
    ///
    /// A dark shape painted over the dot would be a shape; this is the plate
    /// showing through a hole in the dot, because it is drawn from the same
    /// deterministic surface the plate itself is drawn from. The bite therefore
    /// carries the real grain at 1024 and the real gradient at every size.
    private func bite(_ geometry: DotMarkDialGeometry, plate s: CGFloat) -> some View {
        let d = geometry.diameter
        let reach = d / 2 * dial.biteReach
        let diagonal = reach / 2.squareRoot()
        return DotPlateSurface(direction: .porcelain, size: s)
            .mask(
                ZStack {
                    Rectangle()
                        .fill(Color.clear)
                    Circle()
                        .fill(Color.white)
                        .frame(width: d, height: d)
                        .offset(x: geometry.dx + diagonal, y: geometry.dy - diagonal)
                }
                .frame(width: s, height: s)
            )
    }

    /// A disc split by a hairline into a lit upper half and a shaded lower one.
    ///
    /// The hairline is a gap, not a line: the plate shows between the halves,
    /// so the split is the same material fact as the plate's own floor. Below
    /// 32 points a one pixel gap is a fifth of the disc and the dot reads as two
    /// stacked blobs, so the gap is dropped there and the value break carries
    /// the terminator on its own.
    private func horizon(_ geometry: DotMarkDialGeometry) -> some View {
        let d = geometry.diameter
        let gap = size >= 32 ? max(1, d * 0.015) : 0
        let split = d * dial.terminator
        let upper = max(0, split - gap / 2)
        let lower = max(0, d - split - gap / 2)
        return ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: DialInk.hex(0xE9E4DA), location: 0.0),
                            .init(color: DialInk.hex(0xD6D0C4), location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: d, height: lower)
                .offset(y: split + gap / 2 + lower / 2 - d / 2)
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: DialInk.hex(0xFFFFFF), location: 0.0),
                            .init(color: DialInk.hex(0xF4F2EE), location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: d, height: upper)
                .offset(y: upper / 2 - d / 2)
        }
        .frame(width: d, height: d)
        .clipShape(Circle())
        .offset(x: geometry.dx, y: geometry.dy)
    }
}

/// A dial as an icon on a desktop: masked, and sitting in its shadow.
///
/// `size` is the plate's own edge; the canvas around it is the grid's margin,
/// exactly as ``DotIconPresentation`` draws a direction.
struct DotMarkDialPresentation: View {
    let dial: DotMarkDial
    let size: CGFloat
    var showsShadow = true

    var body: some View {
        DotMarkDialTile(dial: dial, size: size)
            .clipShape(DotSquircle())
            .shadow(
                color: .black.opacity(showsShadow ? DotShadow.alpha : 0),
                radius: size * DotShadow.radius,
                x: 0,
                y: size * DotShadow.offset
            )
            .frame(width: size, height: size)
            .padding(size * DotIconPresentation.paddingRatio)
    }
}

/// The dials' colours, as sRGB hex.
private enum DialInk {
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
