import AppKit
import DotCore
@testable import Dot
import SwiftUI
import XCTest

@MainActor
final class HistoryTranscriptListTests: XCTestCase {
    private let size = CGSize(width: 620, height: 560)

    private struct Mounted {
        let host: NSHostingView<AnyView>
        let window: OffscreenWindow
        let scrollView: NSScrollView
        let table: HistoryTranscriptTableView
        let copied: Box<[String]>
        let closed: Box<Int>
        let cleared: Box<Int>
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func mount(
        _ texts: [String],
        initialQuery: String = "",
        onClose: Box<Int>? = nil
    ) throws -> Mounted {
        FontFixture.register()
        let copied = Box<[String]>([])
        let closed = onClose ?? Box<Int>(0)
        let cleared = Box<Int>(0)
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        let host = NSHostingView(rootView: AnyView(
            HistoryView(
                history: texts,
                onCopy: { copied.value.append($0) },
                onClear: { cleared.value += 1 },
                onClose: { closed.value += 1 },
                initialQuery: initialQuery
            )
            .environment(\.historyHeadless, true)
        ))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()

        var stack: [NSView] = [host]
        var scrollView: NSScrollView?
        var table: HistoryTranscriptTableView?
        while let view = stack.popLast() {
            if scrollView == nil, let found = view as? NSScrollView { scrollView = found }
            if let found = view as? HistoryTranscriptTableView { table = found }
            stack.append(contentsOf: view.subviews)
        }
        return Mounted(
            host: host,
            window: window,
            scrollView: try XCTUnwrap(scrollView),
            table: try XCTUnwrap(table),
            copied: copied,
            closed: closed,
            cleared: cleared
        )
    }

    private func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
    }

    private func host(forRow row: Int, in table: NSTableView) -> HistoryRowCellHost? {
        table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HistoryRowCellHost
    }

    private func scrollToBottom(_ mounted: Mounted, steps: Int = 60) {
        let scroll = mounted.scrollView
        let maxY = max(0, mounted.table.frame.height - scroll.contentView.bounds.height)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        for step in 0..<steps {
            let progress = Double(step) / Double(max(1, steps - 1))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY * progress))
            scroll.reflectScrolledClipView(scroll.contentView)
            mounted.host.layoutSubtreeIfNeeded()
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        CATransaction.flush()
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String = "",
        flags: NSEvent.ModifierFlags = [],
        windowNumber: Int = 0
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    // MARK: Heights

    func testComputedHeightsMatchConstrainedRowMeasurement() throws {
        let texts = Self.heightCorpus()
        XCTAssertGreaterThanOrEqual(texts.count, 150)
        let mounted = try mount(texts)
        defer { mounted.window.close() }

        let counts = texts.map {
            HistoryTranscriptList.Coordinator.lineCount(of: $0, width: 462)
        }
        let perturbed = texts.map {
            HistoryTranscriptList.Coordinator.lineCount(of: $0, width: 442)
        }
        XCTAssertNotEqual(counts, perturbed, "a twenty point width error must change the measurement")

        func constrainedHeight(_ text: String) -> CGFloat {
            let host = NSHostingView(
                rootView: AnyView(HistoryTranscriptList.Coordinator.previewCell(text: text).frame(width: 620))
            )
            return host.fittingSize.height
        }
        let one = constrainedHeight("Line 0")
        let two = constrainedHeight("Line 0\nLine 1")
        let three = constrainedHeight("Line 0\nLine 1\nLine 2")
        XCTAssertGreaterThan(two, one, "two-line calibration collapsed")
        XCTAssertGreaterThan(three, two, "three-line calibration collapsed")

        var worst: CGFloat = 0
        for (row, text) in texts.enumerated() {
            let measuredHost = NSHostingView(
                rootView: AnyView(HistoryTranscriptList.Coordinator.previewCell(text: text).frame(width: 620))
            )
            let expected = measuredHost.fittingSize.height
            let actual = mounted.table.delegate?.tableView?(mounted.table, heightOfRow: row) ?? -1
            let delta = abs(actual - expected)
            worst = max(worst, delta)
            XCTAssertLessThanOrEqual(delta, 0.5, "row \(row) text: \(text)")
        }
        print("HISTORY-HEIGHTS rows=\(texts.count) worst_delta=\(String(format: "%.3f", worst))pt")
    }

    private static func heightCorpus() -> [String] {
        var texts: [String] = [
            "Yes",
            "a",
            "Word",
            "One two three four five six seven eight nine ten eleven twelve",
            "First line\nSecond line after an explicit newline.\nThird line closes the row.",
            "请把这段中文历史记录保留在窗口中，不要改变它的行距和字体。这是一段更长的文本，用来测试换行与高度。",
            "Remember the emoji 🧠 in this transcript and the trailing words so the row wraps onto several lines.",
            "https://example.com/a/very/long/unbroken/url/that/never/gets/a/space/and/forces/the/layout/engine/to/break/inside/the/path",
        ]
        let words = [
            "alpha", "brisk", "context", "dictation", "evening", "format", "gravity",
            "history", "inside", "jacket", "keyboard", "length", "meeting", "notes",
            "outside", "paper", "quality", "record", "smooth", "transcript", "under", "voice",
        ]
        for length in 1...90 {
            let text = (0..<length).map { words[$0 % words.count] }.joined(separator: " ")
            texts.append("Boundary \(length): \(text)")
        }
        for length in 1..<60 {
            let prefix = String(repeating: "abcdefghij", count: length / 10 + 1).prefix(length)
            texts.append("Unbroken \(length): \(prefix)")
        }
        return texts
    }

    // MARK: Reuse and state

    func testScrollingReusesAControlledNumberOfCells() throws {
        let entries = (0..<250).map { "Transcript line \($0): Testing smooth scrolling performance without frame drops." }
        let mounted = try mount(entries)
        defer { mounted.window.close() }
        scrollToBottom(mounted)

        let hosts = allViews(in: mounted.table).compactMap { $0 as? HistoryRowCellHost }
        XCTAssertLessThanOrEqual(hosts.count, 16, "\(hosts.count) cell hosts were created")
        print("HISTORY-REUSE hosts=\(hosts.count) rows=250")
    }

    func testReusedCellsDoNotLeakHoverOrCopiedState() throws {
        let entries = (0..<250).map { "Transcript line \($0): Testing smooth scrolling performance without frame drops." }
        let mounted = try mount(entries)
        defer { mounted.window.close() }

        let row = 2
        guard let hovered = host(forRow: row, in: mounted.table) else {
            return XCTFail("row 2 had no cell")
        }
        let windowPoint = mounted.table.convert(
            NSPoint(x: 100, y: mounted.table.rect(ofRow: row).midY),
            to: nil
        )
        mounted.table.coordinator?.mouseMoved(at: windowPoint, in: mounted.table)
        XCTAssertTrue(hovered.rootView.isHovered, "hover did not reach the cell")

        hovered.rootView.onCopy()
        mounted.host.layoutSubtreeIfNeeded()
        XCTAssertEqual(mounted.copied.value, [entries[row]])
        XCTAssertTrue(host(forRow: row, in: mounted.table)?.rootView.isCopied == true)

        scrollToBottom(mounted)
        for cell in allViews(in: mounted.table).compactMap({ $0 as? HistoryRowCellHost }) {
            XCTAssertFalse(cell.rootView.isHovered, "a reused cell kept hover")
            if cell.boundEntryID != row {
                XCTAssertFalse(cell.rootView.isCopied, "a reused cell kept copied state")
            }
        }
    }

    func testSyntheticClickCopiesExactlyOnce() throws {
        let mounted = try mount((0..<8).map { "Click transcript \($0)" })
        defer { mounted.window.close() }
        mounted.window.makeKey()
        defer { mounted.window.resignKey() }
        mounted.host.layoutSubtreeIfNeeded()

        let point = mounted.table.convert(
            NSPoint(x: 100, y: mounted.table.rect(ofRow: 1).midY),
            to: nil
        )
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: mounted.window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: type == .leftMouseDown ? 1 : 2,
                pressure: 1.0
            ) else { return XCTFail("could not build a mouse event") }
            mounted.window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        print("HISTORY-CLICK copies=\(mounted.copied.value)")
        XCTAssertEqual(mounted.copied.value.count, 1, "a click copied " + String(mounted.copied.value.count) + " times")
    }

    // MARK: Keyboard

    func testKeyboardSelectionCopyEscapeAndTab() throws {
        let entries = (0..<8).map { "Keyboard transcript \($0)" }
        let closed = Box<Int>(0)
        let mounted = try mount(entries, initialQuery: "Keyboard", onClose: closed)
        defer { mounted.window.close() }

        mounted.window.makeFirstResponder(mounted.table)
        XCTAssertTrue(mounted.window.firstResponder === mounted.table)
        let unselectedReturn = try XCTUnwrap(keyEvent(keyCode: 36, characters: "\r"))
        mounted.table.keyDown(with: unselectedReturn)
        XCTAssertTrue(mounted.copied.value.isEmpty, "copy without a selection did anything")
        for expectedRow in [0, 1] {
            let event = try XCTUnwrap(keyEvent(keyCode: 125))
            mounted.table.keyDown(with: event)
            XCTAssertEqual(mounted.table.selectedRow, expectedRow)
            let cell = try XCTUnwrap(host(forRow: expectedRow, in: mounted.table))
            XCTAssertTrue(cell.rootView.isFocused, "row \(expectedRow) has no focus border")
        }

        let previous = mounted.table.selectedRow
        let up = try XCTUnwrap(keyEvent(keyCode: 126))
        mounted.table.keyDown(with: up)
        XCTAssertEqual(mounted.table.selectedRow, previous - 1)

        let down = try XCTUnwrap(keyEvent(keyCode: 125))
        mounted.table.keyDown(with: down)
        let returnKey = try XCTUnwrap(keyEvent(keyCode: 36, characters: "\r"))
        mounted.table.keyDown(with: returnKey)
        XCTAssertEqual(mounted.copied.value, [entries[mounted.table.selectedRow]])

        let space = try XCTUnwrap(keyEvent(keyCode: 49, characters: " "))
        mounted.table.keyDown(with: space)
        XCTAssertEqual(mounted.copied.value.count, 2)

        let commandC = try XCTUnwrap(keyEvent(keyCode: 8, characters: "c", flags: [.command]))
        mounted.table.keyDown(with: commandC)
        XCTAssertEqual(mounted.copied.value.count, 3)

        let escape = try XCTUnwrap(keyEvent(keyCode: 53, characters: "\u{1B}"))
        mounted.table.keyDown(with: escape)
        mounted.host.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let search = allViews(in: mounted.host).first { $0 is NSTextField } as? NSTextField
        XCTAssertNotNil(search)
        XCTAssertEqual(search?.stringValue, "", "Escape did not reach the search field")
        XCTAssertEqual(closed.value, 0)

        mounted.table.keyDown(with: escape)
        XCTAssertEqual(closed.value, 1, "Escape with an empty query did not close")

        closed.value = 0
        mounted.table.cancelOperation(nil)
        XCTAssertEqual(closed.value, 1, "cancelOperation did not exit exactly once")
    }

    func testTabMovesFocusThroughSearchTableAndClear() throws {
        let fullKeyboardAccess = NSApplication.shared.isFullKeyboardAccessEnabled
        print("HISTORY-FKA enabled=\(fullKeyboardAccess)")
        let mounted = try mount((0..<5).map { "Tab transcript \($0)" }, initialQuery: "Tab")
        defer { mounted.window.close() }
        mounted.window.makeKey()
        defer { mounted.window.resignKey() }

        let search = allViews(in: mounted.host).first { $0 is NSTextField }
        XCTAssertNotNil(search, "the search field is missing")
        mounted.window.makeFirstResponder(search)

        let tab = try XCTUnwrap(keyEvent(keyCode: 48, characters: "\t", windowNumber: mounted.window.windowNumber))
        mounted.window.sendEvent(tab)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        mounted.host.layoutSubtreeIfNeeded()
        XCTAssertTrue(mounted.window.firstResponder === mounted.table, "Tab from search did not focus the table")
        XCTAssertEqual(mounted.table.selectedRow, 0, "Tab from search did not select row 0")
        XCTAssertTrue(host(forRow: 0, in: mounted.table)?.rootView.isFocused == true)

        let forward = try XCTUnwrap(keyEvent(keyCode: 48, characters: "\t", windowNumber: mounted.window.windowNumber))
        mounted.window.sendEvent(forward)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        mounted.host.layoutSubtreeIfNeeded()
        XCTAssertTrue(mounted.window.firstResponder !== mounted.table, "Tab from the table left it focused")
        if fullKeyboardAccess {
            let space = try XCTUnwrap(keyEvent(keyCode: 49, characters: " ", windowNumber: mounted.window.windowNumber))
            mounted.window.sendEvent(space)
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            XCTAssertEqual(mounted.cleared.value, 1, "Space after Tab from the table did not press Clear history exactly once")
            XCTAssertTrue(mounted.copied.value.isEmpty, "Space after Tab copied a transcript instead of pressing Clear history")
        } else {
            let forwardView = mounted.window.firstResponder as? NSView
            let forwardFrame = forwardView.map { $0.convert($0.bounds, to: mounted.host) } ?? .zero
            XCTAssertTrue(forwardFrame.minY > 70 && forwardFrame.minY < 110, "Tab from the table did not wrap to search without Full Keyboard Access")
        }

        mounted.window.makeFirstResponder(mounted.table)
        let backward = try XCTUnwrap(
            keyEvent(keyCode: 48, characters: "\t", flags: [.shift], windowNumber: mounted.window.windowNumber)
        )
        mounted.window.sendEvent(backward)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        mounted.host.layoutSubtreeIfNeeded()
        let backView = mounted.window.firstResponder as? NSView
        let backFrame = backView.map { $0.convert($0.bounds, to: mounted.host) } ?? .zero
        print("HISTORY-TAB back_class=\(backView?.className ?? "nil") back_frame=\(backFrame)")
        XCTAssertTrue(backFrame.minY > 70 && backFrame.minY < 110, "Shift-Tab from the table did not focus search")
    }

    // MARK: Scrolling and accessibility

    func testElasticityAndScrollGestureTrace() throws {
        let long = try mount((0..<250).map { "Elastic transcript \($0)" })
        defer { long.window.close() }
        XCTAssertEqual(long.scrollView.verticalScrollElasticity, .none, "a long list must stop at its edges, not rubber-band")
        XCTAssertEqual(long.scrollView.horizontalScrollElasticity, .none)

        let short = try mount(["One", "Two"])
        defer { short.window.close() }
        XCTAssertEqual(short.scrollView.verticalScrollElasticity, .none)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dot-history-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Never reopen the default log here: that is the user's real
        // ~/Library/Logs/Dot/Dot.log, and every later test would write to it.
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(Log.fileName)
        XCTAssertTrue(Log.shared.openFile(at: url))

        let scroll = long.scrollView
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        let maxY = max(0, long.table.frame.height - scroll.contentView.bounds.height)
        for step in 0..<10 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY * Double(step) / 9))
            scroll.reflectScrolledClipView(scroll.contentView)
            long.host.layoutSubtreeIfNeeded()
        }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        Log.shared.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("scroll.gesture"), "no scroll.gesture was logged")
        XCTAssertTrue(text.contains("history"), "the trace did not name the history surface")
    }

    func testThreeVisibleRowsExposeAccessibleCopyButtons() throws {
        let mounted = try mount((0..<20).map { "Accessible transcript \($0)" })
        defer { mounted.window.close() }

        var elements: [NSView] = []
        for row in 0..<3 {
            let cell = try XCTUnwrap(host(forRow: row, in: mounted.table))
            let rowElements = allViews(in: cell).filter {
                $0.isAccessibilityElement()
                    && ($0.accessibilityLabel() ?? "").hasPrefix("Transcript, ")
            }
            XCTAssertEqual(rowElements.count, 1, "row \(row) did not expose one button")
            elements.append(contentsOf: rowElements)
        }
        XCTAssertEqual(
            elements.map { $0.accessibilityLabel() ?? "" },
            (0..<3).map { "Transcript, Accessible transcript \($0)" }
        )
        for element in elements {
            XCTAssertEqual(element.accessibilityHelp(), "Copies this transcript to the clipboard.")
        }
        for element in elements {
            XCTAssertEqual(element.accessibilityRole(), .button)
            XCTAssertEqual(
                (element.accessibilityChildren() ?? []).count, 0,
                "the hosted SwiftUI button must not add a second copy action"
            )
        }
        XCTAssertTrue(elements[2].accessibilityPerformPress())
        XCTAssertEqual(mounted.copied.value, ["Accessible transcript 2"])
    }

    // MARK: Updates

    @Observable
    final class ListModel {
        var entries: [HistoryView.Entry]
        init(_ entries: [HistoryView.Entry]) { self.entries = entries }
    }

    struct ListHarness: View {
        let model: ListModel
        var body: some View {
            HistoryTranscriptList(
                entries: model.entries,
                copiedID: nil,
                rowVisible: true,
                reduceMotion: true,
                headless: true,
                onCopy: { _ in },
                onExit: {},
                onTabForward: {},
                onTabBackward: {},
                focusRequest: 0
            )
        }
    }

    private func mountList(_ model: ListModel) throws -> (OffscreenWindow, NSHostingView<ListHarness>, HistoryTranscriptTableView) {
        FontFixture.register()
        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        let host = NSHostingView(rootView: ListHarness(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let table = try XCTUnwrap(allViews(in: host).compactMap { $0 as? HistoryTranscriptTableView }.first)
        return (window, host, table)
    }

    func testFilterKeepsRowHeightsAndFocusOnTheSelectedTranscript() throws {
        let long = HistoryView.Entry(id: 1, text: (0..<6).map { "Long transcript line \($0) with enough words to wrap" }.joined(separator: " "))
        let short = HistoryView.Entry(id: 0, text: "Short")
        let tail = HistoryView.Entry(id: 2, text: "Tail")

        let reference = ListModel([long, tail])
        let (referenceWindow, _, referenceTable) = try mountList(reference)
        let expectedHeight = referenceTable.rect(ofRow: 0).height
        referenceWindow.close()
        XCTAssertGreaterThan(expectedHeight, referenceTable.rect(ofRow: 1).height + 10)

        let model = ListModel([short, long, tail])
        let (window, hosting, table) = try mountList(model)
        defer { window.close() }
        let coordinator = try XCTUnwrap(table.coordinator)
        coordinator.focusTableFromParent()
        coordinator.tableDidBecomeFirstResponder()
        coordinator.moveSelection(1)
        XCTAssertEqual(table.selectedRow, 1)

        model.entries = [long, tail]
        hosting.layoutSubtreeIfNeeded()
        CATransaction.flush()

        XCTAssertEqual(table.rect(ofRow: 0).height, expectedHeight, accuracy: 0.5)
        XCTAssertEqual(table.selectedRow, 0)
        let cell = try XCTUnwrap(host(forRow: 0, in: table))
        XCTAssertEqual(cell.boundEntryID, 1)
        XCTAssertTrue(cell.rootView.isFocused, "focus ring must follow the selected transcript")
        let other = try XCTUnwrap(host(forRow: 1, in: table))
        XCTAssertFalse(other.rootView.isFocused)
    }

    func testChangedTextUnderTheSameIDsResizesTheRow() throws {
        let longText = (0..<6).map { "Long transcript line \($0) with enough words to wrap" }.joined(separator: " ")
        let reference = ListModel([HistoryView.Entry(id: 0, text: longText), HistoryView.Entry(id: 1, text: "Tail")])
        let (referenceWindow, _, referenceTable) = try mountList(reference)
        let expectedHeight = referenceTable.rect(ofRow: 0).height
        referenceWindow.close()

        let model = ListModel([HistoryView.Entry(id: 0, text: "Short"), HistoryView.Entry(id: 1, text: "Tail")])
        let (window, hosting, table) = try mountList(model)
        defer { window.close() }
        XCTAssertLessThan(table.rect(ofRow: 0).height, expectedHeight - 10)

        model.entries = [HistoryView.Entry(id: 0, text: longText), HistoryView.Entry(id: 1, text: "Tail")]
        hosting.layoutSubtreeIfNeeded()
        CATransaction.flush()

        XCTAssertEqual(table.rect(ofRow: 0).height, expectedHeight, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(host(forRow: 0, in: table)).rootView.entry.text, longText)
    }

    func testOpeningFiveHundredRowsIsCheap() throws {
        let entries = (0..<500).map { "Open cost transcript \($0): a short line with a few more words." }
        FontFixture.register()
        let warmup = OffscreenWindow(size: size, styleMask: [.borderless])
        let warmupHost = NSHostingView(rootView: AnyView(
            HistoryView(history: ["warmup"], onCopy: { _ in }, onClear: {}, onClose: {})
                .environment(\.historyHeadless, true)
        ))
        warmupHost.frame = NSRect(origin: .zero, size: size)
        warmup.contentView = warmupHost
        warmupHost.layoutSubtreeIfNeeded()
        warmup.close()

        let window = OffscreenWindow(size: size, styleMask: [.borderless])
        defer { window.close() }
        let startedInstructions = Self.retiredInstructions()
        let started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let host = NSHostingView(
            rootView: HistoryView(history: entries, onCopy: { _ in }, onClear: {}, onClose: {})
                .environment(\.historyHeadless, true)
        )
        let afterInit = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let elapsed = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - started) / 1_000_000
        print("HISTORY-SEGMENTS init=\(Double(afterInit - started)/1_000_000) layout=\(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - afterInit)/1_000_000)")
        let instructions = Self.retiredInstructions() - startedInstructions
        print("HISTORY-OPEN rows=500 thread_cpu_ms=\(String(format: "%.2f", elapsed)) instructions=\(instructions)")
        // Retired instructions, not CPU time: the same work costs about twice
        // the CPU time on an efficiency core, which a busy host schedules it on.
        // About 610 M are retired when this passes; measuring each row with its
        // own hosting view instead of the calibrated heights retires far more.
        XCTAssertLessThan(instructions, 900_000_000, "opening 500 rows retired \(instructions) instructions")
    }

    private static func retiredInstructions() -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        precondition(status == 0, "proc_pid_rusage failed")
        return info.ri_instructions
    }
}
