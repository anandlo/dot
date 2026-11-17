import AppKit
@testable import Dot

/// A window the window server never draws on a display.
///
/// A test that puts a window on screen interrupts whoever is using the Mac, and
/// a menu is a window, so every test that needs one builds it with this: the
/// frame is placed outside every display and AppKit is told not to pull it back.
///
/// `constrainFrameRect` normally keeps a window's title bar on a screen; an
/// origin at -20000 is then moved back to the visible frame, which is why the
/// override is what makes the placement stick.
class OffscreenWindow: NSWindow {
    static let origin = NSPoint(x: -20_000, y: -20_000)

    init(size: CGSize, styleMask: NSWindow.StyleMask = [.titled]) {
        super.init(
            contentRect: NSRect(origin: Self.origin, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        alphaValue = 1
        level = .normal
        setFrameOrigin(Self.origin)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// A borderless panel for tests, off every display and unable to take a click.
final class OffscreenPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: NSRect(origin: OffscreenWindow.origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        level = .normal
        setFrameOrigin(OffscreenWindow.origin)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// A HUD panel for tests, off every display and unable to be pulled back.
///
/// The island's tests put the real panel in their own window so they can send
/// it a click or a wheel; this keeps that window where the window server never
/// draws it.
final class OffscreenHUDPanel: HUDPanel {
    init(size: CGSize) {
        super.init(
            contentRect: NSRect(origin: OffscreenWindow.origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        setFrameOrigin(OffscreenWindow.origin)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// A screen that exists only for the test, under the window it is holding.
///
/// The list is placed against a screen's visible frame, and an off-screen window
/// is on no display, so the controller is handed this instead of asking AppKit.
@MainActor
enum OffscreenScreen {
    /// The synthetic screen: the off-screen origin, and room for every fixture.
    static let frame = NSRect(x: -20_000, y: -20_000, width: 1600, height: 1000)

    /// Points the controller at ``frame``.
    static func install() {
        install(screens: [frame])
    }

    /// Points the controller at a display of the rects given.
    ///
    /// The display holding the trigger's centre answers, which is the question
    /// the app asks the window server; the first rect is the fallback, the way
    /// the first screen is.
    static func install(screens: [NSRect]) {
        let screens = screens
        DotSelectListController.shared.screenProvider = { trigger, _ in
            let centre = CGPoint(x: trigger.midX, y: trigger.midY)
            let screen = screens.first { $0.contains(centre) } ?? screens[0]
            return (screen, screen)
        }
    }

    /// Asks AppKit again.
    static func restore() {
        DotSelectListController.shared.screenProvider = DotSelectListController.defaultScreenProvider
    }
}

/// The palette's display, made of the rect that exists only for the test.
///
/// The palette places its panel on a screen, so a test that shows one hands the
/// controller a display that is on no Mac: the panel is ordered front where the
/// window server never draws it.
@MainActor
enum OffscreenPalette {
    static func install() {
        PaletteController.screens = {
            ([(frame: OffscreenScreen.frame, visible: OffscreenScreen.frame)], 0)
        }
    }

    /// Asks AppKit again.
    static func restore() {
        PaletteController.screens = PaletteController.defaultScreens
    }
}
