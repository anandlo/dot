import AppKit
import DotCore
import SwiftUI

/// The panel the dictation palette lives in.
///
/// It is a non-activating panel, like the HUD card: the panel itself never
/// takes focus from the app the person is working in. The app is activated only
/// while the palette is open — a search field cannot be typed into by an app
/// that is not receiving key events — and the application that was frontmost is
/// activated again on every dismissal, so focus always returns where it was.
final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// What the palette is showing, and which row is chosen.
@MainActor
final class PaletteModel: ObservableObject {
    /// One row of the list.
    struct Row: Identifiable, Equatable {
        /// The offset of the transcript in the history it came from.
        let id: Int
        /// The whole transcript, which is what gets inserted.
        let text: String
        /// The transcript on one line.
        let preview: String
        /// How old the transcript is, e.g. `"2h ago"`; `nil` when unknown.
        let age: String?

        static func == (first: Row, second: Row) -> Bool {
            first.id == second.id
                && first.text == second.text
                && first.preview == second.preview
                && first.age == second.age
        }
    }

    /// The rows a person can see.
    @Published private(set) var rows: [Row] = []
    /// The chosen row.
    @Published private(set) var selection = 0
    /// What has been typed into the search field.
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            refresh(resetSelection: true)
        }
    }

    private var entries: [HistoryStore.Entry] = []
    /// The clock the ages are read from. A test can stop it.
    private let now: () -> Date

    /// Creates the model.
    ///
    /// - Parameter now: the current time, used for the ages.
    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Fills the palette with a history and empties the search field.
    ///
    /// - Parameter entries: the history, newest first.
    func present(entries: [HistoryStore.Entry]) {
        self.entries = entries
        // The assignment is deliberate even when the field is already empty:
        // a second summon must not keep the query of the first.
        if query.isEmpty {
            refresh(resetSelection: true)
        } else {
            query = ""
        }
    }

    /// The chosen row, or `nil` when the list is empty.
    var selectedRow: Row? {
        rows.indices.contains(selection) ? rows[selection] : nil
    }

    /// Moves the selection, wrapping at both ends.
    func move(by step: Int) {
        selection = TranscriptSearch.advanced(selection, by: step, count: rows.count)
    }

    /// Chooses one row by its offset.
    func select(id: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        selection = index
    }

    /// Recomputes the rows from the history and the query.
    ///
    /// - Parameter resetSelection: whether the selection goes back to the best
    ///   match. A new query is a new question, so it does; a new history is
    ///   not, so the row the person was on stays chosen.
    func refresh(resetSelection: Bool = false) {
        let matches = TranscriptSearch.matches(query, in: entries.map(\.text))
        let moment = now()
        rows = matches.map { match in
            let entry = entries[match.index]
            return Row(
                id: match.index,
                text: match.text,
                preview: TranscriptSearch.preview(of: match.text),
                age: PaletteAge.string(since: entry.addedAt, now: moment)
            )
        }
        if resetSelection || rows.isEmpty {
            selection = 0
        } else {
            selection = min(selection, rows.count - 1)
        }
    }
}

/// The palette's surface: a search field over the recent transcripts.
///
/// It draws on paper, like every window: the HUD is the only dark surface in
/// the app, and the palette is a window that happens to float.
@MainActor
struct PaletteView: View {
    @ObservedObject var model: PaletteModel
    /// Inserts one transcript at the cursor.
    let insert: (String) -> Void
    /// Copies one transcript without inserting it.
    let copy: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var hoveredID: Int?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            hairline
            list
            hairline
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                .fill(DotTheme.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous)
                .strokeBorder(DotTheme.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DotTheme.cardCorner, style: .continuous))
        .onAppear { focusSearch() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictation palette")
    }

    /// The field the panel focuses when it opens.
    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(searchFocused ? DotTheme.accent : DotTheme.ink3)
                .frame(width: 15)
                .accessibilityHidden(true)

            TextField("Search dictations", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(DotTheme.ink)
                .focused($searchFocused)
                .accessibilityLabel("Search dictations")
                .accessibilityHint("Filters the recent dictations as you type.")

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    focusSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DotTheme.ink3.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            Text("Esc")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(DotTheme.ink3)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(DotTheme.keycapFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(DotTheme.keycapBorder, lineWidth: 1)
                )
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    @ViewBuilder
    private var list: some View {
        if model.rows.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 4) {
                    ForEach(model.rows) { row in
                        self.row(row)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ row: PaletteModel.Row) -> some View {
        let isSelected = model.selectedRow?.id == row.id
        let isHovered = hoveredID == row.id
        return Button {
            model.select(id: row.id)
            insert(row.text)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                // One line per transcript: a row is a way to recognise the
                // words, and the whole transcript is what gets inserted.
                Text(row.preview)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DotTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let age = row.age {
                    Text(age)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DotTheme.ink3)
                        .frame(minWidth: 46, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                            ? DotTheme.cardSelectedFill
                            : (isHovered ? DotTheme.cardHoverFill : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected ? DotTheme.cardBorderSelected : .clear,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? row.id : (hoveredID == row.id ? nil : hoveredID)
        }
        .accessibilityLabel(row.preview)
        .accessibilityValue(row.age ?? "")
        .accessibilityHint("Inserts this dictation at the cursor.")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The palette with nothing to show: no history at all, or a query that
    /// matched none of it.
    private var emptyState: some View {
        VStack(spacing: 4) {
            Text(model.query.isEmpty ? "No dictations yet" : "No matches")
                .font(DotTheme.sectionFont)
                .foregroundStyle(DotTheme.ink)
            Text(
                model.query.isEmpty
                    ? "Recent dictations appear here."
                    : "Nothing matches this search."
            )
            .font(DotTheme.smallFont)
            .foregroundStyle(DotTheme.ink3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.query.isEmpty ? "No dictations yet" : "No matches")
    }

    private var footer: some View {
        HStack(spacing: 14) {
            // The key hints describe rows, so an empty palette shows none:
            // three keys that would do nothing are the loudest thing in a list
            // with nothing in it.
            if !model.rows.isEmpty {
                hint(key: "↑↓", action: "Move")
                hint(key: "Return", action: "Insert")
                hint(key: "⇧ Return", action: "Copy")
            }
            Spacer(minLength: 0)
            Text("Newest first")
                .font(.system(size: 10))
                .foregroundStyle(DotTheme.ink3)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .accessibilityHidden(true)
    }

    private func hint(key: String, action: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(DotTheme.ink2)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(DotTheme.keycapFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(DotTheme.keycapBorder, lineWidth: 0.5)
                )
            Text(action)
                .font(.system(size: 10))
                .foregroundStyle(DotTheme.ink3)
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(DotTheme.hairline)
            .frame(height: 1)
    }

    /// Puts the cursor in the search field.
    ///
    /// The panel becomes key in the same turn it is ordered front, so the field
    /// is focused twice: once now, and once after the first layout, which is
    /// when SwiftUI has a field to focus.
    private func focusSearch() {
        searchFocused = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            searchFocused = true
        }
    }
}

/// Owns the palette panel.
///
/// The controller is the only part that touches AppKit: it places the panel,
/// keeps the key monitor that gives the palette its arrows and its Escape, and
/// hands focus back to the application the person was in.
@MainActor
final class PaletteController {
    /// The size of the palette, in points.
    static let panelSize = CGSize(width: 560, height: 400)
    /// How far below the top of the usable screen the palette sits.
    static let topInset: CGFloat = 96

    private let panel: PalettePanel
    private let model: PaletteModel
    /// Whether showing the palette activates the app.
    ///
    /// A test turns it off: activating in a test would take focus away from
    /// whatever the person running the suite is doing.
    private let activates: Bool
    private var hosting: NSHostingView<AnyView>?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var previousApp: NSRunningApplication?
    private var insertHandler: ((String) -> Void)?
    private var copyHandler: ((String) -> Void)?

    /// Creates the controller.
    ///
    /// - Parameter activates: whether showing the palette activates the app so
    ///   the search field can be typed into. Production leaves it on.
    init(activates: Bool = true) {
        self.activates = activates
        model = PaletteModel()
        panel = PalettePanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level.floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
    }

    /// Whether the palette is on screen.
    var isVisible: Bool { panel.isVisible }

    /// The query currently typed. The test reads it; the app never does.
    var debugQuery: String { model.query }

    /// How many rows the current query produced.
    var debugRowCount: Int { model.rows.count }

    /// The row that is chosen. The test reads it; the app never does.
    var debugSelectedText: String? { model.selectedRow?.text }

    /// Shows the palette.
    ///
    /// - Parameters:
    ///   - entries: the history, newest first.
    ///   - insert: inserts one transcript at the cursor.
    ///   - copy: copies one transcript without inserting it.
    func show(
        entries: [HistoryStore.Entry],
        insert: @escaping (String) -> Void,
        copy: @escaping (String) -> Void
    ) {
        insertHandler = insert
        copyHandler = copy
        model.present(entries: entries)
        // The app that was in front before the palette appeared is the one
        // focus goes back to, whatever happens while it is up.
        if previousApp == nil {
            previousApp = NSWorkspace.shared.frontmostApplication
        }
        if hosting == nil {
            makeContent()
        }
        place()
        startMonitoring()
        if activates {
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.invalidateShadow()
        Log.shared.info("palette.shown", ["rows": .int(model.rows.count)])
    }

    /// Hides the palette.
    ///
    /// - Parameter restoringFocus: whether the app that was frontmost before
    ///   the palette opened is activated again. A dismissal caused by the person
    ///   moving to another app passes `false`: pulling them back would be the
    ///   palette stealing focus, which is the one thing it must never do.
    func dismiss(restoringFocus: Bool = true) {
        guard panel.isVisible else { return }
        stopMonitoring()
        let query = model.query
        panel.orderOut(nil)
        if restoringFocus, activates {
            previousApp?.activate()
        }
        previousApp = nil
        Log.shared.info("palette.hidden", [
            "rows": .int(model.rows.count),
            "filtered": .bool(!query.isEmpty),
        ])
    }

    /// Applies one key and returns what it did.
    ///
    /// The mapping lives in ``PaletteKeyboard``; this method only performs it,
    /// which is what lets a test drive Escape and Return without a keyboard.
    @discardableResult
    func perform(_ key: PaletteKey) -> PaletteCommand {
        let command = PaletteKeyboard.command(for: key, hasSelection: model.selectedRow != nil)
        switch command {
        case .moveUp:
            model.move(by: -1)
        case .moveDown:
            model.move(by: 1)
        case .insert:
            guard let row = model.selectedRow else { return command }
            // The palette leaves before the text is delivered: focus has to be
            // back in the target app when the paste keystroke is posted.
            let text = row.text
            dismiss()
            insertHandler?(text)
        case .copyOnly:
            guard let row = model.selectedRow else { return command }
            let text = row.text
            dismiss()
            copyHandler?(text)
        case .dismiss:
            dismiss()
        case .ignore:
            break
        }
        return command
    }

    /// Translates one key press into a palette key.
    ///
    /// - Returns: the key, or `nil` when the palette does not use it.
    nonisolated static func key(for event: NSEvent) -> PaletteKey? {
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 36, 76: return event.modifierFlags.contains(.shift) ? .shiftReturn : .returnKey
        case 53: return .escape
        default: return nil
        }
    }

    /// Takes one key event, and reports whether the palette consumed it.
    func handle(_ event: NSEvent) -> Bool {
        guard let key = Self.key(for: event) else { return false }
        perform(key)
        return true
    }

    // MARK: - Pieces

    private func makeContent() {
        let view = PaletteView(
            model: model,
            insert: { [weak self] text in self?.insertHandler?(text) },
            copy: { [weak self] text in self?.copyHandler?(text) }
        )
        // The panel is sized by the controller and the view fills it; the
        // hosting view must not resize the window to its fitting size.
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.hosting = hosting
    }

    /// Places the panel on the screen the pointer is on.
    private func place() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            panel.center()
            return
        }
        let mainIndex = NSScreen.main.flatMap { main in
            screens.firstIndex { $0 === main }
        }
        let index = HUDPlacement.screenIndex(
            containing: NSEvent.mouseLocation,
            frames: screens.map(\.frame),
            fallback: mainIndex
        ) ?? 0
        guard screens.indices.contains(index) else { return }
        let frame = HUDPlacement.frame(
            visibleFrame: screens[index].visibleFrame,
            panelSize: Self.panelSize,
            topInset: Self.topInset
        )
        panel.setFrame(frame, display: false)
    }

    /// Watches the keyboard and the app the person moves to.
    private func startMonitoring() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var consumed = false
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                consumed = self.handle(event)
            }
            return consumed ? nil : event
        }
        if keyMonitor == nil {
            // Without the monitor the panel still works with the mouse; only
            // the keyboard would be lost, and that is worth a line in the log.
            Log.shared.warn("palette.key.monitor.missing")
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // The person moved to another app. Leave them there.
                self?.dismiss(restoringFocus: false)
            }
        }
    }

    private func stopMonitoring() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
    }
}
