import AppKit
import DotCore

/// A view that swallows the next key combination the user types.
private final class ShortcutCaptureView: NSView {
    var onCombination: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        onCombination?(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onCombination?(event)
        return true
    }
}

/// A small window that asks the user for a new shortcut.
///
/// The window is the only part of Dot that takes focus, and only because
/// the user asked for it.
@MainActor
final class ShortcutRecorder {
    /// Called with the shortcut the user pressed, or the reason it was refused.
    var completion: ((Result<Hotkey, HotkeyRejection>) -> Void)?

    private var window: NSWindow?
    private let hintLabel = NSTextField(labelWithString: "")

    /// The shortcuts Dot already uses; they may not be reused.
    var inUse: [Hotkey] = []

    /// The title of the window.
    var title = "Set shortcut"

    /// Opens the window.
    func begin() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 132),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.center()

        let caption = NSTextField(labelWithString: "New shortcut")
        caption.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        caption.textColor = NSColor.labelColor

        hintLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        hintLabel.textColor = NSColor.secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.stringValue = "Requires ⌘, ⌥ or ⌃. A function key can be used alone."

        let capture = ShortcutCaptureView()
        capture.onCombination = { [weak self] event in
            self?.handle(event)
        }

        let stack = NSStackView(views: [caption, hintLabel, capture])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            caption.heightAnchor.constraint(equalToConstant: 20),
            hintLabel.heightAnchor.constraint(equalToConstant: 16),
            hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])

        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(capture)
    }

    /// Closes the window.
    func cancel() {
        window?.close()
        window = nil
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [] {
            cancel()
            completion?(.failure(.unsupportedKey))
            return
        }
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        let typed = event.charactersIgnoringModifiers
        // The ANSI alias of the key, so the shortcut keeps working when the
        // keyboard layout is changed.
        let ansi = typed?.first.flatMap { HotkeyValidator.ansiKeyCode(forCharacter: $0) }
        switch HotkeyValidator.validate(
            keyCode: Int(event.keyCode),
            modifiers: modifiers,
            typed: typed,
            ansiKeyCode: ansi,
            inUse: inUse
        ) {
        case .success(let hotkey):
            cancel()
            completion?(.success(hotkey))
        case .failure(let rejection):
            hintLabel.stringValue = rejection.localizedDescription
            hintLabel.textColor = NSColor.systemRed
        }
    }

    /// Converts AppKit's modifier flags into Carbon's.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var modifiers = 0
        if flags.contains(.command) { modifiers |= HotkeyModifiers.mask(.command) }
        if flags.contains(.shift) { modifiers |= HotkeyModifiers.mask(.shift) }
        if flags.contains(.option) { modifiers |= HotkeyModifiers.mask(.option) }
        if flags.contains(.control) { modifiers |= HotkeyModifiers.mask(.control) }
        if flags.contains(.capsLock) { modifiers |= HotkeyModifiers.mask(.capsLock) }
        return modifiers
    }
}
