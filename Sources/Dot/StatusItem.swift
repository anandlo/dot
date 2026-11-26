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
    /// Called just before the menu is built, so the app can re-read the facts the
    /// menu shows.
    ///
    /// The menu is the one surface that has to be current when it opens rather
    /// than when something changed: an input plugged in an hour ago and a login
    /// item switched in System Settings are both news the app has not been told.
    var onMenuOpen: (() -> Void)?

    /// What the menu shows. Setting it refreshes the menu the next time it
    /// opens.
    var menuState = MenuState() {
        didSet {
            if menuState.isRecording != oldValue.isRecording {
                updateGlyph()
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
    private var appliedRecording: Bool?
    private var appliedDark: Bool?
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?

    /// Creates the menu bar item.
    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        button = statusItem.button!
        super.init()

        target.handler = { [weak self] action in
            self?.onAction?(action)
        }

        button.contentTintColor = nil
        button.imagePosition = .imageOnly
        button.toolTip = nil
        updateGlyph(force: true)

        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateGlyph()
            }
        }

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
        updateGlyph()
        onMenuOpen?()
        let fresh = MenuBuilder.build(state: menuState, target: target)
        menu.removeAllItems()
        while let item = fresh.items.first {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }

    deinit {
        if let themeObserver {
            DistributedNotificationCenter.default().removeObserver(themeObserver)
        }
    }

    /// Removes the item.
    func tearDown() {
        if let themeObserver {
            DistributedNotificationCenter.default().removeObserver(themeObserver)
            self.themeObserver = nil
        }
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - The glyph

    /// How far the cut-out moves while a recording is running.
    private static let recordingAmplitude: CGFloat = 1

    /// Updates `button.image` only when recording state or menu bar appearance changes
    /// to avoid triggering FrontBoard status-item replicant snapshots and XPC fences.
    private func updateGlyph(force: Bool = false) {
        let recording = menuState.isRecording
        let dark = Self.menuBarIsDark
        guard force || appliedRecording != recording || appliedDark != dark else { return }
        appliedRecording = recording
        appliedDark = dark
        button.image = MenuGlyph.image(
            phase: 0,
            amplitude: recording ? Self.recordingAmplitude : 0,
            dark: dark
        )
    }

    /// Whether the menu bar is dark, and so whether the mark inverts.
    ///
    /// The bar belongs to the system, not to this app: Dot's own appearance
    /// setting must never change it, and `NSApp.appearance` would. The global
    /// domain's `AppleInterfaceStyle` is the system's answer and is unaffected
    /// by anything set through `NSApp.appearance`.
    private static var menuBarIsDark: Bool {
        let value = CFPreferencesCopyAppValue(
            "AppleInterfaceStyle" as CFString,
            kCFPreferencesAnyApplication
        )
        return (value as? String)?.caseInsensitiveCompare("Dark") == .orderedSame
    }
}
