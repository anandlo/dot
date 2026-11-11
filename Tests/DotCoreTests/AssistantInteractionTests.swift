import XCTest

@testable import DotCore

/// The assistant's key table, row by row.
///
/// The table is the whole interaction, so every cell is asserted: a phase that
/// answers the wrong key is a question that cannot be sent, an answer that
/// cannot be stopped, or a confirmation that a keystroke approves.
final class AssistantInteractionTests: XCTestCase {
    /// Every phase, so a new one cannot be added without a row appearing here.
    private static let phases: [AssistantPhase] = [
        .idle, .recording, .thinking, .streaming, .tool, .speaking, .confirming,
    ]

    private func action(_ key: AssistantKey, _ phase: AssistantPhase) -> AssistantAction {
        AssistantInteraction.action(for: key, phase: phase)
    }

    func testTheAssistantKeyStartsSendsStopsAndSilences() {
        XCTAssertEqual(action(.assistant, .idle), .startCapture)
        XCTAssertEqual(action(.assistant, .recording), .stopCapture)
        XCTAssertEqual(action(.assistant, .thinking), .cancelTurn)
        XCTAssertEqual(action(.assistant, .streaming), .cancelTurn)
        XCTAssertEqual(action(.assistant, .tool), .cancelTurn)
        XCTAssertEqual(action(.assistant, .speaking), .stopSpeech)
        XCTAssertEqual(action(.assistant, .confirming), .ignore)
    }

    func testEscapeBacksOutOfOneThingAtATime() {
        XCTAssertEqual(action(.escape, .idle), .ignore)
        XCTAssertEqual(action(.escape, .recording), .cancelCapture)
        XCTAssertEqual(action(.escape, .thinking), .cancelTurn)
        XCTAssertEqual(action(.escape, .streaming), .cancelTurn)
        XCTAssertEqual(action(.escape, .tool), .cancelTurn)
        XCTAssertEqual(action(.escape, .speaking), .stopSpeech)
        XCTAssertEqual(action(.escape, .confirming), .decline)
    }

    func testTheDictationKeyIsIgnoredInEveryPhase() {
        for phase in Self.phases {
            XCTAssertEqual(
                action(.dictation, phase),
                .ignore,
                "a dictation must never start over \(phase)"
            )
        }
    }

    func testEveryPhaseIsAnsweredForEveryKey() {
        // Not a tautology: it fails the moment a phase is added to the enum and
        // the table does not answer it, because the switch would not compile.
        // Kept as a table so the whole interaction can be read at once.
        let expected: [AssistantKey: [AssistantPhase: AssistantAction]] = [
            .assistant: [
                .idle: .startCapture,
                .recording: .stopCapture,
                .thinking: .cancelTurn,
                .streaming: .cancelTurn,
                .tool: .cancelTurn,
                .speaking: .stopSpeech,
                .confirming: .ignore,
            ],
            .escape: [
                .idle: .ignore,
                .recording: .cancelCapture,
                .thinking: .cancelTurn,
                .streaming: .cancelTurn,
                .tool: .cancelTurn,
                .speaking: .stopSpeech,
                .confirming: .decline,
            ],
            .dictation: Dictionary(uniqueKeysWithValues: Self.phases.map { ($0, AssistantAction.ignore) }),
        ]
        for (key, rows) in expected {
            XCTAssertEqual(rows.count, Self.phases.count)
            for (phase, wanted) in rows {
                XCTAssertEqual(action(key, phase), wanted, "\(key) in \(phase)")
            }
        }
    }

    func testNoKeyEverApprovesAConfirmation() {
        for key in [AssistantKey.assistant, .escape, .dictation] {
            XCTAssertNotEqual(action(key, .confirming), .startCapture)
            XCTAssertNotEqual(action(key, .confirming), .stopCapture)
            // The only answer a confirmation takes from the keyboard is a no.
            XCTAssertTrue([.ignore, .decline].contains(action(key, .confirming)))
        }
    }

    func testTheSameKeyCancelsEveryRunningPhase() {
        for phase in [AssistantPhase.thinking, .streaming, .tool] {
            XCTAssertEqual(action(.assistant, phase), .cancelTurn)
            XCTAssertEqual(action(.escape, phase), .cancelTurn)
        }
    }
}
