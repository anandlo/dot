import DotCore

/// Turns the configured hot keys into menu shortcuts.
enum MenuShortcuts {
    /// The shortcut a menu item displays.
    static func shortcut(for hotkey: Hotkey) -> MenuShortcut? {
        let key: String
        switch hotkey.label {
        case let label where label.hasSuffix("Space"): key = " "
        case let label where label.hasSuffix("Return"): key = "\r"
        case let label where label.hasSuffix("Tab"): key = "\t"
        case let label where label.hasSuffix("Escape"): key = "\u{1b}"
        default:
            guard let last = hotkey.label.last else { return nil }
            key = String(last).lowercased()
        }
        var modifiers: MenuModifiers = []
        if HotkeyModifiers.contains(hotkey.modifiers, .command) { modifiers.insert(.command) }
        if HotkeyModifiers.contains(hotkey.modifiers, .option) { modifiers.insert(.option) }
        if HotkeyModifiers.contains(hotkey.modifiers, .control) { modifiers.insert(.control) }
        if HotkeyModifiers.contains(hotkey.modifiers, .shift) { modifiers.insert(.shift) }
        return MenuShortcut(display: hotkey.label, key: key, modifiers: modifiers)
    }
}
