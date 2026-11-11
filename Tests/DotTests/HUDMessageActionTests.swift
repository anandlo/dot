import AppKit
@testable import Dot
import DotCore
import SwiftUI
import XCTest

/// Proves a message's titled button actually runs the work it names.
///
/// The card offers "Open Settings" on a message that a permission is missing.
/// A button whose handler is dropped looks identical to a working one and does
/// nothing, which is the failure this guards: the card would tell a person how
/// to fix the problem and then ignore them when they asked it to.
@MainActor
final class HUDMessageActionTests: XCTestCase {
    func testAMessageWithAnActionCarriesItsHandler() {
        _ = NSApplication.shared

        let hud = HUD(offscreen: true)
        hud.showMessage(text: "Dot needs the microphone.", action: "Open Settings") {}
        defer { hud.hide() }

        XCTAssertNotNil(hud.debugMessageAction, "the handler was dropped")
        XCTAssertEqual(hud.debugMessageAction?.title, "Open Settings")
    }

    func testTheCarriedHandlerIsTheOneThatRuns() {
        _ = NSApplication.shared

        let hud = HUD(offscreen: true)
        var opened = false
        hud.showMessage(text: "Dot needs the microphone.", action: "Open Settings") {
            opened = true
        }
        defer { hud.hide() }

        hud.debugMessageAction?.handler()
        XCTAssertTrue(opened, "the button ran something other than its handler")
    }

    /// A message that only reports offers no button, and the width of its card
    /// does not reserve room for one.
    func testAMessageWithoutAnActionOffersNoButton() {
        _ = NSApplication.shared

        let hud = HUD(offscreen: true)
        hud.showMessage(text: "Nothing was recorded.", action: nil)
        defer { hud.hide() }

        XCTAssertNil(hud.debugMessageAction)
    }

    func testTheActionWidensTheCardForItsTitle() {
        let without = HUD.messageWidth(text: "Dot needs the microphone.")
        let with = HUD.messageWidth(text: "Dot needs the microphone.", actionTitle: "Open Settings")
        XCTAssertGreaterThan(with, without, "the titled button is drawn outside the card")
        // The button is measured, not guessed: a longer title takes more room.
        XCTAssertGreaterThan(
            HUD.messageWidth(text: "Dot needs the microphone.", actionTitle: "Open Microphone Settings"),
            with
        )
    }

    /// The next card must not inherit the previous message's button.
    func testTheHandlerDoesNotOutliveItsMessage() {
        _ = NSApplication.shared

        let hud = HUD(offscreen: true)
        hud.showMessage(text: "Dot needs the microphone.", action: "Open Settings") {}
        hud.showMessage(text: "Nothing was recorded.", action: nil)
        defer { hud.hide() }

        XCTAssertNil(hud.debugMessageAction)
    }
}
