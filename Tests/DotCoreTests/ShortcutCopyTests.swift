import XCTest

@testable import DotCore

/// Copy that describes the shortcut has to describe the *live* one.
///
/// The shortcut is configurable, so any sentence that writes a combination out
/// by hand is a claim that can go stale the moment someone rebinds it. Two
/// forms are covered: the glyph form (`⌥⌘D`) and the spelled form ("Option
/// Command D"), because the second is what a screen reader hears and it can
/// drift just as far from the truth.
final class ShortcutCopyTests: XCTestCase {
    /// The package root.
    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every Swift file in the app's UI layer.
    private static func uiFiles() -> [URL] {
        let start = root.appendingPathComponent("Sources/Dot", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: start, includingPropertiesForKeys: nil)
        else { return [] }
        return enumerator.compactMap { entry in
            guard let url = entry as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    /// The text inside the string literals of one line.
    private static func quotedSegments(in line: String) -> [String] {
        line.split(separator: "\"", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.offset % 2 == 1 }
            .map { String($0.element) }
    }

    /// A run of two or more modifier glyphs, which is a written-out combination
    /// rather than the one-glyph mention a rule can legitimately make.
    private static let glyphRun = try! NSRegularExpression(pattern: "[\u{2303}\u{2325}\u{21E7}\u{2318}]{2,}")

    /// The spelled form of a combination, as an accessibility hint would say it.
    private static func spellsOutCombination(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["option command", "command option", "control option", "option control"]
            .contains { lower.contains($0) }
    }

    func testNoUserFacingStringBakesAShortcut() {
        // Fixtures are exempt: a preview has to render a concrete combination,
        // and it is not copy a person reads in the running app.
        var offenders: [String] = []
        for file in Self.uiFiles() where !file.lastPathComponent.hasSuffix("Preview.swift") {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            {
                for quoted in Self.quotedSegments(in: String(line)) {
                    let range = NSRange(quoted.startIndex..<quoted.endIndex, in: quoted)
                    let bakesGlyphs = Self.glyphRun.firstMatch(in: quoted, range: range) != nil
                    guard bakesGlyphs || Self.spellsOutCombination(quoted) else { continue }
                    offenders.append("\(file.lastPathComponent):\(index + 1): \(quoted)")
                }
            }
        }
        XCTAssertEqual(
            offenders,
            [],
            "these strings write out a shortcut; the shortcut is configurable, so they must read config.hotkey instead"
        )
    }

    func testTheSpelledFormFollowsTheCombination() {
        XCTAssertEqual(Hotkey.defaultRecord.label, "⌥⌘D")
        XCTAssertEqual(Hotkey.defaultRecord.spelledOut, "Option Command D")
        XCTAssertEqual(Hotkey.defaultPaste.spelledOut, "Option Command V")

        // A binding the user made: control and shift, with a letter.
        let rebound = Hotkey(
            keyCode: 15, // kVK_ANSI_R
            modifiers: HotkeyModifiers.mask(.control, .shift),
            label: Hotkey.makeLabel(
                keyCode: 15,
                modifiers: HotkeyModifiers.mask(.control, .shift)
            )
        )
        XCTAssertEqual(rebound.label, "⌃⇧R")
        XCTAssertEqual(rebound.spelledOut, "Control Shift R")

        // The two forms describe the same binding, which is the whole point: one
        // is for the eye and one is for the ear, and neither is written by hand.
        XCTAssertEqual(
            Hotkey.makeLabel(keyCode: 2, modifiers: HotkeyModifiers.mask(.option, .command)),
            Hotkey.defaultRecord.label
        )
    }

    func testTheKeycapLabelSeparatesEveryGlyph() {
        // Drawn tight, the modifier glyphs collide into one mark: the welcome
        // window shipped a keycap nobody could read. The label every keycap
        // draws is derived from `label`, so a rebind cannot leave it behind.
        let hotkey = Hotkey.defaultRecord
        let keycap = hotkey.keycapLabel
        XCTAssertEqual(keycap.filter { $0 != "\u{200A}" }, hotkey.label)
        XCTAssertEqual(keycap.count, hotkey.label.count * 2 - 1, "every pair needs a hair space")
        for index in stride(from: 0, to: keycap.count, by: 2) {
            XCTAssertEqual(Array(keycap)[index], Array(hotkey.label)[index / 2])
        }
        // The paste shortcut spreads the same way.
        let paste = Hotkey.defaultPaste
        XCTAssertEqual(paste.keycapLabel.filter { $0 != "\u{200A}" }, paste.label)
    }
}
