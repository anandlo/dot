import AppKit
import DotCore
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
    /// The inset the card gives its rows, which is also how far the highlight
    /// sits from the card's edge.
    static let inset: CGFloat = 4
    /// The part of a row the card shows past the last whole one, so a list that
    /// scrolls ends on a cut row rather than on a flat edge.
    ///
    /// Twenty-two points is the row's own title line and not a pixel of its
    /// detail: a card cut lower would slice the next row's letters in half, and
    /// a card cut at the title's baseline shows a word that can be read rather
    /// than a band of grey shapes. The height stays inside ``maxHeight`` because
    /// the row that would have crossed it is not counted at all.
    static let hint: CGFloat = 22
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
        let trigger = triggerWidth.isFinite ? max(0, triggerWidth) : 0
        let row = widestRow.isFinite ? max(0, widestRow) : 0
        return CGSize(
            width: min(maxWidth, max(trigger, row + 2 * inset)),
            height: height(rowHeights)
        )
    }

    /// The drawn height of a card: every row, or as many whole rows as fit with
    /// half of the next one showing.
    ///
    /// A card cut exactly at its last whole row reads as the end of the list;
    /// half a row under it reads as more below, which is what the list has.
    static func height(_ rowHeights: [CGFloat]) -> CGFloat {
        let rows = rowHeights.reduce(0) { $0 + max(0, $1) }
        let room = maxHeight - 2 * inset
        guard rows > room else { return max(0, rows + 2 * inset) }
        var used: CGFloat = 0
        for row in rowHeights {
            let height = max(0, row)
            if used + height > room - hint { break }
            used += height
        }
        return used + hint + 2 * inset
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
        let room = max(0, visibleFrame.width - width)
        let x = min(max(anchor.minX, visibleFrame.minX), visibleFrame.minX + room)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Whether the card hangs below the trigger.
    static func opensBelow(anchor: CGRect, size: CGSize, visibleFrame: CGRect) -> Bool {
        anchor.minY - gap - max(0, size.height) >= visibleFrame.minY
    }

    /// The scroll offset, in list content coordinates, that shows a row when the
    /// card opens.
    ///
    /// The offset is arithmetic rather than a request to a scroll view, so the
    /// list can be placed before its first frame is drawn and nothing moves once
    /// the card appears. A middle row sits in the middle of the card; the first
    /// row opens flush with the top and the last row flush with the foot, because
    /// the list cannot travel past either end.
    ///
    /// - Parameters:
    ///   - rowHeights: the height of every row, in order.
    ///   - selected: the row the list opens on.
    ///   - viewport: the height the card draws the rows through.
    /// - Returns: the clip view's origin for the open, in points from the top of
    ///   the rows.
    static func openOffset(rowHeights: [CGFloat], selected: Int?, viewport: CGFloat) -> CGFloat {
        guard let selected, rowHeights.indices.contains(selected), viewport > 0 else { return 0 }
        let heights = rowHeights.map { max(0, $0) }
        let content = heights.reduce(0, +) + 2 * inset
        let limit = max(0, content - viewport)
        let top = heights.prefix(selected).reduce(0, +) + inset
        let centred = top + heights[selected] / 2 - viewport / 2
        return min(max(centred, 0), limit)
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
        case appDeactivated
        case scrolled
        case parentChanged
        case commit
        case closed
    }

    /// What the session asks its owner to do.
    enum Event: Equatable {
        case highlightChanged(Int?, scrolls: Bool)
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
    /// The number of monitors and observers one session installs.
    ///
    /// A test counts what a session added against this number, so a new watch
    /// cannot be forgotten by the tests that prove nothing outlives a list.
    static let watchCount = 6
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
    /// Called when a wheel belongs to the list, before the list scrolls.
    var onListScroll: () -> Void = {}

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
        onEvent(.highlightChanged(keyboard.highlight, scrolls: true))
        install(registrar.add([.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }, remove: registrar.remove)
        install(registrar.add([.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleMouse(event)
        }, remove: registrar.remove)
        install(registrar.add([.scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return self.handleScroll(event)
        }, remove: registrar.remove)
        install(observers.add(NSWindow.didResignKeyNotification) { [weak self] in
            self?.close(.parentResignedKey)
        }, remove: observers.remove)
        install(observers.add(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            self?.close(.spaceChanged)
        }, remove: observers.remove)
        install(observers.add(NSApplication.didResignActiveNotification) { [weak self] in
            self?.close(.appDeactivated)
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

    /// Whether a hover is taken, which the card's growth turns off.
    var hoverAllowed: () -> Bool = { true }

    /// The row the pointer named, highlighted.
    ///
    /// A hover that arrives while the card grows is dropped before it moves
    /// anything: the row under the pointer is read once, when the growth ends.
    func hover(_ index: Int?) {
        guard hoverAllowed() else { return }
        keyboard.highlightRow(index)
        onEvent(.highlightChanged(keyboard.highlight, scrolls: false))
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

    /// The highlight moved by a key, which is the only highlight the list
    /// scrolls to.
    /// A wheel over the page dismisses the list and is then delivered, so the
    /// one gesture both ends the list and scrolls the page the user aimed at.
    /// A wheel over the list belongs to the list.
    func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard shouldCloseForScroll(windowNumber: event.windowNumber) else {
            onListScroll()
            return event
        }
        close(.scrolled)
        return event
    }

    /// Whether a wheel belongs to the page rather than to the list.
    ///
    /// The window number of a wheel is the window under the pointer, so a wheel
    /// over the list names the list and one over the page names the page.
    func shouldCloseForScroll(windowNumber: Int) -> Bool {
        windowNumber != panelNumber()
    }

    private func report() {
        onEvent(.highlightChanged(keyboard.highlight, scrolls: true))
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

/// How long a chosen row stays lit before the list goes.
///
/// A list that vanishes on the click reads as a missed click; the row holds for
/// a moment, then the card fades. Reduce Motion skips both.
struct DotSelectCommitTimeline: Equatable {
    let hold: TimeInterval
    let fade: TimeInterval

    init(reducesMotion: Bool) {
        hold = reducesMotion ? 0 : 0.07
        fade = reducesMotion ? 0 : 0.09
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
    private weak var anchor: DotSelectAnchor?
    private var dismissalObservers: [NSObjectProtocol] = []
    /// Where a list believes the screen is.
    ///
    /// The default asks AppKit for the display the trigger is on. A test hands
    /// in a synthetic rect so no test needs a window on the Mac it runs on.
    var screenProvider: (NSRect, NSWindow) -> (frame: NSRect, visible: NSRect)? = defaultScreenProvider

    static let defaultScreenProvider: (NSRect, NSWindow) -> (frame: NSRect, visible: NSRect)? = { trigger, window in
        guard let screen = screen(for: trigger, of: window) else { return nil }
        return (screen.frame, screen.visibleFrame)
    }

    /// The one window a list is drawn in.
    private var reusedPanel: DotSelectPanel = .init()
    /// Counts the opens, so a reopened list is drawn from the top.
    private var generation = 0
    /// The close a chosen row asked for, which fires after the row has held.
    private var commitTask: Task<Void, Never>?
    /// Where the page's clip view was scrolled to when the list opened, and what
    /// it said about posting bounds changes before the list asked for them.
    private var watchedClip: (clip: NSClipView, postsBoundsChanges: Bool, origin: NSPoint)?

    /// Whether a list is open.
    var isShowing: Bool { panel != nil }

    /// Whether the opening about to happen belongs to a click that closed the
    /// list, which must not reopen it in the same click.
    func takeSuppressedOpening() -> Bool {
        defer { suppressNextOpening = false }
        return suppressNextOpening
    }

    /// Whether a dismissal was the first half of a click on the trigger.
    ///
    /// A click on the trigger is outside the list, so it closes the list; the
    /// same click then reaches the trigger, whose press would open the list
    /// again. The click that closed it must not open it.
    ///
    /// - Parameters:
    ///   - dismissal: what ended the list.
    ///   - click: where the pointer was, in screen coordinates.
    ///   - anchor: the trigger's frame on screen.
    static func suppressesNextOpening(
        dismissal: DotSelectSession.Dismissal,
        click: CGPoint,
        anchor: NSRect
    ) -> Bool {
        dismissal == .outsideClick && anchor.contains(click)
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
        guard let screen = screenProvider(trigger, parent) else { return false }
        let visible = screen.visible
        let heights = rows.map { DotSelectPlacement.rowHeight(detail: $0.detail) }
        let size = DotSelectPlacement.size(
            triggerWidth: trigger.width,
            widestRow: DotSelectListMetrics.widestRow(rows),
            rowHeights: heights
        )
        let card = DotSelectPlacement.frame(anchor: trigger, size: size, visibleFrame: visible)
        let opensBelow = DotSelectPlacement.opensBelow(anchor: trigger, size: size, visibleFrame: visible)

        generation &+= 1
        let openGeneration = generation
        let model = DotSelectListModel(highlight: selectedIndex)
        let host = DotSelectListHost(
            generation: generation,
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
        let panel = reusedPanel
        panel.present(
            host,
            cardFrame: card,
            appearance: parent.effectiveAppearance,
            grew: { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.hoverUnderThePointer(in: panel, rowHeights: heights)
            }
        )
        self.anchorFrame = trigger
        self.anchor = anchor
        self.model = model
        self.panel = panel
        // The session owns the hover the grown card reports. Under Reduce Motion
        // the growth finishes inside showOpening, so the session must exist first.
        beginSession(
            titles: rows.map(\.title),
            selected: selectedIndex,
            panelNumber: { panel.windowNumber },
            onSelect: onSelect,
            onClose: onClose
        )
        panel.showOpening(
            rowHeights: heights,
            selected: selectedIndex,
            scroll: model.scroll,
            growsFrom: host.scaleAnchor,
            isCurrent: { [weak self] in self?.generation == openGeneration }
        )

        watch(around: parent, anchor: anchor)
        parent.addChildWindow(panel, ordered: .above)
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DotSelectPanel.openingDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
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
        session.onListScroll = { [weak self] in self?.model?.scroll.cancelPendingEnd() }
        session.hoverAllowed = { [weak self] in self?.model?.isGrowing != true }
        self.onSelect = onSelect
        self.onClose = onClose
        self.session = session
        session.start { [weak self] event in
            self?.receive(event)
        }
        return session
    }

    /// Highlights the row the pointer rests on, once the card has grown.
    ///
    /// Hover reports that arrive while the card grows are dropped, so the row under
    /// a pointer that has not moved since the open is read here, once.
    private func hoverUnderThePointer(in panel: DotSelectPanel, rowHeights: [CGFloat]) {
        let row = panel.row(
            underPointerAt: DotSelectPanel.pointerLocation(),
            rowHeights: rowHeights
        )
        session?.hover(row)
    }

    /// Closes the list, if one is open.
    ///
    /// Every close is synchronous: the child window is unhooked and closed here
    /// rather than a tenth of a second later, because a window that lingers in
    /// the app's window list outlives the list it belonged to.
    func close() {
        // A close is a newer generation: a retry left by the open it ends must
        // not run against a list that is no longer there.
        generation &+= 1
        commitTask?.cancel()
        commitTask = nil
        session?.stop()
        session = nil
        model?.scroll.stop()
        model = nil
        onSelect = nil
        anchor = nil
        stopWatching()
        let closing = panel
        panel = nil
        let finished = onClose
        onClose = nil
        finished?()
        guard let closing else { return }
        closing.parent?.removeChildWindow(closing)
        closing.orderOut(nil)
        closing.releaseContents()
    }

    /// Ends the list whenever the window around it moves, resizes or closes, and
    /// whenever the page it hangs from scrolls.
    ///
    /// A floating list placed against a trigger cannot stay correct through any
    /// of those: the trigger moves and the window does not follow. Closing is
    /// what a menu does, and it keeps the list from hanging over the place the
    /// trigger used to be.
    private func watch(around parent: NSWindow, anchor: DotSelectAnchor) {
        stopWatching()
        let centre = NotificationCenter.default
        let names = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.willCloseNotification,
        ]
        for name in names {
            dismissalObservers.append(centre.addObserver(
                forName: name,
                object: parent,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
        guard let clip = anchor.hostScrollView?.contentView else { return }
        watchedClip = (clip, clip.postsBoundsChangedNotifications, clip.bounds.origin)
        clip.postsBoundsChangedNotifications = true
        dismissalObservers.append(centre.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageMoved(clip) }
        })
    }

    /// Closes the list when the page scrolled under it.
    ///
    /// A bounds *size* change is a layout pass, not a scroll: the page was laid
    /// out again and the trigger is where it was, so the list stays. Only a
    /// change of where the clip view is scrolled to moves the trigger.
    private func pageMoved(_ clip: NSClipView) {
        guard clip.bounds.origin != watchedClip?.origin else { return }
        watchedClip?.origin = clip.bounds.origin
        close()
    }

    private func stopWatching() {
        for token in dismissalObservers {
            NotificationCenter.default.removeObserver(token)
        }
        dismissalObservers.removeAll()
        if let watched = watchedClip {
            watched.clip.postsBoundsChangedNotifications = watched.postsBoundsChanges
            watchedClip = nil
        }
    }

    private func commit(_ index: Int) {
        let choose = onSelect
        onSelect = nil
        session?.stop()
        session = nil
        model?.highlight = index
        let closing = panel
        let timeline = DotSelectCommitTimeline(reducesMotion: DotMotion.reducesMotion)
        choose?(index)
        guard timeline.hold > 0 || timeline.fade > 0 else {
            close()
            return
        }
        // The row that was chosen holds for a moment before the card goes, and
        // a second list may be opened in that moment. The close belongs to the
        // open that chose the row, so it does nothing once another open has
        // happened: closing by identity would shut the new list.
        let token = generation
        commitTask?.cancel()
        commitTask = Task { @MainActor [weak self] in
            if timeline.hold > 0 {
                try? await Task.sleep(for: .seconds(timeline.hold))
            }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            if let closing, timeline.fade > 0, closing.isVisible {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = timeline.fade
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    closing.animator().alphaValue = 0
                }, completionHandler: nil)
                try? await Task.sleep(for: .seconds(timeline.fade))
            }
            guard self.generation == token else {
                closing?.alphaValue = 1
                return
            }
            closing?.alphaValue = 1
            self.close()
        }
    }

    private func receive(_ event: DotSelectSession.Event) {
        switch event {
        case .highlightChanged(let row, let scrolls):
            model?.highlight = row
            guard scrolls else { return }
            model?.scrollTarget = row
        case .commit(let row):
            commit(row)
        case .dismiss(let reason):
            if Self.suppressesNextOpening(
                dismissal: reason,
                click: NSEvent.mouseLocation,
                anchor: anchorFrame
            ) {
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
    /// The row the list has to show, which only a key or the open moves.
    ///
    /// A wheel moves the rows under a resting pointer, and every row that comes
    /// under it reports a hover; if those reports scrolled the list it would
    /// jerk against the wheel, so the pointer changes the highlight and never
    /// the scroll position.
    @Published var scrollTarget: Int?
    /// What the card knows about its own scrolling. It is a separate object so
    /// a wheel tick redraws the two fades and the scroller, not sixty rows.
    let scroll = DotSelectScrollModel()
    /// Whether the card is still growing open.
    ///
    /// A pointer over a row while the card grows is not hovering it: the rows are
    /// sliding under a pointer that has not moved, and the row it happens to cross
    /// would flash. Hover is dropped until the growth ends, and the row under the
    /// pointer is read once then.
    var isGrowing = false

    init(highlight: Int?) {
        self.highlight = highlight
        self.scrollTarget = highlight
    }
}

/// Where a list is scrolled to, and whether it is moving.
///
/// The numbers are written the moment the list is measured: the card's fade mask
/// and the placement code read them in the same pass that measured them, so they
/// cannot wait. The change SwiftUI is told about is a separate matter. The
/// measurement comes from `layout`, which runs inside SwiftUI's own update, and a
/// change published from there is the one SwiftUI reports as "Publishing changes
/// from within view updates". Publishing is deferred to the next turn of the run
/// loop and folded into a single notification, so a pass that measures and
/// scrolls twice redraws the fades and the bar once.
@MainActor
final class DotSelectScrollModel: ObservableObject {
    private(set) var offset: CGFloat = 0
    private(set) var contentHeight: CGFloat = 0
    private(set) var viewportHeight: CGFloat = 0
    /// Whether the list moved within the last ``linger`` seconds.
    private(set) var isScrolling = false

    /// An end of the list the card has to show, rather than a row to centre.
    ///
    /// The offset of an end is arithmetic on the document and the viewport, so
    /// it is exact once the list is measured; a row scrolled to an edge would
    /// leave the card's own inset showing.
    enum End: Equatable {
        case top
        case bottom
    }

    /// The end the card has to show, kept until the card can place it.
    ///
    /// The request is one shot: the reporter that measures the list takes it,
    /// and a wheel that follows moves the list without being pulled back.
    private(set) var pendingEnd: End?

    /// The view that measures the card.
    ///
    /// An end can arrive after the list was measured, when no layout or bounds
    /// change would wake the reporter.
    weak var reporter: DotSelectScrollReportingView?

    /// How long the scroller stays after the last movement.
    static let linger: TimeInterval = 0.6
    private var generation = 0
    /// The publication waiting for the run loop to turn, if one is.
    private var pendingPublication: Task<Void, Never>?
    /// The countdown that takes the scroller away, if one is running.
    private var lingerTask: Task<Void, Never>?
    /// Whether the list the model was made for has closed.
    private var isStopped = false

    /// A fade is only drawn when more than its own height is hidden on that
    /// side: a list that opens within a point of its top must not show one.
    var showsTopFade: Bool { offset > DotSelectListMetrics.fade }
    var showsBottomFade: Bool {
        offset + viewportHeight < contentHeight - DotSelectListMetrics.fade
    }
    var scrolls: Bool { contentHeight > viewportHeight + 0.5 }

    /// The scroller's height and travel, in points, inside the track the card
    /// keeps for it.
    ///
    /// The track is the card less ``DotSelectListMetrics/scrollerTrackInset`` at
    /// each end, and the bar is measured against that track rather than against
    /// the whole card: its length is the share of the list on screen, never
    /// shorter than a fingerhold and never longer than the track, and its travel
    /// is what the track has left. The offset counts from the card's top edge,
    /// so the overlay places it without knowing the inset, and no list — however
    /// long or short — can draw the bar over the card's own corners.
    /// The track the bar travels in, or nothing when the list fits.
    ///
    /// The track is drawn whenever the list overflows, at rest as well as while
    /// it moves: a card that ends on a whole row with nothing at its edge reads
    /// as the end of the list even when four more rows are hidden, and the
    /// clipped bottom row is not a reliable cue — at some offsets it is a whole
    /// row. The track is the cue that does not depend on where the list happens
    /// to be.
    var track: (height: CGFloat, inset: CGFloat)? {
        guard scrolls, contentHeight > 0, viewportHeight > 0 else { return nil }
        let inset = DotSelectListMetrics.scrollerTrackInset
        let height = max(0, viewportHeight - 2 * inset)
        guard height > 0 else { return nil }
        return (height, inset)
    }

    var thumb: (height: CGFloat, offset: CGFloat)? {
        guard let track else { return nil }
        let inset = track.inset
        let room = track.height
        let share = min(1, viewportHeight / contentHeight)
        let height = min(room, max(24, room * share))
        let travel = max(0, room - height)
        let progress = max(0, min(1, offset / max(1, contentHeight - viewportHeight)))
        return (height, inset + travel * progress)
    }

    /// Records where the list is, and keeps the scroller up for a moment.
    func moved(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) {
        guard !isStopped else { return }
        guard offset != self.offset
            || contentHeight != self.contentHeight
            || viewportHeight != self.viewportHeight
        else { return }
        self.offset = offset
        self.contentHeight = contentHeight
        self.viewportHeight = viewportHeight
        isScrolling = true
        generation &+= 1
        let token = generation
        lingerTask?.cancel()
        lingerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.linger))
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.isScrolling = false
            self.publish()
        }
        publish()
    }

    /// Asks the card to show an end of the list.
    ///
    /// The request waits until the reporter has a document and a viewport to
    /// measure.
    func requestEnd(_ end: End) {
        guard !isStopped else { return }
        pendingEnd = end
        reporter?.publish()
    }

    /// Takes the end the card has to show, once.
    func takePendingEnd() -> End? {
        defer { pendingEnd = nil }
        return pendingEnd
    }

    /// Drops an end the card has not placed yet: a newer target owns the list.
    func cancelPendingEnd() {
        pendingEnd = nil
    }

    /// The offset that puts an end of the list against the card's edge.
    ///
    /// A list shorter than its card has one offset, zero, at both ends.
    func offset(showing end: End) -> CGFloat {
        switch end {
        case .top:
            return 0
        case .bottom:
            return max(0, contentHeight - viewportHeight)
        }
    }

    /// Ends the movement a closing list was counting down, and drops the
    /// publication it had not sent: a card that is gone has nothing to redraw,
    /// and a countdown left running would clear a flag nothing is reading.
    ///
    /// A stopped model is inert: the card is torn down by an update of its own,
    /// and a pass that measures it on the way out has nothing to report.
    func stop() {
        isStopped = true
        pendingEnd = nil
        reporter = nil
        generation &+= 1
        lingerTask?.cancel()
        lingerTask = nil
        pendingPublication?.cancel()
        pendingPublication = nil
        isScrolling = false
    }

    /// Tells SwiftUI the numbers moved, once, after the current update is over.
    ///
    /// A task started here runs when the main actor is next free, which is after
    /// the layout pass that measured the list has finished; the guard folds every
    /// measurement taken before it into the one notification.
    private func publish() {
        guard pendingPublication == nil else { return }
        pendingPublication = Task { @MainActor [weak self] in
            guard let self else { return }
            let cancelled = Task.isCancelled
            self.pendingPublication = nil
            guard !cancelled else { return }
            self.objectWillChange.send()
        }
    }
}

/// Reports where the list is scrolled to, and nothing else.
///
/// The card is a `ScrollView` and SwiftUI keeps its offset to itself, so the one
/// `NSView` inside the scrolling content watches the clip view the list ended up
/// in. It publishes numbers only: the fades and the scroller are drawn from
/// them, and no state that draws a row depends on them.
struct DotSelectScrollReporter: NSViewRepresentable {
    let scroll: DotSelectScrollModel

    func makeNSView(context: Context) -> DotSelectScrollReportingView {
        let view = DotSelectScrollReportingView()
        view.model = scroll
        scroll.reporter = view
        return view
    }

    func updateNSView(_ view: DotSelectScrollReportingView, context: Context) {
        view.model = scroll
        scroll.reporter = view
        view.publish()
    }
}

final class DotSelectScrollReportingView: NSView {
    weak var model: DotSelectScrollModel?
    private var tokens: [NSObjectProtocol] = []
    private let mask = CAGradientLayer()

    /// The scroll view the list is drawn in, once the card has been laid out.
    var listScrollView: NSScrollView? { enclosingScrollView }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            releaseObservers()
            if model?.reporter === self { model?.reporter = nil }
            return
        }
        roundTheScrollView()
        observe()
        publish()
        updateMask()
    }

    private func releaseObservers() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
    }

    override func layout() {
        super.layout()
        publish()
    }

    private func observe() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens.removeAll()
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        let names: [(Notification.Name, Any?)] = [
            (NSView.boundsDidChangeNotification, clip),
            (NSView.frameDidChangeNotification, scroll.documentView),
        ]
        for (name, object) in names {
            tokens.append(NotificationCenter.default.addObserver(
                forName: name,
                object: object,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            })
        }
    }

    /// Rounds the scroll view's own layer.
    ///
    /// A `clipShape` in SwiftUI is applied to the drawing SwiftUI owns; the
    /// scrolling content is an `NSScrollView`, so its corners are square unless
    /// the layer that holds it is told otherwise. The card's seat is a separate
    /// layer behind this one, which is what keeps its shadow unclipped.
    private func roundTheScrollView() {
        guard let scroll = enclosingScrollView else { return }
        scroll.wantsLayer = true
        guard let layer = scroll.layer else { return }
        layer.cornerRadius = DotSelectListMetrics.corner
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        scroll.contentView.wantsLayer = true
        scroll.contentView.layer?.masksToBounds = true
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        mask.frame = scroll.bounds
        if layer.mask !== mask { layer.mask = mask }
    }

    /// One mask carries the corners and the two fades: black keeps a pixel,
    /// clear drops it, so the drawing never asks what colour the card is in the
    /// appearance it was opened in.
    private func updateMask() {
        guard let scroll = enclosingScrollView, let model else { return }
        let fade = DotSelectListMetrics.fade / max(1, scroll.bounds.height)
        mask.frame = scroll.bounds
        mask.locations = [0, NSNumber(value: fade), NSNumber(value: 1 - fade), 1]
        let solid = CGColor(gray: 0, alpha: 1)
        let clear = CGColor(gray: 0, alpha: 0)
        // The first stop is the top of the list and the last is its foot: an
        // edge the list continues past dissolves into the paper behind it, and
        // an edge that is the end of the list stays solid.
        mask.colors = [
            model.showsTopFade ? clear : solid,
            solid,
            solid,
            model.showsBottomFade ? clear : solid,
        ]
    }

    func publish() {
        guard let spinner = enclosingScrollView, let model else { return }
        let contentHeight = spinner.documentView?.frame.height ?? 0
        let viewportHeight = spinner.contentView.bounds.height
        model.moved(
            offset: spinner.contentView.bounds.origin.y,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight
        )
        applyPendingEnd(in: spinner, model: model)
        updateMask()
    }

    /// Shows the end of the list the card was asked for, once the list has a
    /// document and a viewport to place it against.
    ///
    /// The request is taken before the clip view is scrolled: the scroll posts a
    /// bounds change, which measures the list again, and a request still waiting
    /// would be applied a second time on the way back.
    private func applyPendingEnd(in scroll: NSScrollView, model: DotSelectScrollModel) {
        guard model.pendingEnd != nil else { return }
        let clip = scroll.contentView
        let contentHeight = scroll.documentView?.frame.height ?? 0
        let viewportHeight = clip.bounds.height
        guard contentHeight > 0, viewportHeight > 0 else { return }
        guard let end = model.takePendingEnd() else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: model.offset(showing: end)))
        scroll.reflectScrolledClipView(clip)
        model.moved(
            offset: clip.bounds.origin.y,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight
        )
    }
}

/// The panel's content: the card, the appearance it was opened in and the two
/// answers of the motion.
struct DotSelectListHost: View {
    /// Changes on every open, so the card is rebuilt rather than inherited: a
    /// list reopened in the same window must not start where the last one was
    /// scrolled to.
    var generation = 0

    /// A list with no rows, drawn in the window between opens so the window
    /// holds nothing of the last list's rows or closures.
    static var empty: DotSelectListHost {
        DotSelectListHost(
            generation: 0,
            rows: [],
            title: "",
            selectedIndex: nil,
            model: DotSelectListModel(highlight: nil),
            cardSize: .zero,
            scaleAnchor: .top,
            scheme: .light,
            onHighlight: { _ in },
            onChoose: { _ in }
        )
    }

    let rows: [DotSelectRow]
    let title: String
    let selectedIndex: Int?
    @ObservedObject var model: DotSelectListModel
    let cardSize: CGSize
    /// The edge the card grows from when it opens: the top when it hangs below
    /// its trigger, the bottom when it opens above it.
    let scaleAnchor: UnitPoint
    let scheme: ColorScheme
    let onHighlight: (Int?) -> Void
    let onChoose: (Int) -> Void

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
            model: model,
            size: cardSize,
            onHighlight: onHighlight,
            onChoose: onChoose
        )
        .id(generation)
        .frame(width: windowSize.width, height: windowSize.height)
        .environment(\.colorScheme, scheme)
        .accessibilityLabel(title)
    }
}

/// The floating list: paper under the card's fill, one edge and a soft seat.
///
/// The card's fill is translucent by design, and a list floats over the desktop,
/// so the paper is drawn under it: what is behind the card cannot show through.
/// The seat is a shape of its own rather than a shadow on the scrolling content,
/// because a shadow around a scroll view is redrawn every time a row moves.
struct DotSelectListCard: View {
    let rows: [DotSelectRow]
    let selectedIndex: Int?
    @ObservedObject var model: DotSelectListModel
    let size: CGSize
    let onHighlight: (Int?) -> Void
    let onChoose: (Int) -> Void

    @State private var hover = DotSelectHoverGate()

    private var corner: CGFloat { DotSelectListMetrics.corner }

    private var symbols: Bool {
        DotSelectListMetrics.reservesSymbolColumn(rows)
    }

    private var highlight: Int? { model.highlight }

    var body: some View {
        ZStack {
            seat
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(DotTheme.cardFill)
            scrollingContent
                .overlay { DotSelectListOverlay(scroll: model.scroll) }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    /// The paper, the edge and the shadow: a still layer the scrolling content
    /// never invalidates.
    ///
    /// The paper is under a translucent wash because that is the tone the menu
    /// has always drawn: ``DotTheme/raisedFill`` was measured against it and is
    /// a point off on light but six, and visibly deeper, on dark, so the two
    /// layers stay until a menu-specific surface token is agreed.
    private var seat: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(DotTheme.paper)
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(DotTheme.cardBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
            .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
    }

    private var scrollingContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        let described = DotSelectRowDescription(
                            row: row,
                            isSelected: index == selectedIndex
                        )
                        Button {
                            onChoose(index)
                        } label: {
                            EmptyView()
                        }
                        .buttonStyle(DotSelectListRowStyle(
                            row: row,
                            isSelected: index == selectedIndex,
                            isHighlighted: index == highlight,
                            reservesSymbol: symbols
                        ))
                        // The button is the element VoiceOver reads, so its
                        // name and the chosen state belong to it rather
                        // than to the drawing inside it.
                        .accessibilityLabel(described.label)
                        .accessibilityValue(described.value)
                        .id(index)
                        .onHover { inside in
                            guard inside else { return }
                            let location = NSEvent.mouseLocation
                            guard hover.accept(at: location) else { return }
                            onHighlight(index)
                        }
                    }
                    DotSelectScrollReporter(scroll: model.scroll)
                        .frame(height: 0)
                }
                .padding(DotSelectPlacement.inset)
            }
            .scrollIndicators(.never)
            .onChange(of: model.scrollTarget) { _, _ in scroll(proxy) }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    /// Shows the row a key asked for.
    ///
    /// The row a list opens on is not asked for here: the panel places the list
    /// at that offset before the card is drawn, so the first frame is the final
    /// one. A key pressed while the list is open moves the rows under a reader
    /// who is already looking at them: the ends belong to the card's scroll
    /// model, which places them against the card's own edge from a measured
    /// document and viewport, and a row in the middle is centred by SwiftUI,
    /// which knows where the rows are.
    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = model.scrollTarget else { return }
        if target <= 0 {
            model.scroll.requestEnd(.top)
        } else if target >= rows.count - 1 {
            model.scroll.requestEnd(.bottom)
        } else {
            model.scroll.cancelPendingEnd()
            proxy.scrollTo(target, anchor: .center)
        }
    }

}

/// The edges and the scroller: the only part of the card that a wheel redraws.
struct DotSelectListOverlay: View {
    @ObservedObject var scroll: DotSelectScrollModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            scroller
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .clipShape(RoundedRectangle(cornerRadius: DotSelectListMetrics.corner, style: .continuous))
        .allowsHitTesting(false)
    }

    /// The track and the bar at the trailing edge.
    ///
    /// The track runs the length of the list and is drawn whenever the list
    /// overflows, at rest as well as while it moves: it is the only cue that
    /// says "there is more" at every position, because the cut row at the foot
    /// sometimes lands on a row boundary and reads as the end. The bar is the
    /// darker part and shows where the list is; it lifts while the list moves
    /// and settles to a quieter tone, never to nothing.
    @ViewBuilder
    private var scroller: some View {
        if let track = scroll.track, let thumb = scroll.thumb {
            Capsule()
                .fill(DotTheme.ink3.opacity(DotSelectListMetrics.scrollerTrackOpacity))
                .frame(width: DotSelectListMetrics.scrollerWidth, height: track.height)
                .padding(.trailing, DotSelectListMetrics.scrollerInset)
                .offset(y: track.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            Capsule()
                .fill(DotTheme.ink3.opacity(
                    scroll.isScrolling
                        ? DotSelectListMetrics.scrollerThumbActiveOpacity
                        : DotSelectListMetrics.scrollerThumbRestingOpacity
                ))
                .frame(width: DotSelectListMetrics.scrollerWidth, height: thumb.height)
                .padding(.trailing, DotSelectListMetrics.scrollerInset)
                .offset(y: thumb.offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .animation(.easeOut(duration: 0.2), value: scroll.isScrolling)
        }
    }
}

extension DotSelectListCard {
    /// Draws a card from a highlight alone, for a preview or a render.
    ///
    /// The list an open window draws shares one model with the session that
    /// moves its highlight; a still picture has no session, so it makes one.
    init(
        rows: [DotSelectRow],
        selectedIndex: Int?,
        highlight: Int?,
        size: CGSize,
        onHighlight: @escaping (Int?) -> Void,
        onChoose: @escaping (Int) -> Void
    ) {
        self.init(
            rows: rows,
            selectedIndex: selectedIndex,
            model: DotSelectListModel(highlight: highlight),
            size: size,
            onHighlight: onHighlight,
            onChoose: onChoose
        )
    }
}

/// The row as a button, so a press is drawn while the mouse is down and the
/// click still chooses the row.
///
/// A drag gesture of no distance draws the press and swallows the tap; a button
/// is the control that has both.
struct DotSelectListRowStyle: ButtonStyle {
    let row: DotSelectRow
    let isSelected: Bool
    let isHighlighted: Bool
    let reservesSymbol: Bool

    func makeBody(configuration: Configuration) -> some View {
        DotSelectListRow(
            row: row,
            isSelected: isSelected,
            isHighlighted: isHighlighted,
            isPressed: configuration.isPressed,
            reservesSymbol: reservesSymbol
        )
    }
}

/// One row: a check for the chosen row, a symbol, and the words.
struct DotSelectListRow: View {
    let row: DotSelectRow
    let isSelected: Bool
    let isHighlighted: Bool
    var isPressed = false
    /// Whether the list draws a symbol column on every row, so the titles of a
    /// list that mixes rows with and without a symbol still start at one place.
    let reservesSymbol: Bool

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(DotType.font(11, .semibold))
                        .foregroundStyle(DotTheme.ink)
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
                        .font(DotType.font(11, .regular))
                        .foregroundStyle(DotTheme.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, DotSelectListMetrics.rowPadding)
        .frame(height: DotSelectPlacement.rowHeight(detail: row.detail))
        .background(
            RoundedRectangle(cornerRadius: DotSelectListMetrics.rowCorner, style: .continuous)
                .fill(fill)
        )
        .contentShape(Rectangle())
    }

    private var fill: Color {
        if isPressed { return DotTheme.menuRowPressed }
        if isHighlighted { return DotTheme.menuRowHighlight }
        return .clear
    }

    @ViewBuilder
    private var symbolView: some View {
        if let symbol = row.symbol {
            Image(systemName: symbol)
                .font(DotType.font(13, .regular))
                .foregroundStyle(DotTheme.ink2)
        } else {
            Color.clear
        }
    }
}

/// What VoiceOver reads for a row of a list.
///
/// A row is a button, and the button is the element that is read: the drawing
/// inside it is ignored. The name of the row and the fact that it is the list's
/// chosen row therefore belong to the button, and the two strings are decided
/// here so they can be checked without a window.
struct DotSelectRowDescription: Equatable {
    let label: String
    let value: String

    init(row: DotSelectRow, isSelected: Bool) {
        label = row.title
        value = isSelected ? "Selected" : ""
    }
}

/// Whether a hover report came from a pointer that actually moved.
///
/// A row reports a hover when it arrives under the pointer, and a scroll moves
/// rows under a pointer that has not moved at all. Rejecting a report from the
/// place the last one came from keeps a wheel from changing the highlight.
struct DotSelectHoverGate {
    private var location: CGPoint?

    mutating func accept(at location: CGPoint) -> Bool {
        guard self.location != location else { return false }
        self.location = location
        return true
    }
}

// MARK: - Diagnosis

/// What the open list says when it cannot do its job.
///
/// A card that is asked for a row it has no scroll view for is a defect in the
/// open rather than a thing that happens per click, so it is reported once: one
/// line names the event, and a line per open would bury it.
@MainActor
enum DotSelectLog {
    /// The event written when the card has no scroll view to place the list in.
    static let missingList = "select.open.noscroll"
    /// Whether the event has been written. A test clears it to read the line.
    static var reportedMissingList = false
    /// Where a line goes. A test replaces this to read what the list said.
    static var write: (String) -> Void = { Log.shared.warn($0) }

    static func reportMissingList() {
        guard !reportedMissingList else { return }
        reportedMissingList = true
        write(missingList)
    }
}

// MARK: - The window

/// The list's own window.
///
/// A borderless child panel, so the list is never clipped by the window it
/// belongs to and travels with it. It never becomes key: the settings window
/// keeps the focus and the keyboard is handed to the list by a monitor.
///
/// One panel serves every list in the app. A window built per open is a hosting
/// view and a window-server registration per click, and a window that is only
/// ordered out is not the same as a window that is gone: five opens used to
/// leave five windows in the app's window list.
@MainActor
final class DotSelectPanel: NSPanel {
    /// The scale the card grows from when it opens.
    static let openingScale: CGFloat = 0.97
    /// How long the card takes to grow and to fade in.
    static let openingDuration: TimeInterval = 0.14
    /// The key the growth is animated under.
    private static let growthKey = "openingScale"
    /// Where the pointer is on screen. A test places it without moving the Mac's
    /// own cursor.
    static var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    /// Whether the next open is treated as one whose card has not been built.
    /// A test sets it to drive the retry through the controller; the app never
    /// writes it.
    static var skipsFirstPlacement = false
    /// How many retries have got past the open's identity check. A test reads it
    /// to show that a closed open's retry was dropped before it touched a list.
    static var retriesPastTheCheck = 0

    /// The list the panel is drawing, which names its scroll view.
    private weak var presentedModel: DotSelectListModel?
    /// The work that follows the growth, kept until it has run.
    private var growthFinished: (() -> Void)?
    /// The countdown that ends the growth, if one is running.
    private var growthTask: Task<Void, Never>?

    /// The room the card's shadow needs inside the window.
    let shadowInset: CGFloat
    /// The content, replaced on every open.
    private let hosting: DotSelectHostingView<DotSelectListHost>

    init(shadowInset: CGFloat = DotSelectPlacement.shadowInset) {
        self.shadowInset = shadowInset
        hosting = DotSelectHostingView(rootView: .empty)
        super.init(
            contentRect: NSRect(origin: .zero, size: .zero),
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
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        contentView = hosting
    }

    /// Puts a list in the window and records what follows its growth.
    ///
    /// - Parameters:
    ///   - host: the content of the list.
    ///   - cardFrame: where the card goes, in screen coordinates.
    ///   - appearance: the appearance the window is drawn in.
    ///   - grew: called once the card has reached its own size, or at once when
    ///     there is no growth to watch.
    func present(
        _ host: DotSelectListHost,
        cardFrame: NSRect,
        appearance: NSAppearance?,
        grew: @escaping () -> Void = {}
    ) {
        stopGrowth()
        growthFinished = nil
        let windowFrame = cardFrame.insetBy(dx: -shadowInset, dy: -shadowInset)
        hosting.rootView = host
        hosting.frame = NSRect(origin: .zero, size: windowFrame.size)
        self.appearance = appearance
        alphaValue = 1
        setFrame(windowFrame, display: false)
        presentedModel = host.model
        growthFinished = grew
    }

    /// Grows the card from the edge it hangs from, as a compositing transform.
    ///
    /// The scale is a transform on the content's backing layer rather than a
    /// geometry in SwiftUI: a scale there reaches AppKit as a frame transform, and
    /// AppKit answers by re-deriving the clip view under the list, leaving its
    /// scroll offset 0, 0.5 or 1 point away from the one the list opened on. A
    /// sublayer transform scales the drawing only, so no frame, no bounds and no
    /// clip origin changes as the card grows.
    ///
    /// - Parameter anchor: the unit point of the card's own edges that stays
    ///   still: `.top` when the card hangs below its trigger, `.bottom` when it
    ///   opens above it.
    private func scaleOpen(from anchor: UnitPoint) {
        stopGrowth()
        guard !DotMotion.reducesMotion, let layer = hosting.layer else {
            finishGrowth()
            return
        }
        let width = layer.bounds.width
        let height = layer.bounds.height
        guard width > 0, height > 0 else {
            finishGrowth()
            return
        }
        // The anchor names a point on the drawn card, which counts from its top;
        // the transform's own space does not. Measured on this panel, a point at
        // `drawn.y - height` is the card's top edge, which is the edge the card
        // hangs from and therefore the one that stays still.
        let drawn = CGPoint(x: anchor.x * width, y: anchor.y * height)
        hosting.growthOrigin = drawn
        presentedModel?.isGrowing = true
        let origin = CGPoint(x: drawn.x, y: drawn.y - height)
        let grow = CATransform3DConcat(
            CATransform3DConcat(
                CATransform3DMakeTranslation(origin.x, origin.y, 0),
                CATransform3DMakeScale(Self.openingScale, Self.openingScale, 1)
            ),
            CATransform3DMakeTranslation(-origin.x, -origin.y, 0)
        )
        let animation = CABasicAnimation(keyPath: "sublayerTransform")
        animation.fromValue = NSValue(caTransform3D: grow)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = Self.openingDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.sublayerTransform = CATransform3DIdentity
        layer.add(animation, forKey: Self.growthKey)
        growthTask?.cancel()
        growthTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.openingDuration))
            guard let self, !Task.isCancelled else { return }
            self.finishGrowth()
        }
    }

    /// Stops the growth, wherever it is, and returns the content to its own
    /// geometry.
    ///
    /// A card that is closed, reopened, or opened under Reduce Motion must not
    /// inherit the transform of a growth that is still running: an animation left
    /// on the layer draws the card small for good, and with no recorded origin it
    /// would leave presses unmapped as well.
    private func stopGrowth() {
        growthTask?.cancel()
        growthTask = nil
        hosting.layer?.removeAnimation(forKey: Self.growthKey)
        hosting.layer?.sublayerTransform = CATransform3DIdentity
        hosting.growthOrigin = nil
        presentedModel?.isGrowing = false
    }

    /// Ends the growth, once, and hands over to the work it was waiting for.
    private func finishGrowth() {
        let finished = growthFinished
        growthFinished = nil
        stopGrowth()
        finished?()
    }

    /// Draws the list already showing the row it opens on, and then grows the card
    /// open.
    ///
    /// The offset is arithmetic on the rows and the clip's height
    /// (``DotSelectPlacement/openOffset(rowHeights:selected:viewport:)``), so the
    /// panel is laid out here and the list's clip view is scrolled to it, rather
    /// than asking SwiftUI to scroll once the card is on screen and letting the
    /// first frame show the top. The layout pass is forced because a panel reused
    /// at the same size still holds the list it drew last until it is laid out
    /// again, and a card that is not built yet is given one more turn. The scroll
    /// model is told where the list is in the same breath, so the two fades and the
    /// bar describe the frame the rows are drawn in. A panel reused from the last
    /// list also loses the offset that list was left at.
    ///
    /// - Parameters:
    ///   - rowHeights: the height of every row, in order.
    ///   - selected: the row the list opens on.
    ///   - scroll: the scroll model the card draws its edges from.
    ///   - anchor: the edge the card grows from.
    ///   - isCurrent: whether the open that asked for the place is still the
    ///     panel's. A retry from an open the controller has replaced is dropped.
    func showOpening(
        rowHeights: [CGFloat],
        selected: Int?,
        scroll: DotSelectScrollModel,
        growsFrom anchor: UnitPoint,
        isCurrent: @escaping () -> Bool = { true }
    ) {
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        Self.placeOpeningWhenBuilt(
            in: hosting,
            scroll: scroll,
            rowHeights: rowHeights,
            selected: selected,
            relayout: { [weak self] in
                self?.hosting.needsLayout = true
                self?.hosting.layoutSubtreeIfNeeded()
            },
            isCurrent: isCurrent
        )
        scaleOpen(from: anchor)
    }

    /// Places the list, and gives a card that has not been built one more turn.
    ///
    /// The panel installs its content and lays it out in the same turn, but a card
    /// can arrive a turn later; the offset is applied then. Only a list that is
    /// still missing after that turn is reported.
    ///
    /// - Parameters:
    ///   - hosting: the view the card is drawn in.
    ///   - scroll: the scroll model the card draws its edges from.
    ///   - rowHeights: the height of every row, in order.
    ///   - selected: the row the list opens on.
    ///   - relayout: lays the card out again before the second look.
    ///   - isCurrent: whether the open that asked for the place is still the
    ///     panel's. The retry is dropped when it is not, so an offset from the
    ///     old list is never placed on the new one.
    static func placeOpeningWhenBuilt(
        in hosting: NSView,
        scroll: DotSelectScrollModel,
        rowHeights: [CGFloat],
        selected: Int?,
        relayout: @escaping () -> Void = {},
        isCurrent: @escaping () -> Bool = { true }
    ) {
        if skipsFirstPlacement {
            skipsFirstPlacement = false
        } else if placeOpening(in: hosting, scroll: scroll, rowHeights: rowHeights, selected: selected) {
            return
        }
        Task { @MainActor in
            guard isCurrent() else { return }
            retriesPastTheCheck += 1
            relayout()
            guard isCurrent() else { return }
            if !placeOpening(in: hosting, scroll: scroll, rowHeights: rowHeights, selected: selected) {
                DotSelectLog.reportMissingList()
            }
        }
    }

    /// Places the list inside a laid-out card at the row it opens on.
    ///
    /// A card that has not been built has no scroll view to place against: the
    /// open leaves the list at the top and says so once, rather than giving an
    /// offset to a list that does not exist.
    ///
    /// - Parameters:
    ///   - hosting: the view the card is drawn in.
    ///   - scroll: the scroll model the card draws its edges from.
    ///   - rowHeights: the height of every row, in order.
    ///   - selected: the row the list opens on.
    /// - Returns: whether a list was found to place.
    @discardableResult
    static func placeOpening(
        in hosting: NSView,
        scroll: DotSelectScrollModel,
        rowHeights: [CGFloat],
        selected: Int?
    ) -> Bool {
        guard let spinner = scroll.reporter?.listScrollView ?? scrollView(in: hosting) else {
            return false
        }
        let clip = spinner.contentView
        let offset = DotSelectPlacement.openOffset(
            rowHeights: rowHeights,
            selected: selected,
            viewport: clip.bounds.height
        )
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: offset))
        spinner.reflectScrolledClipView(clip)
        let measured = spinner.documentView?.frame.height ?? 0
        scroll.moved(
            offset: clip.bounds.origin.y,
            contentHeight: measured > 0
                ? measured
                : rowHeights.reduce(0, +) + 2 * DotSelectPlacement.inset,
            viewportHeight: clip.bounds.height
        )
        return true
    }

    /// Routes a press to the row drawn under the pointer.
    ///
    /// While the card grows open the events carry the point a person aimed at,
    /// and the frames SwiftUI hit-tests are the card at its own size: a press two
    /// points inside the edge of a drawn row is up to nine points away from that
    /// row's frame at the first frame, which is enough to choose the row next to
    /// it. The location is mapped back through the growth before the window routes
    /// the event, so the hit test and the row SwiftUI picks are the ones drawn
    /// under the pointer. At rest the scale is one and the event is untouched.
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(restingEvent(event))
    }

    /// The event with the point the card's own geometry has under the pointer.
    ///
    /// Only a left press, drag or release is relocated, and only while the card
    /// grows: those are the events that choose a row. The rebuilt event carries the
    /// button, the modifiers, the click count and the pressure, but not the scroll
    /// deltas or the tablet payload: a drag cannot start a meaningful gesture inside
    /// the 0.14 s growth, and a wheel does not choose a row.
    private func restingEvent(_ event: NSEvent) -> NSEvent {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            break
        default:
            return event
        }
        let location = hosting.restingPoint(fromWindow: event.locationInWindow)
        guard location != event.locationInWindow else { return event }
        return NSEvent.mouseEvent(
            with: event.type,
            location: location,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        ) ?? event
    }

    /// The point the card's growth leaves still, in the content's coordinates,
    /// when an open is growing the card.
    var growthOrigin: CGPoint? { hosting.growthOrigin }

    /// The row a screen point falls on, as the list is drawn.
    ///
    /// The rows are drawings rather than views, so the row is found from the same
    /// arithmetic the open places them with: the point is taken into the list's
    /// content, where row `i` starts at the card's inset plus the heights of the
    /// rows above it.
    ///
    /// - Parameters:
    ///   - screenPoint: the point, in screen coordinates.
    ///   - rowHeights: the height of every row, in order.
    /// - Returns: the row, or `nil` when the point is outside the list.
    func row(underPointerAt screenPoint: CGPoint, rowHeights: [CGFloat]) -> Int? {
        guard let spinner = presentedModel?.scroll.reporter?.listScrollView
                ?? Self.scrollView(in: hosting)
        else { return nil }
        let clip = spinner.contentView
        let inContent = hosting.convert(convertPoint(fromScreen: screenPoint), from: nil)
        let inClip = clip.convert(inContent, from: hosting)
        guard clip.bounds.contains(inClip) else { return nil }
        // The clip counts down from its top when the document is flipped, which is
        // the orientation every offset in this file is measured in.
        let fromTop = clip.isFlipped ? inClip.y : clip.bounds.height - inClip.y
        var top = DotSelectPlacement.inset
        let document = clip.bounds.origin.y + fromTop
        for (index, height) in rowHeights.enumerated() {
            if document < top + height { return index }
            top += height
        }
        return nil
    }

    /// The first scroll view in a view's subtree, which is the list's own.
    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }

    /// Lets go of the list's rows and its closures while the window is hidden.
    func releaseContents() {
        growthFinished = nil
        stopGrowth()
        presentedModel = nil
        hosting.rootView = .empty
    }

    override func close() {
        growthFinished = nil
        stopGrowth()
        super.close()
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
    /// The point the card's growth leaves still, in this view's own coordinates.
    ///
    /// The panel sets it when the card starts to grow, and it is the point the
    /// layer's transform is taken about.
    var growthOrigin: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Where a point on the drawn card is in the card's own geometry.
    ///
    /// While the card grows open it is drawn through a transform on its layer,
    /// and the frames under it are the card at its own size, so a point on the
    /// drawing is mapped back through the growth. At rest the scale is one and
    /// nothing moves.
    func restingPoint(fromWindow point: NSPoint) -> CGPoint {
        guard let growthOrigin,
              let scale = layer?.presentation()?.sublayerTransform.m11,
              scale > 0, scale != 1
        else { return point }
        let drawn = convert(point, from: nil)
        let resting = CGPoint(
            x: growthOrigin.x + (drawn.x - growthOrigin.x) / scale,
            y: growthOrigin.y + (drawn.y - growthOrigin.y) / scale
        )
        return convert(resting, to: nil)
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
    /// The corner of a row's highlight, which is also the card's radius less
    /// its own inset: the wash follows the card's curve without touching it.
    static let rowCorner: CGFloat = 4
    /// The corner of the card, shared by its seat and the scrolling content.
    ///
    /// The trigger is the only field a menu is attached to, and it draws at
    /// eight; a list at ten read as a second, softer control opening under it.
    static let corner: CGFloat = 8
    /// The height of the fade that says the list continues past an edge. It is
    /// a gradient over the last line of a cut row, so it stays under that
    /// line's own height: ten points dim the row's foot without hiding it.
    static let fade: CGFloat = 10
    static let scrollerWidth: CGFloat = 4
    /// The air between the bar and the card's trailing edge.
    static let scrollerInset: CGFloat = 3
    /// The air the bar's track keeps at the card's top and bottom.
    ///
    /// The bar is a measure of the list, not a border: six points of card at
    /// either end is what keeps its rounded foot from reading as the card's
    /// own corner, and no thumb is drawn outside that track whatever the list's
    /// height.
    static let scrollerTrackInset: CGFloat = 6
    /// The tone of the track: present at rest, quiet enough to sit under the
    /// rows rather than beside them.
    static let scrollerTrackOpacity: CGFloat = 0.11
    /// The tone of the bar while the list moves.
    static let scrollerThumbActiveOpacity: CGFloat = 0.55
    /// The tone of the bar once the list rests. It stays: the bar is the half of
    /// the cue that says how much is left, and a list that showed no bar at rest
    /// looked like a list that had ended.
    static let scrollerThumbRestingOpacity: CGFloat = 0.40

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
