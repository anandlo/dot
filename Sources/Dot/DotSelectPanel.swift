import AppKit
import SwiftUI

// MARK: - Geometry

/// Where the open list goes, and how large it draws.
///
/// The math is pure: the panel owns a screen, a trigger frame and a list, and
/// nothing here asks AppKit anything, so the policy can be tested without a
/// display. Frames are in the bottom-left screen coordinates `NSScreen` uses.
enum DotSelectPlacement {
    /// The air between the trigger and the card.
    static let gap: CGFloat = 4
    /// The inset the card gives its rows.
    static let inset: CGFloat = 5
    /// The widest a list may be drawn.
    static let maxWidth: CGFloat = 360
    /// The tallest a list may be drawn before it scrolls.
    static let maxHeight: CGFloat = 320
    /// The height of a row with one line.
    static let rowHeight: CGFloat = 28
    /// The height of a row with a title and a detail line.
    static let rowDetailHeight: CGFloat = 40
    /// The room the card's own shadow needs inside its window.
    ///
    /// The shadow is drawn by the content, not by the window, so the window is
    /// larger than the card: a window sized to the card would cut the shadow
    /// off at the card's own edge.
    static let shadowInset: CGFloat = 24

    /// The height of one row.
    static func rowHeight(detail: String?) -> CGFloat {
        detail == nil ? rowHeight : rowDetailHeight
    }

    /// The drawn size of the card.
    ///
    /// The list is as wide as its trigger unless a row needs more, and never
    /// wider than ``maxWidth``. Its height is its rows plus the card's inset,
    /// and never taller than ``maxHeight``.
    ///
    /// - Parameters:
    ///   - triggerWidth: the drawn width of the trigger.
    ///   - widestRow: the width of the widest row's content, without the inset.
    ///   - rowHeights: the height of every row, in order.
    /// - Returns: the size of the card.
    static func size(
        triggerWidth: CGFloat,
        widestRow: CGFloat,
        rowHeights: [CGFloat]
    ) -> CGSize {
        let rows = rowHeights.reduce(0) { $0 + max(0, $1) }
        let trigger = triggerWidth.isFinite ? max(0, triggerWidth) : 0
        let row = widestRow.isFinite ? max(0, widestRow) : 0
        return CGSize(
            width: min(maxWidth, max(trigger, row + 2 * inset)),
            height: min(maxHeight, max(0, rows + 2 * inset))
        )
    }

    /// The frame of the card, in screen coordinates.
    ///
    /// The card hangs `gap` below the trigger with its left edge on the
    /// trigger's. When the screen has less room below the trigger than the card
    /// needs, it opens above it instead. A card that fits on neither side is
    /// slid inside the visible frame rather than drawn off the screen.
    static func frame(
        anchor: CGRect,
        size: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let width = max(0, size.width)
        let height = max(0, size.height)
        let below = anchor.minY - gap - height
        let above = anchor.maxY + gap
        let y: CGFloat
        if below >= visibleFrame.minY {
            y = below
        } else if above + height <= visibleFrame.maxY {
            y = above
        } else {
            y = visibleFrame.minY
        }
        return CGRect(x: anchor.minX, y: y, width: width, height: height)
    }

    /// Whether the card hangs below the trigger.
    static func opensBelow(anchor: CGRect, size: CGSize, visibleFrame: CGRect) -> Bool {
        anchor.minY - gap - max(0, size.height) >= visibleFrame.minY
    }
}

// MARK: - Keyboard

/// What the open list does with the keyboard.
///
/// The list never becomes the key window - the settings window keeps the keys,
/// and a local monitor hands them here - so this is the whole keyboard model of
/// a menu: a highlight that moves without wrapping, Return or Space to commit,
/// and type-select that finds the first row starting with what was typed.
struct DotSelectKeyboardModel: Equatable {
    /// The titles the rows draw, in order.
    let titles: [String]
    /// The highlighted row, if the list has one.
    private(set) var highlight: Int?
    /// The letters typed since the last pause.
    private(set) var prefix = ""
    /// When the last letter arrived, on the event clock.
    private(set) var prefixAt: TimeInterval = 0
    /// How long a typed prefix lives.
    static let typeReset: TimeInterval = 1

    /// Creates the model with the selected row highlighted.
    ///
    /// A list whose selection matches no row highlights its first row, which is
    /// where a list with no selected row starts.
    init(titles: [String], selected: Int?) {
        self.titles = titles
        if let selected, titles.indices.contains(selected) {
            highlight = selected
        } else {
            highlight = titles.isEmpty ? nil : 0
        }
    }

    /// Moves the highlight one row, stopping at the ends.
    mutating func move(by step: Int) {
        guard !titles.isEmpty, step != 0 else { return }
        guard let current = highlight else {
            highlight = step > 0 ? 0 : titles.count - 1
            return
        }
        highlight = min(max(current + step, 0), titles.count - 1)
    }

    /// Highlights a row the pointer named.
    mutating func highlightRow(_ index: Int?) {
        guard let index, titles.indices.contains(index) else { return }
        highlight = index
    }

    /// Extends the typed prefix and jumps to the first row it matches.
    ///
    /// - Parameters:
    ///   - characters: the characters of one key press.
    ///   - time: the event clock, in seconds.
    /// - Returns: whether the highlight moved.
    @discardableResult
    mutating func type(_ characters: String, at time: TimeInterval) -> Bool {
        guard let character = characters.first, !character.isWhitespace else { return false }
        let continues = !prefix.isEmpty && time - prefixAt <= Self.typeReset
        prefix = continues ? prefix + String(character) : String(character)
        prefixAt = time
        let needle = prefix.lowercased()
        guard let match = titles.firstIndex(where: { $0.lowercased().hasPrefix(needle) }) else {
            return false
        }
        highlight = match
        return true
    }

    /// The row Return or Space would commit.
    var commitIndex: Int? {
        guard let highlight, titles.indices.contains(highlight) else { return nil }
        return highlight
    }
}

// MARK: - Monitoring

/// How the open list watches the app's events.
///
/// The list is deliberately not the key window: the settings window keeps the
/// keys, and a local monitor sees every event before it is dispatched, which is
/// what lets the list take Up, Down and Escape without a focus change. The seam
/// exists for a test that counts what was installed against what was removed.
@MainActor
struct DotSelectMonitorRegistrar {
    var add: (NSEvent.EventTypeMask, @escaping (NSEvent) -> NSEvent?) -> Any?
    var remove: (Any) -> Void

    static let live = DotSelectMonitorRegistrar(
        add: { mask, handler in
            NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
        },
        remove: { token in
            NSEvent.removeMonitor(token)
        }
    )
}

/// How the open list watches the windows and the space around it.
///
/// A notification observer is not an event monitor, but it is removed on close
/// for the same reason and counted the same way.
@MainActor
struct DotSelectObserverRegistrar {
    var add: (NSNotification.Name, @escaping @Sendable @MainActor () -> Void) -> Any?
    var remove: (Any) -> Void

    static func live(centre: NotificationCenter, workspace: NSWorkspace) -> DotSelectObserverRegistrar {
        DotSelectObserverRegistrar(
            add: { name, handler in
                centre.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { handler() }
                }
            },
            remove: { token in
                guard let token = token as? NSObjectProtocol else { return }
                centre.removeObserver(token)
            }
        )
    }
}

/// One open list: what the keyboard does and what the app watches.
///
/// Nothing here draws or places anything, and nothing here knows what a screen
/// is, so every close path can be driven by a test with synthetic events: the
/// counters are the proof that no monitor outlives its list.
@MainActor
final class DotSelectSession {
    /// What ended the session.
    enum Dismissal: Equatable {
        case escape
        case outsideClick
        case parentResignedKey
        case spaceChanged
        case commit
        case closed
    }

    /// What the session asks its owner to do.
    enum Event: Equatable {
        case highlightChanged(Int?)
        case commit(Int)
        case dismiss(Dismissal)
    }

    /// The key codes the model reads by number, because AppKit names none of
    /// them and `specialKey` leaves them out.
    enum KeyCode {
        static let escape: UInt16 = 53
        static let space: UInt16 = 49
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    private(set) var keyboard: DotSelectKeyboardModel
    /// The number of monitors and observers installed.
    private(set) var monitorsAdded = 0
    /// The number of monitors and observers removed, which must reach the first
    /// number on every close path.
    private(set) var monitorsRemoved = 0

    private let registrar: DotSelectMonitorRegistrar
    private let observers: DotSelectObserverRegistrar
    /// The window number of the panel the list is drawn in.
    var panelNumber: () -> Int
    private var tokens: [(token: Any, remove: (Any) -> Void)] = []
    private var onEvent: (Event) -> Void = { _ in }
    private var started = false

    init(
        titles: [String],
        selected: Int?,
        registrar: DotSelectMonitorRegistrar = .live,
        observers: DotSelectObserverRegistrar? = nil,
        panelNumber: @escaping () -> Int = { 0 }
    ) {
        self.keyboard = DotSelectKeyboardModel(titles: titles, selected: selected)
        self.registrar = registrar
        self.observers = observers
            ?? DotSelectObserverRegistrar.live(centre: .default, workspace: .shared)
        self.panelNumber = panelNumber
    }

    /// Starts watching, and reports the row the list opens on.
    func start(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        started = true
        onEvent(.highlightChanged(keyboard.highlight))
        install(registrar.add([.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }, remove: registrar.remove)
        install(registrar.add([.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleMouse(event)
        }, remove: registrar.remove)
        install(observers.add(NSWindow.didResignKeyNotification) { [weak self] in
            self?.close(.parentResignedKey)
        }, remove: observers.remove)
        install(observers.add(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            self?.close(.spaceChanged)
        }, remove: observers.remove)
    }

    /// Removes every monitor. A second call removes nothing.
    func stop() {
        guard started else { return }
        for entry in tokens {
            entry.remove(entry.token)
            monitorsRemoved += 1
        }
        tokens.removeAll()
        started = false
    }

    /// The row the pointer named, highlighted.
    func hover(_ index: Int?) {
        keyboard.highlightRow(index)
        onEvent(.highlightChanged(keyboard.highlight))
    }

    /// Hands a key press to the list's model.
    ///
    /// - Returns: `nil` when the list used the key, so it never reaches the
    ///   window behind the list.
    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown else { return event }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return event
        }
        switch Self.command(for: event) {
        case .up:
            keyboard.move(by: -1)
            report()
            return nil
        case .down:
            keyboard.move(by: 1)
            report()
            return nil
        case .commit:
            commit()
            return nil
        case .escape:
            close(.escape)
            return nil
        case nil:
            break
        }
        let characters = event.charactersIgnoringModifiers ?? ""
        guard !characters.isEmpty, characters != "\t" else { return event }
        if keyboard.type(characters, at: event.timestamp) {
            report()
        }
        return nil
    }

    /// What a key press means to a list.
    enum Command: Equatable {
        case up
        case down
        case commit
        case escape
    }

    /// Reads a key by its name where AppKit names it and by its code where it
    /// does not: Return, Space and Escape have no `specialKey`.
    static func command(for event: NSEvent) -> Command? {
        switch event.specialKey {
        case .upArrow:
            return .up
        case .downArrow:
            return .down
        case .carriageReturn, .enter, .newline:
            return .commit
        default:
            break
        }
        switch event.keyCode {
        case KeyCode.upArrow:
            return .up
        case KeyCode.downArrow:
            return .down
        case KeyCode.returnKey, KeyCode.keypadEnter, KeyCode.space:
            return .commit
        case KeyCode.escape:
            return .escape
        default:
            return nil
        }
    }

    private func report() {
        onEvent(.highlightChanged(keyboard.highlight))
    }

    /// Hands a pointer press to the list.
    ///
    /// A press inside the list is the panel's own business. A press anywhere
    /// else dismisses the list and is then delivered to whatever it landed on,
    /// so one click both closes the list and acts on the window behind it.
    func handleMouse(_ event: NSEvent) -> NSEvent? {
        guard event.windowNumber != panelNumber() else { return event }
        close(.outsideClick)
        return event
    }

    /// Ends the session, whatever ended it.
    func close(_ dismissal: Dismissal) {
        stop()
        onEvent(.dismiss(dismissal))
    }

    private func commit() {
        guard let index = keyboard.commitIndex else { return }
        onEvent(.commit(index))
    }

    private func install(_ token: Any?, remove: @escaping (Any) -> Void) {
        guard let token else { return }
        tokens.append((token, remove))
        monitorsAdded += 1
    }
}

// MARK: - Controller

/// The one open list in the app.
///
/// A menu is a mode: while one list is open the rest of the app is answering it,
/// so a second list closes the first. The panel exists only while the list is
/// open - it is built on the first call and released when the list closes - and
/// the controller keeps the session that owns the monitors, so every close path
/// ends in the same place.
@MainActor
final class DotSelectListController {
    static let shared = DotSelectListController()

    private(set) var panel: DotSelectPanel?
    private(set) var session: DotSelectSession?
    /// Builds the session that watches the app while a list is open.
    var makeSession: ([String], Int?, @escaping () -> Int) -> DotSelectSession = { titles, selected, number in
        DotSelectSession(titles: titles, selected: selected, panelNumber: number)
    }
    private(set) var model: DotSelectListModel?
    private var anchorFrame: NSRect = .zero
    private var onSelect: ((Int) -> Void)?
    private var onClose: (() -> Void)?
    private var suppressNextOpening = false

    /// Whether a list is open.
    var isShowing: Bool { panel != nil }

    /// Whether the opening about to happen belongs to a click that closed the
    /// list, which must not reopen it in the same click.
    func takeSuppressedOpening() -> Bool {
        defer { suppressNextOpening = false }
        return suppressNextOpening
    }

    /// Opens the list under a trigger.
    ///
    /// - Parameters:
    ///   - anchor: the trigger's frame recorder, which names the window and the
    ///     place on screen.
    ///   - rows: what the list offers.
    ///   - selectedIndex: the row to open on.
    ///   - title: the accessibility label of the list.
    ///   - scheme: the appearance the trigger is drawn in.
    ///   - onSelect: called with the committed row.
    ///   - onClose: called whenever the list closes, whatever closed it.
    /// - Returns: whether the list opened.
    @discardableResult
    func present(
        anchor: DotSelectAnchor,
        rows: [DotSelectRow],
        selectedIndex: Int?,
        title: String,
        scheme: ColorScheme,
        onSelect: @escaping (Int) -> Void,
        onClose: @escaping () -> Void
    ) -> Bool {
        close()
        guard let parent = anchor.window, !rows.isEmpty else { return false }
        let trigger = anchor.screenFrame
        guard trigger.width > 0, trigger.height > 0 else { return false }
        guard let screen = Self.screen(for: trigger, of: parent) else { return false }
        let visible = screen.visibleFrame
        let heights = rows.map { DotSelectPlacement.rowHeight(detail: $0.detail) }
        let size = DotSelectPlacement.size(
            triggerWidth: trigger.width,
            widestRow: DotSelectListMetrics.widestRow(rows),
            rowHeights: heights
        )
        let card = DotSelectPlacement.frame(anchor: trigger, size: size, visibleFrame: visible)
        let opensBelow = DotSelectPlacement.opensBelow(anchor: trigger, size: size, visibleFrame: visible)

        let model = DotSelectListModel(highlight: selectedIndex)
        let host = DotSelectListHost(
            rows: rows,
            title: title,
            selectedIndex: selectedIndex,
            model: model,
            cardSize: card.size,
            scaleAnchor: opensBelow ? .top : .bottom,
            scheme: scheme,
            onHighlight: { [weak self] index in self?.session?.hover(index) },
            onChoose: { [weak self] index in self?.commit(index) }
        )
        let panel = DotSelectPanel(
            cardFrame: card,
            shadowInset: DotSelectPlacement.shadowInset,
            host: host,
            appearance: parent.effectiveAppearance
        )
        self.anchorFrame = trigger
        self.model = model
        self.panel = panel
        beginSession(
            titles: rows.map(\.title),
            selected: selectedIndex,
            panelNumber: { panel.windowNumber },
            onSelect: onSelect,
            onClose: onClose
        )

        parent.addChildWindow(panel, ordered: .above)
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        model.isPresented = true
        return true
    }

    /// Installs the session that owns the monitors for one open list.
    ///
    /// It is separate from the window so the close paths can be driven without
    /// one: a session with a stub registrar is what a test counts.
    @discardableResult
    func beginSession(
        titles: [String],
        selected: Int?,
        panelNumber: @escaping () -> Int,
        onSelect: @escaping (Int) -> Void,
        onClose: @escaping () -> Void
    ) -> DotSelectSession {
        session?.stop()
        let session = makeSession(titles, selected, panelNumber)
        self.onSelect = onSelect
        self.onClose = onClose
        self.session = session
        session.start { [weak self] event in
            self?.receive(event)
        }
        return session
    }

    /// Closes the list, if one is open.
    func close() {
        session?.stop()
        session = nil
        model?.isPresented = false
        model = nil
        onSelect = nil
        let closing = panel
        panel = nil
        let finished = onClose
        onClose = nil
        finished?()
        guard let closing else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            closing.animator().alphaValue = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            closing.parent?.removeChildWindow(closing)
            closing.orderOut(nil)
        }
    }

    private func commit(_ index: Int) {
        let choose = onSelect
        close()
        choose?(index)
    }

    private func receive(_ event: DotSelectSession.Event) {
        switch event {
        case .highlightChanged(let row):
            model?.highlight = row
        case .commit(let row):
            commit(row)
        case .dismiss(let reason):
            if reason == .outsideClick, anchorFrame.contains(NSEvent.mouseLocation) {
                suppressNextOpening = true
            }
            close()
        }
    }

    /// The screen a trigger sits on, falling back to the window's own screen.
    private static func screen(for trigger: NSRect, of window: NSWindow) -> NSScreen? {
        let screens = NSScreen.screens
        let centre = CGPoint(x: trigger.midX, y: trigger.midY)
        let fallback = window.screen.flatMap { screens.firstIndex(of: $0) }
        guard let index = HUDPlacement.screenIndex(
            containing: centre,
            frames: screens.map(\.frame),
            fallback: fallback
        ) else {
            return window.screen ?? NSScreen.main
        }
        return screens.indices.contains(index) ? screens[index] : (NSScreen.main ?? screens.first)
    }
}

/// The state the open list's rows are drawn from.
@MainActor
final class DotSelectListModel: ObservableObject {
    /// The row under the pointer or under the arrow keys.
    @Published var highlight: Int?
    /// Whether the open animation has started.
    @Published var isPresented = false

    init(highlight: Int?) {
        self.highlight = highlight
    }
}

/// The list's own window.
///
/// A borderless child panel, so the list is never clipped by the window it
/// belongs to and travels with it. It never becomes key: the settings window
/// keeps the focus and the keyboard is handed to the list by a monitor.
@MainActor
final class DotSelectPanel: NSPanel {
    init(
        cardFrame: NSRect,
        shadowInset: CGFloat,
        host: DotSelectListHost,
        appearance: NSAppearance?
    ) {
        let windowFrame = cardFrame.insetBy(dx: -shadowInset, dy: -shadowInset)
        super.init(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = true
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        self.appearance = appearance
        let hosting = DotSelectHostingView(rootView: host)
        hosting.frame = NSRect(origin: .zero, size: windowFrame.size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A hosting view that takes the first click.
///
/// The panel is never the key window, so without this the first click on a row
/// would only bring the list forward and be swallowed: one click must both pick
/// a row and close the list.
final class DotSelectHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

// MARK: - Drawing

/// The numbers a row is drawn with, and the width the list needs.
@MainActor
enum DotSelectListMetrics {
    static let checkColumn: CGFloat = 14
    /// The air between the check column and whatever follows it, on every row.
    static let checkGap: CGFloat = 6
    static let rowPadding: CGFloat = 8
    static let symbolColumn: CGFloat = 16
    static let symbolGap: CGFloat = 8
    /// The air a row keeps after its longest word.
    static let trailingGap: CGFloat = 8

    /// Whether any row of a list carries a symbol, which gives every row the
    /// same symbol column so a list's titles start at one place.
    static func reservesSymbolColumn(_ rows: [DotSelectRow]) -> Bool {
        rows.contains { $0.symbol != nil }
    }

    /// The width the widest of the rows needs.
    ///
    /// The rows are laid out by SwiftUI and asked how wide they want to be,
    /// rather than measured with a font: `NSString` and SwiftUI disagree by a
    /// few points on the same string, and a card sized by the smaller number
    /// truncates the longest title in the list. The result excludes the card's
    /// own inset, which the placement adds.
    static func widestRow(_ rows: [DotSelectRow]) -> CGFloat {
        let symbols = reservesSymbolColumn(rows)
        let stack = VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                DotSelectListRow(
                    row: row,
                    isSelected: false,
                    isHighlighted: false,
                    reservesSymbol: symbols
                )
            }
        }
        let hosting = NSHostingView(rootView: stack)
        hosting.layoutSubtreeIfNeeded()
        return ceil(hosting.fittingSize.width) + trailingGap
    }
}

/// The panel's content: the card, the appearance it was opened in and the two
/// answers of the motion.
struct DotSelectListHost: View {
    let rows: [DotSelectRow]
    let title: String
    let selectedIndex: Int?
    @ObservedObject var model: DotSelectListModel
    let cardSize: CGSize
    let scaleAnchor: UnitPoint
    let scheme: ColorScheme
    let onHighlight: (Int?) -> Void
    let onChoose: (Int) -> Void

    private var scale: CGFloat {
        if model.isPresented || DotMotion.reducesMotion { return 1 }
        return 0.97
    }

    private var windowSize: CGSize {
        CGSize(
            width: cardSize.width + 2 * DotSelectPlacement.shadowInset,
            height: cardSize.height + 2 * DotSelectPlacement.shadowInset
        )
    }

    var body: some View {
        DotSelectListCard(
            rows: rows,
            selectedIndex: selectedIndex,
            highlight: model.highlight,
            size: cardSize,
            onHighlight: onHighlight,
            onChoose: onChoose
        )
        .scaleEffect(scale, anchor: scaleAnchor)
        .frame(width: windowSize.width, height: windowSize.height)
        .animation(
            DotMotion.reducesMotion ? nil : .easeOut(duration: 0.14),
            value: model.isPresented
        )
        .environment(\.colorScheme, scheme)
        .accessibilityLabel(title)
    }
}

/// The floating list: paper under the card's fill, one edge and a soft seat.
///
/// The two fills are stacked rather than one: the card's fill is translucent by
/// design, and a list floats over the desktop, so what is behind it cannot show
/// through. The second fill is the card's own colour at the opacity the card
/// uses, over the window's paper.
struct DotSelectListCard: View {
    let rows: [DotSelectRow]
    let selectedIndex: Int?
    let highlight: Int?
    let size: CGSize
    let onHighlight: (Int?) -> Void
    let onChoose: (Int) -> Void

    private var corner: CGFloat { 10 }

    private var symbols: Bool {
        DotSelectListMetrics.reservesSymbolColumn(rows)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        DotSelectListRow(
                            row: row,
                            isSelected: index == selectedIndex,
                            isHighlighted: index == highlight,
                            reservesSymbol: symbols
                        )
                        .id(index)
                        .onHover { inside in
                            if inside { onHighlight(index) }
                        }
                        .onTapGesture {
                            onChoose(index)
                        }
                    }
                }
                .padding(DotSelectPlacement.inset)
            }
            .onAppear {
                guard let highlight else { return }
                proxy.scrollTo(highlight, anchor: .center)
            }
            .onChange(of: highlight) { _, row in
                guard let row else { return }
                proxy.scrollTo(row, anchor: .center)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(DotTheme.paper)
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(DotTheme.cardFill)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(DotTheme.cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// One row: a check for the chosen row, a symbol, and the words.
struct DotSelectListRow: View {
    let row: DotSelectRow
    let isSelected: Bool
    let isHighlighted: Bool
    /// Whether the list draws a symbol column on every row, so the titles of a
    /// list that mixes rows with and without a symbol still start at one place.
    let reservesSymbol: Bool

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DotTheme.selectionFill)
                }
            }
            .frame(width: DotSelectListMetrics.checkColumn)
            .padding(.trailing, DotSelectListMetrics.checkGap)
            if reservesSymbol {
                symbolView
                    .frame(width: DotSelectListMetrics.symbolColumn, alignment: .leading)
                    .padding(.trailing, DotSelectListMetrics.symbolGap)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(DotSelectMetrics.titleFont)
                    .foregroundStyle(DotTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(DotTheme.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, DotSelectListMetrics.rowPadding)
        .frame(height: DotSelectPlacement.rowHeight(detail: row.detail))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted ? DotTheme.accentSoft : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.title)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    @ViewBuilder
    private var symbolView: some View {
        if let symbol = row.symbol {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(DotTheme.ink2)
        } else {
            Color.clear
        }
    }
}
