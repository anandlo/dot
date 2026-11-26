import AppKit
import ApplicationServices
import DotCore
import Foundation

/// The one place in Dot that reads and writes another application's text field.
///
/// Every call here can fail, and each failure means the rewrite goes to the
/// clipboard instead: there is no retry, no fallback into a second AX
/// attribute, and no synthetic keystroke. Writing into somebody else's editor
/// is only ever done through the range the paste itself created.
@MainActor
final class AccessibilityTextFieldAccess: TextFieldAccess {
    /// The subrole macOS gives a password field.
    nonisolated static let secureSubrole = "AXSecureTextField"
    private nonisolated static let messagingTimeoutSeconds: Float = 0.05

    private struct FocusedFieldBox: @unchecked Sendable {
        let field: FocusedTextField?
    }

    /// The shared reader. It holds no state: every call asks the system again.
    static let shared = AccessibilityTextFieldAccess()

    func focusedField() -> FocusedTextField? {
        Self.readFocusedField()
    }

    nonisolated static func readFocusedField() -> FocusedTextField? {
        guard let element = focusedElement() else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        guard let selected = selection(of: element) else { return nil }
        return FocusedTextField(
            processIdentifier: pid,
            bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            element: element,
            selection: NSRange(location: selected.location, length: selected.length),
            isSecure: subrole(of: element) == secureSubrole
        )
    }

    static func captureFocusedFieldAsync() async -> FocusedTextField? {
        let boxed = await Task.detached(priority: .userInitiated) {
            FocusedFieldBox(field: readFocusedField())
        }.value
        return boxed.field
    }

    func isFocused(_ field: FocusedTextField) -> Bool {
        guard let focused = Self.focusedElement() else { return false }
        return CFEqual(focused, field.element)
    }

    func text(in range: NSRange, of field: FocusedTextField) -> String? {
        guard select(range, in: field) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            field.element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    @discardableResult
    func select(_ range: NSRange, in field: FocusedTextField) -> Bool {
        AXUIElementSetMessagingTimeout(field.element, Self.messagingTimeoutSeconds)
        var value = CFRange(location: range.location, length: range.length)
        guard let boxed = AXValueCreate(.cfRange, &value) else { return false }
        return AXUIElementSetAttributeValue(
            field.element,
            kAXSelectedTextRangeAttribute as CFString,
            boxed
        ) == .success
    }

    @discardableResult
    func setText(_ text: String, in field: FocusedTextField) -> Bool {
        AXUIElementSetMessagingTimeout(field.element, Self.messagingTimeoutSeconds)
        return AXUIElementSetAttributeValue(
            field.element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    // MARK: - Attributes

    private nonisolated static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeoutSeconds)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private nonisolated static func selection(of element: AXUIElement) -> CFRange? {
        AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue((value as! AXValue), .cfRange, &range) else { return nil }
        return range
    }

    private nonisolated static func subrole(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }
}
