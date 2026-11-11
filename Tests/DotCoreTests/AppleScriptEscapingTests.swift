import AppKit
import Foundation
import XCTest

@testable import DotCore

/// Model text becomes an AppleScript literal, never AppleScript source.
///
/// The escaping is the boundary that keeps a reminder title from changing a
/// script. The tests do two things: fuzz the escaper with the characters that
/// break naive quoting, and ask the real AppleScript compiler whether the result
/// is a literal and whether it round-trips to the same string.
final class AppleScriptEscapingTests: XCTestCase {
    /// A set of characters chosen because each one has broken a quoting scheme
    /// somewhere: the two escapes, the line breaks, the continuation character,
    /// a control character, quotes a person actually types, and scripts that do
    /// not use the Latin alphabet.
    private let hostile: [String] = [
        "plain",
        #"a"b"#,
        #"a\b"#,
        #"a\\"b"#,
        "line\nbreak",
        "carriage\rreturn",
        "tab\there",
        "not\u{00AC}sign",
        "semi;colon",
        "quote\"semi;do shell script \"x\"",
        "control\u{01}char",
        "line\u{2028}separator",
        "emoji \u{1F600}",
        "日本語のタイトル",
        "مرحبا",
        "",
    ]

    func testAPlainStringIsOneLiteral() {
        XCTAssertEqual(AppleScriptText.literal("plain"), #""plain""#)
    }

    func testAQuoteIsEscaped() {
        XCTAssertEqual(AppleScriptText.literal(#"a"b"#), #""a\"b""#)
    }

    func testABackslashIsEscaped() {
        XCTAssertEqual(AppleScriptText.literal(#"a\b"#), #""a\\b""#)
    }

    func testANewlineNeverStaysInTheSource() {
        let literal = AppleScriptText.literal("a\nb")
        XCTAssertFalse(literal.contains("\n"))
        XCTAssertEqual(literal, #""a\nb""#)
    }

    func testAControlCharacterBecomesACharacterExpression() {
        let literal = AppleScriptText.literal("a\u{01}b")
        XCTAssertEqual(literal, #""a" & (character id 1) & "b""#)
    }

    func testTheContinuationCharacterStaysInsideTheLiteral() {
        // `¬` at the end of a line continues an AppleScript statement. Inside a
        // single-line literal it is data; the test pins that it stays there.
        XCTAssertEqual(AppleScriptText.literal("not\u{00AC}sign"), #""not¬sign""#)
    }

    func testTheEscaperCapsTheValue() {
        let long = String(repeating: "a", count: AppleScriptText.maximumCharacters + 50)
        let literal = AppleScriptText.literal(long)
        XCTAssertEqual(literal.count, AppleScriptText.maximumCharacters + 2)
    }

    func testEveryHostileStringCompilesAndRoundTrips() throws {
        for value in hostile where value.unicodeScalars.count <= AppleScriptText.maximumCharacters {
            let source = "set x to \(AppleScriptText.literal(value))\nreturn x"
            let result = try run(source)
            XCTAssertEqual(result, value, "Round trip failed for \(debugName(value))")
        }
    }

    func testFuzzedValuesCompileAndRoundTrip() throws {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        let alphabet: [Character] = Array("ab\"\\\n\r\t¬;()&'`\u{01}\u{1F600}日")
        for _ in 0..<40 {
            let length = Int.random(in: 0...20, using: &generator)
            let value = String((0..<length).map { _ in alphabet.randomElement(using: &generator) ?? "a" })
            let source = "set x to \(AppleScriptText.literal(value))\nreturn x"
            XCTAssertEqual(try run(source), value)
        }
    }

    func testAHostileTitleStaysInsideItsLiteral() throws {
        // The shape an injection takes: close the string, run a command, open a
        // new string. The escaper must turn every quote into data.
        let hostileTitle = #"" & (do shell script "echo pwned") & ""#
        let program = NotesScripts.create(title: hostileTitle, body: "body", folder: "Notes")
        XCTAssertTrue(program.source.contains("name:\(AppleScriptText.literal(hostileTitle))"))
        XCTAssertEqual(try run("set x to \(AppleScriptText.literal(hostileTitle))\nreturn x"), hostileTitle)
    }

    /// Every fixed template compiles without a syntax error.
    func testEveryTemplateCompiles() throws {
        let programs: [AppleScriptProgram] = [
            NotesScripts.create(title: "t", body: "b", folder: "f"),
            NotesScripts.append(title: "t", body: "b"),
            NotesScripts.search(query: "q", limit: 5),
            NotesScripts.probe(),
            MusicScripts.playback(.toggle),
            MusicScripts.playPlaylist(named: "p"),
            MusicScripts.playTrack(matching: "q"),
            MusicScripts.currentTrack(),
            MusicScripts.probe(),
            SpotifyScripts.playback(.next),
            SpotifyScripts.playURI("spotify:playlist:abc123"),
            SpotifyScripts.currentTrack(),
            SpotifyScripts.probe(),
            MailScripts.draft(to: "a@b.com", subject: "s", body: "b"),
            MailScripts.probe(),
            MessagesScripts.send(to: "+15551234567", body: "b"),
            MessagesScripts.open(),
            MessagesScripts.probe(),
            SystemScripts.volume(40),
            SystemScripts.muted(true),
            SystemScripts.darkMode(true),
            SystemScripts.readDarkMode(),
            SystemScripts.probe(),
        ]
        for program in programs where program.target != .spotify || Self.spotifyIsInstalled {
            XCTAssertNoThrow(try compile(program.source), "Template did not compile: \(program.target?.rawValue ?? "none")")
        }
    }

    /// Spotify's terms compile only against its dictionary, so a machine
    /// without the app (a CI runner) cannot check those templates.
    private static var spotifyIsInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
    }

    // MARK: - AppleScript

    private func script(_ source: String) -> NSAppleScript? {
        NSAppleScript(source: source)
    }

    /// Compiles source without running it.
    private func compile(_ source: String) throws {
        guard let script = script(source) else {
            throw ScriptTestError.compilation
        }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            throw ScriptTestError.compilation
        }
    }

    /// Runs a script that returns a string and returns it.
    private func run(_ source: String) throws -> String {
        guard let script = script(source) else { throw ScriptTestError.compilation }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error {
            throw ScriptTestError.execution(error.description)
        }
        guard let text = descriptor.stringValue else { throw ScriptTestError.notAString }
        return text
    }

    private func debugName(_ value: String) -> String {
        value.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }
}

private enum ScriptTestError: Error {
    case compilation
    case execution(String)
    case notAString
}

/// A generator a failing fuzz case can be reproduced from.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
