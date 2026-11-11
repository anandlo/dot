import AppKit
import SwiftUI

/// One choice in a ``DotSelect``.
///
/// A choice is a value, the words a person reads and, optionally, the line that
/// explains it. `value` is optional because a list may offer a real "none" —
/// the system default microphone, or no service chosen yet.
struct DotSelectOption<Value: Hashable> {
    /// The value written into the binding when the row is chosen; `nil` is the
    /// list's own "none".
    let value: Value?
    /// The words on the trigger and on the row.
    let title: String
    /// A second, quieter line under the title, when the list needs it.
    var detail: String?
    /// The SF Symbol the row draws.
    var symbol: String?

    init(value: Value?, title: String, detail: String? = nil, symbol: String? = nil) {
        self.value = value
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }
}

/// A choice from a fixed list, drawn by the system.
///
/// The control is an `NSPopUpButton`: the list opens above the window, accepts
/// the keyboard, type-selects by the first letters of a row and marks the
/// current value with a checkmark without Dot drawing any of it. The button is
/// sized by ``width`` so every picker in a column is the same drawn width on
/// screen, not only the same proposed width.
@MainActor
struct DotSelect<Value: Hashable>: View {
    /// What the control selects, e.g. "Microphone".
    let label: String
    /// The choices, in the order the menu lists them.
    let options: [DotSelectOption<Value>]
    @Binding private var selection: Value?
    /// Shown when no row matches the selection.
    private let placeholder: String
    /// The drawn width of the button; `nil` lets it hug the current title.
    private let width: CGFloat?
    private let isEnabled: Bool

    /// Creates a select whose list offers its own "none".
    ///
    /// - Parameters:
    ///   - label: the accessibility label, e.g. "Spoken language".
    ///   - options: the choices.
    ///   - selection: the chosen value.
    ///   - placeholder: the words shown when nothing is selected and no row
    ///     carries `nil`.
    ///   - width: the drawn width of the button.
    ///   - isEnabled: whether the control can be used.
    init(
        label: String,
        options: [DotSelectOption<Value>],
        selection: Binding<Value?>,
        placeholder: String = "Choose…",
        width: CGFloat? = 220,
        isEnabled: Bool = true
    ) {
        self.label = label
        self.options = options
        _selection = selection
        self.placeholder = placeholder
        self.width = width
        self.isEnabled = isEnabled
    }

    /// Creates a select that always has a value, so no row can be "none".
    init(
        label: String,
        options: [DotSelectOption<Value>],
        selection: Binding<Value>,
        placeholder: String = "Choose…",
        width: CGFloat? = 220,
        isEnabled: Bool = true
    ) {
        let optional = Binding<Value?>(
            get: { selection.wrappedValue },
            set: { value in
                guard let value else { return }
                selection.wrappedValue = value
            }
        )
        self.init(
            label: label,
            options: options,
            selection: optional,
            placeholder: placeholder,
            width: width,
            isEnabled: isEnabled
        )
    }

    var body: some View {
        PopUpButton(
            options: options,
            selection: $selection,
            placeholder: placeholder,
            width: displayWidth,
            isEnabled: isEnabled
        )
        .frame(width: displayWidth, alignment: .trailing)
        .accessibilityLabel(label)
        .accessibilityValue(currentOption?.title ?? placeholder)
        .accessibilityHint("Opens a list of \(options.count) choices.")
    }

    /// The row the selection points at, when a row carries it.
    private var currentOption: DotSelectOption<Value>? {
        options.first { $0.value == selection }
    }

    /// The width the button draws at.
    ///
    /// A fixed width is the Provider page's column. Without one the control
    /// hugs the title it is showing, which is what a row in a list wants: the
    /// menu may hold names that are far longer than the one selected.
    private var displayWidth: CGFloat {
        if let width { return width }
        let font = NSFont.systemFont(ofSize: 13)
        let text = (currentOption?.title ?? placeholder) as NSString
        return ceil(text.size(withAttributes: [.font: font]).width) + 42
    }
}

/// The AppKit pop-up behind ``DotSelect``.
///
/// An explicit intrinsic width is what makes the drawn bezel the same for
/// "JSON" and "Authorization: Bearer": the SwiftUI menu picker hugs its title,
/// so two rows in one card came out at different widths.
