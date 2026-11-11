import Foundation
import XCTest

@testable import DotCore

/// Notes and Mail: the fixed template, and the Automation status learned from it.
///
/// The script runner is a fake, so nothing is sent to another application. What
/// the tests pin is the program that would have been sent: its target, its
/// escaped values, and the sentence a refusal becomes.
final class ConnectorScriptingTests: XCTestCase {
    private func bridge(
        _ runner: FakeScriptRunner,
        service: String = "Notes"
    ) -> AppleScriptBridge {
        AppleScriptBridge(runner: runner, automation: AutomationPermission(service: service))
    }

    func testCreatingANoteSendsAnEscapedTitleToNotes() async throws {
        let runner = FakeScriptRunner(outcomes: [.ok("created")])
        let notes = NotesConnector(bridge: bridge(runner))
        let call = try validatedCall(notes, name: "notes_create", arguments: [
            "title": .string(#"Say "hi""#),
            "body": .string("line one\nline two"),
        ])
        let outcome = await notes.invoke(call)
        XCTAssertFalse(outcome.isError)
        let programs = await runner.programs
        let program = try XCTUnwrap(programs.first)
        XCTAssertEqual(program.target, .notes)
        XCTAssertTrue(program.source.contains(#"name:"Say \"hi\"""#))
        XCTAssertFalse(program.source.contains(#""Say "hi"""#), "The raw quotes must not reach the source")
    }

    func testAppendingToAMissingNoteIsReported() async throws {
        let runner = FakeScriptRunner(outcomes: [.ok("missing")])
        let notes = NotesConnector(bridge: bridge(runner))
        let call = try validatedCall(notes, name: "notes_append", arguments: [
            "title": .string("Plan"),
            "body": .string("more"),
        ])
        let outcome = await notes.invoke(call)
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("no note"))
    }

    func testSearchResultsAreRead() async throws {
        let runner = FakeScriptRunner(outcomes: [.ok("Alpha | Notes\nBeta | Work\n")])
        let notes = NotesConnector(bridge: bridge(runner))
        let call = try validatedCall(notes, name: "notes_search", arguments: ["query": .string("a")])
        let outcome = await notes.invoke(call)
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.contains("2 notes"))
        XCTAssertTrue(outcome.text.contains("Alpha"))
    }

    func testAnAutomationPermissionStartsUnknownAndIsGrantedByAProbe() async {
        let runner = FakeScriptRunner(outcomes: [.ok("ok")])
        let notes = NotesConnector(bridge: bridge(runner))
        let before = await notes.permission()
        XCTAssertEqual(before.status, .notDetermined)
        let after = await notes.requestAccess()
        XCTAssertEqual(after.status, .granted)
    }

    func testAnAutomationRefusalIsRecordedAndExplained() async throws {
        let refusal = ScriptOutcome.failed("Not authorized to send Apple events to Notes.", code: -1743)
        let runner = FakeScriptRunner(outcomes: [refusal, refusal])
        let notes = NotesConnector(bridge: bridge(runner))
        _ = await notes.requestAccess()
        let permission = await notes.permission()
        XCTAssertEqual(permission.status, .denied)
        XCTAssertTrue(permission.remedy?.contains("Automation") == true)

        let call = try validatedCall(notes, name: "notes_create", arguments: [
            "title": .string("x"),
            "body": .string("y"),
        ])
        let outcome = await notes.invoke(call)
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("System Settings"))
    }

    func testMailRefusesWhatIsNotAnAddress() async throws {
        let runner = FakeScriptRunner(outcomes: [.ok("drafted")])
        let mail = MailConnector(bridge: bridge(runner, service: "Mail"))
        for address in ["Priya", "Priya <p@example.com>", "p@example", "p@.com", "a b@example.com"] {
            let call = try validatedCall(mail, name: "mail_draft", arguments: [
                "to": .string(address),
                "subject": .string("s"),
                "body": .string("b"),
            ])
            let outcome = await mail.invoke(call)
            XCTAssertTrue(outcome.isError, "\(address) should be refused")
        }
        let programs = await runner.programs
        XCTAssertTrue(programs.isEmpty)
    }

    func testMailCreatesADraftAndNeverSends() async throws {
        let runner = FakeScriptRunner(outcomes: [.ok("drafted")])
        let mail = MailConnector(bridge: bridge(runner, service: "Mail"))
        let call = try validatedCall(mail, name: "mail_draft", arguments: [
            "to": .string("priya@example.com"),
            "subject": .string("Deck"),
            "body": .string("Here it is"),
        ])
        let outcome = await mail.invoke(call)
        XCTAssertFalse(outcome.isError)
        let programs = await runner.programs
        let source = try XCTUnwrap(programs.first?.source)
        XCTAssertTrue(source.contains("make new outgoing message"))
        XCTAssertFalse(source.contains("send theMessage"), "The draft tool must not send")
        XCTAssertTrue(outcome.text.contains("press Send"))
    }

    func testMailHasNoSendTool() {
        let mail = MailConnector(bridge: bridge(FakeScriptRunner(), service: "Mail"))
        XCTAssertEqual(mail.tools().map(\.name), ["mail_draft"])
    }
}
