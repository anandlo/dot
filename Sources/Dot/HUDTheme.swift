import AppKit
import DotCore
import SwiftUI

/// The colours, the type and the measurements of the card.
///
/// The card is porcelain on warm ink. The waveform is the mark's own porcelain,
/// the live dot is amber, and success is mint: the card has no second palette,
/// and its only colour is a status one.
enum HUDTheme {
    // MARK: - Surface

    /// The top of the card's surface.
    static let surfaceTop = Color(red: 0.071, green: 0.061, blue: 0.051)
    /// The bottom of the card's surface.
    static let surfaceBottom = Color(red: 0.031, green: 0.026, blue: 0.022)
    /// The opacity of the surface. High enough that nothing reads through it.
    static let surfaceOpacity: Double = 0.985
    /// The top of the border.
    static let borderTop = Color.white.opacity(0.12)
    /// The bottom of the border.
    static let borderBottom = Color.white.opacity(0.035)

    // MARK: - Ink

    /// The sRGB components of ``inkBase``.
    ///
    /// A style that mixes its own lit ink toward the card's ink mixes components
    /// rather than colours, so the components the card's inks are built from are
    /// read from one place instead of being written a second time.
    static let inkRGB: (red: Double, green: Double, blue: Double) = (1.0, 0.957, 0.902)

    /// The card's ink without its opacity.
    ///
    /// Every ink is this one colour at an opacity, so a token that measures an
    /// opacity per material is a token over the same hue rather than a second
    /// colour that can drift from the first.
    static let inkBase = Color(red: inkRGB.red, green: inkRGB.green, blue: inkRGB.blue)
    /// The primary text and the waveform.
    static let ink = inkBase.opacity(0.95)
    /// The secondary text.
    static let ink2 = inkBase.opacity(0.70)
    /// The tertiary text.
    static let ink3 = inkBase.opacity(0.38)

    // MARK: - Accents

    /// The waveform: the voice drawn in the icon's own porcelain, not a second
    /// colour the product never shipped.
    ///
    /// It is the ink of the card's quieter marks. The voice itself is drawn in
    /// ``live``: see ``meter(_:ceiling:)``.
    static let accent = Color(red: 0.949, green: 0.929, blue: 0.898).opacity(0.72)
    /// The bright tip of the waveform.
    static let accentTip = Color(red: 1.0, green: 0.984, blue: 0.957).opacity(0.95)
    /// Success: a transcript that was copied or pasted.
    static let mint = Color(red: 0.722, green: 0.690, blue: 0.643)
    /// Success, named for what it is: a quiet silver.
    static let silver = mint
    /// Active voice on the Black card, `#FFC414`.
    ///
    /// The live dot, the recording sparkle, the speaking marks and the Stop
    /// control all share the body stop of the visualizer's gold ramp, so the
    /// marks beside a bar are the same gold as the bar.
    static let recording = Color(red: 1, green: 196.0 / 255, blue: 20.0 / 255)
    /// Active voice on the Glass card, `#FFD838`.
    static let recordingGlass = Color(red: 1, green: 216.0 / 255, blue: 56.0 / 255)
    /// The active-voice colour of one material.
    static func recordingInk(_ material: HUDMaterial) -> Color {
        material == .glass ? recordingGlass : recording
    }
    /// A warning or a failure, the earlier live amber `#F5B944`.
    ///
    /// It stays separate from the voice: a failed rewrite is not a recording,
    /// and giving it the visualizer's bright gold would make the two states
    /// hard to tell apart.
    static let warning = Color(red: 0.961, green: 0.725, blue: 0.267)
    /// The running arc on the selected, cream pill, `#8A5A0F`.
    ///
    /// The live amber is a light colour: on the cream pill it reads at about
    /// 1.5:1, which a 1.5 point ring cannot carry. This is the same hue taken
    /// down until the ring clears 3:1 against the pill; the label keeps the
    /// card's dark ink, so the selected chip still reads as selected.
    static let arcOnPill = Color(red: 138 / 255, green: 90 / 255, blue: 15 / 255)
    /// The transcribing state.
    static let amber = Color(red: 0.659, green: 0.639, blue: 0.604)
    /// The faithfulness badge of a rewrite that kept every fact.
    ///
    /// The card's only other status colours are the amber of the live dot and
    /// the silver of a delivery, and a silver dot beside the word "Faithful"
    /// read as decoration rather than as "this one is safe".
    static let faithful = Color(red: 0.361, green: 0.749, blue: 0.435)

    /// The colour of one bar of the meter.
    ///
    /// - Parameters:
    ///   - level: the height of the bar, from `0` to `1`.
    ///   - ceiling: the loudest moment of this take, from `0` to `1`.
    /// - Returns: a warm amber, dim and short at the floor, bright with a warm
    ///   tip at a peak. Never white: the top of the shape has to keep a colour
    ///   to say "that was loud" with.
    static func meter(_ level: Double, ceiling: Double, material: HUDMaterial = .black) -> Color {
        let tint = MeterRamp.tint(level: level, ceiling: ceiling, material: material)
        return Color(red: tint.red, green: tint.green, blue: tint.blue).opacity(tint.opacity)
    }

    // MARK: - Type

    /// The size of the small caps label.
    static let labelFontSize: CGFloat = 10.5
    /// The small caps label.
    static var labelFont: Font { DotType.font(labelFontSize, .semibold) }
    /// The clock's size.
    static let clockFontSize: CGFloat = 12
    /// The clock.
    ///
    /// The face's own figures are proportional, so the clock is set in the
    /// tabular face and carries the tracking that goes with it: the number stays
    /// still while the seconds change, and its digits take the width the card
    /// was laid out for.
    static var clockFont: Font { DotType.tabularFont(clockFontSize, .medium) }
    /// The tracking that belongs to ``clockFont``.
    ///
    /// Read from the clock's own font, so the value follows the face the card is
    /// actually drawn in rather than whatever the process resolved last.
    static var clockTracking: CGFloat {
        DotType.tabularTracking(size: clockFontSize, in: DotType.tabularNSFont(clockFontSize, .medium))
    }
    /// The transcript.
    ///
    /// The face is resolved on every read rather than kept: a font registered
    /// after this token was first touched still has to be seen, and the
    /// resolver caches what it built so a view body pays a lookup, not a
    /// descriptor.
    static var transcriptFont: Font { DotType.font(15, .regular) }
    /// The live partial the recording card shows below the waveform.
    static var liveFont: Font { DotType.font(13, .regular) }
    /// The message.
    static var messageFont: Font { DotType.font(13, .medium) }
    /// The one line of an assistant card that is not a transcript.
    static var assistantFont: Font { DotType.font(13, .regular) }

    /// The tracking of the small caps labels.
    static let labelTracking: CGFloat = 1.6
    /// The distance between two lines of the transcript.
    static let transcriptLineSpacing: CGFloat = 5
    /// The height of one line of the transcript, spacing included.
    static let transcriptLineHeight: CGFloat = 22
    /// The distance between the two lines of the live partial.
    static let liveLineSpacing: CGFloat = 1
    /// How much room the live partial keeps below it.
    static let liveBottomPadding: CGFloat = 6

    // MARK: - Geometry

    /// The corner radius of the card.
    static let cornerRadius: CGFloat = 17
    /// The card's horizontal padding.
    static let padding: CGFloat = 16
    /// The card's vertical padding.
    static let verticalPadding: CGFloat = 13
    /// The height of the waveform.
    static let waveformHeight: CGFloat = 26
    /// The diameter of the live dot.
    static let dotDiameter: CGFloat = 8
    /// The height of the transcript header.
    static let headerHeight: CGFloat = 44
    /// The size of the delivery badge.
    static let badgeSize: CGFloat = 20

    // MARK: - Controls

    /// The size of one icon button in the card.
    static let actionSize: CGFloat = 24
    /// The font of an icon button.
    static var actionFont: Font { DotType.font(10, .semibold) }
    /// The quiet fill of an icon button.
    static let actionFill = Color.white.opacity(0.055)
    /// The fill of an icon button under the pointer.
    static let actionFillHover = Color.white.opacity(0.13)
    /// The quiet border of an icon button.
    static let actionBorder = Color.white.opacity(0.045)
    /// The border of an icon button under the pointer.
    static let actionBorderHover = Color.white.opacity(0.14)
    /// The font of the titled button a message card offers.
    static var messageActionFont: Font { DotType.font(11.5, .medium) }
    /// The padding inside the titled button, on the left and the right, in points.
    static let messageActionHPadding: CGFloat = 10
    /// The height of the titled button, in points.
    static let messageActionHeight: CGFloat = 22
    /// The gap between the titled button and the icon buttons, in points.
    static let messageActionGap: CGFloat = 10
    /// The divider between the content and the actions.
    static let hairline = Color.white.opacity(0.075)

    // MARK: - Glass

    /// The colour the recording card's Liquid Glass is tinted with.
    static let glassTint = Color(red: 0.05, green: 0.06, blue: 0.09)

    /// How opaque that tint is, measured against the ink the card has to carry.
    ///
    /// Liquid Glass is a refracting material, not a wash. On a bright page it
    /// lifts the backdrop toward white, and ink over it loses contrast faster
    /// than a tint can put back. The table below was measured on the regular
    /// variant, through window-server captures of the real 316 by 54 card, over
    /// a white backdrop (luma 0.92), a mid grey (0.5), a dark page (0.12) and a
    /// colour photograph, as the WCAG ratio of ``ink`` against the pixels behind
    /// the REC glyphs:
    ///
    /// | tint | white | grey | dark | colour |
    /// | 0.00 | 1.96  | 3.49 | 10.66 | 6.87 |
    /// | 0.25 | 1.83  | 3.23 | 9.77  | 6.24 |
    /// | 0.35 | 1.78  | 3.11 | 9.34  | 6.01 |
    /// | 0.45 | 1.74  | 2.99 | 9.07  | 5.81 |
    /// | 0.55 | 1.69  | 2.91 | 8.67  | 5.56 |
    ///
    /// Every step of tint lowered all four, because a dark tint on this material
    /// brightens the fill in the dark appearance the island's panel forces. The
    /// card therefore ships the material untinted. The contrast the ink needs is
    /// carried by the scrim in ``glassScrimOpacity`` instead, which is drawn
    /// over the material, and the card draws the clear variant in
    /// ``glassVariant``: a tint on the clear variant is not measured, because
    /// the tint's own table is the reason there is none.
    static let glassTintOpacity: Double = 0

    /// The variant of the system glass the card draws.
    ///
    /// The regular variant carries the system's own dimming; the clear variant
    /// is the one Apple specifies for a surface over a visually rich backdrop,
    /// and it is what the card draws. Measured at the shipped scrim through
    /// window-server captures of the real 316 by 54 card, the WCAG ratio of
    /// ``ink`` against the pixels behind the REC glyphs was:
    ///
    /// | variant | wave | wave-bright | white | dark  | bands |
    /// | regular | 5.39 | 4.67        | 3.70  | 13.05 | 4.08  |
    /// | clear   | 5.78 | 4.86        | 3.20  | 13.53 | 3.94  |
    ///
    /// The table was measured with the clock at 0.55, before
    /// ``clockInkOpacity`` was raised; the label's box keeps the first figure of
    /// the clock inside its right edge, which moved the bands cell to 3.93 at the
    /// shipped clock ink.
    ///
    /// The backdrop's own chroma survived the card's interior at 0.83 (regular)
    /// and 0.68 (clear) on the blue wave, 0.80 and 0.71 on the pale sky, 0.72
    /// and 0.68 on the bands, and with no scrim at all at 1.12 and 0.91 on the
    /// wave: the clear variant leaves the backdrop's colours where the
    /// photograph put them, and the regular variant's own dimming lifts them
    /// above what the photograph holds. The card draws clear, which is the
    /// variant Apple specifies for a surface over a visually rich backdrop, and
    /// the ink's contrast is carried by the scrim rather than by the material's
    /// dimming.
    static let glassVariant: HUDGlassVariant = .clear

    /// The opacity of the black scrim the card's ink is carried on.
    ///
    /// A tint cannot lift the ink's contrast: every step of it lowered all four
    /// backdrops. A scrim does, because the ink is drawn over it rather than
    /// through it, and it is placed over the material so the material cannot
    /// sample it and lift it back toward white.
    ///
    /// Measured on the clear variant, through window-server captures of the real
    /// 316 by 54 card, over the five backdrops the glass sweep draws: the
    /// reference photograph's blue wave (B1) and its pale sky and light wave
    /// (B2), a white page at luma 0.92 (B3), a dark page at 0.12 (B4) and the
    /// twelve saturated colour bands the capture tests draw (B5). The WCAG ratio
    /// of ``ink`` against the pixels behind the REC glyphs was:
    ///
    /// | scrim | wave | wave-bright | white | dark  | bands |
    /// | 0.00  | 3.33 | 2.69        | 1.64  | 11.28 | 2.08  |
    /// | 0.15  | 4.35 | 3.58        | 2.24  | 12.40 | 2.80  |
    /// | 0.30  | 5.78 | 4.86        | 3.20  | 13.53 | 3.93  |
    ///
    /// The smallest scrim that carries the label past 3 to 1 on the two bright
    /// backdrops is 0.30: on the pale sky 0.15 leaves it at 3.58 and on the white
    /// page 2.24. At 0.30 the backdrop's colour still survives at 0.68 of its
    /// own chroma on the wave, 0.71 on the pale sky and 0.68 on the bands, and
    /// the material still refracts: the mean absolute difference of the card's
    /// interior between the wave and the white page is 48.38 levels of 255. The
    /// specular rim's brightest pixel stands 0.117 of luminance above the
    /// interior on the pale sky and 0.241 on the white page.
    ///
    /// A dim layer under the material was measured and rejected. At 0.20 it
    /// lifted the REC ratio on the white page from 3.20 to 4.38 but took the
    /// wave's chroma from 0.68 to 0.56; at 0.35 to 5.51 and 0.47. The ink shadow
    /// was measured too and rejected: it moved the card's interior by 0.46 of
    /// 255 and its contrast by less than 0.05 to 1 on every backdrop.
    static let glassScrimOpacity: Double = 0.30

    /// The system's Liquid Glass at ``glassVariant``, tinted to the measured
    /// opacity.
    ///
    /// A zero-opacity tint is the same picture as no tint with a call that says
    /// something untrue about the material, so at zero the untinted material is
    /// asked for.
    @available(macOS 26.0, *)
    static var glass: Glass {
        let material: Glass = glassVariant == .clear ? .clear : .regular
        return glassTintOpacity > 0
            ? material.tint(glassTint.opacity(glassTintOpacity))
            : material
    }

    /// The opacity of the clock's ink on the glass material.
    ///
    /// The clock is the quietest glyph the card draws, and the glass leaves it on
    /// whatever the backdrop is. At 0.55 it read 2.06 to 1 on the
    /// white page at the shipped glass, under the 3 to 1 a small figure needs, so
    /// the glass card draws the clock at this opacity. The steps that were
    /// measured on the white page, one render each:
    ///
    /// | opacity | ratio |
    /// | 0.55    | 2.06  |
    /// | 0.60    | 2.19  |
    /// | 0.65    | 2.33  |
    /// | 0.70    | 2.46  |
    /// | 0.75    | 2.60  |
    /// | 0.80    | 2.74  |
    /// | 0.85    | 2.89  |
    /// | 0.90    | 3.06  |
    ///
    /// 0.90 is the smallest step that clears 3 to 1. At it the clock reads 5.49
    /// on the wave, 4.72 on the pale sky, 3.06 on the white page, 12.32 on the
    /// dark page and 4.12 on the bands. The black card's clock is ``ink2``.
    static let clockInkOpacity: Double = 0.90

    /// The opacity of the transcript header's status ink on the glass material.
    ///
    /// A delivery's own colour is ``silver``, and a failure's is ``live``. Both
    /// are opaque, so there is no opacity of either left to raise: on the glass
    /// material a bright backdrop left the label at 1.70 to 1 on the white page,
    /// under the 3 to 1 a small caps label needs, and 3.50 on the blue wave. The
    /// glass card therefore draws the status label and its glyph in the card's
    /// own ink at this opacity, and the delivery's colour survives in the badge's
    /// tint and in the word itself. The black card keeps the delivery's own
    /// colour, where silver reads 4.4 to 1 and nothing needed to change.
    ///
    /// The steps that were measured on the white page, one render each:
    ///
    /// | opacity | ratio |
    /// | 0.55    | 2.06  |
    /// | 0.60    | 2.19  |
    /// | 0.65    | 2.33  |
    /// | 0.70    | 2.46  |
    /// | 0.75    | 2.60  |
    /// | 0.80    | 2.74  |
    /// | 0.85    | 2.89  |
    /// | 0.90    | 3.06  |
    ///
    /// 0.90 is the smallest step that clears 3 to 1. At it the label reads 5.97
    /// on the blue wave, 4.60 on the pale sky, 3.06 on the white page, 12.32 on
    /// the dark page and 3.72 on the colour bands. The box the ratio is read in
    /// covers the badge, its glyph and the label, so the median is the header's
    /// own surface; it is measured once on the white page, where that surface is
    /// one colour.
    static let statusInkOpacity: Double = 0.90

    /// The transcript header's status ink on one material.
    ///
    /// - Parameters:
    ///   - colour: the delivery's own colour, or ``live`` for a failure.
    ///   - material: the card's fill.
    ///   - useSystemInk: whether Glass draws its labels with semantic ink.
    ///     The measured cream token remains the default for callers that judge
    ///     that token rather than the live card.
    /// - Returns: the colour the status label and its glyph are drawn in.
    static func statusInk(
        _ colour: Color,
        material: HUDMaterial,
        useSystemInk: Bool = false
    ) -> Color {
        if useSystemInk, material == .glass { return Color.primary }
        guard material == .glass else { return colour }
        return inkBase.opacity(statusInkOpacity)
    }

    /// The clock's ink on one material.
    ///
    /// - Parameters:
    ///   - material: the card's fill. The black card's clock is
    ///     ``ink2``; the glass card's is the same colour at
    ///     ``clockInkOpacity`` unless semantic ink is requested.
    ///   - useSystemInk: whether Glass draws its labels with semantic ink.
    /// - Returns: the colour the clock's figures are drawn in.
    static func clockInk(_ material: HUDMaterial, useSystemInk: Bool = false) -> Color {
        if useSystemInk, material == .glass { return Color.secondary }
        guard material == .glass else { return ink2 }
        return inkBase.opacity(clockInkOpacity)
    }

    // The visualizer no longer lifts its ink toward the card's white. Each
    // material draws its own gold stops from MeterRamp, and the specular stop is
    // used only where the picture has a physical highlight: a loud bar's centre,
    // a lit dot's die, a ribbon's upper rim and the orbit's sun.
}

/// The variant of the system's Liquid Glass a surface asks for.
///
/// The two are not opacities of one material: the regular variant carries the
/// system's own dimming, and the clear variant is the one Apple specifies for a
/// surface over a visually rich backdrop. The card draws clear, see
/// ``HUDTheme/glassVariant``.
enum HUDGlassVariant: String, CaseIterable, Sendable {
    /// The variant with the system's own dimming.
    case regular
    /// The highly translucent variant, which the card draws.
    case clear
}

/// Native macOS behind-window backdrop blur using NSVisualEffectView.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
    }
}

/// Which rung of the card's ink ladder a label sits on.
enum HUDInkLevel {
    case primary
    case secondary
    case tertiary
}

private struct HUDUsesSystemInkKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the card's labels use the system's semantic ink. Glass sets it;
    /// Black and the fallback leave it false and keep the cream tokens.
    var hudUsesSystemInk: Bool {
        get { self[HUDUsesSystemInkKey.self] }
        set { self[HUDUsesSystemInkKey.self] = newValue }
    }
}

private struct HUDInkModifier: ViewModifier {
    @Environment(\.hudUsesSystemInk) private var useSystemInk
    let level: HUDInkLevel
    let opacity: Double

    func body(content: Content) -> some View {
        Group {
            if useSystemInk {
                switch level {
                case .primary: content.foregroundStyle(.primary)
                case .secondary: content.foregroundStyle(.secondary)
                case .tertiary: content.foregroundStyle(.tertiary)
                }
            } else {
                switch level {
                case .primary: content.foregroundStyle(HUDTheme.ink.opacity(opacity))
                case .secondary: content.foregroundStyle(HUDTheme.ink2.opacity(opacity))
                case .tertiary: content.foregroundStyle(HUDTheme.ink3.opacity(opacity))
                }
            }
        }
        .opacity(useSystemInk && opacity < 1 ? opacity : 1)
    }
}

extension View {
    /// Applies the card's ink for the current material.
    func hudInk(_ level: HUDInkLevel, opacity: Double = 1) -> some View {
        modifier(HUDInkModifier(level: level, opacity: opacity))
    }

    /// Applies the material's ink in one state and a fixed colour in another,
    /// for controls whose accent or warning colour must stay unchanged.
    func hudInk(
        _ level: HUDInkLevel,
        when useInk: Bool,
        otherwise color: Color,
        opacity: Double = 1
    ) -> some View {
        Group {
            if useInk {
                self.hudInk(level, opacity: opacity)
            } else {
                self.foregroundStyle(color).opacity(opacity)
            }
        }
    }
}

/// The surface of the card: one shape, one fill, one border, supporting Glass and Black materials.
///
/// On macOS 26 and later the Glass fill is the system's Liquid Glass at its
/// regular, adaptive variant. The material draws the backdrop, the refraction
/// and its own edge; the app draws neither a wash, a tint, a specular highlight
/// nor a rim on top of it, and its labels use the system's semantic ink.
/// Before macOS 26 there is no such material, so the same shape is filled with
/// the behind-window blur, the smoky tint and the specular sheen the app has
/// always drawn, under its own 1.25 point rim. Black is one opaque gradient on
/// every system, because an opaque card has nothing to refract.
struct HUDSurface: View {
    var material: HUDMaterial = .glass
    /// Whether the legacy Glass fill samples the desktop behind the window.
    ///
    /// In the island the card is over the person's desktop, and the behind-window
    /// blur is what makes the fill glass. A Settings tile has no desktop behind
    /// it: the page is opaque, so a behind-window sampler would read the page
    /// itself and lift the card into a grey wash. The tile turns the sampler off
    /// and draws the same tint and the same specular over a backdrop of its own,
    /// so the two pictures are the legacy material at two sizes. The system's
    /// Liquid Glass samples what is behind the window and has no switch, which is
    /// why on macOS 26 the Settings tile draws its own glass rather than this
    /// fill.
    var samplesDesktop: Bool = true
    /// Whether Glass is drawn with the system material.
    ///
    /// It is true wherever the system has the material. A test sets it false to
    /// render the pre-26 fill on a system that has the new one, so the path a Mac
    /// without Liquid Glass takes stays proved rather than shipping blind.
    var useSystemGlass: Bool = true

    /// Whether a material draws the system's Liquid Glass on this system.
    ///
    /// The card's shadow is chosen by the same answer: Liquid Glass carries its
    /// own edge and sits lighter on the desktop than the filled shape it
    /// replaces, so it casts a shorter, softer shadow.
    static func drawsSystemGlass(_ material: HUDMaterial, useSystemGlass: Bool = true) -> Bool {
        guard material == .glass, useSystemGlass else { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        ZStack {
            if material == .glass {
                if Self.drawsSystemGlass(material, useSystemGlass: useSystemGlass) {
                    if #available(macOS 26.0, *) {
                        systemGlass
                    }
                } else {
                    legacyGlass
                }
            } else {
                black
            }

            // The material draws its own edge, so a rim over it would be a second
            // border a pixel inside the first.
            if !Self.drawsSystemGlass(material, useSystemGlass: useSystemGlass) {
                RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: material == .glass ? 1.25 : 1)
            }
        }
    }

    /// The fill on macOS 26 and later: the system's untinted Liquid Glass at its
    /// regular, adaptive variant. The material's own legibility treatment is used
    /// instead of an app-drawn wash, so nothing covers the rim or the backdrop.
    @available(macOS 26.0, *)
    private var systemGlass: some View {
        Color.clear
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
            )
    }

    /// The fill before Liquid Glass: the behind-window blur, the tint and the sheen.
    private var legacyGlass: some View {
        ZStack {
            // The desktop showing through the card.
            if samplesDesktop {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                    .clipShape(RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous))
            }

            // Translucent smoky glass tint (translucent so backdrop shows through)
            RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.13, blue: 0.16).opacity(0.32),
                            Color(red: 0.06, green: 0.07, blue: 0.09).opacity(0.42),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Refined glass specular highlight
            RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.26), location: 0),
                            .init(color: Color.white.opacity(0.04), location: 0.32),
                            .init(color: Color.clear, location: 0.65),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    /// The fill for the Black material: one opaque matte gradient.
    private var black: some View {
        RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.06, blue: 0.07),
                        Color(red: 0.02, green: 0.02, blue: 0.025),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private var border: LinearGradient {
        switch material {
        case .glass:
            // Polished chamfered glass specular rim
            LinearGradient(
                colors: [
                    Color.white.opacity(0.38),
                    Color.white.opacity(0.14),
                    Color.white.opacity(0.05),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .black:
            // Quiet, stealthy, matte black edge
            LinearGradient(
                colors: [
                    Color.white.opacity(0.09),
                    Color.white.opacity(0.02),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
