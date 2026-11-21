import AppKit
import DotCore
import SwiftUI

/// The window language: warm paper, warm graphite ink, porcelain, amber.
///
/// Every colour is a dynamic `NSColor`, so one token serves both appearances.
/// Light keeps the warm paper identity with deeper secondary ink; dark turns
/// the paper into warm charcoal and the ink into bone. The interactive accent
/// is the shipped mark's own warm graphite, not a second colour: the product's
/// only coloured tones are status ones. The HUD has its own palette.
enum DotTheme {
    // MARK: - Core palette

    /// The window paper.
    static let paper = adaptive(light: ns(0.973, 0.957, 0.929), dark: ns(0.102, 0.090, 0.082))
    /// The deeper paper of the sidebar and inset areas.
    static let paperDeep = adaptive(light: ns(0.918, 0.892, 0.847), dark: ns(0.078, 0.071, 0.063))
    /// The second stop of the paper gradient.
    static let paperTint = adaptive(light: ns(0.945, 0.921, 0.867), dark: ns(0.133, 0.118, 0.106))

    /// The primary text.
    static let ink = adaptive(light: ns(0.075, 0.065, 0.085), dark: ns(0.953, 0.929, 0.894))
    /// The secondary text.
    static let ink2 = adaptive(light: ns(0.290, 0.271, 0.247), dark: ns(0.784, 0.753, 0.710))
    /// The tertiary text and quiet labels.
    static let ink3 = adaptive(light: ns(0.400, 0.373, 0.337), dark: ns(0.608, 0.569, 0.522))

    /// The amber action colour.
    static let amber = adaptive(light: ns(0.961, 0.725, 0.267), dark: ns(0.949, 0.757, 0.361))
    /// A warning or destructive accent.
    static let coral = adaptive(light: ns(1.000, 0.420, 0.290), dark: ns(1.000, 0.565, 0.471))
    /// The quiet neutral.
    static let silver = adaptive(light: ns(0.722, 0.722, 0.722), dark: ns(0.663, 0.635, 0.604))
    /// Success.
    static let mint = adaptive(light: ns(0.561, 0.890, 0.753), dark: ns(0.525, 0.878, 0.714))

    /// The interactive accent: the mark's warm graphite on paper, its
    /// porcelain on ink. A control tinted with this cannot drift from the icon.
    static let accent = adaptive(light: ns(0.169, 0.157, 0.133), dark: ns(0.949, 0.929, 0.898))
    /// A pale accent wash for icon chips.
    static let accentSoft = adaptive(light: white(0.08), dark: white(0.075))
    /// The label colour on an accent fill.
    static let onAccent = adaptive(light: white(1), dark: ns(0.090, 0.075, 0.065))
    // MARK: - Surfaces

    /// The fill of a raised card.
    static let cardFill = adaptive(light: white(0.58), dark: white(0.055))
    /// The fill of a card under the pointer.
    static let cardHoverFill = adaptive(light: white(0.72), dark: white(0.085))
    /// The fill of a selected card.
    static let cardSelectedFill = adaptive(light: black(0.055), dark: white(0.07))
    /// The border of a card.
    static let cardBorder = adaptive(light: white(0.72), dark: white(0.10))
    /// The border of a selected card.
    static let cardBorderSelected = adaptive(light: black(0.30), dark: white(0.34))

    /// The fill of a text field.
    static let fieldFill = adaptive(light: white(0.62), dark: white(0.06))
    /// The fill of a focused text field.
    static let fieldFillFocused = adaptive(light: white(0.78), dark: white(0.085))
    /// The border of a text field.
    static let fieldBorder = adaptive(light: black(0.16), dark: white(0.16))

    /// The opaque surface of a raised list or popover.
    ///
    /// A menu floats over whatever is beneath it, so it cannot be the
    /// translucent card fill: it takes the card's colour at full opacity.
    static let raisedFill = adaptive(light: ns(0.996, 0.988, 0.973), dark: ns(0.145, 0.129, 0.118))

    /// The divide between rows and sections.
    static let hairline = adaptive(light: black(0.10), dark: white(0.10))

    /// The quiet button fill.
    static let secondaryFill = adaptive(light: white(0.55), dark: white(0.06))
    /// The quiet button border.
    static let secondaryBorder = adaptive(light: black(0.16), dark: white(0.15))

    /// The fill of a keyboard keycap.
    static let keycapFill = adaptive(light: white(0.74), dark: white(0.08))
    /// The border of a keyboard keycap.
    static let keycapBorder = adaptive(light: black(0.16), dark: white(0.17))

    /// The sidebar surface.
    static let sidebarFill = adaptive(light: ns(0.945, 0.929, 0.898), dark: ns(0.082, 0.075, 0.069))
    /// The light that falls on the top of the sidebar.
    static let sidebarHighlight = adaptive(light: white(0.22), dark: white(0.035))
    /// The pill behind the selected sidebar item.
    ///
    /// A tint of the ink rather than a plate of it: a near-black slab on paper
    /// was the largest black shape in the window, and the sidebar is a list of
    /// names, not a toolbar. The fill only says "here"; the weight of the label
    /// and the icon carry the rest.
    static let sidebarSelectedFill = adaptive(light: ns(0.075, 0.065, 0.085, 0.08), dark: white(0.10))
    /// The border of the selected sidebar pill: a hairline that keeps the tint
    /// from fading into the sidebar surface.
    static let sidebarSelectedBorder = adaptive(light: black(0.09), dark: white(0.12))
    /// The selected sidebar text.
    static let sidebarSelectedText = ink
    /// The selected sidebar icon.
    static let sidebarSelectedIcon = accent
    /// The hover wash of an unselected sidebar item: the same tint, at half the
    /// strength of the pill.
    static let sidebarHoverFill = adaptive(light: ns(0.075, 0.065, 0.085, 0.045), dark: white(0.06))

    // MARK: - Menus

    /// The wash behind the row under the pointer in an open menu.
    ///
    /// A menu floats over an unknown desktop, so its rows cannot use the
    /// sidebar's pill, which is a tint of the window paper. This is the same
    /// neutral ink tint, stepped for a raised surface: "here" in a tone that
    /// introduces no colour, so the check — not the wash — says which row is
    /// chosen.
    static let menuRowHighlight = adaptive(light: ns(0.075, 0.065, 0.085, 0.08), dark: white(0.10))
    /// The wash behind a row held by the pointer.
    ///
    /// The highlight pushed in, not a second colour: the same ink tint at nearly
    /// twice the strength, so a press reads as depth rather than as selection,
    /// and the chosen row's check stays the thing that says "this one".
    static let menuRowPressed = adaptive(light: ns(0.075, 0.065, 0.085, 0.14), dark: white(0.16))

    /// The glow in the top-left corner of the paper.
    static let paperGlow = adaptive(light: white(0.65), dark: white(0.050))
    /// The warm shade at the bottom of the paper.
    static let paperShade = adaptive(light: ns(0.42, 0.31, 0.20, 0.06), dark: black(0.30))

    // MARK: - Switch

    /// The track of a switch that is on.
    ///
    /// The system green, stepped per appearance: the light stop is the green
    /// that sits calmly on warm paper, the dark stop the slightly brighter one
    /// that holds on warm charcoal. A switch is the one control whose colour
    /// says a state, so it keeps the colour the platform uses for that state
    /// rather than borrowing the action colour.
    static let switchOn = adaptive(light: ns(0.204, 0.780, 0.349), dark: ns(0.188, 0.820, 0.345))
    /// The lit stop at the top of the on track, which keeps it from reading as
    /// a flat rectangle of colour.
    static let switchOnTop = adaptive(light: ns(0.286, 0.855, 0.427), dark: ns(0.271, 0.878, 0.435))
    /// The hairline around the on track.
    static let switchOnEdge = adaptive(light: black(0.16), dark: white(0.22))

    /// The track of a switch that is off: the paper's own warm edge, and a veil
    /// of white on ink. Never black, and never white.
    static let switchOff = adaptive(light: ns(0.890, 0.878, 0.855), dark: white(0.16))
    /// The hairline around the off track.
    static let switchOffEdge = adaptive(light: black(0.13), dark: white(0.14))
    /// The veil that lifts either track under the pointer.
    static let switchHoverLift = adaptive(light: white(0.18), dark: white(0.12))

    /// The knob is porcelain in both appearances: the track carries the state.
    static let switchKnob = Color.white
    /// The hairline that separates the porcelain knob from its track. On a lit
    /// track the two light shapes would otherwise touch and the knob would lose
    /// its edge.
    static let switchKnobEdge = adaptive(light: black(0.16), dark: black(0.34))
    /// The shadow that seats the knob on its track.
    static let switchKnobShadow = adaptive(light: black(0.26), dark: black(0.55))

    // MARK: - Action

    /// The fill of the primary action.
    ///
    /// Amber, the product's one warm action colour, in both appearances. The
    /// graphite accent is the mark's colour and the sidebar's; as a button fill
    /// it turned into a second, unrelated identity in dark mode.
    static let actionFill = adaptive(light: ns(0.961, 0.725, 0.267), dark: ns(0.976, 0.784, 0.365))
    /// The primary fill under the pointer.
    static let actionFillHover = adaptive(light: ns(0.976, 0.780, 0.365), dark: ns(0.988, 0.827, 0.435))
    /// The primary fill while pressed.
    static let actionFillPressed = adaptive(light: ns(0.918, 0.659, 0.196), dark: ns(0.937, 0.722, 0.302))
    /// The label on the primary fill: warm graphite in both appearances,
    /// because the fill is light in both.
    static let onAction = adaptive(light: ns(0.129, 0.102, 0.063), dark: ns(0.114, 0.090, 0.051))
    /// The highlight along the top of the primary fill.
    static let actionEdge = adaptive(light: white(0.42), dark: white(0.30))
    /// The seat under the primary fill.
    static let actionShadow = adaptive(light: ns(0.482, 0.325, 0.075, 0.26), dark: black(0.45))

    /// The quiet button fill under the pointer.
    static let secondaryFillHover = adaptive(light: white(0.74), dark: white(0.105))
    /// The quiet button border under the pointer.
    static let secondaryBorderHover = adaptive(light: black(0.30), dark: white(0.26))

    /// The fill of a selected indicator: the same amber a switch uses when it is
    /// on, so "chosen" and "on" are one colour rather than two.
    static let selectionFill = switchOn
    /// The mark drawn on a selected indicator. Graphite, not white: white on
    /// amber is barely two to one, and the check is the smallest glyph in the
    /// window.
    static let onSelection = onAction

    /// The focus ring around a control.
    static let focusRing = adaptive(light: black(0.45), dark: white(0.60))
    /// The unfilled track of a slider: the same warm grey the off state of a
    /// switch uses, so a row of controls reads as one family.
    static let sliderTrack = adaptive(light: ns(0.890, 0.878, 0.855), dark: white(0.16))
    /// The ring of an unselected radio indicator.
    static let selectionRing = adaptive(light: black(0.20), dark: white(0.28))

    /// The edge of a preview window.
    static let windowBorder = adaptive(light: black(0.10), dark: white(0.12))


    /// The plate of the app's mark: warm graphite, measured from the icon.
    ///
    /// These are fixed rather than adaptive because the mark is a picture of the
    /// app icon, and the icon does not change with the system appearance.
    static let markPlateTop = Color(red: 0x2B / 255, green: 0x28 / 255, blue: 0x22 / 255)
    static let markPlateBottom = Color(red: 0x19 / 255, green: 0x17 / 255, blue: 0x14 / 255)
    /// The seat under the mark, matching the icon's measured shadow.
    static let markShadow = Color.black.opacity(0.28)

    /// A one-pixel edge around the mark's plate. On dark paper the plate's own
    /// colour is within a few points of the background, so without an edge the
    /// mark collapses into a white disc floating in nothing.
    static let markEdge = adaptive(light: black(0.10), dark: white(0.16))

    // MARK: - Geometry and type

    static let windowCorner: CGFloat = 22
    static let cardCorner: CGFloat = 10
    static let sidebarWidth: CGFloat = 198
    static let headerHeight: CGFloat = 64
    static let windowPadding: CGFloat = 24

    static var paperFill: LinearGradient {
        LinearGradient(
            colors: [paper, paperTint],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The face the app's titles are set in.
    ///
    /// Satoshi, semibold, at the size the caller asks for. The title used to be
    /// New York because a serif is the one face that reads as a heading, and
    /// then the owner asked for one typeface on every surface: a page title in
    /// a second family is the one place the app would still look like two
    /// products. The function stays because every page calls it, and only the
    /// face inside it changed.
    static func displayFont(_ size: CGFloat) -> Font {
        DotType.font(size, .semibold)
    }

    static var titleFont: Font { displayFont(22) }
    static var sectionFont: Font { DotType.font(15, .semibold) }
    static var bodyFont: Font { DotType.font(13, .medium) }
    static var smallFont: Font { DotType.font(11.5, .medium) }
    /// The size of the line under a window title.
    static let subtitleSize: CGFloat = 11.5
    /// The line under a window title, which carries a count as often as a word.
    ///
    /// The same size as ``smallFont``, set in the tabular face: the history
    /// header counts transcripts, and a count that changes has to stay in its
    /// column rather than shuffle its own digits.
    static var subtitleFont: Font { DotType.tabularFont(subtitleSize, .medium) }
    static var labelFont: Font { DotType.font(10.5, .semibold) }
    /// The name of a setting.
    static var rowTitleFont: Font { DotType.font(12.5, .semibold) }
    /// The line under a setting that says what it does. One size everywhere:
    /// the pages used to mix 10.5 and 11, which read as two ranks of the same
    /// thing.
    static var rowDetailFont: Font { DotType.font(11, .medium) }
    /// The caps label above a field or a card.
    static var fieldLabelFont: Font { DotType.font(9.5, .semibold) }

    // MARK: - Colour helpers

    /// A colour that resolves per appearance.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func ns(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func ns(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func white(_ alpha: CGFloat) -> NSColor {
        NSColor.white.withAlphaComponent(alpha)
    }

    private static func black(_ alpha: CGFloat) -> NSColor {
        NSColor.black.withAlphaComponent(alpha)
    }
}

/// The warm paper behind every window.
struct DotPaper: View {
    var body: some View {
        ZStack {
            DotTheme.paperFill
            RadialGradient(
                colors: [DotTheme.paperGlow, .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 520
            )
            LinearGradient(
                colors: [.clear, DotTheme.paperShade],
                startPoint: .center,
                endPoint: .bottom
            )
        }
    }
}

/// A quiet sheet on the paper.
///
/// The card is a surface, not an object on the page: a hairline border and a
/// translucent fill, no drop shadow. The horizontal inset belongs to the card;
/// the vertical inset is small because every row brings its own padding, and a
/// row that carried a second inset would move the divider away from the text.
struct DotCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                    .fill(DotTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                            .strokeBorder(DotTheme.cardBorder, lineWidth: 1)
                    )
            )
    }
}

/// The title row, with room for the native traffic lights at the left.
struct DotWindowHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DotTheme.titleFont)
                    .foregroundStyle(DotTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(DotTheme.subtitleFont)
                        .foregroundStyle(DotTheme.ink3)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.leading, 78)
        .padding(.trailing, DotTheme.windowPadding)
        .frame(height: DotTheme.headerHeight)
    }
}

extension DotWindowHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// The solid button used for the primary action.
///
/// Amber on paper and amber on ink: one action colour that does not change
/// identity with the appearance. The press scale and the hover lift are what
/// make it feel like a physical key rather than a painted rectangle.
struct DotPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DotPrimaryButtonBody(configuration: configuration)
    }
}

private struct DotPrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var fill: Color {
        if configuration.isPressed {
            return DotTheme.actionFillPressed
        }
        return isHovering ? DotTheme.actionFillHover : DotTheme.actionFill
    }

    private var scale: CGFloat {
        guard isEnabled, !reducesMotion else { return 1 }
        if configuration.isPressed {
            return DotPressFeedback.pressedScale
        }
        return isHovering ? 1.015 : 1
    }

    private var reducesMotion: Bool {
        reduceMotion || DotMotion.reducesMotion
    }

    var body: some View {
        configuration.label
            .font(DotType.font(12.5, .semibold))
            .foregroundStyle(DotTheme.onAction)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .circular)
                    .fill(fill)
                    .overlay(
                        Capsule(style: .circular)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.28), .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    )
                    .overlay(
                        // The rim is a lit top edge, not a ring around the whole
                        // capsule: a full ring bled a hairline of white onto the
                        // paper at the two sides of the button.
                        Capsule(style: .circular)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [DotTheme.actionEdge, .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.75
                            )
                    )
            )
            .shadow(
                color: DotTheme.actionShadow,
                radius: isHovering ? 7 : 4,
                x: 0,
                y: isHovering ? 3 : 2
            )
            .scaleEffect(scale)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(
                DotPressFeedback.animation(reduceMotion: reducesMotion),
                value: configuration.isPressed
            )
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .onHover { inside in
                isHovering = isEnabled && inside
            }
    }
}

/// The secondary button on paper: a quiet capsule that answers the pointer
/// without ever competing with the primary action.
struct DotSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DotSecondaryButtonBody(configuration: configuration)
    }
}

private struct DotSecondaryButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var reducesMotion: Bool {
        reduceMotion || DotMotion.reducesMotion
    }

    var body: some View {
        configuration.label
            .font(DotType.font(12.5, .semibold))
            .foregroundStyle(isEnabled ? DotTheme.ink : DotTheme.ink3)
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .circular)
                    .fill(isHovering && isEnabled ? DotTheme.secondaryFillHover : DotTheme.secondaryFill)
                    .overlay(
                        Capsule(style: .circular)
                            .strokeBorder(
                                isHovering && isEnabled
                                    ? DotTheme.secondaryBorderHover
                                    : DotTheme.secondaryBorder,
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(DotPressFeedback.scale(
                isPressed: configuration.isPressed,
                isEnabled: isEnabled,
                reduceMotion: reducesMotion
            ))
            .opacity(isEnabled ? 1 : 0.62)
            .animation(
                DotPressFeedback.animation(reduceMotion: reducesMotion),
                value: configuration.isPressed
            )
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .onHover { inside in
                isHovering = isEnabled && inside
            }
    }
}

/// The press every control in the app answers with.
///
/// One policy in one place: a held button shrinks to 98 per cent over 120
/// milliseconds on the app's strong ease-out. The values are a value rather than
/// four lines inside every style, so the answer an ordinary press, a disabled
/// control and a reduced-motion session get can be read — and tested — without
/// drawing anything.
enum DotPressFeedback {
    /// How far a held control shrinks.
    static let pressedScale: CGFloat = 0.98
    /// How opaque a held control becomes when it may not move.
    static let pressedOpacity: Double = 0.82
    /// How long the press takes, in seconds.
    static let duration: Double = 0.12
    /// The control points of the press curve.
    ///
    /// The app's strong ease-out, written once: a stock `easeOut` is too weak to
    /// carry a press, and a second hand-rolled curve beside this one would make
    /// two answers to the same question.
    static let curvePoints = (x1: 0.23, y1: 1.0, x2: 0.32, y2: 1.0)

    /// The curve of the press: the strong ease-out of the app's motion.
    static var curve: Animation {
        .timingCurve(
            curvePoints.x1,
            curvePoints.y1,
            curvePoints.x2,
            curvePoints.y2,
            duration: duration
        )
    }

    /// The scale a control draws at while it is held.
    ///
    /// A disabled control does not move: a press is the answer to "I heard
    /// you", and a control that cannot act has nothing to answer with. A person
    /// who asked for reduced motion gets the colour answer only, with no
    /// spatial movement at all.
    ///
    /// - Parameters:
    ///   - isPressed: whether the control is held.
    ///   - isEnabled: whether the control can act.
    ///   - reduceMotion: whether the system asked for reduced motion.
    /// - Returns: the scale to draw the control at.
    static func scale(isPressed: Bool, isEnabled: Bool, reduceMotion: Bool) -> CGFloat {
        guard isPressed, isEnabled, !reduceMotion else { return 1 }
        return pressedScale
    }

    /// The opacity a control draws at while it is held.
    ///
    /// It is the reduced-motion answer: when the scale is stilled, the press is
    /// carried by the fill alone. With the motion allowed the scale says it, so
    /// the fill keeps its colour.
    ///
    /// - Parameters:
    ///   - isPressed: whether the control is held.
    ///   - isEnabled: whether the control can act.
    ///   - reduceMotion: whether the system asked for reduced motion.
    /// - Returns: the opacity to draw the control at.
    static func opacity(isPressed: Bool, isEnabled: Bool, reduceMotion: Bool) -> Double {
        guard isPressed, isEnabled, reduceMotion else { return 1 }
        return pressedOpacity
    }

    /// The animation a press is drawn with.
    ///
    /// - Parameter reduceMotion: whether the system asked for reduced motion.
    /// - Returns: the press curve, or `nil` when nothing may move.
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : curve
    }
}

/// The shared press for a control that draws its own chrome.
///
/// It adds the press and nothing else: a row's fill, a chip's capsule and a
/// tile's border stay exactly as the view drew them, so a control with its own
/// hover affordance can take the app's press without being re-skinned.
struct DotPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DotPressBody(configuration: configuration)
    }
}

private struct DotPressBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var reducesMotion: Bool {
        reduceMotion || DotMotion.reducesMotion
    }

    var body: some View {
        configuration.label
            .scaleEffect(DotPressFeedback.scale(
                isPressed: configuration.isPressed,
                isEnabled: isEnabled,
                reduceMotion: reducesMotion
            ))
            .opacity(DotPressFeedback.opacity(
                isPressed: configuration.isPressed,
                isEnabled: isEnabled,
                reduceMotion: reducesMotion
            ))
            .animation(
                DotPressFeedback.animation(reduceMotion: reducesMotion),
                value: configuration.isPressed
            )
    }
}

/// A keyboard shortcut on paper.
struct DotKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DotType.tabularFont(12, .semibold))
            .foregroundStyle(DotTheme.ink)
            .padding(.horizontal, 9)
            // The same height as the quiet button beside it: a keycap and a
            // Change button are one row, and two heights in one row read as a
            // mistake rather than as two weights of control.
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(DotTheme.keycapFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(DotTheme.keycapBorder, lineWidth: 1)
            )
    }
}

/// A text field that sits on the paper instead of in a stock bezel.
///
/// The same chrome is used by Settings and Welcome, so a key looks the same
/// wherever it is pasted. The focused ring never draws a filled stock control.
struct DotFieldStyle: ViewModifier {
    var focused = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(DotType.font(12.5, .medium))
            .foregroundStyle(DotTheme.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(focused ? DotTheme.fieldFillFocused : DotTheme.fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        focused ? DotTheme.focusRing : DotTheme.fieldBorder,
                        lineWidth: focused ? 1.5 : 1
                    )
            )
    }
}

/// A multiline text field that sits on the paper like ``DotFieldStyle`` does.
///
/// `TextEditor` cannot draw that chrome: it is a scroll view of its own, and a
/// padding modifier around it moves the scroller inside the border, so the
/// vertical bar hangs nine points off the field's edge and reads as a second,
/// detached control. This wraps an `NSScrollView` that spans the whole rounded
/// box and lets the text view's container inset hold the text away from the
/// border instead, which leaves the overlay scroller on the box's own edge.
@MainActor
struct DotTextEditor: View {
    @Binding var text: String
    /// The height of the field, border included.
    let height: CGFloat
    /// The accessible name of the field.
    var accessibilityLabel: String = ""
    /// The explanation VoiceOver reads when the field has focus.
    var accessibilityHelp: String?
    /// The size of the text, in points.
    var fontSize: CGFloat = 12.5

    /// The radius the field and its focus ring share with ``DotFieldStyle``.
    static let cornerRadius: CGFloat = 8
    /// The inset between the border and the first character.
    ///
    /// The clip view already holds the text five points clear of the top
    /// border, so this is the room above the first line and beside the text
    /// rather than the whole distance to the border. The vertical inset is the
    /// same length as ``edgeFadeHeight``, so a line at either end of the text
    /// stands in full below the fade the field draws at that end rather than
    /// under it.
    static let textInset = NSSize(width: 9, height: 12)
    /// The room the clip view keeps clear of the field's top and bottom border.
    ///
    /// The text scrolls under the clip view, so a line that overflows the field
    /// would otherwise be cut by the rounded border itself. Insetting the clip
    /// view by this much at both ends cuts the overflow five points above the
    /// bottom border, and because only the clip view moves, the overlay
    /// scroller still spans the rounded box's own edge.
    static let verticalClipInset: CGFloat = 5
    /// The distance the text fades out over at an edge it runs past.
    ///
    /// The clip view ends the text on a hard line five points inside the
    /// border, which reads as a slice through the middle of a line. The clip
    /// view's own layer takes the ink to nothing over this distance instead, so
    /// the text dissolves at the edge it continues past and the field ends on a
    /// line rather than on a cut. The fade is drawn from the clip view's
    /// position: an edge the text stops at is fully opaque.
    static let edgeFadeHeight: CGFloat = 12

    @State private var isFocused = false

    var body: some View {
        DotTextEditorRepresentable(
            text: $text,
            fontSize: fontSize,
            accessibilityLabel: accessibilityLabel,
            accessibilityHelp: accessibilityHelp,
            onFocusChange: { isFocused = $0 }
        )
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(isFocused ? DotTheme.fieldFillFocused : DotTheme.fieldFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(
                    isFocused ? DotTheme.focusRing : DotTheme.fieldBorder,
                    lineWidth: isFocused ? 1.5 : 1
                )
        )
        .clipShape(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        )
    }

    /// The scroll view of a laid-out editor, for a test that measures the
    /// inset the border leaves it.
    ///
    /// - Parameter view: the host the editor was drawn in.
    /// - Returns: the first ``DotTextEditorScrollView`` under the host.
    static func scrollView(in view: NSView?) -> DotTextEditorScrollView? {
        guard let view else { return nil }
        if let scrollView = view as? DotTextEditorScrollView { return scrollView }
        for sub in view.subviews {
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }
}

/// The scroll view a ``DotTextEditor`` draws.
///
/// It is a named type rather than a plain `NSScrollView` so the text editor's
/// own scroll view can be found in a host without guessing which of the page's
/// scroll views is the field.
final class DotTextEditorScrollView: NSScrollView {
    /// The mask that takes the text to nothing at an edge it runs past.
    private let edgeFade = CAGradientLayer()
    /// The observers of the clip view's position and the document's height.
    ///
    /// Registered and removed on the main actor only, and the removal in
    /// `deinit` runs when no other reference to the view exists, so the tokens
    /// need no isolation of their own.
    nonisolated(unsafe) private var edgeFadeTokens: [NSObjectProtocol] = []

    /// Insets the clip view, which is what clips overflowing text clear of the
    /// border.
    ///
    /// The scroll view itself still spans the whole rounded box: only the clip
    /// view is inset, so the overlay scroller stays on the field's own edge and
    /// the text stops five points short of the bottom border instead of being
    /// sliced by it. `super.tile()` sets the clip view's frame from the scroll
    /// view's bounds on every pass, so the inset is applied to that frame
    /// rather than accumulating on the previous one.
    ///
    /// The overlay style is reasserted here because the field's chrome is the
    /// rounded box itself: a legacy scroller would take a strip out of the text
    /// rather than sit on the border, and AppKit falls back to the process's
    /// preferred style as it lays the view out.
    override func tile() {
        super.tile()
        if scrollerStyle != .overlay {
            scrollerStyle = .overlay
        }
        let frame = contentView.frame
        guard frame.height > DotTextEditor.verticalClipInset * 2 else { return }
        contentView.frame = frame.insetBy(dx: 0, dy: DotTextEditor.verticalClipInset)
        refreshEdgeFade()
    }

    /// Keeps the whole wheel gesture while the text overflows.
    ///
    /// The field sits inside the settings page's own scroll view, and at a
    /// limit AppKit hands the wheel to the next responder, which is that page:
    /// a wheel over a prompt that had reached its last line scrolled the page
    /// out from under it. While the text overflows, the field therefore
    /// consumes the event at every phase, momentum included, and moves its own
    /// clip view by the delta, so one gesture never leaves the field. A field
    /// whose text fits has nothing to consume and forwards, and a gesture that
    /// is mostly horizontal belongs to the page.
    override func scrollWheel(with event: NSEvent) {
        let keeps = keepsWheel(event)
        keptTheLastWheel = keeps
        guard keeps else {
            super.scrollWheel(with: event)
            return
        }
        let documentHeight = documentView?.frame.height ?? 0
        let clipHeight = contentView.bounds.height
        // A precise device reports points and a wheel that is not precise
        // reports lines, which the field's own line scroll converts.
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * verticalLineScroll
        let origin = contentView.bounds.origin
        let limit = max(0, documentHeight - clipHeight)
        let y = min(max(origin.y - delta, 0), limit)
        guard y != origin.y else { return }
        contentView.scroll(to: NSPoint(x: origin.x, y: y))
        reflectScrolledClipView(contentView)
        flashScrollers()
        refreshEdgeFade()
    }

    /// Whether the field keeps this wheel for its own text.
    ///
    /// The field keeps every wheel while the text overflows, whatever phase it
    /// is in, and hands on a wheel it has nothing to scroll with and one that
    /// is mostly horizontal.
    func keepsWheel(_ event: NSEvent) -> Bool {
        let documentHeight = documentView?.frame.height ?? 0
        let clipHeight = contentView.bounds.height
        guard documentHeight > clipHeight + 0.5 else { return false }
        return abs(event.scrollingDeltaX) <= abs(event.scrollingDeltaY)
    }

    /// Whether the field kept the last wheel it was handed.
    ///
    /// A wheel built in a test carries no window, and AppKit chains a wheel to
    /// the page under the pointer in the window that dispatches it: off screen
    /// neither the forward nor the chain happens, so nothing outside the field
    /// can tell a wheel the field kept from one it handed on. The field records
    /// which it did, and the tests read that beside the page's own offset.
    private(set) var keptTheLastWheel = false

    /// The layer the mask hangs on is built when the field reaches a window, so
    /// the fades are read again there as well as in `tile()`.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        observeEdgeFade()
    }

    /// Watches the two numbers the fades are read from.
    ///
    /// The clip view's position says how far each edge is from the end of the
    /// text and the document's height says whether there is anything past the
    /// edge to fade at all, so the mask is rebuilt when either of them moves.
    func observeEdgeFade() {
        for token in edgeFadeTokens {
            NotificationCenter.default.removeObserver(token)
        }
        edgeFadeTokens.removeAll()
        contentView.postsBoundsChangedNotifications = true
        contentView.wantsLayer = true
        documentView?.postsFrameChangedNotifications = true
        let names: [(Notification.Name, Any?)] = [
            (NSView.boundsDidChangeNotification, contentView),
            (NSView.frameDidChangeNotification, documentView),
        ]
        for (name, object) in names {
            edgeFadeTokens.append(NotificationCenter.default.addObserver(
                forName: name,
                object: object,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshEdgeFade() }
            })
        }
        refreshEdgeFade()
    }

    /// Draws the two edge fades from the clip view's position.
    ///
    /// The fade ramps in over the text past the padding its container keeps at
    /// that end: the padding is not text, so an edge whose padding is all that
    /// overflows stays fully opaque and the first or last line is drawn whole.
    /// Each fade is as long as the text still runs past that padding, up to
    /// ``DotTextEditor/edgeFadeHeight``. The mask is black where the text is
    /// kept and clear where it is dropped, and its stops are read from the clip
    /// view's own height, so the fade is the same number of points whatever the
    /// field's height is.
    func refreshEdgeFade() {
        guard let documentView, let layer = contentView.layer else { return }
        if layer.mask !== edgeFade {
            layer.mask = edgeFade
        }
        let clipHeight = contentView.bounds.height
        guard clipHeight > 0 else { return }
        let origin = contentView.bounds.origin.y
        let limit = max(0, documentView.frame.height - clipHeight)
        let fade = DotTextEditor.edgeFadeHeight
        // The text container keeps the same inset at both ends of the text, and
        // only what lies past it is a line a reader loses.
        let pad = DotTextEditor.textInset.height
        let topOverflow = max(0, origin - pad)
        let bottomOverflow = max(0, limit - origin - pad)
        let topLength = fade * min(1, topOverflow / fade)
        let bottomLength = fade * min(1, bottomOverflow / fade)
        let topStop = min(1, topLength / clipHeight)
        let bottomStop = min(max(0, 1 - topStop), bottomLength / clipHeight)
        let solid = CGColor(gray: 0, alpha: 1)
        let clear = CGColor(gray: 0, alpha: 0)
        // The first stop is the clip view's top edge and the last is its foot.
        // Which way the mask's own y axis runs is read from the layer rather
        // than assumed: a geometry-flipped layer puts its zero at the top and a
        // plain one at the bottom. The pixel test in `DotTextEditorScrollTests`
        // measures the ink at both edges of a drawn field, which is what proves
        // the reading is the way round a reader sees it.
        let flipped = layer.isGeometryFlipped
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edgeFade.frame = layer.bounds
        edgeFade.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        edgeFade.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
        edgeFade.locations = [0, NSNumber(value: topStop), NSNumber(value: 1 - bottomStop), 1]
        edgeFade.colors = [
            topLength > 0 ? clear : solid,
            solid,
            solid,
            bottomLength > 0 ? clear : solid,
        ]
        CATransaction.commit()
    }

    deinit {
        for token in edgeFadeTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

/// The AppKit editor behind ``DotTextEditor``.
private struct DotTextEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let accessibilityLabel: String
    let accessibilityHelp: String?
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> DotTextEditorScrollView {
        let scrollView = DotTextEditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        // The field owns the whole gesture: rubber-banding at a limit would
        // drag the text past the clip and leave it sliced by the border.
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = DotTextEditor.cornerRadius
        scrollView.layer?.cornerCurve = .continuous
        scrollView.layer?.masksToBounds = true

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = DotType.nsFont(fontSize, .medium)
        textView.textColor = NSColor(DotTheme.ink)
        textView.insertionPointColor = NSColor(DotTheme.ink)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = DotTextEditor.textInset
        // A prompt and a Markdown brief are code, not prose: the smart
        // substitutions turn `"` into a curly quote and `--` into a dash, and
        // the model reads a different prompt than the one that was typed.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHelp)
        textView.toolTip = accessibilityHelp
        textView.string = text
        scrollView.documentView = textView
        scrollView.observeEdgeFade()
        return scrollView
    }

    func updateNSView(_ scrollView: DotTextEditorScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.font = DotType.nsFont(fontSize, .medium)
        textView.textColor = NSColor(DotTheme.ink)
        textView.insertionPointColor = NSColor(DotTheme.ink)
        textView.textContainerInset = DotTextEditor.textInset
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityHelp(accessibilityHelp)
        textView.toolTip = accessibilityHelp
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let end = (text as NSString).length
            textView.setSelectedRange(
                NSRange(location: min(selection.location, end), length: 0)
            )
        }
        // New text is a new document height, and the fades are read from it.
        scrollView.refreshEdgeFade()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DotTextEditorRepresentable

        init(_ parent: DotTextEditorRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  parent.text != textView.string
            else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChange(true)
        }

        /// The ring follows the first responder rather than the notification:
        /// a window that closes or a panel that opens resigns the responder for
        /// its own reasons, and a field that lost the ring for that would look
        /// unfocused while it still holds the selection.
        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  textView.window?.firstResponder !== textView
            else { return }
            parent.onFocusChange(false)
        }
    }
}

/// The switch.
///
/// The state is carried by colour and by motion, not by the two extremes: a
/// graphite track with a black knob on paper and a bone track with a black knob
/// on ink were two different controls, and neither of them said "on". The track
/// is green when the switch is on, the warm grey of the paper's own edge when it
/// is off, and the porcelain knob slides between the two on a spring, stretching
/// the way a physical switch does while it is held.
struct DotToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        DotSwitch(configuration: configuration)
    }
}

private struct DotSwitch: View {
    let configuration: ToggleStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            configuration.label
            Button {
                configuration.isOn.toggle()
            } label: {
                EmptyView()
            }
            .buttonStyle(
                DotSwitchStyle(
                    isOn: configuration.isOn,
                    hovering: isHovering && isEnabled,
                    focused: isFocused,
                    reduceMotion: reduceMotion || DotMotion.reducesMotion
                )
            )
            .focusEffectDisabled()
            .focused($isFocused)
            .disabled(!isEnabled)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .onHover { inside in
                isHovering = inside
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Draws the track, because only a button style is told when the control is held.
private struct DotSwitchStyle: ButtonStyle {
    let isOn: Bool
    let hovering: Bool
    let focused: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        DotSwitchTrack(
            isOn: isOn,
            hovering: hovering,
            pressed: configuration.isPressed,
            focused: focused,
            reduceMotion: reduceMotion
        )
    }
}

private struct DotSwitchTrack: View {
    let isOn: Bool
    let hovering: Bool
    let pressed: Bool
    let focused: Bool
    let reduceMotion: Bool

    static let width: CGFloat = 40
    static let height: CGFloat = 23
    static let inset: CGFloat = 2
    /// How much wider the knob grows while the switch is held.
    static let stretch: CGFloat = 5

    private var knobHeight: CGFloat { Self.height - Self.inset * 2 }
    private var knobWidth: CGFloat {
        pressed && !reduceMotion ? knobHeight + Self.stretch : knobHeight
    }

    private var onFill: LinearGradient {
        LinearGradient(
            colors: [DotTheme.switchOnTop, DotTheme.switchOn],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The knob is placed, not slid, when the motion is reduced: a switch that
    /// travelled across its track was the one spatial animation a reduced-motion
    /// session still saw, and the colour of the track already says which state
    /// the switch is in.
    private var knobSlide: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78)
    }

    private var trackFade: Animation {
        reduceMotion ? .easeOut(duration: 0.14) : .easeInOut(duration: 0.22)
    }

    private var knobStretch: Animation? {
        reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 0.70)
    }

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule(style: .circular)
                .fill(DotTheme.switchOff)
                .overlay(
                    Capsule(style: .circular)
                        .strokeBorder(DotTheme.switchOffEdge, lineWidth: 0.75)
                )

            Capsule(style: .circular)
                .fill(onFill)
                .overlay(
                    Capsule(style: .circular)
                        .strokeBorder(DotTheme.switchOnEdge, lineWidth: 0.75)
                )
                .opacity(isOn ? 1 : 0)

            Capsule(style: .circular)
                .fill(DotTheme.switchHoverLift)
                .opacity(hovering ? 1 : 0)

            Circle()
                .fill(DotTheme.switchKnob)
                .overlay(
                    Circle().strokeBorder(DotTheme.switchKnobEdge, lineWidth: 0.75)
                )
                .shadow(color: DotTheme.switchKnobShadow, radius: 2, x: 0, y: 1)
                .frame(width: knobWidth, height: knobHeight)
                .padding(Self.inset)
                .animation(knobSlide, value: isOn)
                .animation(knobStretch, value: pressed)
        }
        .frame(width: Self.width, height: Self.height)
        .animation(trackFade, value: isOn)
        .animation(.easeOut(duration: 0.16), value: hovering)
        .contentShape(Capsule(style: .circular))
        .overlay(
            Capsule(style: .circular)
                .strokeBorder(focused ? DotTheme.focusRing : Color.clear, lineWidth: 1.5)
                .padding(-2.5)
                .animation(.easeOut(duration: 0.12), value: focused)
        )
        .accessibilityHidden(true)
    }
}

/// The motion answers that are not in the SwiftUI environment.
enum DotMotion {
    /// Whether the person asked the system to reduce motion.
    ///
    /// SwiftUI carries the same answer in `accessibilityReduceMotion`, but a
    /// view can be built before the environment reaches it - an offscreen
    /// render, or a control in a window that does not exist yet - so the
    /// workspace setting is read as well. Either one is enough to still a
    /// spring.
    static var reducesMotion: Bool {
        if let override = reducesMotionOverride { return override }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The answer a test gives instead of the workspace setting, or `nil` to ask
    /// the workspace. Reduce Motion cannot be turned on for one test on a Mac that
    /// has not asked for it, and the open behaves differently when it is on.
    ///
    /// It is a seam, not state the app keeps: nothing writes it outside a test,
    /// and the read below is the only reader.
    nonisolated(unsafe) static var reducesMotionOverride: Bool?
}

/// The app's mark, drawn in AppKit instead of loaded from the icon.
///
/// It is the shipped Clipped mark: a white disc on a warm graphite plate, with
/// the disc pushed past the top-right corner so the plate's own mask does the
/// cutting. The numbers come from the icon dial that produces `AppIcon.icns`, so
/// the mark in the app and the mark in the Dock are the same drawing rather than
/// two interpretations of one idea.
///
/// It used to be an indigo tile with a lavender waveform and three capsules -
/// the previous product's mark, still being drawn inside an app that had already
/// changed identity.
struct DotSignalMark: View {
    var size: CGFloat = 96
    var animated: Bool = false

    static let discScale: CGFloat = 0.66
    static let discCentre = CGPoint(x: 0.745, y: 0.255)
    static let cornerScale: CGFloat = 0.2237

    private var corner: CGFloat { size * Self.cornerScale }
    private var disc: CGFloat { size * Self.discScale }
    private var centre: CGPoint { Self.discCentre }

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let breathing = (sin(t * 2.0) + 1.0) * 0.5
                markContent(breathing: breathing)
            }
        } else {
            markContent(breathing: 0)
        }
    }

    @ViewBuilder
    private func markContent(breathing: Double) -> some View {
        let whiteGlow = Color.white
        let glowRadius = size * (0.16 + (breathing * 0.06))
        let glowOpacity = 0.16 + (breathing * 0.10)

        ZStack {
            if let icon = loadAppIcon() {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                fallbackVectorMark(breathing: breathing)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: whiteGlow.opacity(animated ? glowOpacity : 0.18), radius: glowRadius, y: size * 0.02)
        .shadow(color: Color.black.opacity(0.65), radius: size * 0.12, y: size * 0.06)
        .scaleEffect(animated ? (1.0 + (breathing * 0.02)) : 1.0)
    }

    private func loadAppIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon-1024", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        if let img = NSImage(named: "AppIcon") {
            return img
        }
        if let appIcon = NSApp?.applicationIconImage {
            return appIcon
        }
        return nil
    }

    @ViewBuilder
    private func fallbackVectorMark(breathing: Double) -> some View {
        let offsetX = size * (centre.x - 0.5)
        let offsetY = size * (centre.y - 0.5)

        let bloomOpacity = 0.15 + (breathing * 0.22)
        let bloomBlur = size * (0.05 + (breathing * 0.04))
        let bloomScale = 1.0 + (breathing * 0.08)

        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [DotTheme.markPlateTop, DotTheme.markPlateBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(DotTheme.markEdge, lineWidth: max(1, size * 0.010))
                )

            if animated {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(bloomOpacity),
                                Color.white.opacity(bloomOpacity * 0.3),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: disc * 0.35,
                            endRadius: disc * 0.8
                        )
                    )
                    .frame(width: disc * 1.5 * bloomScale, height: disc * 1.5 * bloomScale)
                    .blur(radius: bloomBlur)
                    .offset(x: offsetX, y: offsetY)
            }

            Circle()
                .fill(Color.white)
                .frame(width: disc, height: disc)
                .scaleEffect(animated ? (1.0 + breathing * 0.035) : 1.0, anchor: .center)
                .offset(x: offsetX, y: offsetY)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

// MARK: - Appearance

extension View {
    /// Draws this view in the scheme the configuration selects.
    ///
    /// SwiftUI resolves a dynamic `NSColor` against the scheme in its own
    /// environment and keeps what it resolved. A window whose AppKit appearance
    /// changed but whose environment did not went on drawing the old palette
    /// until something else rebuilt the tree, which is why a theme tile felt
    /// like it took seconds to answer - or never answered at all. Naming the
    /// scheme here puts the choice into the view, so the reply is the same
    /// display cycle as the click.
    ///
    /// `system` is deliberately not named: the window then takes the Mac's
    /// appearance and SwiftUI follows it, which is the behaviour that case is
    /// asking for. Pinning a resolved value here would freeze a window that is
    /// meant to follow the system.
    @ViewBuilder
    func dotAppearance(_ mode: AppearanceMode) -> some View {
        switch mode {
        case .light:
            environment(\.colorScheme, ColorScheme.light)
        case .dark:
            environment(\.colorScheme, ColorScheme.dark)
        case .system:
            self
        }
    }
}
