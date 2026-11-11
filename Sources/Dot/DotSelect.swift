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
    /// The SF Symbol the row and the trigger draw.
    var symbol: String?

    init(value: Value?, title: String, detail: String? = nil, symbol: String? = nil) {
        self.value = value
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }
}

/// The select control Dot draws itself, in place of a stock pop-up button.
///
/// It is a select, not a menu of actions: exactly one value is current, a
/// checkmark names that row, and every row writes a value back through the
/// binding. A row may carry `nil`, which is how "System Default" and "Choose a
/// service" are offered.
///
/// Contract:
///
/// - Space and Return open the list, the arrow keys move, Return commits, Escape
///   closes and leaves focus on the trigger.
/// - The trigger reports its label, its current value and that it opens a list.
/// - The list opens upward when there is more room above the trigger than below
///   it, and scrolls instead of overflowing the surface it sits in.
/// - Reduce Motion replaces the scale transition with a fade.
@MainActor
struct DotSelect<Value: Hashable>: View {
    /// What the control selects, e.g. "Microphone".
    let label: String
    /// The choices, in the order the list draws them.
    let options: [DotSelectOption<Value>]
    @Binding private var selection: Value?
    /// Shown when no row matches the selection.
    private let placeholder: String
    /// The width of the trigger, which is also the width of the list.
    private let width: CGFloat
    private let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isOpen: Bool
    @State private var highlighted = 0
    @State private var scrollToHighlighted = false
    /// The height of the trigger, so the list can sit under it.
    @State private var triggerHeight: CGFloat = 29
    /// Where the trigger sits in the container, and how tall the container is.
    /// The list drops down unless there is more room above it than below.
    @State private var triggerFrame: CGRect = .zero
    @State private var containerHeight: CGFloat = 0
    @State private var dismissMonitor: Any?
    @State private var pointerInside = false
    @State private var hovered = false
    @FocusState private var focused: Bool

    /// Creates a select whose list offers its own "none".
    ///
    /// - Parameters:
    ///   - label: the accessibility label, e.g. "Spoken language".
    ///   - options: the choices.
    ///   - selection: the chosen value; `nil` draws the placeholder, or the row
    ///     whose value is `nil`.
    ///   - placeholder: the words shown when nothing is selected and no row
    ///     carries `nil`.
    ///   - width: the width of the trigger and of the list.
    ///   - isEnabled: whether the control can be used.
    ///   - openForPreview: draws the list open on the first frame. Headless
    ///     renders use it to capture the open state; production never does.
    init(
        label: String,
        options: [DotSelectOption<Value>],
        selection: Binding<Value?>,
        placeholder: String = "Choose…",
        width: CGFloat = 220,
        isEnabled: Bool = true,
        openForPreview: Bool = false
    ) {
        self.label = label
        self.options = options
        _selection = selection
        self.placeholder = placeholder
        self.width = width
        self.isEnabled = isEnabled
        _isOpen = State(initialValue: openForPreview)
        _highlighted = State(initialValue: options.firstIndex { $0.value == selection.wrappedValue } ?? 0)
    }

    /// Creates a select that always has a value, so no row can be "none".
    init(
        label: String,
        options: [DotSelectOption<Value>],
        selection: Binding<Value>,
        placeholder: String = "Choose…",
        width: CGFloat = 220,
        isEnabled: Bool = true,
        openForPreview: Bool = false
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
            isEnabled: isEnabled,
            openForPreview: openForPreview
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            trigger
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { measure(proxy) }
                            .onChange(of: proxy.size.height) { _, _ in measure(proxy) }
                            .onChange(of: proxy.frame(in: .global)) { _, _ in measure(proxy) }
                    }
                )
            if isOpen {
                list
                    .offset(y: listOffset)
                    .transition(listTransition)
                    .zIndex(isOpen ? 100 : 1)
            }
        }
        .frame(width: width, height: triggerHeight, alignment: .topLeading)
        .background(ContainerHeightReader { height in
            containerHeight = height
        })
        .zIndex(isOpen ? 100 : 1)
        .preference(key: DotSelectOpenKey.self, value: isOpen)
        .animation(motion, value: isOpen)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            // Space opens and closes; Return commits, so a keyboard user cannot
            // change the value by accident.
            toggle()
            return .handled
        }
        .onKeyPress(.return) { activateFromKeyboard() }
        .onKeyPress(.upArrow) {
            move(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            move(1)
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onDisappear {
            isOpen = false
            stopDismissMonitor()
        }
        .disabled(!isEnabled)
    }

    // MARK: - Trigger

    private var trigger: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 8) {
                if let symbol = currentOption?.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(currentOption == nil ? DotTheme.ink3 : DotTheme.accent)
                        .frame(width: 16)
                }
                Text(currentOption?.title ?? placeholder)
                    .font(.system(size: 12.5, weight: currentOption == nil ? .regular : .medium))
                    .foregroundStyle(currentOption == nil ? DotTheme.ink3 : DotTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(DotTheme.ink3)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
        }
        .buttonStyle(DotSelectTriggerStyle(focused: focused, open: isOpen, hovered: hovered))
        .focusable(false)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hovered = hovering }
            pointerInside = hovering
        }
        .accessibilityLabel(label)
        .accessibilityValue(currentOption?.title ?? placeholder)
        .accessibilityHint(
            "Opens a list of \(options.count) choices. Use the arrow keys to move, Return to choose and Escape to close."
        )
    }

    // MARK: - List

    private var list: some View {
        let maxAllowed = allowedListHeight
        let needsScroll = estimatedListHeight > maxAllowed
        let innerHeight = max(40, displayedListHeight - 12)
        return VStack(spacing: 0) {
            if needsScroll {
                IsolatedDropdownScroll(
                    content: optionsStack,
                    width: max(0, width - 12),
                    height: innerHeight,
                    highlighted: highlighted,
                    scrollToHighlighted: $scrollToHighlighted,
                    rowHeight: options.first.map(Self.rowHeight) ?? 32
                )
                .frame(width: max(0, width - 12), height: innerHeight)
            } else {
                optionsStack
                    .frame(width: max(0, width - 12))
            }
        }
        .padding(6)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DotTheme.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.40), radius: 18, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.20), radius: 4, x: 0, y: 2)
        .onHover { hovering in
            pointerInside = hovering
        }
    }

    private var optionsStack: some View {
        VStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                DotSelectRowView(
                    option: option,
                    isSelected: option.value == selection,
                    isHighlighted: index == highlighted,
                    rowHeight: Self.rowHeight(option),
                    onCommit: { commit(option) },
                    onHover: {
                        scrollToHighlighted = false
                        highlighted = index
                    }
                )
                .id(index)
            }
        }
    }

    // MARK: - Placement

    private func measure(_ proxy: GeometryProxy) {
        triggerHeight = proxy.size.height
        triggerFrame = proxy.frame(in: .global)
    }

    /// The tallest the list may be before it scrolls, in points.
    private static var maxDropdownHeight: CGFloat { 250 }
    /// The room a list opening upward must leave above it, in points.
    private static var safeTopMargin: CGFloat { 78 }
    /// The room a list opening downward must leave below it, in points.
    private static var safeBottomMargin: CGFloat { 16 }

    /// How tall the list will be, near enough to place it.
    ///
    /// Exact enough for placement: the card adds the vertical padding, and the
    /// rows are measured with ``rowHeight(_:)`` rather than laid out.
    private var estimatedListHeight: CGFloat {
        Self.listHeight(for: options)
    }

    /// Whether the options exceed the allowed dropdown height and require scrolling.
    /// Whether the options do not fit the space the list may take.
    private var needsScroll: Bool {
        estimatedListHeight > allowedListHeight
    }

    /// The height of a list of these options.
    static func listHeight(for options: [DotSelectOption<Value>]) -> CGFloat {
        let rows = options.reduce(CGFloat.zero) { $0 + rowHeight($1) }
        return 12 + rows + CGFloat(max(0, options.count - 1)) * 2
    }

    /// The height of one row, in points: a detail line takes its own room.
    static func rowHeight(_ option: DotSelectOption<Value>) -> CGFloat {
        option.detail == nil ? 32 : 40
    }

    /// The room above the trigger, in points, inside the surface the select sits in.
    private var availableSpaceAbove: CGFloat {
        guard triggerFrame.height > 0 else { return Self.maxDropdownHeight }
        return max(0, triggerFrame.minY - Self.safeTopMargin - 6)
    }

    /// The room below the trigger, in points, inside the surface the select sits in.
    private var availableSpaceBelow: CGFloat {
        guard containerHeight > 0, triggerFrame.height > 0 else { return Self.maxDropdownHeight }
        return max(0, containerHeight - triggerFrame.maxY - Self.safeBottomMargin - 6)
    }

    /// Whether the list has to open above the trigger.
    ///
    /// It drops down whenever it fits below, because a list that covers the
    /// fields above the trigger hides the thing it is editing.
    private var opensUpward: Bool {
        let fitsBelow = availableSpaceBelow >= min(estimatedListHeight, Self.maxDropdownHeight)
        if fitsBelow { return false }

        let canFitUpward = availableSpaceAbove >= 110
        if canFitUpward && availableSpaceAbove > availableSpaceBelow {
            return true
        }
        return false
    }

    /// The maximum height the list is allowed to take.
    private var allowedListHeight: CGFloat {
        let space = opensUpward ? availableSpaceAbove : availableSpaceBelow
        return max(60, min(Self.maxDropdownHeight, space))
    }

    /// The actual displayed height of the dropdown card.
    private var displayedListHeight: CGFloat {
        min(estimatedListHeight, allowedListHeight)
    }

    /// Where the list sits relative to the trigger, with the gap between them.
    private var listOffset: CGFloat {
        opensUpward ? -(displayedListHeight + 6) : triggerHeight + 6
    }

    // MARK: - State

    /// The row the selection points at, when a row carries it.
    private var currentOption: DotSelectOption<Value>? {
        options.first { $0.value == selection }
    }

    private func toggle() {
        if isOpen {
            close()
        } else {
            open()
        }
    }

    private func open() {
        guard isEnabled else { return }
        highlighted = options.firstIndex { $0.value == selection } ?? 0
        focused = true
        isOpen = true
        startDismissMonitor()
    }

    private func close() {
        isOpen = false
        focused = true
        stopDismissMonitor()
    }

    private func commit(_ option: DotSelectOption<Value>) {
        selection = option.value
        close()
    }

    private func move(_ step: Int) {
        guard !options.isEmpty else { return }
        if !isOpen {
            open()
        }
        scrollToHighlighted = true
        highlighted = min(max(highlighted + step, 0), options.count - 1)
    }

    private var motion: Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.26, dampingFraction: 0.84)
    }

    private var listTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.98, anchor: opensUpward ? .bottom : .top))
    }

    // MARK: - Dismissal

    /// Closes the list on a click or a scroll outside the control.
    ///
    /// The monitor is local, so it only sees events delivered to this app: a
    /// click in another application closes the window that owns the select and
    /// takes the list with it. A scroll inside a list that does not overflow is
    /// swallowed, so the surface behind it does not move under the pointer.
    private func startDismissMonitor() {
        guard dismissMonitor == nil else { return }
        dismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { event in
            var swallowed = false
            MainActor.assumeIsolated {
                guard isOpen else { return }
                let isInside = isPointerInsideControl(event: event)

                if event.type == .scrollWheel {
                    if !isInside {
                        close()
                        swallowed = true
                    } else if !needsScroll {
                        swallowed = true
                    }
                } else if !isInside {
                    close()
                    swallowed = true
                }
            }
            return swallowed ? nil : event
        }
    }

    private func isPointerInsideControl(event: NSEvent) -> Bool {
        if pointerInside { return true }
        guard let window = event.window ?? NSApp.keyWindow else { return pointerInside }
        let location = event.locationInWindow
        let windowHeight = window.contentView?.bounds.height ?? containerHeight
        guard windowHeight > 0 else { return pointerInside }
        let topY = windowHeight - location.y
        let pt = CGPoint(x: location.x, y: topY)

        let trig = triggerFrame.insetBy(dx: -2, dy: -2)
        if trig.contains(pt) { return true }

        let listY = opensUpward ? (triggerFrame.minY - displayedListHeight - 6) : (triggerFrame.maxY + 6)
        let listRect = CGRect(x: triggerFrame.minX - 4, y: listY - 4, width: width + 8, height: displayedListHeight + 8)
        if listRect.contains(pt) { return true }

        return false
    }

    private func stopDismissMonitor() {
        if let dismissMonitor {
            NSEvent.removeMonitor(dismissMonitor)
        }
        dismissMonitor = nil
    }

    private func activateFromKeyboard() -> KeyPress.Result {
        if isOpen, options.indices.contains(highlighted) {
            commit(options[highlighted])
        } else {
            open()
        }
        return .handled
    }
}

// MARK: - Row View

@MainActor
private struct DotSelectRowView<Value: Hashable>: View {
    let option: DotSelectOption<Value>
    let isSelected: Bool
    let isHighlighted: Bool
    let rowHeight: CGFloat
    let onCommit: () -> Void
    let onHover: () -> Void

    var body: some View {
        Button {
            onCommit()
        } label: {
            HStack(spacing: 8) {
                if let symbol = option.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isSelected ? DotTheme.accent : DotTheme.ink3)
                        .frame(width: 18, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? DotTheme.cardSelectedFill : DotTheme.accentSoft)
                        )
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DotTheme.ink)
                        .lineLimit(1)
                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(DotTheme.ink3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DotTheme.accent)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: rowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHighlighted ? DotTheme.cardHoverFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                onHover()
            }
        }
        .accessibilityLabel(option.detail.map { "\(option.title), \($0)" } ?? option.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// An overlay scroller drawn as a thin translucent pill on a transparent track.
///
/// The knob is ``pillWidth`` points wide and inset by ``pillInset`` at both ends,
/// so it stays a hairline at any scroll-extent without a gutter being reserved
/// for it.
final class MinimalScroller: NSScroller {
    /// The width of the knob, in points.
    static let pillWidth: CGFloat = 3.5
    /// The inset at each end of the knob, in points.
    static let pillInset: CGFloat = 2
    /// The smallest knob the pill is drawn at, in points.
    static let minimumPillHeight: CGFloat = 16

    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        guard let knobRect = rect(for: .knob) as NSRect? else { return }
        let width = Self.pillWidth
        let pillRect = NSRect(
            x: knobRect.midX - width / 2,
            y: knobRect.minY + Self.pillInset,
            width: width,
            height: max(Self.minimumPillHeight, knobRect.height - Self.pillInset * 2)
        )
        let path = NSBezierPath(roundedRect: pillRect, xRadius: width / 2, yRadius: width / 2)
        NSColor.white.withAlphaComponent(0.24).setFill()
        path.fill()
    }
}

/// A scroll view that belongs to exactly one surface.
///
/// It never forwards a wheel event to an enclosing scroll view, it draws its knob
/// through ``MinimalScroller``, and it clamps the offset itself so reaching the
/// end of the content never scrolls the window behind it.
final class PureIsolatedScrollView: NSScrollView {
    override var enclosingScrollView: NSScrollView? {
        nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard let docView = documentView else { return }
        let deltaY = event.scrollingDeltaY
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 14.0
        let dy = deltaY * multiplier

        let currentOrigin = contentView.bounds.origin
        let maxOriginY = max(0, docView.bounds.height - contentView.bounds.height)
        let targetY = min(max(0, currentOrigin.y - dy), maxOriginY)

        contentView.bounds.origin = CGPoint(x: currentOrigin.x, y: targetY)
        reflectScrolledClipView(contentView)
    }
}

@MainActor
private struct IsolatedDropdownScroll<Content: View>: NSViewRepresentable {
    let content: Content
    let width: CGFloat
    let height: CGFloat
    let highlighted: Int
    @Binding var scrollToHighlighted: Bool
    let rowHeight: CGFloat

    func makeNSView(context: Context) -> PureIsolatedScrollView {
        let sv = PureIsolatedScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.verticalScroller = MinimalScroller()

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        sv.documentView = hosting
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: sv.contentView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: sv.contentView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: sv.contentView.topAnchor)
        ])

        if highlighted > 0 {
            DispatchQueue.main.async {
                let targetY = CGFloat(highlighted) * rowHeight
                let maxOriginY = max(0, hosting.bounds.height - sv.contentView.bounds.height)
                let clampedY = min(max(0, targetY - (sv.contentView.bounds.height / 2) + (rowHeight / 2)), maxOriginY)
                sv.contentView.bounds.origin.y = clampedY
                sv.reflectScrolledClipView(sv.contentView)
            }
        }

        return sv
    }

    func updateNSView(_ sv: PureIsolatedScrollView, context: Context) {
        if let hosting = sv.documentView as? NSHostingView<Content> {
            hosting.rootView = content
        }
        if scrollToHighlighted {
            DispatchQueue.main.async {
                scrollToHighlighted = false
                guard let docView = sv.documentView else { return }
                let targetY = CGFloat(highlighted) * rowHeight
                let maxOriginY = max(0, docView.bounds.height - sv.contentView.bounds.height)
                let clampedY = min(max(0, targetY - (sv.contentView.bounds.height / 2) + (rowHeight / 2)), maxOriginY)
                sv.contentView.bounds.origin.y = clampedY
                sv.reflectScrolledClipView(sv.contentView)
            }
        }
    }
}

/// Reports how tall the surface the select sits in is.
///
/// In a window that is the content view; in an offscreen render it is the
/// hosting view the preview draws into. Either way it is the height the list
/// has to fit inside, which is what decides whether it opens up or down.
private struct ContainerHeightReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = onChange
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.onChange = onChange
        probe.report()
    }

    final class Probe: NSView {
        var onChange: ((CGFloat) -> Void)?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            report()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        /// Measures; never takes a click from the control drawn above it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func report() {
            guard let container = window?.contentView ?? topmost, container.bounds.height > 0 else {
                return
            }
            onChange?(container.bounds.height)
        }

        private var topmost: NSView? {
            var node: NSView? = self
            while let next = node?.superview {
                node = next
            }
            return node
        }
    }
}

/// Whether a select inside this subtree has its list open.
struct DotSelectOpenKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Keeps the card a select sits in above the cards beside it while its list is
/// open.
///
/// A list is drawn outside its card, and a stack draws later children over
/// earlier ones, so without this every list that opens upward is covered by the
/// card below it regardless of where it is drawn.
private struct DotSelectLayer: ViewModifier {
    @State private var isOpen = false

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(DotSelectOpenKey.self) { open in
                isOpen = open
            }
            .zIndex(isOpen ? 100 : 0)
    }
}

extension View {
    /// Draws this container over its siblings while a select inside it is open.
    func dotSelectLayer() -> some View {
        modifier(DotSelectLayer())
    }
}

/// The trigger: the chrome of ``DotFieldStyle``, with a chevron.
///
/// The radius, the fill, the border and the focus ring are the field's values,
/// so a select beside a text field reads as the same control family.
private struct DotSelectTriggerStyle: ButtonStyle {
    let focused: Bool
    let open: Bool
    let hovered: Bool

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let raised = configuration.isPressed || open || focused || hovered
        return configuration.label
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(minHeight: 29)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(raised ? DotTheme.fieldFillFocused : DotTheme.fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        open || focused ? DotTheme.focusRing : DotTheme.fieldBorder,
                        lineWidth: open || focused ? 1.5 : 1
                    )
            )
            .opacity(isEnabled ? 1 : 0.55)
            .scaleEffect(configuration.isPressed && !open ? 0.99 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: raised)
    }
}
