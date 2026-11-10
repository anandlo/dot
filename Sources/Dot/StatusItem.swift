import AppKit
import DotCore

/// The menu bar item.
///
/// A click — left or right — opens the menu. The menu is the product's front
/// door: it is where the microphone, the language, the provider and the
/// settings live. The global shortcut is the fast path to a recording; the
/// menu is the complete one.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    /// Called when the user picks an item.
    var onAction: ((MenuAction) -> Void)?

    /// What the menu shows. Setting it refreshes the menu the next time it
    /// opens.
    var menuState = MenuState() {
        didSet {
            if menuState.isRecording != oldValue.isRecording {
                startGlyph()
            }
            if menuState.fastRecordEnabled != oldValue.fastRecordEnabled {
                configureClickMode()
            }
        }
    }

    private let statusItem: NSStatusItem
    private let button: NSStatusBarButton
    private let target = MenuActionTarget()
    private var dropdownMenu: NSMenu!
    /// Drives the breathing glyph.
    private var glyphTimer: Timer?
    /// The frame of the breath that is showing.
    private var glyphFrame = 0

    /// Creates the menu bar item.
    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        button = statusItem.button!
        super.init()

        target.handler = { [weak self] action in
            self?.onAction?(action)
        }

        button.image = MenuGlyph.image(
            phase: 0,
            amplitude: Self.idleAmplitude,
            dark: Self.menuBarIsDark
        )
        button.contentTintColor = nil
        button.imagePosition = .imageOnly
        button.toolTip = nil
        startGlyph()

        let menu = MenuBuilder.build(state: menuState, target: target)
        menu.delegate = self
        dropdownMenu = menu
        configureClickMode()
    }

    /// Configures whether a single left-click toggles recording (Fast Record)
    /// or opens the menu. When Fast Record is on, right-clicking or Control/Option-clicking
    /// still opens the menu.
    private func configureClickMode() {
        if menuState.fastRecordEnabled {
            statusItem.menu = nil
            button.target = self
            button.action = #selector(handleStatusBarClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = nil
        } else {
            button.target = nil
            button.action = nil
            statusItem.menu = dropdownMenu
            button.toolTip = nil
        }
    }

    @objc private func handleStatusBarClick(_ sender: Any?) {
        guard menuState.fastRecordEnabled else {
            popUpMenu()
            return
        }
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp || event?.type == .rightMouseDown
        let hasModifier = event?.modifierFlags.intersection([.control, .option]).isEmpty == false
        if isRightClick || hasModifier {
            popUpMenu()
        } else {
            onAction?(.toggleRecording)
        }
    }

    private func popUpMenu() {
        menuNeedsUpdate(dropdownMenu)
        statusItem.menu = dropdownMenu
        button.performClick(nil)
        if menuState.fastRecordEnabled {
            statusItem.menu = nil
        }
    }

    /// Rebuilds the menu in place, so an open menu reflects the truth.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = MenuBuilder.build(state: menuState, target: target)
        menu.removeAllItems()
        while let item = fresh.items.first {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }

    /// Removes the item.
    func tearDown() {
        glyphTimer?.invalidate()
        glyphTimer = nil
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - The glyph

    /// How far the cut-out moves while nothing is being dictated.
    private static let idleAmplitude: CGFloat = 0.55
    /// How far it moves while a recording is running.
    private static let recordingAmplitude: CGFloat = 1
    /// Frames per second while idle: one breath every eight seconds.
    private static let idleFrameRate: Double = 3
    /// Frames per second while a recording runs: one breath every 1.2 seconds.
    private static let recordingFrameRate: Double = 20

    /// Starts the breathing glyph.
    ///
    /// A menu bar item that never changes is furniture, and one that pulses
    /// quickly while idle is noise. Worse, every image the button is given
    /// makes AppKit snapshot the whole status item again for its replicants, so
    /// a fast idle animation is not free: three frames a second is a slow drift
    /// a person reads as alive, and the fast breath belongs to the seconds when
    /// a recording is actually running.
    private func startGlyph() {
        glyphTimer?.invalidate()
        let rate = menuState.isRecording ? Self.recordingFrameRate : Self.idleFrameRate
        let timer = Timer(timeInterval: 1.0 / rate, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceGlyph() }
        }
        RunLoop.main.add(timer, forMode: .common)
        glyphTimer = timer
        advanceGlyph()
    }

    private func advanceGlyph() {
        let recording = menuState.isRecording
        glyphFrame += 1
        button.image = MenuGlyph.frame(
            index: glyphFrame,
            amplitude: recording ? Self.recordingAmplitude : Self.idleAmplitude,
            dark: Self.menuBarIsDark
        )
    }

    /// Whether the menu bar is dark, and so whether the mark inverts.
    ///
    /// The bar belongs to the system, not to this app: Dot's own appearance
    /// setting must never change it, and `NSApp.appearance` would. The global
    /// domain's `AppleInterfaceStyle` is the system's answer, it is unaffected
    /// by anything set through `NSApp.appearance`, and reading it once a frame
    /// costs a dictionary lookup.
    private static var menuBarIsDark: Bool {
        let value = CFPreferencesCopyAppValue(
            "AppleInterfaceStyle" as CFString,
            kCFPreferencesAnyApplication
        )
        return (value as? String)?.caseInsensitiveCompare("Dark") == .orderedSame
    }
}
