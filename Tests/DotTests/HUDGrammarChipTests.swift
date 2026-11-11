import DotCore
@testable import Dot
import XCTest

/// The chip that names the grammar a transcript was written for.
///
/// The rewrite is opt-in, so when it runs the card has to say so: a person who
/// wonders where their full stop went should be able to read the answer without
/// opening Settings.
@MainActor
final class HUDGrammarChipTests: XCTestCase {
    func testTheTranscriptCardNamesTheGrammarItWasWrittenFor() {
        let hud = HUD(offscreen: true)
        hud.showTranscript(
            text: "let x = 1",
            delivery: .pasted,
            elapsed: "0:03",
            grammar: .code
        )
        XCTAssertEqual(hud.debugGrammar, .code)
        XCTAssertFalse(hud.debugGrammarWasLong)

        // The chip belongs to the transcript: a message that replaces the card
        // must not keep it.
        hud.showMessage(text: "Copied.", symbol: "doc.on.doc")
        XCTAssertNil(hud.debugGrammar)
        XCTAssertFalse(hud.debugGrammarWasLong)
    }

    func testALongCommitSubjectSaysSo() {
        let hud = HUD(offscreen: true)
        hud.showTranscript(
            text: "Add a bounded update for the microphone calibration book and replace an old room",
            delivery: .pasted,
            elapsed: "0:08",
            grammar: .commit,
            grammarWasLong: true
        )
        XCTAssertEqual(hud.debugGrammar, .commit)
        XCTAssertTrue(hud.debugGrammarWasLong, "a long subject is reported, never cut")
    }

    func testACardWithoutAGrammarNamesNothing() {
        let hud = HUD(offscreen: true)
        hud.showTranscript(text: "Plain words.", delivery: .copied, elapsed: "0:01")
        XCTAssertNil(hud.debugGrammar)
        XCTAssertFalse(hud.debugGrammarWasLong)
    }

    func testAnInlineEditKeepsTheChip() {
        let hud = HUD(offscreen: true)
        hud.showTranscript(text: "One line.", delivery: .pasted, elapsed: "0:02", grammar: .commit)
        hud.updateTranscriptText("One line, edited.")
        XCTAssertEqual(hud.debugGrammar, .commit)
    }
}
