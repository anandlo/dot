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
    /// Rounded, because the mark is a circle on a rounded plate and the system's
    /// default face beside it read as a stock window. A page title is the one
    /// piece of type on a page that can carry the product's voice.
    /// The face the app's own name and page titles are set in.
    ///
    /// New York, not SF. `design: .rounded` was asked for and silently returned
    /// plain SF: SF Pro Rounded is an optional download and this Mac does not
    /// have it, so the titles rendered in the same face as every other word on
    /// the page. The serif is bundled everywhere and is the one face that makes
    /// a page title read as a title: it is the app's paper-and-ink voice, and no
    /// other app on the Mac sets its headings in it.
    static func displayFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }

    static let titleFont = displayFont(22)
    static let sectionFont = Font.system(size: 15, weight: .semibold)
    static let bodyFont = Font.system(size: 13, weight: .regular)
    static let smallFont = Font.system(size: 11.5, weight: .regular)
    static let labelFont = Font.system(size: 10.5, weight: .semibold)
    /// The name of a setting.
    static let rowTitleFont = Font.system(size: 12.5, weight: .medium)
    /// The line under a setting that says what it does. One size everywhere:
    /// the pages used to mix 10.5 and 11, which read as two ranks of the same
    /// thing.
    static let rowDetailFont = Font.system(size: 11, weight: .regular)
    /// The caps label above a field or a card.
    static let fieldLabelFont = Font.system(size: 9.5, weight: .semibold)

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
                        .font(DotTheme.smallFont)
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
            return 0.97
        }
        return isHovering ? 1.015 : 1
    }

    private var reducesMotion: Bool {
        reduceMotion || DotMotion.reducesMotion
    }

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
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
                reducesMotion ? .easeOut(duration: 0.10) : .spring(response: 0.24, dampingFraction: 0.72),
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
            .font(.system(size: 12.5, weight: .medium))
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
            .scaleEffect(
                configuration.isPressed && isEnabled && !reducesMotion ? 0.97 : 1
            )
            .opacity(isEnabled ? 1 : 0.62)
            .animation(
                reducesMotion ? nil : .spring(response: 0.22, dampingFraction: 0.74),
                value: configuration.isPressed
            )
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .onHover { inside in
                isHovering = isEnabled && inside
            }
    }
}

/// A keyboard shortcut on paper.
struct DotKeycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
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
            .font(.system(size: 12.5))
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

    private var knobSlide: Animation {
        reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.28, dampingFraction: 0.78)
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
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
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
