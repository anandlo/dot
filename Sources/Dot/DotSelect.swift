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

/// One row of an open list: the words, without the value behind them.
///
/// The trigger and the panel both draw a list of rows, and neither of them
/// knows what a row is worth: the value stays with the `V` of a
/// ``DotSelect`` and is written back by index.
struct DotSelectRow: Equatable, Sendable {
    let title: String
    let detail: String?
    let symbol: String?

    init(title: String, detail: String? = nil, symbol: String? = nil) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }
}

/// A choice from a fixed list, drawn by Dot.
///
/// The trigger is the same chrome as a text field - one fill, one border, one
/// corner radius, 29 points tall - so a row that picks a value and a row that
/// types one sit on the same line. A trigger whose row does not name a width
/// draws the settings column, so every picker on a page starts and ends at the
/// same place; a longer title truncates rather than widening its row. The list
/// itself is a floating panel (``DotSelectPanel``) rather than a view inside the
/// window: a list drawn in the window's own coordinate space cannot escape the
/// scroll view and the card it is clipped by.
@MainActor
struct DotSelect<Value: Hashable>: View {
    /// What the control selects, e.g. "Microphone".
    let label: String
    /// The choices, in the order the list shows them.
    let options: [DotSelectOption<Value>]
    @Binding private var selection: Value?
    /// Shown when no row matches the selection.
    private let placeholder: String
    /// The drawn width of the trigger; `nil` draws the settings column.
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
    ///   - width: the drawn width of the trigger, or `nil` for the settings
    ///     column.
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
        DotSelectTrigger(
            label: label,
            title: currentOption?.title ?? placeholder,
            rows: rows,
            selectedIndex: selectedIndex,
            width: width ?? DotSelectMetrics.settingsColumn,
            isEnabled: isEnabled
        ) { index in
            guard options.indices.contains(index) else { return }
            selection = options[index].value
        }
    }

    /// The row the selection points at, when a row carries it.
    private var selectedIndex: Int? {
        options.firstIndex { $0.value == selection }
    }

    private var currentOption: DotSelectOption<Value>? {
        selectedIndex.map { options[$0] }
    }

    private var rows: [DotSelectRow] {
        options.map {
            DotSelectRow(title: $0.title, detail: $0.detail, symbol: $0.symbol)
        }
    }
}

/// The drawn trigger: one line of ink and a chevron on a field.
///
/// It is deliberately not a button style of its own: the fill, the border and
/// the ring are the field's, and the open state is what turns the border into
/// the focus ring, so an open list reads as the field being edited rather than
/// as a second kind of control.
@MainActor
private struct DotSelectTrigger: View {
    let label: String
    let title: String
    let rows: [DotSelectRow]
    let selectedIndex: Int?
    let width: CGFloat
    let isEnabled: Bool
    let onSelect: (Int) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    @State private var isOpen = false
    @State private var anchor = DotSelectAnchor()

    var body: some View {
        content
            .accessibilityHidden(true)
            .padding(.horizontal, 10)
            .frame(height: DotSelectMetrics.height)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: DotSelectMetrics.corner, style: .continuous)
                    .fill(isHovering && isEnabled ? DotTheme.fieldFillFocused : DotTheme.fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DotSelectMetrics.corner, style: .continuous)
                    .strokeBorder(borderColour, lineWidth: isFocused || isOpen ? 1.5 : 1)
            )
            .background(DotSelectAnchorReporter(anchor: anchor))
            .contentShape(RoundedRectangle(cornerRadius: DotSelectMetrics.corner, style: .continuous))
            .onTapGesture(perform: toggle)
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(.space) { activate(); return .handled }
            .onKeyPress(.return) { activate(); return .handled }
            .onKeyPress(.downArrow) { activate(); return .handled }
            .onHover { inside in
                isHovering = inside && isEnabled
            }
            .onDisappear {
                if isOpen { DotSelectListController.shared.close() }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .background(
                DotSelectAccessibilityElement(
                    label: label,
                    value: title,
                    isEnabled: isEnabled,
                    onOpen: activate
                )
            )
    }

    private var content: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(DotSelectMetrics.titleFont)
                .foregroundStyle(DotTheme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DotTheme.ink3)
                .fixedSize()
        }
    }

    private var borderColour: Color {
        isFocused || isOpen ? DotTheme.focusRing : DotTheme.fieldBorder
    }

    /// Opens the list, or closes the one this trigger owns.
    private func toggle() {
        guard isEnabled else { return }
        if isOpen {
            DotSelectListController.shared.close()
            return
        }
        guard !DotSelectListController.shared.takeSuppressedOpening() else { return }
        guard anchor.window != nil else { return }
        let opened = DotSelectListController.shared.present(
            anchor: anchor,
            rows: rows,
            selectedIndex: selectedIndex,
            title: label,
            scheme: colorScheme,
            onSelect: onSelect,
            onClose: { isOpen = false }
        )
        isOpen = opened
    }

    /// A key that opens the list, which is also a click on the trigger.
    private func activate() {
        guard isEnabled, !isOpen else { return }
        toggle()
    }
}

/// The numbers the trigger draws at.
enum DotSelectMetrics {
    /// The drawn height, which is the height of a ``DotFieldStyle`` field.
    static let height: CGFloat = 29
    /// The width a trigger draws at when its row does not name one.
    ///
    /// One width on every row of a page: a picker that grew with its longest
    /// title left the pickers above and below it at other widths, which reads
    /// as an unfinished page rather than as three of the same control.
    static let settingsColumn: CGFloat = 240
    /// The corner radius of a field.
    static let corner: CGFloat = 8
    static let titleFont = Font.system(size: 12.5, weight: .regular)
}

/// The trigger's frame, in the coordinates a panel is placed in.
///
/// A SwiftUI view cannot ask for its own window, and a panel is placed in screen
/// coordinates, so a bare `NSView` behind the trigger records both: the window
/// it ended up in and the frame it occupies in screen space.
@MainActor
final class DotSelectAnchor {
    weak var window: NSWindow?
    var screenFrame: NSRect = .zero

    func record(_ view: NSView) {
        window = view.window
        guard let window else { return }
        screenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct DotSelectAnchorReporter: NSViewRepresentable {
    let anchor: DotSelectAnchor

    func makeNSView(context: Context) -> AnchorReportingView {
        let view = AnchorReportingView()
        view.anchor = anchor
        return view
    }

    func updateNSView(_ view: AnchorReportingView, context: Context) {
        view.anchor = anchor
        view.record()
    }
}

private final class AnchorReportingView: NSView {
    var anchor: DotSelectAnchor?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        record()
    }

    override func layout() {
        super.layout()
        record()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        record()
    }

    func record() {
        anchor?.record(self)
    }
}

/// The accessibility element of the trigger: a pop-up button, in AppKit terms.
///
/// SwiftUI has no pop-up button role, and the trigger is a drawing rather than a
/// platform control, so the one `NSView` it owns is the element VoiceOver reads.
private struct DotSelectAccessibilityElement: NSViewRepresentable {
    let label: String
    let value: String
    let isEnabled: Bool
    let onOpen: () -> Void

    func makeNSView(context: Context) -> DotSelectAccessibilityView {
        let view = DotSelectAccessibilityView()
        view.apply(label: label, value: value, isEnabled: isEnabled, onOpen: onOpen)
        return view
    }

    func updateNSView(_ view: DotSelectAccessibilityView, context: Context) {
        view.apply(label: label, value: value, isEnabled: isEnabled, onOpen: onOpen)
    }
}

final class DotSelectAccessibilityView: NSView {
    private var label = ""
    private var value = ""
    private var enabled = true
    private var onOpen: (() -> Void)?

    func apply(label: String, value: String, isEnabled: Bool, onOpen: @escaping () -> Void) {
        self.label = label
        self.value = value
        self.enabled = isEnabled
        self.onOpen = onOpen
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(label)
        setAccessibilityValue(value)
        setAccessibilityEnabled(isEnabled)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .popUpButton
    }

    override func accessibilityLabel() -> String? {
        label
    }

    override func accessibilityValue() -> Any? {
        value
    }

    override func isAccessibilityEnabled() -> Bool {
        enabled
    }

    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        onOpen?()
        return true
    }
}
