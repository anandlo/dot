import AppKit
import ApplicationServices
import Foundation
import DotCore

/// Delivers text to wherever the user is working.
enum Paste {
    /// The virtual key code of `V`.
    private static let vKeyCode: CGKeyCode = 9

    /// Whether Dot may post synthetic key events.
    ///
    /// Posting a ⌘V needs the Accessibility permission.
    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks for the Accessibility permission, showing the system prompt.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// The bundle identifier of the application the user is working in.
    static var frontmostBundleIdentifier: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Puts text back on the pasteboard, but only when Dot is still the last
    /// writer.
    ///
    /// A rewritten transcript has to sit on the pasteboard while the paste
    /// keystroke is posted, because that is how the cursor receives it. The
    /// original words go back immediately afterwards — unless the person has
    /// copied something else in the meantime, in which case their copy wins.
    /// - Parameters:
    ///   - text: the text to put back.
    ///   - holding: the text Dot wrote, which has to still be there.
    ///   - pasteboard: the pasteboard to write to.
    static func restore(
        _ text: String,
        ifStill holding: String,
        on pasteboard: NSPasteboard = .general
    ) {
        guard pasteboard.string(forType: .string) == holding else { return }
        copy(text, to: pasteboard)
    }

    /// The pasteboard types that tell a clipboard manager to skip an entry.
    ///
    /// The convention is `nspasteboard.org`: a writer that puts something
    /// private on the pasteboard adds these types to the item, and a clipboard
    /// manager that honours the convention keeps it out of its history and off
    /// its list. A dictation is exactly that kind of item. Without the marking
    /// every clipboard manager on the Mac keeps a permanent, browsable copy of
    /// everything the person said.
    static let privateTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    /// Puts text on the general pasteboard.
    static func copy(_ text: String) {
        copy(text, to: .general)
    }

    /// Puts text on a pasteboard, marked as private.
    ///
    /// - Parameters:
    ///   - text: the text to write.
    ///   - pasteboard: the pasteboard to write it to.
    static func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string] + privateTypes, owner: nil)
        pasteboard.setString(text, forType: .string)
    }

    /// Sends a ⌘V to the frontmost application.
    ///
    /// - Returns: `false` when the Accessibility permission is missing or the
    ///   event could not be created.
    @discardableResult
    static func pasteCommand() -> Bool {
        guard accessibilityGranted else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(15_000)
        up.post(tap: .cghidEventTap)
        return true
    }
}

/// The system places Dot sends the user to.
enum SystemAction {
    /// Opens System Settings on the Microphone privacy page.
    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// Opens System Settings on the Accessibility privacy page.
    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    /// Reveals the log file in Finder.
    static func revealLog() {
        let url = Log.defaultURL()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
