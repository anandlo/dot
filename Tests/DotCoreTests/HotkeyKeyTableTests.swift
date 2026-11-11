import XCTest

@testable import DotCore

/// The two key tables must agree with the Carbon ANSI layout.
///
/// A shortcut is stored as a virtual key code and is *also* registered on the
/// US-layout code of the character it types, so a non-US layout keeps working
/// (`GlobalHotkeyManager.registerAlias`). If either table is off by one the
/// alias fires the wrong physical key, which is invisible in a label and only
/// shows up as a shortcut that answers to the neighbour of the key printed on
/// screen.
final class HotkeyKeyTableTests: XCTestCase {
    /// The canonical macOS ANSI virtual key codes from `kVK_ANSI_L` to
    /// `kVK_ANSI_Grave`.
    private static let canonical: [(keyCode: Int, label: String)] = [
        (36, "Return"),
        (37, "L"),
        (38, "J"),
        (39, "'"),
        (40, "K"),
        (41, ";"),
        (42, "\\"),
        (43, ","),
        (44, "/"),
        (45, "N"),
        (46, "M"),
        (47, "."),
        (48, "Tab"),
        (49, "Space"),
        (50, "`"),
    ]

    func testTheNamedKeysAreTheCanonicalANSILayout() {
        for expected in Self.canonical {
            XCTAssertEqual(
                HotkeyValidator.keyLabel(keyCode: expected.keyCode),
                expected.label,
                "key code \(expected.keyCode) must be named \(expected.label)"
            )
        }
    }

    func testTheANSICodesAreTheCanonicalLayout() {
        for expected in Self.canonical {
            // The three whitespace keys have no character to type, so only the
            // printable ones have an ANSI code to round-trip.
            guard expected.label.count == 1 else { continue }
            XCTAssertEqual(
                HotkeyValidator.ansiKeyCode(forCharacter: Character(expected.label)),
                expected.keyCode,
                "\(expected.label) must map to key code \(expected.keyCode)"
            )
        }
    }

    /// The letters and punctuation must round-trip through both tables: a label
    /// derived from a code, fed back to the character lookup, must give the same
    /// code.
    func testTheTwoTablesRoundTrip() {
        for expected in Self.canonical where expected.label.count == 1 {
            let label = HotkeyValidator.keyLabel(keyCode: expected.keyCode)
            guard label.count == 1, let character = label.first else {
                XCTFail("key code \(expected.keyCode) did not produce a single character")
                continue
            }
            XCTAssertEqual(
                HotkeyValidator.ansiKeyCode(forCharacter: character),
                expected.keyCode,
                "\(label) round-trips to a different key code"
            )
        }
    }

    /// The lower half of the table was already correct and must not move.
    func testTheLowerHalfOfTheTableIsUnchanged() {
        XCTAssertEqual(HotkeyValidator.keyLabel(keyCode: 0), "A")
        XCTAssertEqual(HotkeyValidator.keyLabel(keyCode: 2), "D")
        XCTAssertEqual(HotkeyValidator.keyLabel(keyCode: 9), "V")
        XCTAssertEqual(HotkeyValidator.keyLabel(keyCode: 12), "Q")
        XCTAssertEqual(HotkeyValidator.keyLabel(keyCode: 35), "P")
        XCTAssertEqual(HotkeyValidator.keyLabel(keyCode: 27), "-")
        XCTAssertEqual(HotkeyValidator.keyLabel(keyCode: 33), "[")
        XCTAssertEqual(HotkeyValidator.ansiKeyCode(forCharacter: "z"), 6)
        XCTAssertEqual(HotkeyValidator.ansiKeyCode(forCharacter: "1"), 18)
    }

    /// Every named key of the ANSI block is unique: a code names one key and a
    /// label names one code.
    func testNoTwoKeyCodesShareALabel() {
        var labels: [String: Int] = [:]
        for expected in Self.canonical {
            if let other = labels[expected.label] {
                XCTFail("\(expected.label) is both \(other) and \(expected.keyCode)")
            }
            labels[expected.label] = expected.keyCode
        }
    }

    /// The shifted pair in the table has exactly one alias per letter, so a
    /// shortcut typed as `L` can never be registered on `Return`.
    func testAShortcutOnLIsNotAShortcutOnReturn() {
        XCTAssertNotEqual(
            HotkeyValidator.ansiKeyCode(forCharacter: "l"),
            HotkeyValidator.ansiKeyCode(forCharacter: "\r"),
            "L and Return must not share a code"
        )
        XCTAssertEqual(HotkeyValidator.ansiKeyCode(forCharacter: "l"), 37)
    }
}
