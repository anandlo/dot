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

    /// Puts text on the general pasteboard.
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
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
