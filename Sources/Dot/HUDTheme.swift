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

    /// The primary text and the waveform.
    static let ink = Color(red: 1.0, green: 0.957, blue: 0.902).opacity(0.95)
    /// The secondary text.
    static let ink2 = Color(red: 1.0, green: 0.957, blue: 0.902).opacity(0.55)
    /// The tertiary text.
    static let ink3 = Color(red: 1.0, green: 0.957, blue: 0.902).opacity(0.38)

    // MARK: - Accents

    /// The waveform: the voice drawn in the icon's own porcelain, not a second
    /// colour the product never shipped.
    static let accent = Color(red: 0.949, green: 0.929, blue: 0.898).opacity(0.72)
    /// The bright tip of the waveform.
    static let accentTip = Color(red: 1.0, green: 0.984, blue: 0.957).opacity(0.95)
    /// Success: a transcript that was copied or pasted.
    static let mint = Color(red: 0.722, green: 0.690, blue: 0.643)
    /// Success, named for what it is: a quiet silver.
    static let silver = mint
    /// The live dot and a failure.
    static let live = Color(red: 0.961, green: 0.725, blue: 0.267)
    /// The transcribing state.
    static let amber = Color(red: 0.659, green: 0.639, blue: 0.604)

    // MARK: - Type

    /// The small caps label.
    static let labelFont = Font.system(size: 10.5, weight: .semibold)
    /// The clock.
    static let clockFont = Font.system(size: 12, weight: .medium, design: .monospaced)
    /// The transcript.
    static let transcriptFont = Font.system(size: 15, weight: .regular)
    /// The live partial the recording card shows below the waveform.
    static let liveFont = Font.system(size: 13, weight: .regular)
    /// The message.
    static let messageFont = Font.system(size: 13, weight: .medium)

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
    static let actionFont = Font.system(size: 10, weight: .semibold)
    /// The quiet fill of an icon button.
    static let actionFill = Color.white.opacity(0.055)
    /// The fill of an icon button under the pointer.
    static let actionFillHover = Color.white.opacity(0.13)
    /// The quiet border of an icon button.
    static let actionBorder = Color.white.opacity(0.045)
    /// The border of an icon button under the pointer.
    static let actionBorderHover = Color.white.opacity(0.14)
    /// The divider between the content and the actions.
    static let hairline = Color.white.opacity(0.075)

    /// The fill of the hint that names a button under the pointer.
    ///
    /// It is the card's own surface lifted by a value, not a second material:
    /// the hint belongs to the card and must not look like a system tooltip.
    static let hintFill = Color(red: 0.118, green: 0.106, blue: 0.090)
    /// The border of the hint.
    static let hintBorder = Color.white.opacity(0.10)
    /// The type of the hint.
    static let hintFont = Font.system(size: 11, weight: .medium)
    /// How long the pointer rests on a button before the hint appears.
    ///
    /// A hint that appears the moment the pointer crosses a button flickers at
    /// every pass; the delay is what makes it an answer to a question.
    static let hintDelay: Duration = .milliseconds(750)
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

/// The surface of the card: one shape, one fill, one border, supporting Glass and Black materials.
struct HUDSurface: View {
    var material: HUDMaterial = .glass

    var body: some View {
        ZStack {
            if material == .glass {
                // Genuine macOS Liquid Glass: behind-window live desktop blur
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                    .clipShape(RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous))

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
            } else {
                // Analytic Black: solid 100% opaque matte obsidian/onyx
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

            RoundedRectangle(cornerRadius: HUDTheme.cornerRadius, style: .continuous)
                .strokeBorder(border, lineWidth: material == .glass ? 1.25 : 1)
        }
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
