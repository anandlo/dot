import AppKit
import SwiftUI

/// The transcript list in the History window.
///
/// Rows are real AppKit cells so scrolling reuses a fixed set of SwiftUI hosts
/// instead of building and tearing down a view graph for every row. All row
/// state lives here, outside the reused views.
struct HistoryTranscriptList: NSViewRepresentable {
    let entries: [HistoryView.Entry]
    let copiedID: Int?
    let rowVisible: Bool
    let reduceMotion: Bool
    let headless: Bool
    let onCopy: (HistoryView.Entry) -> Void
    let onExit: () -> Void
    let onTabForward: () -> Void
    let onTabBackward: () -> Void
    let focusRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onCopy: onCopy,
            onExit: onExit,
            onTabForward: onTabForward,
            onTabBackward: onTabBackward
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 18, right: 0)
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        let table = HistoryTranscriptTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Transcript"))
        column.width = 620
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.gridStyleMask = []
        table.usesAutomaticRowHeights = false
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.focusRingType = .none
        table.wantsLayer = false

        scrollView.documentView = table
        table.frame.origin.y = 4
        table.coordinator = context.coordinator
        context.coordinator.attach(
            table: table,
            scrollView: scrollView,
            entries: entries,
            copiedID: copiedID,
            rowVisible: rowVisible,
            reduceMotion: reduceMotion,
            headless: headless,
            focusRequest: focusRequest
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            entries: entries,
            copiedID: copiedID,
            rowVisible: rowVisible,
            reduceMotion: reduceMotion,
            headless: headless,
            onCopy: onCopy,
            onExit: onExit,
            onTabForward: onTabForward,
            onTabBackward: onTabBackward,
            focusRequest: focusRequest
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private static let cellIdentifier = NSUserInterfaceItemIdentifier("HistoryTranscriptCell")

        private weak var table: HistoryTranscriptTableView?
        private weak var scrollView: NSScrollView?
        private var scrollCoordinator: DotScrollViewConfigurator.Coordinator?
        nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []
        private var entries: [HistoryView.Entry] = []
        private var copiedID: Int?
        private var rowVisible = true
        private var reduceMotion = false
        private var headless = false
        private var onCopy: (HistoryView.Entry) -> Void
        private var onExit: () -> Void
        private var onTabForward: () -> Void
        private var onTabBackward: () -> Void
        private var lastFocusRequest: Int
        private var hoveredRow: Int?
        private var focusedRow: Int?
        private var lastMouseLocation: NSPoint?
        private var measuredWidth: CGFloat = 0
        private var heights: [Int: CGFloat] = [:]
        private var lineCounts: [Int] = []

        init(
            onCopy: @escaping (HistoryView.Entry) -> Void,
            onExit: @escaping () -> Void,
            onTabForward: @escaping () -> Void,
            onTabBackward: @escaping () -> Void
        ) {
            self.onCopy = onCopy
            self.onExit = onExit
            self.onTabForward = onTabForward
            self.onTabBackward = onTabBackward
            self.lastFocusRequest = 0
        }

        deinit {
            for token in observerTokens {
                NotificationCenter.default.removeObserver(token)
            }
        }

        func attach(
            table: HistoryTranscriptTableView,
            scrollView: NSScrollView,
            entries: [HistoryView.Entry],
            copiedID: Int?,
            rowVisible: Bool,
            reduceMotion: Bool,
            headless: Bool,
            focusRequest: Int
        ) {
            self.table = table
            self.lastFocusRequest = focusRequest
            self.scrollView = scrollView
            self.entries = entries
            self.copiedID = copiedID
            self.rowVisible = rowVisible
            self.reduceMotion = reduceMotion
            self.headless = headless
            table.dataSource = self
            table.delegate = self

            let scrollCoordinator = DotScrollViewConfigurator.Coordinator(surface: "history")
            scrollCoordinator.attach(scrollView: scrollView)
            self.scrollCoordinator = scrollCoordinator

            let center = NotificationCenter.default
            observerTokens.append(center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspendHover() }
            })
            observerTokens.append(center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeHoverAfterCooldown() }
            })
            observerTokens.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if DotScrollInteraction.isScrolling {
                        self.suspendHover()
                    } else {
                        self.resumeHover()
                    }
                }
            })

            let width = columnWidth(table)
            if width > 100 {
                calibrate(width: width)
                rebuildLineCounts()
            }
            table.reloadData()
        }

        func update(
            entries: [HistoryView.Entry],
            copiedID: Int?,
            rowVisible: Bool,
            reduceMotion: Bool,
            headless: Bool,
            onCopy: @escaping (HistoryView.Entry) -> Void,
            onExit: @escaping () -> Void,
            onTabForward: @escaping () -> Void,
            onTabBackward: @escaping () -> Void,
            focusRequest: Int
        ) {
            self.onCopy = onCopy
            self.onExit = onExit
            self.onTabForward = onTabForward
            self.onTabBackward = onTabBackward
            self.rowVisible = rowVisible
            self.reduceMotion = reduceMotion
            self.headless = headless

            if focusRequest != lastFocusRequest {
                lastFocusRequest = focusRequest
                focusTableFromParent()
            }

            let oldIDs = self.entries.map(\.id)
            let newIDs = entries.map(\.id)
            let changed = oldIDs != newIDs
            let retexted = changed ? IndexSet() : IndexSet(entries.indices.filter {
                entries[$0].text != self.entries[$0].text
            })
            self.entries = entries
            self.copiedID = copiedID

            if changed {
                let difference = Self.diff(oldIDs: oldIDs, newIDs: newIDs)
                let animation: NSTableView.AnimationOptions = reduceMotion || headless ? [] : .effectFade
                rebuildLineCounts()
                table?.beginUpdates()
                table?.removeRows(at: difference.removed, withAnimation: animation)
                table?.insertRows(at: difference.inserted, withAnimation: animation)
                table?.endUpdates()
                if let table, table.selectedRow >= entries.count {
                    table.selectRowIndexes(IndexSet(), byExtendingSelection: false)
                }
                // Row removal and insertion shift AppKit's selection; the focus
                // ring follows it so Return copies the transcript it outlines.
                if focusedRow != nil, let table {
                    focusedRow = table.selectedRow >= 0 ? table.selectedRow : nil
                }
                hoveredRow = nil
                resumeHover()
            } else if !retexted.isEmpty {
                let previous = lineCounts
                rebuildLineCounts()
                let resized = retexted.filter { previous.indices.contains($0) && previous[$0] != lineCounts[$0] }
                if !resized.isEmpty {
                    table?.noteHeightOfRows(withIndexesChanged: IndexSet(resized))
                }
            }
            rebindVisibleCells()
        }

        func widthDidChange(_ width: CGFloat) {
            guard abs(width - measuredWidth) > 0.5 else { return }
            calibrate(width: width)
            rebuildLineCounts()
            table?.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: 0..<entries.count)
            )
            table?.reloadData()
        }

        func columnWidth(_ table: NSTableView) -> CGFloat {
            table.tableColumns.first?.width ?? table.bounds.width
        }

        // MARK: Rows and cells

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard lineCounts.indices.contains(row) else { return heights[1] ?? 56 }
            return heights[lineCounts[row]] ?? heights[3] ?? 56
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("HistoryTranscriptRow")
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? HistoryTranscriptRowView {
                return reused
            }
            let rowView = HistoryTranscriptRowView()
            rowView.identifier = identifier
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let host: HistoryRowCellHost
            if let reused = tableView.makeView(
                withIdentifier: Self.cellIdentifier,
                owner: nil
            ) as? HistoryRowCellHost {
                host = reused
            } else {
                host = HistoryRowCellHost()
                host.identifier = Self.cellIdentifier
                host.sizingOptions = []
                host.layer?.backgroundColor = NSColor.clear.cgColor
            }
            bind(host, to: row)
            return host
        }

        private func bind(_ host: HistoryRowCellHost, to row: Int) {
            guard entries.indices.contains(row) else { return }
            let entry = entries[row]
            let rebindsSameEntry = host.boundEntryID == entry.id
            host.boundEntryID = entry.id
            host.setAccessibilityElement(true)
            host.setAccessibilityLabel("Transcript, \(entry.text)")
            host.setAccessibilityHelp("Copies this transcript to the clipboard.")
            host.setAccessibilityValue(copiedID == entry.id ? "Copied" : "")
            host.copyAction = { [weak self] in
                guard let self else { return }
                self.onCopy(entry)
            }
            host.rootView = HistoryRowCell(
                entry: entry,
                isCopied: copiedID == entry.id,
                isHovered: hoveredRow == row,
                isFocused: focusedRow == row,
                rowVisible: rowVisible,
                reduceMotion: reduceMotion,
                headless: headless,
                animatesCopy: rebindsSameEntry,
                onCopy: { [weak self] in
                    guard let self else { return }
                    self.onCopy(entry)
                }
            )
        }

        private func rebindVisibleCells() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            var rows = IndexSet(integersIn: visible.location..<(visible.location + visible.length))
            if let hoveredRow, hoveredRow >= 0 { rows.insert(hoveredRow) }
            if let focusedRow, focusedRow >= 0 { rows.insert(focusedRow) }
            for row in rows {
                guard let host = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HistoryRowCellHost else { continue }
                bind(host, to: row)
            }
        }

        private func rebindCell(at row: Int) {
            guard let table, let host = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HistoryRowCellHost else { return }
            bind(host, to: row)
        }

        // MARK: Hover and focus

        func mouseMoved(at location: NSPoint, in table: HistoryTranscriptTableView) {
            lastMouseLocation = location
            guard !DotScrollInteraction.isScrolling else {
                setHoveredRow(nil)
                return
            }
            let local = table.convert(location, from: nil)
            setHoveredRow(table.row(at: local) >= 0 ? table.row(at: local) : nil)
        }

        func mouseExited() {
            lastMouseLocation = nil
            setHoveredRow(nil)
        }

        private func resumeHoverAfterCooldown() {
            let delay = DotScrollInteraction.cooldownDuration + 0.03
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.resumeHover() }
            }
        }

        func suspendHover() {
            setHoveredRow(nil)
        }

        func resumeHover() {
            guard !DotScrollInteraction.isScrolling,
                  let location = lastMouseLocation,
                  let table
            else { return }
            let local = table.convert(location, from: nil)
            setHoveredRow(table.row(at: local) >= 0 ? table.row(at: local) : nil)
        }

        private func setHoveredRow(_ row: Int?) {
            guard hoveredRow != row else { return }
            let previous = hoveredRow
            hoveredRow = row
            if let previous, previous >= 0 { rebindCell(at: previous) }
            if let row { rebindCell(at: row) }
        }

        func tableDidBecomeFirstResponder() {
            focusedRow = table?.selectedRow
            rebindVisibleCells()
        }

        func tableDidResignFirstResponder() {
            focusedRow = nil
            rebindVisibleCells()
        }

        func moveSelection(_ offset: Int) {
            guard let table, !entries.isEmpty else { return }
            let current = table.selectedRow
            if offset < 0 && current <= 0 {
                onTabBackward()
                return
            }
            let target = max(0, min(entries.count - 1, current + offset))
            guard target != current || current < 0 else { return }
            let previous = focusedRow
            table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            table.scrollRowToVisible(target)
            focusedRow = target
            if let previous, previous >= 0 { rebindCell(at: previous) }
            rebindCell(at: target)
        }

        func requestExit() {
            onExit()
        }

        func tabForward() {
            // SwiftUI moves focus only while its own host holds first responder.
            table?.window?.makeFirstResponder(nil)
            onTabForward()
        }

        func tabBackward() {
            table?.window?.makeFirstResponder(nil)
            onTabBackward()
        }

        func focusTableFromParent() {
            guard let table, let window = table.window else { return }
            window.makeFirstResponder(table)
            if table.selectedRow < 0, !entries.isEmpty {
                let previous = focusedRow
                table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                table.scrollRowToVisible(0)
                focusedRow = 0
                if let previous, previous >= 0 { rebindCell(at: previous) }
                rebindCell(at: 0)
            }
        }

        func copySelected() {
            guard let table, table.selectedRow >= 0,
                  entries.indices.contains(table.selectedRow)
            else { return }
            onCopy(entries[table.selectedRow])
        }

        // MARK: Sizing

        private func calibrate(width: CGFloat) {
            guard width > 0 else { return }
            measuredWidth = width
            var measured: [Int: CGFloat] = [:]
            for lines in 1...3 {
                let text = (0..<lines).map { "Line \($0)" }.joined(separator: "\n")
                measured[lines] = Self.fitHeight(text: text, width: width)
            }
            heights = measured
        }

        private static func fitHeight(text: String, width: CGFloat) -> CGFloat {
            // A fixed SwiftUI width makes the row measure its wrapped text;
            // NSHostingView.fittingSize alone measures the ideal, unwrapped text.
            let host = NSHostingView(
                rootView: AnyView(previewCell(text: text).frame(width: width))
            )
            return host.fittingSize.height
        }

        static func previewCell(text: String) -> HistoryRowCell {
            HistoryRowCell(
                entry: HistoryView.Entry(id: -1, text: text),
                isCopied: false,
                isHovered: false,
                isFocused: false,
                rowVisible: true,
                reduceMotion: true,
                headless: true,
                animatesCopy: false,
                onCopy: {}
            )
        }

        /// Wrapped line counts by text, valid for `lineCountWidth`; the row
        /// font is fixed, so text and width are the whole measurement input.
        private var lineCountCache: [String: Int] = [:]
        private var lineCountWidth: CGFloat = -1

        private func rebuildLineCounts() {
            let width = max(1, measuredWidth - 2 * DotTheme.windowPadding - 28 - 12 - 70)
            if width != lineCountWidth {
                lineCountCache.removeAll(keepingCapacity: true)
                lineCountWidth = width
            }
            lineCounts = entries.map { entry in
                if let cached = lineCountCache[entry.text] { return cached }
                let count = Self.lineCount(of: entry.text, width: width)
                lineCountCache[entry.text] = count
                return count
            }
        }

        static func lineCount(of text: String, width: CGFloat) -> Int {
            let font = DotType.nsFont(13, .medium)
            let lineHeight = font.ascender - font.descender + font.leading
            let rect = (text as NSString).boundingRect(
                with: NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: [.font: font],
                context: nil
            )
            return min(3, max(1, Int((rect.height / lineHeight).rounded())))
        }

        // MARK: Diff

        static func diff(oldIDs: [Int], newIDs: [Int]) -> (removed: IndexSet, inserted: IndexSet) {
            let rows = oldIDs.count
            let columns = newIDs.count
            var lengths = [[Int]](repeating: [Int](repeating: 0, count: columns + 1), count: rows + 1)
            for row in stride(from: rows - 1, through: 0, by: -1) {
                for column in stride(from: columns - 1, through: 0, by: -1) {
                    lengths[row][column] = oldIDs[row] == newIDs[column]
                        ? lengths[row + 1][column + 1] + 1
                        : max(lengths[row + 1][column], lengths[row][column + 1])
                }
            }

            var removed: [Int] = []
            var inserted: [Int] = []
            var row = 0
            var column = 0
            while row < rows || column < columns {
                if row < rows && column < columns && oldIDs[row] == newIDs[column] {
                    row += 1
                    column += 1
                } else if column < columns && (row == rows || lengths[row][column + 1] >= lengths[row + 1][column]) {
                    inserted.append(column)
                    column += 1
                } else {
                    removed.append(row)
                    row += 1
                }
            }
            return (IndexSet(removed), IndexSet(inserted))
        }
    }
}

// MARK: - AppKit views

struct HistoryRowCell: View {
    let entry: HistoryView.Entry
    let isCopied: Bool
    let isHovered: Bool
    let isFocused: Bool
    let rowVisible: Bool
    let reduceMotion: Bool
    let headless: Bool
    let animatesCopy: Bool
    let onCopy: () -> Void

    var body: some View {
        HistoryRowView(
            entry: entry,
            isCopied: isCopied,
            isHovered: isHovered,
            isFocused: isFocused,
            rowVisible: rowVisible,
            reduceMotion: reduceMotion,
            headless: headless,
            animatesCopy: animatesCopy,
            onCopy: onCopy
        )
        // A reused cell bound to another transcript starts with fresh button
        // press state instead of inheriting the previous row's.
        .id(entry.id)
        .padding(.horizontal, DotTheme.windowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

final class HistoryRowCellHost: NSHostingView<HistoryRowCell> {
    var boundEntryID: Int?
    var copyAction: (() -> Void)?

    convenience init() {
        self.init(rootView: HistoryTranscriptList.Coordinator.previewCell(text: ""))
    }

    override var isOpaque: Bool { false }

    // The host is the row's single accessibility element; exposing the hosted
    // button as well would give VoiceOver two copy actions per row.
    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityPerformPress() -> Bool {
        guard let copyAction else { return false }
        copyAction()
        return true
    }
}

final class HistoryTranscriptRowView: NSTableRowView {
    override var isOpaque: Bool { false }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {}
}

final class HistoryTranscriptTableView: NSTableView {
    weak var coordinator: HistoryTranscriptList.Coordinator?
    private var lastWidth: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, abs(width - lastWidth) > 0.5 else { return }
        lastWidth = width
        if let column = tableColumns.first, abs(column.width - width) > 0.5 {
            column.width = width
        }
        coordinator?.widthDidChange(width)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.userInfo?["HistoryTranscriptList"] as? Bool == true {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: ["HistoryTranscriptList": true]
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator?.mouseMoved(at: event.locationInWindow, in: self)
    }

    override func mouseEntered(with event: NSEvent) {
        coordinator?.mouseMoved(at: event.locationInWindow, in: self)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.mouseExited()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.tableDidBecomeFirstResponder() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { coordinator?.tableDidResignFirstResponder() }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 125:
            coordinator?.moveSelection(1)
        case 126:
            coordinator?.moveSelection(-1)
        case 36, 49:
            coordinator?.copySelected()
        case 8 where flags.contains(.command):
            coordinator?.copySelected()
        case 48 where flags.isEmpty:
            coordinator?.tabForward()
        case 48 where flags.contains(.shift):
            coordinator?.tabBackward()
        case 53:
            coordinator?.requestExit()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        coordinator?.requestExit()
    }
}
