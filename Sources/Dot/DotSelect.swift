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

/// The select control Dot draws itself.
///
/// The app has one design language — ``DotFieldStyle`` fields, ``DotCard``
/// sheets, the ``DotTheme`` tokens — and a stock macOS pop-up button is the one
/// control that never learned it. This is the replacement: the trigger wears the
/// field chrome, and the list is a raised card of the app's own surface and
/// border instead of a system menu.
///
/// It is a select, not a menu of actions: one value is always current, a row
/// with a checkmark says which, and every row carries a value back through the
/// binding. A row may present `nil`, which is how "System Default" and "Choose
/// a service" are offered.
///
/// Keyboard and VoiceOver are part of the control rather than a wrapper:
/// Space and Return open the list, the arrow keys move, Return commits, Escape
/// cancels and leaves focus on the trigger. The trigger reports its label, its
/// current value and that it opens a list. Reduce Motion swaps the spring for a
/// fade, so the chevron and the list never spring.
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
            ScrollWheelIsolator {
                if needsScroll {
                    ScrollViewReader { scrollProxy in
                        ScrollView(.vertical) {
                            optionsStack
                        }
                        .scrollDisabled(false)
                        .scrollIndicators(.automatic)
                        .frame(width: max(0, width - 12), height: innerHeight)
                        .onAppear {
                            if options.indices.contains(highlighted) {
                                scrollProxy.scrollTo(highlighted, anchor: .center)
                            }
                        }
                        .onChange(of: highlighted) { _, newIndex in
                            if scrollToHighlighted {
                                scrollToHighlighted = false
                                withAnimation(.easeOut(duration: 0.12)) {
                                    scrollProxy.scrollTo(newIndex, anchor: .center)
                                }
                            }
                        }
                    }
                } else {
                    optionsStack
                }
            }
            .frame(width: max(0, width - 12), height: innerHeight)
        }
        .padding(6)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                .fill(DotTheme.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                .strokeBorder(DotTheme.cardBorder, lineWidth: 1)
        )
        .shadow(color: DotTheme.cardShadow, radius: 18, x: 0, y: 10)
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

    /// The upper limit for a dropdown menu before scrolling kicks in.
    private static var maxDropdownHeight: CGFloat { 250 }
    private static var safeTopMargin: CGFloat { 78 }
    private static var safeBottomMargin: CGFloat { 16 }

    /// How tall the list will be, near enough to place it.
    private var estimatedListHeight: CGFloat {
        Self.listHeight(for: options)
    }

    /// The height of a list of these options.
    static func listHeight(for options: [DotSelectOption<Value>]) -> CGFloat {
        let rows = options.reduce(CGFloat.zero) { $0 + rowHeight($1) }
        return 12 + rows + CGFloat(max(0, options.count - 1)) * 2
    }

    /// The height of one row: a detail line takes its own room.
    static func rowHeight(_ option: DotSelectOption<Value>) -> CGFloat {
        option.detail == nil ? 32 : 40
    }

    private var availableSpaceAbove: CGFloat {
        guard triggerFrame.height > 0 else { return Self.maxDropdownHeight }
        return max(0, triggerFrame.minY - Self.safeTopMargin - 6)
    }

    private var availableSpaceBelow: CGFloat {
        guard containerHeight > 0, triggerFrame.height > 0 else { return Self.maxDropdownHeight }
        return max(0, containerHeight - triggerFrame.maxY - Self.safeBottomMargin - 6)
    }

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

    /// Closes the list on a click anywhere outside the control, or when scrolling
    /// outside the control, matching native macOS pop-up button behavior.
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

/// An NSViewRepresentable that hosts a SwiftUI view and stops unhandled `scrollWheel`
/// events from bubbling up to any enclosing ancestor NSScrollView.
@MainActor
private struct ScrollWheelIsolator<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> IsolatorContainerView {
        let container = IsolatorContainerView()
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        container.hosting = hosting
        return container
    }

    func updateNSView(_ container: IsolatorContainerView, context: Context) {
        if let hosting = container.hosting as? NSHostingView<Content> {
            hosting.rootView = content
        }
    }

    final class IsolatorContainerView: NSView {
        var hosting: NSView?

        override func scrollWheel(with event: NSEvent) {}
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
/// A list is drawn outside its card, so it crosses into whatever the page puts
/// next — and a stack draws later children over earlier ones, which would hide
/// every list that opens upward. While a select is open the card it lives in
/// takes the front, whatever the page's order is.
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

/// The trigger: the same chrome as ``DotFieldStyle``, with a chevron.
///
/// The radius, the fill, the border and the focus ring are the field's values,
/// so a select and the text field beside it read as one control family.
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
