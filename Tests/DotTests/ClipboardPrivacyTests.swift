import AppKit
import XCTest

@testable import Dot

/// What every dictation leaves on the pasteboard.
///
/// The transcript has to sit on the pasteboard while the paste keystroke is
/// posted. Without a marking, every clipboard manager on the Mac keeps a
/// permanent, browsable copy of everything the person said, so the item is
/// flagged the way `nspasteboard.org` defines.
final class ClipboardPrivacyTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var pasteboardName: NSPasteboard.Name!

    override func setUpWithError() throws {
        pasteboardName = NSPasteboard.Name("dot.tests.\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: pasteboardName)
    }

    override func tearDownWithError() throws {
        pasteboard?.releaseGlobally()
    }

    func testATranscriptIsMarkedConcealedAndTransient() {
        Paste.copy("the quarterly numbers", to: pasteboard)

        let types = pasteboard.types ?? []
        XCTAssertTrue(
            types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")),
            "a clipboard manager would keep the dictation: \(types)"
        )
        XCTAssertTrue(
            types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")),
            "a clipboard manager would keep the dictation: \(types)"
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "the quarterly numbers")
    }

    func testARewriteIsMarkedTheSameWay() {
        // The rewrite path writes twice: the insertion, then the original back.
        Paste.copy("the insertion", to: pasteboard)
        Paste.restore("the original", ifStill: "the insertion", on: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "the original")
        XCTAssertTrue(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
    }

    func testTheOriginalIsNotRestoredOverACopyThePersonMade() {
        Paste.copy("the insertion", to: pasteboard)
        // The person copied something of their own in the meantime.
        pasteboard.clearContents()
        pasteboard.setString("something else", forType: .string)

        Paste.restore("the original", ifStill: "the insertion", on: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "something else")
    }

    func testTheWriteIsOneItemOfText() {
        Paste.copy("one transcript", to: pasteboard)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.string(forType: .string), "one transcript")
    }
}
