import AppKit
import ApplicationServices
import DotCore
import Foundation

/// One focused text field, as the Accessibility API reported it.
///
/// The element is kept beside the record it was read from: the rewrite needs
/// the same element twice, once to verify it still has focus and once to write
/// into it, and AX has no token that names an element.
struct FocusedTextField {
    /// The process the field belongs to.
    var processIdentifier: Int32
    /// The application's bundle id, for the card's header.
    var bundleIdentifier: String?
    /// The field itself.
    var element: AXUIElement
    /// The selected range before the paste, in UTF-16 units.
    var selection: NSRange
    /// Whether the field is a password field, which Dot never offers to rewrite.
    var isSecure: Bool
}

/// The insertion a paste made, and the field it went into.
struct InsertionAnchor {
    /// What was written, where, and when.
    var record: InsertionRecord
    /// The field it was written into.
    var field: FocusedTextField
}

/// The Accessibility operations a rewrite needs.
///
/// It is a protocol because the whole feature is a sequence of writes into
/// somebody else's text field, and a test has to be able to run that sequence
/// without one: the fake records the calls, and the real one is the only place
/// in Dot that talks to AX.
@MainActor
protocol TextFieldAccess: AnyObject {
    /// Reads the focused field of the frontmost application.
    ///
    /// - Returns: the field, or `nil` when AX cannot read it: no permission, no
    ///   focused element, or no selected range to insert at.
    func focusedField() -> FocusedTextField?

    /// Whether the focused element of the system is still this field.
    func isFocused(_ field: FocusedTextField) -> Bool

    /// The text a range currently holds.
    ///
    /// The range is selected before it is read, because AX has no other way to
    /// name a stretch of text inside a field.
    func text(in range: NSRange, of field: FocusedTextField) -> String?

    /// Selects a range.
    @discardableResult
    func select(_ range: NSRange, in field: FocusedTextField) -> Bool

    /// Writes text over the current selection.
    @discardableResult
    func setText(_ text: String, in field: FocusedTextField) -> Bool
}
