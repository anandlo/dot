import AppKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

/// The menu a person meets: the check on the chosen row, the wash under the
/// pointer, the panel under the trigger, and the sheet a design review reads.
///
/// The colour cases are arithmetic on the tokens the views draw with; the row
/// and panel cases read real pixels back from real views, off every display; the
/// sheet is written only when asked for, because it needs a window and a drawing
/// pass. Nothing here orders a window front, asks a display to draw, or touches
/// the microphone.
@MainActor
final class DotSelectMenuTests: XCTestCase {
    // MARK: - The check

    /// The check is the smallest glyph in the window and the only mark on the
    /// chosen row, so it has to clear 7:1 against the wash under it in both
    /// appearances — at the highlight and while the row is held.
    func testTheCheckmarkClearsSevenToOneInBothAppearances() {
        for mode in MenuMode.all {
            let ink = MenuColour.resolve(DotTheme.ink, mode)
            let raised = MenuColour.resolve(DotTheme.raisedFill, mode)
            let highlight = MenuColour.resolve(DotTheme.menuRowHighlight, mode)
            let pressed = MenuColour.resolve(DotTheme.menuRowPressed, mode)

            for (state, fill) in [("highlighted", highlight), ("pressed", pressed)] {
                let background = MenuColour.over(fill, on: raised)
                let ratio = MenuColour.contrast(ink, background)
                XCTAssertGreaterThanOrEqual(
                    ratio,
                    7,
                    "the check on a \(state) row in \(mode.name) reads \(String(format: "%.2f", ratio)):1"
                )
            }
        }
    }

    /// The two washes are neutral tints of the ink, not coloured plates, and the
    /// press is the stronger one in both appearances: the values the decision
    /// names, read back from the tokens the views draw with.
    func testTheMenuWashesAreNeutralAndStepUpWhenPressed() {
        for mode in MenuMode.all {
            let highlight = MenuColour.resolve(DotTheme.menuRowHighlight, mode)
            let pressed = MenuColour.resolve(DotTheme.menuRowPressed, mode)

            XCTAssertEqual(highlight.a, mode.isDark ? 0.10 : 0.08, accuracy: 0.005)
            XCTAssertEqual(pressed.a, mode.isDark ? 0.16 : 0.14, accuracy: 0.005)
            XCTAssertLessThan(highlight.a, pressed.a, "the press is not stronger than the highlight")
            XCTAssertEqual(highlight.r, 0.075, accuracy: mode.isDark ? 1 : 0.005)
            XCTAssertEqual(highlight.g, 0.065, accuracy: mode.isDark ? 1 : 0.005)
            XCTAssertEqual(highlight.b, 0.085, accuracy: mode.isDark ? 1 : 0.005)
            if mode.isDark {
                XCTAssertEqual(highlight.r, 1, accuracy: 0.005, "the dark wash is white, not ink")
                XCTAssertEqual(highlight.g, 1, accuracy: 0.005)
                XCTAssertEqual(highlight.b, 1, accuracy: 0.005)
            }
        }
    }

    /// The chosen row's check is the window's ink, and the menu does not touch
    /// the green the rest of the app uses for "on".
    func testTheCheckIsInkAndTheSwitchGreenIsUntouched() {
        for mode in MenuMode.all {
            let ink = MenuColour.resolve(DotTheme.ink, mode)
            let check = MenuColour.resolve(DotTheme.ink, mode)
            XCTAssertEqual(check.r, ink.r, accuracy: 0.001)
            XCTAssertEqual(check.g, ink.g, accuracy: 0.001)
            XCTAssertEqual(check.b, ink.b, accuracy: 0.001)

            let selection = MenuColour.resolve(DotTheme.selectionFill, mode)
            let wash = MenuColour.resolve(DotTheme.menuRowHighlight, mode)
            XCTAssertNotEqual(selection.g, wash.g, accuracy: 0.0001, "the menu wash became the switch green")
        }
    }

    // MARK: - The surface

    // MARK: - The rows

    /// A row under the pointer is darker than the surface, and a held row
    /// darker again, in both appearances: a highlight nobody can see is the
    /// defect this case exists for.
    func testTheHighlightIsVisibleInBothAppearances() throws {
        for mode in MenuMode.all {
            let row = DotSelectRow(title: "Nova 3", detail: "Deepgram")
            let plain = try rowMean(row, highlight: false, pressed: false, mode: mode)
            let highlighted = try rowMean(row, highlight: true, pressed: false, mode: mode)
            let pressed = try rowMean(row, highlight: true, pressed: true, mode: mode)

            if mode.isDark {
                XCTAssertGreaterThan(highlighted, plain + 0.02, "the highlight is invisible in \(mode.name)")
                XCTAssertGreaterThan(pressed, highlighted + 0.01, "the press is invisible in \(mode.name)")
            } else {
                XCTAssertLessThan(highlighted, plain - 0.02, "the highlight is invisible in \(mode.name)")
                XCTAssertLessThan(pressed, highlighted - 0.01, "the press is invisible in \(mode.name)")
            }
        }
    }

    // MARK: - The panel

    /// The list the settings page actually opens: its left edge on the trigger's
    /// within half a point, the trigger's own four point gap, and the width the
    /// trigger asked for or the rows demanded. The panel is placed by the app
    /// from the trigger's own frame, not by this test.
    func testTheOpenListSitsUnderItsTriggerWithOneGap() throws {
        _ = NSApplication.shared
        OffscreenScreen.install(screens: [MenuPage.screen])
        defer { OffscreenScreen.restore() }

        let page = try MenuPage(config: MenuPage.deepgramConfig, height: 1180)
        defer { page.close() }

        // Room below: the Service row sits near the top of the page.
        let service = try XCTUnwrap(page.trigger("Service"), "the page has no Service trigger")
        let serviceFrame = page.screenFrame(of: service)
        try page.press("Service")
        page.settle(0.3)
        let serviceCard = try XCTUnwrap(DotSelectListController.shared.panel).frame.insetBy(
            dx: DotSelectPlacement.shadowInset,
            dy: DotSelectPlacement.shadowInset
        )
        XCTAssertEqual(serviceCard.minX, serviceFrame.minX, accuracy: 0.5, "the list does not align with its trigger")
        XCTAssertEqual(
            serviceCard.maxY,
            serviceFrame.minY - DotSelectPlacement.gap,
            accuracy: 0.5,
            "the list is not one four point gap under its trigger"
        )
        XCTAssertEqual(DotSelectPlacement.gap, 4)
        XCTAssertGreaterThanOrEqual(serviceCard.width, serviceFrame.width - 0.5, "the list is narrower than its trigger")
        XCTAssertLessThanOrEqual(serviceCard.width, DotSelectPlacement.maxWidth, "the list is wider than the cap")
        DotSelectListController.shared.close()
        page.settle(0.2)

        // No room below: the language row sits at the foot of the page, so the
        // same list opens above it, still on the trigger's left edge.
        let language = try XCTUnwrap(page.trigger("Spoken language"), "the page has no language trigger")
        let languageFrame = page.screenFrame(of: language)
        try page.press("Spoken language")
        page.settle(0.3)
        let panel = try XCTUnwrap(DotSelectListController.shared.panel)
        let languageCard = panel.frame.insetBy(
            dx: DotSelectPlacement.shadowInset,
            dy: DotSelectPlacement.shadowInset
        )
        XCTAssertEqual(languageCard.minX, languageFrame.minX, accuracy: 0.5, "the flipped list is off its trigger")
        XCTAssertEqual(
            languageCard.minY,
            languageFrame.maxY + DotSelectPlacement.gap,
            accuracy: 0.5,
            "the list did not open one gap above a trigger with no room below"
        )

        // A thirty row list draws a bar, and the bar lives inside the track.
        let scroll = DotSelectListController.shared.model?.scroll
        let thumb = try XCTUnwrap(scroll?.thumb, "a thirty row list has no bar to draw")
        XCTAssertGreaterThan(scroll?.contentHeight ?? 0, scroll?.viewportHeight ?? 0, "the list does not scroll")
        XCTAssertGreaterThanOrEqual(thumb.offset, DotSelectListMetrics.scrollerTrackInset, "the bar is on the corner")
        XCTAssertLessThanOrEqual(
            thumb.offset + thumb.height,
            languageCard.height - DotSelectListMetrics.scrollerTrackInset,
            "the bar crosses the card's foot"
        )
        DotSelectListController.shared.close()
    }

    /// The trigger a person has just opened does not look like the one they
    /// have not: the fill and the ring change, and the picture says so.
    func testTheOpenTriggerDiffersFromTheIdleOne() throws {
        _ = NSApplication.shared
        OffscreenScreen.install(screens: [MenuPage.screen])
        defer { OffscreenScreen.restore() }

        let page = try MenuPage(config: MenuPage.deepgramConfig, height: 1180)
        defer { page.close() }
        let idle = try page.triggerShot("Service")
        try page.press("Service")
        page.settle(0.3)
        let open = try page.triggerShot("Service")

        XCTAssertEqual(idle.pixelsWide, open.pixelsWide, "the two crops are not the same size")
        let delta = PixelDifference(idle, open)
        XCTAssertGreaterThan(delta.mean, 0.01, "the open trigger is the idle one")
        XCTAssertGreaterThan(delta.changed, 0.05, "the open trigger barely changes")
        DotSelectListController.shared.close()
    }

    // MARK: - The sheet

    /// The pictures a design review reads, written only when asked for.
    ///
    /// `DOT_SELECT_MENU_DIR=/tmp/dd-menu`. Every frame is drawn from a real
    /// settings page in a window off every display and from the real panel the
    /// app opened under a real trigger: the list is not composited into a
    /// guessed frame, its own window is captured and placed where the window
    /// server was told it is.
    func testTheMenuSheetRenders() throws {
        guard let value = ProcessInfo.processInfo.environment["DOT_SELECT_MENU_DIR"], !value.isEmpty else {
            throw XCTSkip("Set DOT_SELECT_MENU_DIR to render the menu sheet.")
        }
        _ = NSApplication.shared
        OffscreenScreen.install(screens: [MenuPage.screen])
        defer { OffscreenScreen.restore() }

        let directory = URL(fileURLWithPath: value, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for mode in MenuMode.all {
            try renderServiceSheet(into: directory, mode: mode)
            try renderModelSheet(into: directory, mode: mode)
            try renderLanguageAndAbove(into: directory, mode: mode)
            try renderTriggerCrops(into: directory, mode: mode)
            try renderNextRowHint(into: directory, mode: mode)
        }
    }

    // MARK: - Sheet pieces

    private func renderServiceSheet(into directory: URL, mode: MenuMode) throws {
        let page = try MenuPage(config: MenuPage.deepgramConfig, height: 1180, mode: mode)
        defer { page.close() }
        try page.press("Service")
        page.settle(0.4)
        try page.writeComposite("Service", named: "service-open-\(mode.suffix)", to: directory)
        try page.writeList(named: "service-selected-\(mode.suffix)", to: directory)

        // Hover: the pointer reports a row, which is the row the panel draws
        // under it, with the check still on the chosen one.
        page.hover(4)
        page.settle(0.2)
        try page.writeList(named: "service-hover-\(mode.suffix)", to: directory)

        // Keyboard: two downs move the highlight and the list with it.
        page.key(DotSelectSession.KeyCode.downArrow)
        page.key(DotSelectSession.KeyCode.downArrow)
        page.settle(0.2)
        try page.writeList(named: "service-keyboard-\(mode.suffix)", to: directory)

        // A held row: the pointer is reported on the row first, so the picture
        // is one row's press and not a press beside a keyboard highlight, then a
        // real mouse down, released outside the list so the press is drawn and
        // nothing is chosen.
        page.hover(3)
        page.settle(0.15)
        page.pressRow(3)
        try page.writeList(named: "service-pressed-\(mode.suffix)", to: directory)
        page.releaseOutside()
        DotSelectListController.shared.close()
        page.settle(0.2)
    }

    private func renderModelSheet(into directory: URL, mode: MenuMode) throws {
        let page = try MenuPage(config: MenuPage.deepgramConfig, height: 1180, mode: mode)
        defer { page.close() }
        try page.press("Model")
        page.settle(0.4)
        try page.writeComposite("Model", named: "model-open-\(mode.suffix)", to: directory)
        try page.writeList(named: "model-top-\(mode.suffix)", to: directory)

        // Rest at the top, at the middle and at the foot: the track and the bar
        // have to be there with nothing moving, or the list reads as ended.
        page.settle(1.3)
        try page.writeList(named: "model-rest-top-\(mode.suffix)", to: directory)
        page.scrollList(to: 120)
        page.settle(1.3)
        try page.writeList(named: "model-rest-mid-\(mode.suffix)", to: directory)
        page.scrollList(to: 10_000)
        page.settle(1.3)
        try page.writeList(named: "model-rest-bottom-\(mode.suffix)", to: directory)
        DotSelectListController.shared.close()
        page.settle(0.2)
    }

    private func renderLanguageAndAbove(into directory: URL, mode: MenuMode) throws {
        let page = try MenuPage(config: MenuPage.deepgramConfig, height: 1180, mode: mode)
        defer { page.close() }
        try page.press("Spoken language")
        page.settle(0.4)
        try page.writeComposite("Spoken language", named: "language-open-\(mode.suffix)", to: directory)
        page.settle(1.3)
        try page.writeList(named: "language-rest-\(mode.suffix)", to: directory)
        DotSelectListController.shared.close()
        page.settle(0.2)

        // The one that opens above: a display whose foot is just under the
        // trigger leaves no room below and all the room above.
        let language = try XCTUnwrap(page.trigger("Spoken language"))
        let anchor = page.screenFrame(of: language)
        OffscreenScreen.install(screens: [
            NSRect(x: anchor.minX - 400, y: anchor.minY - 80, width: 1200, height: 700)
        ])
        try page.press("Spoken language")
        page.settle(0.4)
        let panel = try XCTUnwrap(DotSelectListController.shared.panel)
        let card = panel.frame.insetBy(dx: DotSelectPlacement.shadowInset, dy: DotSelectPlacement.shadowInset)
        XCTAssertEqual(card.minY, anchor.maxY + DotSelectPlacement.gap, accuracy: 0.5, "the list opened below")
        try page.writeComposite("Spoken language", named: "language-above-\(mode.suffix)", to: directory)
        DotSelectListController.shared.close()
        OffscreenScreen.install(screens: [MenuPage.screen])
        page.settle(0.2)
    }

    private func renderTriggerCrops(into directory: URL, mode: MenuMode) throws {
        let page = try MenuPage(config: MenuPage.deepgramConfig, height: 1180, mode: mode)
        defer { page.close() }
        try page.writeTrigger("Service", named: "trigger-idle-\(mode.suffix)", scale: 4, to: directory)
        try page.press("Service")
        page.settle(0.3)
        try page.writeTrigger("Service", named: "trigger-open-\(mode.suffix)", scale: 4, to: directory)
        DotSelectListController.shared.close()
        page.settle(0.2)
    }

    private func renderNextRowHint(into directory: URL, mode: MenuMode) throws {
        let page = try MenuPage(config: MenuPage.deepgramConfig, height: 1180, mode: mode)
        defer { page.close() }
        try page.press("Spoken language")
        page.settle(0.4)
        try page.writeHintCrop(named: "next-row-hint-\(mode.suffix)", scale: 4, to: directory)
        DotSelectListController.shared.close()
        page.settle(0.2)
    }

    // MARK: - Pixels

    private func swatch(_ view: some View, mode: MenuMode) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: 16, height: 16))
        host.appearance = NSAppearance(named: mode.appearance)
        host.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func rowMean(_ row: DotSelectRow, highlight: Bool, pressed: Bool, mode: MenuMode) throws -> CGFloat {
        let view = ZStack {
            RoundedRectangle(cornerRadius: 0).fill(DotTheme.raisedFill)
            DotSelectListRow(
                row: row,
                isSelected: false,
                isHighlighted: highlight,
                isPressed: pressed,
                reservesSymbol: true
            )
            .padding(.horizontal, DotSelectPlacement.inset)
        }
        .frame(width: 240, height: 40)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: mode.appearance)
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return PixelDifference.meanLuminance(rep)
    }
}

// MARK: - The two appearances

/// One appearance, with the names the pictures and the tests use for it.
struct MenuMode {
    let appearance: NSAppearance.Name
    let scheme: ColorScheme
    let name: String
    let suffix: String

    var isDark: Bool { appearance == .darkAqua }

    static let light = MenuMode(appearance: .aqua, scheme: .light, name: "light", suffix: "light")
    static let dark = MenuMode(appearance: .darkAqua, scheme: .dark, name: "dark", suffix: "dark")
    static let all: [MenuMode] = [.light, .dark]
}

// MARK: - Colour arithmetic

/// A colour read back from a token, in sRGB, with its alpha.
struct MenuColour {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat

    /// Resolves a theme token in one appearance.
    ///
    /// The tokens are dynamic `NSColor`s, so the appearance has to be current
    /// while the colour is converted; asking outside one returns the light stop.
    static func resolve(_ colour: Color, _ mode: MenuMode) -> MenuColour {
        var out = MenuColour(r: 0, g: 0, b: 0, a: 1)
        let appearance = NSAppearance(named: mode.appearance) ?? NSAppearance(named: .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(colour).usingColorSpace(.sRGB) else { return }
            out = MenuColour(
                r: srgb.redComponent,
                g: srgb.greenComponent,
                b: srgb.blueComponent,
                a: srgb.alphaComponent
            )
        }
        return out
    }

    /// The colour a fill of `top` leaves over `base`.
    static func over(_ top: MenuColour, on base: MenuColour) -> MenuColour {
        MenuColour(
            r: top.r * top.a + base.r * (1 - top.a),
            g: top.g * top.a + base.g * (1 - top.a),
            b: top.b * top.a + base.b * (1 - top.a),
            a: 1
        )
    }

    /// WCAG relative luminance.
    var luminance: CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// WCAG contrast of two opaque colours, the lighter over the darker.
    static func contrast(_ a: MenuColour, _ b: MenuColour) -> CGFloat {
        let one = a.luminance
        let two = b.luminance
        return (max(one, two) + 0.05) / (min(one, two) + 0.05)
    }
}

// MARK: - Pixels

/// What two pictures of the same size say about each other, in 0...1 channels.
struct PixelDifference {
    let mean: CGFloat
    let maximum: CGFloat
    let changed: CGFloat

    init(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) {
        var total: CGFloat = 0
        var worst: CGFloat = 0
        var count = 0
        var differing = 0
        let width = min(a.pixelsWide, b.pixelsWide)
        let height = min(a.pixelsHigh, b.pixelsHigh)
        for y in 0..<height {
            for x in 0..<width {
                let one = PixelDifference.channels(a, x, y)
                let two = PixelDifference.channels(b, x, y)
                let delta = (abs(one.0 - two.0) + abs(one.1 - two.1) + abs(one.2 - two.2)) / 3
                total += delta
                worst = max(worst, delta)
                if delta > 2.0 / 255 { differing += 1 }
                count += 1
            }
        }
        mean = count == 0 ? 0 : total / CGFloat(count)
        maximum = worst
        changed = count == 0 ? 0 : CGFloat(differing) / CGFloat(count)
    }

    /// The mean channel of one picture, for asking whether a row is darker.
    static func meanLuminance(_ rep: NSBitmapImageRep) -> CGFloat {
        var total: CGFloat = 0
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                let value = channels(rep, x, y)
                total += value.0 * 0.21 + value.1 * 0.72 + value.2 * 0.07
                count += 1
            }
        }
        return count == 0 ? 0 : total / CGFloat(count)
    }

    static func channels(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
        guard let data = rep.bitmapData, x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else {
            return (0, 0, 0)
        }
        let offset = y * rep.bytesPerRow + x * rep.samplesPerPixel
        guard rep.samplesPerPixel >= 3 else { return (0, 0, 0) }
        return (
            CGFloat(data[offset]) / 255,
            CGFloat(data[offset + 1]) / 255,
            CGFloat(data[offset + 2]) / 255
        )
    }
}

// MARK: - The page

/// A real settings page in a window no display draws, and the real panel the
/// app opens under one of its triggers.
///
/// The page is the shipped `SettingsView` with the keychain and the audio
/// devices replaced by the render environment, so no key is read and no
/// microphone is enumerated. Its triggers are the shipped ones, and the list is
/// opened by pressing one through its accessibility action: the panel is placed
/// by the app from the trigger's own frame, never by this test.
@MainActor
final class MenuPage {
    /// The display the page sits on: nothing the Mac owns, with room for the
    /// page and for the list under or over any row.
    static let screen = NSRect(x: -20_000, y: -20_000, width: 1600, height: 1400)

    /// The service the rendered page presents: one whose model and language
    /// lists are long enough to scroll, drawn from the shipped catalogues.
    static var deepgramConfig: DotConfig {
        var config = DotConfig.default
        ProviderPreset.deepgram.apply(to: &config)
        var settings = config.settings(for: ProviderIdentifier.deepgram)
        settings.language = "en"
        config.providers[ProviderIdentifier.deepgram] = settings
        return config
    }

    /// The models Deepgram's own `/models` endpoint reports for transcription.
    static let deepgramModels: [AvailableModel] = [
        AvailableModel(id: "nova-3", name: "Nova 3"),
        AvailableModel(id: "nova-3-general", name: "Nova 3 General"),
        AvailableModel(id: "nova-3-medical", name: "Nova 3 Medical"),
        AvailableModel(id: "nova-2", name: "Nova 2"),
        AvailableModel(id: "nova-2-meeting", name: "Nova 2 Meeting"),
        AvailableModel(id: "nova-2-phonecall", name: "Nova 2 Phonecall"),
        AvailableModel(id: "nova-2-finance", name: "Nova 2 Finance"),
        AvailableModel(id: "nova-2-conversationalai", name: "Nova 2 Conversational AI"),
        AvailableModel(id: "nova-2-video", name: "Nova 2 Video"),
        AvailableModel(id: "nova-2-drivethru", name: "Nova 2 Drive-thru"),
        AvailableModel(id: "nova-2-medical", name: "Nova 2 Medical"),
        AvailableModel(id: "nova-2-automotive", name: "Nova 2 Automotive"),
        AvailableModel(id: "nova", name: "Nova"),
        AvailableModel(id: "enhanced", name: "Enhanced"),
        AvailableModel(id: "base", name: "Base"),
        AvailableModel(id: "whisper-large", name: "Whisper Large"),
    ]

    let window: OffscreenWindow
    let host: NSHostingView<AnyView>
    let mode: MenuMode
    /// The scale every picture is drawn at.
    let scale: CGFloat = 2

    init(config: DotConfig, height: CGFloat, mode: MenuMode = .light) throws {
        self.mode = mode
        // The page paints itself from the configuration's appearance, and the
        // shipped default is dark: a light page has to say `light` or it draws
        // the ink palette in the appearance it was asked to show as paper.
        var config = config
        config.appearance = mode.isDark ? .dark : .light
        let providers = MenuBuilder.providerRows(config: config) { _ in false }
        let settings = SettingsView(
            config: Binding.constant(config),
            providers: providers,
            tab: 1,
            onChange: {},
            onSetAPIKey: { _, _ in nil },
            onTest: { _ in true },
            onChangeShortcut: {},
            modelPreview: MenuPage.deepgramModels
        )
        .environment(\.settingsHeadless, true)
        .environment(\.settingsDefaultInputUID, "DotRenderBuiltInMicrophone")
        .environment(\.settingsVersionOverride, "1.0")
        .environment(\.settingsHeightOverride, height)
        .environment(\.colorScheme, mode.scheme)

        host = NSHostingView(rootView: AnyView(settings))
        window = OffscreenWindow(size: CGSize(width: 820, height: height), styleMask: [.borderless])
        host.frame = NSRect(origin: .zero, size: CGSize(width: 820, height: height))
        host.appearance = NSAppearance(named: mode.appearance)
        window.appearance = NSAppearance(named: mode.appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        settle(0.25)
    }

    var controller: DotSelectListController { .shared }

    func close() {
        controller.close()
        window.contentView = nil
        window.close()
        settle(0.05)
    }

    // MARK: The page's own controls

    func trigger(_ label: String) -> DotSelectAccessibilityView? {
        Self.find(label, in: host)
    }

    func press(_ label: String) throws {
        let element = try XCTUnwrap(trigger(label), "the page has no \(label) trigger")
        XCTAssertTrue(element.accessibilityPerformPress(), "the \(label) trigger did not open")
    }

    /// The trigger's frame in its window, and on the display the window is on.
    func windowRect(of view: NSView) -> NSRect {
        view.convert(view.bounds, to: nil)
    }

    func screenFrame(of view: NSView) -> NSRect {
        window.convertToScreen(windowRect(of: view))
    }

    // MARK: The list

    /// Reports the pointer on a row of the open list, through the shipped
    /// session, which is what the app's own hover monitor does.
    func hover(_ index: Int) {
        controller.session?.hover(index)
    }

    /// A trigger's own pixels, for comparing two states.
    func triggerShot(_ label: String) throws -> NSBitmapImageRep {
        let element = try XCTUnwrap(trigger(label), "the page has no \(label) trigger")
        let rect = windowRect(of: element).insetBy(dx: -3, dy: -3)
        return try bitmap(of: host, cropping: topRect(rect, in: host.bounds.height))
    }

    /// Presses a key through the shipped session.
    func key(_ code: UInt16) {
        let characters: String
        switch code {
        case DotSelectSession.KeyCode.downArrow: characters = "\u{F701}"
        case DotSelectSession.KeyCode.upArrow: characters = "\u{F700}"
        default: characters = "\r"
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: controller.panel?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        ) else { return }
        _ = controller.session?.handleKey(event)
    }

    func listScrollView() -> NSScrollView? {
        guard let content = controller.panel?.contentView else { return nil }
        return Self.scrollView(in: content)
    }

    func scrollList(to offset: CGFloat) {
        guard let scroll = listScrollView() else { return }
        let room = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, offset), room)))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        settle(0.3)
    }

    /// Holds a row of the open list with a real mouse down.
    ///
    /// The mouse up is sent outside the list by ``releaseOutside()`` so the
    /// press is drawn and no row is chosen: the picture is of a hold, not of a
    /// choice.
    func pressRow(_ index: Int) {
        guard let panel = controller.panel, panel.contentView != nil else { return }
        let card = panel.frame.insetBy(
            dx: DotSelectPlacement.shadowInset,
            dy: DotSelectPlacement.shadowInset
        )
        let rowHeight = DotSelectPlacement.rowHeight
        let y = card.height - DotSelectPlacement.inset - CGFloat(index) * rowHeight - rowHeight / 2
        let point = NSPoint(x: card.width / 2, y: y)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }
        panel.sendEvent(event)
        settle(0.25)
    }

    func releaseOutside() {
        guard let panel = controller.panel else { return }
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: -40, y: -40),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ) else { return }
        panel.sendEvent(event)
        settle(0.15)
    }

    // MARK: Pictures

    /// What the settings page looks like, with the open list where the app put
    /// it: the page is captured from its own window and the list from its own
    /// window, and the two are placed by the frames the window server was given.
    func writeComposite(_ label: String, named name: String, to directory: URL) throws {
        guard let panel = controller.panel else { throw XCTSkip("no list is open") }
        let page = try bitmap(of: host)
        let list = try bitmap(of: panel.contentView ?? host)

        let trigger = try XCTUnwrap(trigger(label), "the page has no \(label) trigger")
        let triggerRect = topRect(windowRect(of: trigger), in: host.bounds.height)
            .insetBy(dx: -8, dy: -8)
        let listRect = topRect(window.convertFromScreen(panel.frame), in: host.bounds.height)
        let crop = triggerRect.union(listRect).insetBy(dx: -16, dy: -16)

        let canvas = try canvas(size: crop.size)
        let context = try XCTUnwrap(canvas.context)
        context.imageInterpolation = .high
        draw(
            page,
            at: NSRect(
                x: -crop.minX,
                y: -crop.minY,
                width: host.bounds.width,
                height: host.bounds.height
            ),
            in: context
        )
        draw(
            list,
            at: NSRect(
                x: listRect.minX - crop.minX,
                y: listRect.minY - crop.minY,
                width: listRect.width,
                height: listRect.height
            ),
            in: context
        )
        try write(canvas.rep, named: name, to: directory)
    }

    /// The card alone, as the panel draws it.
    func writeList(named name: String, to directory: URL) throws {
        guard let panel = controller.panel, let content = panel.contentView else {
            throw XCTSkip("no list is open")
        }
        let card = content.bounds.insetBy(
            dx: DotSelectPlacement.shadowInset,
            dy: DotSelectPlacement.shadowInset
        )
        let shot = try bitmap(of: content, cropping: topRect(card, in: content.bounds.height))
        try write(shot, named: name, to: directory)
    }

    /// A trigger at four times its drawn size.
    func writeTrigger(_ label: String, named name: String, scale factor: CGFloat, to directory: URL) throws {
        let element = try XCTUnwrap(trigger(label), "the page has no \(label) trigger")
        let rect = topRect(windowRect(of: element).insetBy(dx: -3, dy: -3), in: host.bounds.height)
        let shot = try bitmap(of: host, cropping: rect)
        try write(try scaled(shot, by: factor), named: name, to: directory)
    }

    /// The bottom of the card and the next row's title under it, large enough to
    /// read the letters: the crop is where a card cut mid-word would show.
    func writeHintCrop(named name: String, scale factor: CGFloat, to directory: URL) throws {
        guard let panel = controller.panel, let content = panel.contentView else {
            throw XCTSkip("no list is open")
        }
        let cardInContent = content.bounds.insetBy(
            dx: DotSelectPlacement.shadowInset,
            dy: DotSelectPlacement.shadowInset
        )
        let foot = NSRect(
            x: cardInContent.minX,
            y: cardInContent.minY,
            width: cardInContent.width,
            height: 56
        )
        let shot = try bitmap(of: content, cropping: topRect(foot, in: content.bounds.height))
        try write(try scaled(shot, by: factor), named: name, to: directory)
    }

    // MARK: The drawing underneath

    func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        host.layoutSubtreeIfNeeded()
    }

    static func find(_ label: String, in view: NSView?) -> DotSelectAccessibilityView? {
        guard let view else { return nil }
        if let element = view as? DotSelectAccessibilityView, element.accessibilityLabel() == label {
            return element
        }
        for sub in view.subviews {
            if let found = find(label, in: sub) { return found }
        }
        return nil
    }

    static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }

    /// A window rectangle in the top-left coordinates pictures are stitched in.
    private func topRect(_ rect: NSRect, in height: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Renders a view's layer tree at ``scale``, with the first row at the top.
    private func bitmap(of view: NSView, cropping crop: NSRect? = nil) throws -> NSBitmapImageRep {
        let bounds = crop ?? view.bounds
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        if let layer = view.layer {
            layer.render(in: context)
        } else {
            throw XCTSkip("the view has no layer tree to render")
        }
        let image = try XCTUnwrap(context.makeImage(), "the layer tree did not render")
        return NSBitmapImageRep(cgImage: image)
    }

    /// A bitmap a picture is stitched into, with top-left point coordinates.
    private func canvas(size: CGSize) throws -> (rep: NSBitmapImageRep, context: NSGraphicsContext?) {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()),
            pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return (rep, nil) }
        let context = graphics.cgContext
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let flipped = NSGraphicsContext(cgContext: context, flipped: true)
        return (rep, flipped)
    }

    private func draw(_ rep: NSBitmapImageRep, at rect: NSRect, in context: NSGraphicsContext) {
        guard let image = rep.cgImage else { return }
        let size = NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSImage(cgImage: image, size: size).draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func scaled(_ rep: NSBitmapImageRep, by factor: CGFloat) throws -> NSBitmapImageRep {
        let rep2 = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((CGFloat(rep.pixelsWide) * factor).rounded()),
            pixelsHigh: Int((CGFloat(rep.pixelsHigh) * factor).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        guard let graphics = NSGraphicsContext(bitmapImageRep: rep2), let image = rep.cgImage else {
            return rep
        }
        let context = NSGraphicsContext(cgContext: graphics.cgContext, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .none
        // The context counts pixels: the picture is drawn over the whole canvas
        // at its own pixel size, so every source pixel becomes exactly `factor`
        // pixels and nothing is resampled by accident.
        let canvas = NSSize(width: CGFloat(rep2.pixelsWide), height: CGFloat(rep2.pixelsHigh))
        NSImage(cgImage: image, size: NSSize(width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh)))
            .draw(in: NSRect(origin: .zero, size: canvas))
        NSGraphicsContext.restoreGraphicsState()
        return rep2
    }

    private func write(_ rep: NSBitmapImageRep, named name: String, to directory: URL) throws {
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "\(name) did not encode")
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
