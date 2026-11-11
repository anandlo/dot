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
    static let secureSubrole = "AXSecureTextField"

    /// The shared reader. It holds no state: every call asks the system again.
    static let shared = AccessibilityTextFieldAccess()

    func focusedField() -> FocusedTextField? {
        guard let element = Self.focusedElement() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        guard let selected = Self.selection(of: element) else { return nil }
        return FocusedTextField(
            processIdentifier: pid,
            bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            element: element,
            selection: NSRange(location: selected.location, length: selected.length),
            isSecure: Self.subrole(of: element) == Self.secureSubrole
        )
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
        AXUIElementSetAttributeValue(
            field.element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    // MARK: - Attributes

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
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

    private static func selection(of element: AXUIElement) -> CFRange? {
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

    private static func subrole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }
}
