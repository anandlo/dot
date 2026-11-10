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
    /// The card shadow.
    static let cardShadow = adaptive(light: black(0.07), dark: black(0.32))

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
    /// The plate's own warm graphite rather than the indigo accent: the sidebar
    /// carries the app's identity, and a navy pill on porcelain paper was a
    /// second, unrelated accent sitting next to the mark.
    static let sidebarSelectedFill = adaptive(light: ns(0.169, 0.157, 0.133), dark: ns(0.208, 0.196, 0.176))
    /// The border of the selected sidebar pill: a highlight along the top of a
    /// dark plate, not a coloured ring.
    static let sidebarSelectedBorder = adaptive(light: white(0.16), dark: white(0.13))
    /// The selected sidebar text.
    static let sidebarSelectedText = adaptive(light: white(1), dark: ns(0.980, 0.969, 0.953))
    /// The selected sidebar icon.
    static let sidebarSelectedIcon = adaptive(light: white(0.78), dark: white(0.74))
    /// The hover wash of an unselected sidebar item.
    static let sidebarHoverFill = adaptive(light: white(0.55), dark: white(0.055))

    /// The glow in the top-left corner of the paper.
    static let paperGlow = adaptive(light: white(0.65), dark: white(0.050))
    /// The warm shade at the bottom of the paper.
    static let paperShade = adaptive(light: ns(0.42, 0.31, 0.20, 0.06), dark: black(0.30))

    /// The off track of a switch.
    static let toggleTrack = adaptive(light: black(0.20), dark: white(0.22))
    /// The border of the off track.
    static let toggleTrackBorder = adaptive(light: black(0.12), dark: white(0.16))
    /// The on track of a switch.
    static let toggleOn = adaptive(light: ns(0.169, 0.157, 0.133), dark: ns(0.949, 0.929, 0.898))
    /// The border of the on track.
    static let toggleOnBorder = adaptive(light: black(0.18), dark: white(0.30))
    /// The switch knob.
    static let toggleKnob = adaptive(light: white(1), dark: ns(0.953, 0.929, 0.894))
    /// The border that keeps the knob visible on a pale track.
    static let toggleKnobBorder = adaptive(light: black(0.16), dark: black(0.30))
    /// The shadow under the knob.
    static let toggleKnobShadow = adaptive(light: black(0.22), dark: black(0.50))

    /// The focus ring around a control.
    static let focusRing = adaptive(light: black(0.45), dark: white(0.60))
    /// The unfilled track of a slider.
    static let sliderTrack = adaptive(light: black(0.16), dark: white(0.18))
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
    static let cardCorner: CGFloat = 16
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

    private static func indigoAlpha(_ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: 0.122, green: 0.176, blue: 0.361, alpha: alpha)
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

/// A raised sheet on the paper.
struct DotCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                // The border is drawn behind the content, not over it. A list
                // that opens out of a card is drawn over the card's own edge,
                // and a border in an overlay drew a hairline straight across
                // it: the faint line that ran through the provider list.
                RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                    .fill(DotTheme.cardFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                            .strokeBorder(DotTheme.cardBorder, lineWidth: 1)
                    )
            )
            .shadow(color: DotTheme.cardShadow, radius: 12, x: 0, y: 6)
            .dotSelectLayer()
    }
}

/// A piece of advice, drawn as advice.
///
/// It is deliberately not a card. A tip inside a card has the same fill, the
/// same border and the same weight as a control, so a page of settings and
/// suggestions stops telling the difference between what can be changed and
/// what is worth knowing. A tip is quiet type with a small glyph and nothing
/// else around it.
struct DotTip: View {
    /// The glyph that names the kind of advice.
    let symbol: String
    /// The advice itself.
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DotTheme.ink3)
                .frame(width: 13, height: 13)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(DotTheme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
        .accessibilityElement(children: .combine)
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

/// The solid button used for the primary action: clean, minimal, and crisp with zero glowing bloom.
struct DotPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(DotTheme.onAccent)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(DotTheme.accent)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The secondary button on paper: clean minimal capsule with crisp hairline border.
struct DotSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(isEnabled ? DotTheme.ink : DotTheme.ink3)
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(DotTheme.secondaryFill)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(DotTheme.secondaryBorder, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .opacity(isEnabled ? 1 : 0.62)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
            .padding(.vertical, 5)
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

/// A switch styled after the tactile "happy-warthog-87" slider from Uiverse,
/// tailored with Dot's own theme palette.
///
/// Features a recessed capsule track with an inset shadow, a pure porcelain
/// knob with 3D drop shadow that glides smoothly and squishes on active press,
/// and transitions into Dot's active theme accent when switched on.
struct DotToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        DotToggleBody(configuration: configuration)
    }
}

private struct DotToggleBody: View {
    let configuration: ToggleStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            configuration.label
            Button {
                configuration.isOn.toggle()
            } label: {
                track
            }
            .buttonStyle(DotTogglePressStyle(isOn: configuration.isOn))
            .focusEffectDisabled()
            .focused($isFocused)
            .disabled(!isEnabled)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .animation(motion, value: configuration.isOn)
            .onHover { inside in
                isHovering = inside
            }
        }
        .opacity(isEnabled ? 1 : 0.55)
    }

    private var track: some View {
        ZStack(alignment: configuration.isOn ? .trailing : .leading) {
            // Minimal modern track
            Capsule(style: .continuous)
                .fill(
                    configuration.isOn
                        ? DotTheme.accent
                        : (isHovering ? Color.white.opacity(0.18) : Color.white.opacity(0.12))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            configuration.isOn
                                ? DotTheme.accent.opacity(0.40)
                                : Color.white.opacity(0.08),
                            lineWidth: 0.75
                        )
                )

            // Minimal precision porcelain knob with high contrast in both states
            Circle()
                .fill(
                    configuration.isOn
                        ? Color(white: 0.12)
                        : Color.white.opacity(0.92)
                )
                .shadow(color: Color.black.opacity(0.24), radius: 1.5, x: 0, y: 0.75)
                .padding(2)
        }
        .frame(width: 36, height: 20)
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isFocused ? DotTheme.focusRing : .clear, lineWidth: 1.5)
                .padding(-2)
        )
        .contentShape(Capsule(style: .continuous))
    }

    private var motion: Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.22, dampingFraction: 0.80)
    }
}

private struct DotTogglePressStyle: ButtonStyle {
    let isOn: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.8),
                value: configuration.isPressed
            )
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

/// The smooth signal wave, the same shape as the app icon.
struct SignalWave: Shape {
    /// The moment the still line draws.
    ///
    /// A swatch is a picture, not a live meter, so the moment is fixed; what it
    /// shows is a voice, because a sine draws a wave with every crest identical
    /// and the preview then advertises nothing the card actually does.
    var moment: Double = 2.4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = 120
        for index in 0...count {
            let t = Double(index) / Double(count)
            let x = rect.minX + rect.width * t
            // Quiet at both ends, present in the middle, and irregular in
            // between, the way a voice is.
            let taper = sin(Double.pi * t)
            let voice = SpeechShape.value(at: t, time: moment) * 2 - 1
            let y = rect.midY - rect.height * 0.5 * taper * voice
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
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
