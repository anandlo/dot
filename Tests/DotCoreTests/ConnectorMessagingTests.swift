import Foundation
import XCTest

@testable import DotCore

/// Messages, Music and Spotify.
///
/// Messages is the highest-stakes tool Dot has: a mistake reaches a real person
/// and cannot be undone. The tests pin the resolution rule (the handle must
/// belong to the person the model named), the refusal of an ambiguous name, and
/// the preview the confirmation shows.
final class ConnectorMessagingTests: XCTestCase {
    private func bridge(
        _ runner: FakeScriptRunner,
        service: String = "Messages"
    ) -> AppleScriptBridge {
        AppleScriptBridge(runner: runner, automation: AutomationPermission(service: service))
    }

    private let priya = ContactMatch(
        id: "c1",
        name: "Priya Patel",
        handles: ["+1 (555) 123-4567"],
        emails: ["priya@example.com"]
    )

    private let otherPriya = ContactMatch(
        id: "c2",
        name: "Priya Shah",
        handles: ["+1 (555) 999-0000"],
        emails: []
    )

    private func messages(
        _ people: [ContactMatch],
        runner: FakeScriptRunner
    ) -> MessagesConnector {
        MessagesConnector(
            bridge: bridge(runner),
            contacts: FakeContactsDirectory(people: people)
        )
    }

    func testASendRunsWhenTheHandleBelongsToTheNamedPerson() async throws {
        let runner = FakeScriptRunner(outcomes: [.ok("sent")])
        let connector = messages([priya], runner: runner)
        let call = try validatedCall(connector, name: "messages_send", arguments: [
            "name": .string("Priya"),
            "handle": .string("+15551234567"),
            "body": .string("I am late"),
        ])
        let outcome = await connector.invoke(call)
        XCTAssertFalse(outcome.isError)
        let programs = await runner.programs
        XCTAssertEqual(programs.first?.target, .messages)
        XCTAssertTrue(outcome.text.contains("Priya Patel"))
    }

    func testAHandleThatBelongsToNobodyIsRefused() async throws {
        let runner = FakeScriptRunner(outcomes: [.ok("sent")])
        let connector = messages([priya], runner: runner)
        let call = try validatedCall(connector, name: "messages_send", arguments: [
            "name": .string("Priya"),
            "handle": .string("+15550000000"),
            "body": .string("I am late"),
        ])
        let outcome = await connector.invoke(call)
        XCTAssertTrue(outcome.isError)
        let programs = await runner.programs
        XCTAssertTrue(programs.isEmpty, "A handle Contacts does not know must not be messaged")
    }

    func testAnAmbiguousNameIsResolvedByTheHandle() async throws {
        let runner = FakeScriptRunner(outcomes: [.ok("sent")])
        let connector = messages([priya, otherPriya], runner: runner)
        let call = try validatedCall(connector, name: "messages_send", arguments: [
            "name": .string("Priya"),
            "handle": .string("+15551234567"),
            "body": .string("hello"),
        ])
        let outcome = await connector.invoke(call)
        // The handle picks exactly one of the two Priyas, so the send is
        // allowed; what matters is that the handle did the picking.
        XCTAssertFalse(outcome.isError)
        let resolved = MessagesConnector.recipient(
            named: "Priya",
            handle: "+15551234567",
            in: [priya, otherPriya]
        )
        XCTAssertEqual(resolved?.id, "c1")
    }

    func testTwoPeopleWithTheSameHandleAreRefused() {
        let duplicate = ContactMatch(id: "c3", name: "Priya Shah", handles: ["+1 (555) 123-4567"], emails: [])
        XCTAssertNil(MessagesConnector.recipient(
            named: "Priya",
            handle: "+15551234567",
            in: [priya, duplicate]
        ))
    }

    func testTheConfirmationNamesThePersonTheHandleAndTheMessage() throws {
        let connector = messages([priya], runner: FakeScriptRunner())
        let call = try validatedCall(connector, name: "messages_send", arguments: [
            "name": .string("Priya Patel"),
            "handle": .string("+1 (555) 123-4567"),
            "body": .string(String(repeating: "word ", count: 30)),
        ])
        let summary = call.tool.confirmation(call.arguments)
        XCTAssertTrue(summary.contains("Priya Patel"))
        XCTAssertTrue(summary.contains("+1 (555) 123-4567"))
        XCTAssertTrue(summary.contains("..."), "A long message is shortened in the confirmation")
        XCTAssertLessThan(summary.count, 160)
    }

    func testBadHandlesAreRefusedBeforeContacts() async throws {
        let runner = FakeScriptRunner()
        let connector = messages([priya], runner: runner)
        for handle in ["not a number", "123", "+1234567890123456", "priya@"] {
            let call = try validatedCall(connector, name: "messages_send", arguments: [
                "name": .string("Priya"),
                "handle": .string(handle),
                "body": .string("hi"),
            ])
            let outcome = await connector.invoke(call)
            XCTAssertTrue(outcome.isError, "\(handle) should be refused")
        }
        let programs = await runner.programs
        XCTAssertTrue(programs.isEmpty)
    }

    func testTheOnlyMessageToolIsDestructive() {
        let connector = messages([priya], runner: FakeScriptRunner())
        XCTAssertEqual(connector.tools().map(\.name), ["messages_send"])
        XCTAssertEqual(connector.tools().first?.risk, .destructive)
    }

    func testMusicReportsAMissingPlaylist() async throws {
        let runner = FakeScriptRunner(outcomes: [.ok("missing")])
        let music = MusicConnector(bridge: bridge(runner, service: "Music"))
        let call = try validatedCall(music, name: "music_playPlaylist", arguments: ["name": .string("Focus")])
        let outcome = await music.invoke(call)
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("matched"))
    }

    func testMusicPlaybackBuildsTheRightCommand() async throws {
        let runner = FakeScriptRunner(outcomes: [.ok("ok")])
        let music = MusicConnector(bridge: bridge(runner, service: "Music"))
        let call = try validatedCall(music, name: "music_playback", arguments: ["action": .string("pause")])
        _ = await music.invoke(call)
        let programs = await runner.programs
        XCTAssertTrue(programs.first?.source.contains("pause") == true)
        XCTAssertEqual(programs.first?.target, .music)
    }

    func testSpotifyURIsAreCheckedBeforeAScriptSeesThem() {
        XCTAssertTrue(SpotifyConnector.isSpotifyURI("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"))
        XCTAssertTrue(SpotifyConnector.isSpotifyURI("spotify:track:4uLU6hMCjMI75M1A2tKUQC"))
        XCTAssertFalse(SpotifyConnector.isSpotifyURI("spotify:track:"))
        XCTAssertFalse(SpotifyConnector.isSpotifyURI("spotify:search:focus"))
        XCTAssertFalse(SpotifyConnector.isSpotifyURI("spotify:track:abc/def"))
        XCTAssertFalse(SpotifyConnector.isSpotifyURI("https://open.spotify.com/track/x"))
        XCTAssertFalse(SpotifyConnector.isSpotifyURI(" spotify:track:abc"))
    }

    func testABadSpotifyUriNeverRunsAScript() async throws {
        let runner = FakeScriptRunner()
        let spotify = SpotifyConnector(bridge: bridge(runner, service: "Spotify"))
        let call = try validatedCall(spotify, name: "spotify_playURI", arguments: ["uri": .string("https://example.com")])
        let outcome = await spotify.invoke(call)
        XCTAssertTrue(outcome.isError)
        let programs = await runner.programs
        XCTAssertTrue(programs.isEmpty)
    }
}
